# Listening-export import — Phase 2: Spotify import on iOS and web

*Status: active · 2026-09-02 · founder go for Track A and both parsers (B1, C1); B3 board approval pending before B4/B5; deploy deferred*
*Design: [listening-export import](../specs/2026-09-01-listening-export-import-design.md) (revision 3) · Phase 1: [server plan](2026-09-01-listening-export-p1-server.md) (code complete)*

**Founder decisions (2026-09-01/02):** both surfaces get the Spotify import, each ships when ready; iOS is the natural home (the email lands there and the archive is small); web carries paste-in, copy-out, and the embed probe later; both Spotify packages are requested and imported in either order; private sessions excluded by default with a toggle; the interview gates any pre-data mix; no email provider, Spotify's emails are the triggers; deploy is deferred and happens on explicit go.

**Phase 2 scope:** everything a Spotify listener touches, on both surfaces, against the phase-1 server: choosing a service, the request instructions and waiting state, the DJ interview and seeds, the export parser, the staged upload, the sources view, and the API-free outputs in the queue. Plus the shared fixture suite both parsers are tested against and two small server additions the clients need. Phase 3 (enrichment by id, ISRC cross-link, artwork), 4 (relay and embed probes), and 5 (Apple "go deeper") stay out.

## Binding design facts

Read the spec's "Product flow", "Client parsers", "Import protocol", and "Review follow-ups" in the phase-1 plan first. These are the facts an implementer must not drift from.

- **Nothing but the snapshot leaves the device.** No endpoint accepts a file. The parser opens only allow-listed entries (`Streaming_History_Audio_*.json`, `YourLibrary.json`, `Playlist*.json`, matched by base name at any path, case-insensitive) and never reads the bytes of any other entry; a fixture with identity and payment files present pins that their contents never reach the parser. Never log track, artist, album, or playlist names, on either surface, including in diagnostics.
- **One snapshot contract, one fixture suite.** `fixtures/listening-exports/` at the repo root holds committed archives and their exact expected `ListeningExportSnapshot` JSON (canonical order: tracks by `platformId`; days by `platformId`, `day`; library by `platformId`; artists by `name`; playlists by `ordinal`, entries by `position`). Both parsers must produce byte-identical canonical JSON for every fixture. A parser change that alters an expected file updates the fixture in the same PR and both suites must pass.
- **Parsing rules** (spec "Client parsers"): drop podcast, audiobook, and video rows and rows with no track URI (counted as unresolved); drop `ip_addr`, `platform`, `user_agent`, `offline_timestamp`, `username`; keep `conn_country` only as its most common value; drop `incognito_mode = true` rows unless the listener opted in; a play is `ms_played >= 30000`; a skip is `skipped = true`, or `reason_end = "fwdbtn"` when the flag is absent; a complete is `reason_end = "trackdone"`; derived duration is the maximum `ms_played` over completes; days and hours are local to the device time zone (IANA), which the run records. Account data: liked tracks and followed artists from the library file; each playlist keyed by `sha256(name + ordinal)` as lowercase hex; entries keep order and `addedDate`; entries with no track URI stay as name-only snapshots; ignore `StreamingHistory_*` and everything else. The snapshot's `tracks` is the union of tracks seen in any read file.
- **Time zone and day aggregation.** Convert each `ts` to the device zone once per UTC hour and cache (offsets only change on the hour), so a 200k-row history aggregates in seconds. `hoursMask` bit `h` is set when any counted play ended in local hour `h`.
- **Protocol mapping.** Extended package → begin `{ source: 'spotify_export', package: 'spotify_extended', timeZone, country, expectedTracks, expectedDays, expectedLibraryTracks: 0, expectedArtists: 0, unresolvedRows, unresolvedPlays }`, tracks in chunks of 500, days in chunks of 2000, complete. Account package → begin with `package: 'spotify_account'`, `expectedDays: 0`, tracks (union), library (liked, null counts) in 500s, artists in 500s, complete; then the playlist sync with `source: 'spotify_export'`, `storefront: null`, playlists in 50s and entries in 200s, where `appleLibraryId` is the fingerprint key, `appleLibraryEntryId` is `key:position`, `kind: 'user'`, `canEdit: false`, all artwork fields null, `sourceFingerprint` is the sha256 hex of the ordered entry ids and spotify ids, and entries carry `spotifyId`, `titleSnapshot`, `artistSnapshot`, `albumSnapshot`. Never run the Apple and Spotify playlist syncs concurrently (one open playlist run per user). Error bodies: `not_found` 404, `sync_conflict` 409, `invalid_state` 409, `count_mismatch` 409, `invalid_id` 400, `invalid_request` 400.
- **Funnel events** (`POST /me/funnel-events { type, surface }`): the client posts `chose_spotify`, `marked_requested`, `file_inspected`, `import_completed`, `first_personal_mix`, `first_output`; the server posts `interview_completed` itself. `first_personal_mix` fires once, on the first session the listener creates that comes back with `notPersonal = false` after any completed import; `first_output` fires once, on the first Spotify output action. Fire-and-forget, never blocking UI, same as session events.
- **Copy.** The request-flow, waiting-state, and inventory copy is the spec's, word for word, with each address a tappable link. The corpus banner reads "Not personal yet" wherever a session has `notPersonal = true`.
- **Outputs.** "Open in Spotify" per track when `spotifyId` is present: web `https://open.spotify.com/track/<id>` in a new tab; iOS `spotify:track:<id>` when the Spotify app can be opened, else the https link. "Copy for Spotify" (desktop web only): one `https://open.spotify.com/track/<id>` per line for every track with a Spotify id, then a one-line hint to paste into a new playlist in Spotify desktop. "Send to a transfer tool" (both): copy or share one `Artist - Title` per line and open the transfer tool's page. A queue whose tracks all lack an Apple id shows no Apple play or save control; the Spotify actions take that slot.
- **Surfaces and gates.** The web screens get a state board and a founder approval record before UI implementation (house convention, `docs/mockups/`); parsers, services, and server work do not wait for it. The Flutter app follows its existing Material patterns and needs no board. Whichever surface is ready ships first.
- **Conventions.** TDD, red first. Web: `npm test`, `npm run build` (typechecks both tsconfigs); components take the `MixtapeApi` object as a prop and the fake API in `web/src/test/fake-api.ts` must grow with it; approved design values get pinned in `styles.test.ts`. iOS: `flutter test`; user-scoped providers `ref.watch(authProvider)` in build and cancel via `ref.onDispose`; every interactive widget carries a `Key`; new Swift files need pbxproj membership in both the build-file and sources lists; Home stays the only screen that pushes routes and hosts sign-out. Server: `npx vitest run --no-file-parallelism`. Commits one line, no attribution; stage by explicit path.

## Tasks

Four tracks. A must finish before B2/C2; B3's approval gates B4/B5 only.

### Track A — shared foundation

#### A1: fixture suite
- `fixtures/listening-exports/README.md` (the contract above, how to add a case, how the builder runs), `fixtures/listening-exports/src/<case>/` JSON definitions, `fixtures/listening-exports/build.mjs` (Node, deterministic: fixed entry mtimes, sorted entries) producing `fixtures/listening-exports/<case>/archive.zip` and one `expected.<option>.json` per option in the case's `options` (`expected.default.json` always; `expected.private-included.json`, `expected.los-angeles.json`, `expected.st-johns.json` where a toggle or zone matters), and a vitest in `server/test/fixtures/listening-exports.test.ts` that runs `build.mjs --check` (expected files byte for byte, archives structurally) and the suite's `verify.test.mjs`.
- Spotify extended cases: `basic` (three tracks over two years, multiple files, plays below and above 30 s, skips with and without the flag, completes, hours mask, derived duration); `podcasts-and-local` (episode and audiobook rows, URI-less rows counted as unresolved); `private-sessions` (both expected files); `various-artists`; `timezone` (plays at 23:30 and 00:30 UTC with `Africa/Lagos` and `America/Los_Angeles` expectations); `nested-folder`; `malformed` (one file with a JSON error → parser fails closed, expected diagnostics only). Account cases: `basic` (liked tracks, followed artists, two playlists with added dates), `empty-playlist`, `duplicates`, `local-and-episode-entries`, `liked-absent-from-history`, `pii-present` (Userdata, Identity, Payments, Inferences files whose contents are sentinels the parser must never read). Layout assumption recorded in the README: file names as above at any depth; corrected from the founder's real exports before B1/C1 close.
- Commit `test: Add listening-export fixtures`.

#### A2: server additions the clients need
- Queue tracks in the sessions API (list, detail, messages, ops responses) carry `spotifyId` alongside `appleId` (`queue-store.ts` select and mappers); pool `PoolTrack.spotifyId` already exists.
- `GET /me/onboarding` → `{ sources: [...as /me/music-sources], hasLibrary: boolean (any in_library row), chosenService: 'spotify' | null (from the funnel), markedRequestedAt, interviewCompletedAt, importCompletedAt (first funnel timestamps or null) }`, so both clients render the service gate and the waiting state from one read.
- Tests as in phase 1; commit `feat(server): Expose Spotify ids and onboarding state`.

### Track B — web

#### B1: parser
- `web/src/import/`: `zip-reader.ts` (central-directory reads over a `File` via `@zip.js/zip.js` `BlobReader`, entry allow-list, never loads the whole archive), `spotify-parser.ts` (inventory, parse with `{ timeZone, includePrivateSessions, signal, onProgress }`, day aggregation with the per-UTC-hour cache, canonical snapshot), `diagnostics.ts` (file names, byte sizes, row counts, top-level keys; no values), `canonical.ts` (ordering). Runs inside a Web Worker (`parser.worker.ts`) for the page; the modules stay pure so tests run them directly.
- Tests: every fixture in `fixtures/listening-exports/` (byte-identical canonical JSON), the PII fixture asserting the reader never requested those entries, abort mid-file, and a synthetic large archive built in the test (200k rows across 15 files) with a wall-clock ceiling.
- Commit `feat(web): Spotify export parser`.

#### B2: import service and API client
- `web/src/api/client.ts`: listening import endpoints, `beginPlaylistSync` accepting `storefront: null` for `spotify_export`, `getOnboarding`, `getMusicSources`, `deleteMusicSource`, `postFunnelEvent`, `postInterview`, `getArtistSeeds`/`putArtistSeeds`, `getSeedTracks`/`postSeedTracks`/`deleteSeedTrack`; `ApiSession` gains `notPersonal`; `ApiQueueTrack` gains `spotifyId`; fake API updated.
- `web/src/import/import-service.ts` modelled on `sync/music-sync-service.ts`: snapshot → protocol mapping above, chunking, `AbortSignal` between every step, progress union, playlist sync after the listening import completes, funnel `file_inspected` and `import_completed`.
- Tests: chunk boundaries (501 tracks, 2001 days), either package, cancellation between chunks, error code mapping, playlist mapping including fingerprint and entry ids, no concurrent playlist runs.
- Commit `feat(web): Listening import service`.

#### B3: state board and approval (founder gate)
- `docs/mockups/2026-09-0X-web-spotify-import-states.html` with every state: choose service; Spotify request instructions; waiting state with "I've requested it", elapsed wait, the interview card, the paste box (desktop only), the demo tape; interview (five turns) and completion; import page (drop or pick, inventory with package/files/counts/years/time zone/private toggle, upload progress with cancel, failure with diagnostics, summary with "make a mix"); sources view (connected sources with ledger ranges, import another package, delete with confirmation); queue with Spotify actions, Copy for Spotify, transfer handoff, the "Not personal yet" banner; mobile web, dark, large text, reduced motion. Two or three directions for the request/waiting screen, one recommended. Must not collide with the pending "Your music" board; the sources view is designed as that view's Spotify state.
- On approval: `docs/mockups/approved/<date>-web-spotify-import.md` in the house format.

#### B4: screens
- Service gate after sign-in when onboarding reports no sources and no library; request and waiting screens with copy from the spec; interview; paste box (parses pasted lines into 22-char ids, posts, lists, removes); import page driving the Worker parser and the import service; sources view; funnel events; the demo tape reachable from the waiting state.
- Component tests for every approved state and breakpoint; `styles.test.ts` pins.
- Commit `feat(web): Spotify import flow`.

#### B5: queue outputs
- `spotifyId` through `ApiQueueTrack` → mapper → `QueueTrack`; per-track "Open in Spotify"; "Copy for Spotify" and "Send to a transfer tool" in the rail when any track has a Spotify id; Apple play and save hidden when no track has an Apple id; "Not personal yet" banner from `notPersonal`; `first_personal_mix` and `first_output` events.
- Commit `feat(web): Spotify mix outputs`.

### Track C — iOS

#### C1: parser
- `client/lib/import/`: `zip_reader.dart` (`package:archive` over a file with per-entry decompression, allow-list), `spotify_parser.dart` (same rules and canonical order as B1, run via `Isolate.run`), `diagnostics.dart`, `snapshot.dart` (models + canonical JSON). Time zone from `flutter_timezone`.
- Tests read `../fixtures/listening-exports/` and assert byte-identical canonical JSON for every case; PII fixture; cancellation; a synthetic large archive with a ceiling.
- New dependencies: `archive`, `flutter_timezone`. Commit `feat(client): Spotify export parser`.

#### C2: import service
- `client/lib/import/import_service.dart` modelled on `library_sync_service.dart`: same protocol mapping and chunk sizes as B2, `cancel()` checked at every await, progress callback with staged bounds, playlist sync after completion, funnel events; API additions in the data layer (`listening_api.dart`, onboarding, sources, funnel, interview, seeds).
- Tests with `MockClient` as in `library_sync_service` tests. Commit `feat(client): Listening import service`.

#### C3: screens
- Service gate between `signedIn` and `HomeScreen` when onboarding reports no sources and no library (a new gate in `main.dart`'s status switch, with Home still the only route pusher); Spotify request screen with tappable links (`url_launcher`) and "I've requested it" (funnel event + a local notification three days later via `flutter_local_notifications`, permission requested at that tap); waiting state on Home (elapsed wait, interview card, demo tape); interview screen; import flow: `file_picker` restricted to ZIP → inventory sheet → progress → summary, modelled on the library sync sheet; sources screen from the Home AppBar with delete confirmation; `Info.plist` gains the ZIP document type so Files can hand archives over (`CFBundleDocumentTypes`, `LSSupportsOpeningDocumentsInPlace`) even before C5 wires the share sheet.
- Widget and provider tests for every state; native contract test pins the Info.plist entries. New dependencies: `file_picker`, `url_launcher`, `flutter_local_notifications`. Commit `feat(client): Spotify import flow`.

#### C4: queue outputs
- `QueueTrack.spotifyId` in the models; per-row "Open in Spotify" (`LSApplicationQueriesSchemes` for `spotify`, https fallback); "Send to a transfer tool" via `share_plus`; Play and Save hidden when no track has an Apple id, replacing the current disabled-reason copy; "Not personal yet" banner; `first_personal_mix` and `first_output` events through the existing `_postEvent` pattern.
- Commit `feat(client): Spotify mix outputs`.

#### C5: open from the share sheet (after C3)
- Receive an archive shared from Files or Mail into the import flow (`receive_sharing_intent` or the document-type open path through `AppDelegate`; any new Swift file gets pbxproj membership).
- Commit `feat(client): Open export archives from Files`.

### Track D — verification and release

#### D1: suites and docs
- Server `npx vitest run --no-file-parallelism`, web `npm test` and `npm run build`, client `flutter test`; the fixture rebuild check; this plan's "Current verification"; backlog.

#### D2: founder gates, in order
1. Apply migrations 0018–0019 and deploy the Worker from a clean worktree of committed HEAD.
2. Deploy the web app (Netlify) after B4/B5; TestFlight build after C3/C4 (founder handles signing and upload).
3. Real-import smoke with the founder's own exports: iOS app, desktop Chrome, Android Chrome. Ledger ranges match the exports; play counts for three known heavy-rotation tracks match a manual count, including one under two Spotify ids; a mix generates with observed counts; re-import yields identical summaries; the funnel report shows the founder's events in order.

## Out of scope (resist)
Apple "go deeper" parsing (phase 5) · ReccoBeats-by-id enrichment stage, ISRC cross-link, oEmbed artwork (phase 3) · scrobble relay and embed player (phase 4) · Spotify branding beyond the name · email or push from Mixtape · the pending "Your music" Apple sync UI (separate track) · Android native · replacing interview notes on re-run (phase-2 UI decision recorded in the phase-1 plan; default is append).

## Review follow-ups

- A2 review: `GET /me/onboarding` reports `chosenService` as `'spotify' | 'apple' | null`, wider than the plan's `'spotify' | null`; `'apple'` is inferred from a live or exported Apple library and lets both clients skip the service gate for existing Apple listeners. A Spotify import source counts as Spotify even without the funnel event (fix round).
Recorded from phase-1 reviews for this phase: `ApiSession.notPersonal` and `spotifyId` on queue tracks (A2, B2, C4); clients must refetch a session after a message turn to learn it went corpus-mode; the playlist browse summary lacks `user_playlists.source`, so a mixed listing cannot badge per source until a later server addition; malformed JSON is a 400 `invalid_request`.

## Current verification

- Track A delivered: fixtures `d7dea60` + contract tightening `f596332` (15 cases, 56 verifier tests, gated by `server/test/fixtures/listening-exports.test.ts`); server additions `8c17832` + `320d6c1` (56 files / 1080 server tests at that point).
- B1 web parser delivered `4988631` (web 72 → 140 tests; 200k rows in 0.7 s; worker wrapper typecheck-only until B4 wires it). C1 Dart parser delivered `2a29de3` (client 254 → 299 tests; 200k rows in 1.4 s in-process; archive inflates only the requested entry). Both pass all 15 fixture cases byte-identically. B1 review: no code defects; three tests strengthened (`0c1835b`, `89c4322`) and the fixture contract now allows the raw end-of-directory tail read (`bc6dee7`). C1 review: no privacy findings; one catch hardened and a year-0099 divergence closed by flooring export years at 1900 in the contract and both parsers (`fix: Apply the year floor in both parsers`). Both parsers are reviewed and closed; next are B2/C2 (import services) and the B3 state board.
