# Handoff — listening-export program (Spotify import)

*Written 2026-09-04 at `14cdc44`. Phases 1 and 2 are code-complete locally. Nothing is pushed, migrated, or deployed. Every remaining step is a founder gate or a later phase.*

Read with: `docs/superpowers/specs/2026-09-01-listening-export-import-design.md` (rev 3), the phase plans `docs/superpowers/plans/2026-09-01-listening-export-p1-server.md` and `docs/superpowers/plans/2026-09-02-listening-export-p2-spotify-import.md`, and the 2026-09-01 entry in `docs/decisions.md`.

## What this is

Spotify's Web API is closed to us (5 users, Premium only, batch track endpoint gone), so Spotify listeners bring their own data export instead. They request both packages from Spotify (Account data + Extended streaming history), wait for the email, and hand the ZIP to the app. The app parses it on the device, never uploads the archive, and posts only track identities, per-day play counts, liked tracks, followed artists, and playlists through a staged import protocol. The server builds a day ledger and a taste graph from that, the DJ makes mixes from it, and the outputs are API-free: open in Spotify links, copy as text, and a transfer handoff. Before any data lands, a DJ interview plus pasted seed songs let the DJ make a "not personal yet" mix from the shared corpus. Apple export is a later optional "go deeper" step (phase 5).

Locked decisions (all eleven in `docs/decisions.md`, 2026-09-01): export not API; on-device parsing; per-track-per-day ledger; `spotify_id` as a peer of `apple_id` with ISRC linking and no physical merge; a play is 30 s; candidates are library, seeded, or three plays in the last two years; private sessions excluded unless opted in; interview gates pre-data mixes; one parser contract and fixture suite for both surfaces; export is backfill, relay is the intended live feed; sources are a set per listener.

## Done

### Phase 1 — server (plan closed 2026-09-02)

Schema and migrations `0018_easy_gwen_stacy.sql`, `0019_clear_albert_cleary.sql`: `tracks.spotify_id`, `artist_source`, `enrich_priority`; `listening_days`; derived `user_tracks` fields (`play_count_recent`, `skip_count`, `like_rating`, `seeded`); `user_artist_seeds`; `user_music_sources`; `funnel_events`; `listening_import_*` staging; nullable storefront, `country`, `time_zone` on profiles; `dj_sessions.not_personal`; Spotify ids and `source` on the playlist tables.

Behavior: staged import protocol (begin, idempotent chunk puts, one-transaction complete, expiry and cleanup) under `/ingest/listening/*`; derivations and delete-source; `GET /me/music-sources`; pool candidate CTE, ISRC-group dedupe with platform preference, corpus mode behind the seed threshold (25 tracks across 3 artists), `resolvePoolMode`; seeds, interview, funnel events; enrichment priority ordering; Spotify playlists through the playlist sync protocol with a null storefront; `scripts/funnel-report.ts`.

| Task | Commits |
|---|---|
| 0 decisions and docs | `608eb04` |
| 1 schema, migration 0018 | `2d6203f` |
| 2 contracts and staging | `e3ba56e`, `27da951` |
| 3 publish, derivations, delete-source, migration 0019 | `72978f2`, `79e9e39` |
| 4 routes | `0e39618`, `7f43742`, `ae6d3fe` |
| 5 candidates, dedupe, corpus mode | `b011a4a`, `d43b245` |
| 6 seeds, interview, funnel | `0b26f1e`, `76cec09` |
| 7 enrichment priority | `a4e82da` |
| 8 Spotify playlists via sync | `d961ca5`, `510fca7` |

### Phase 2 — Spotify import on web and iOS (plan closed 2026-09-04)

| Track | What | Commits |
|---|---|---|
| A1 fixtures | `fixtures/listening-exports/`: dependency-free ZIP builder, 15 cases, README as the normative parser contract, structural `--check`, gated from the server suite | `d7dea60`, `f596332`, `bc6dee7`, `f627036`, `5894228` |
| A2 server additions | `spotifyId` on queue tracks, `notPersonal` on sessions, `GET /me/onboarding` (with `userId`, `chosenService`, `interview`), landed packages on source rows | `8c17832`, `320d6c1`, `4b208c3`, `dedd96a`, `7db8274` |
| B1 web parser | zip.js reader, Web Worker parser, diagnostics with no names, byte-identical to the fixtures | `4988631`, `0c1835b`, `89c4322` |
| C1 iOS parser | `package:archive` reader, isolate parser, same contract | `2a29de3` |
| B2 web import service | inspect and upload, chunking, playlist sync after completion, partial success | `e4e6d9d`, `5905508` |
| C2 iOS import service | same, cancellable | `905b72e`, `735a3ad`, `5d09482` |
| B3 state board | `docs/mockups/2026-09-04-web-spotify-import-states.html`, approved direction B | `bc5d6b4`, `d5c7c43` |
| B4 web screens | service gate, request steps, waiting, interview, paste seeds, import page, sources list; run hoisted above the view | `78eb818`, `cc1434a`, `7f0cbc4`, `812717a`, `8f61c5a` |
| C3 iOS screens | service gate, request, waiting with local reminder, interview, import sheet, sources screen, ZIP document type | `d45015c`, `8cb6a0a`, `c37468d`, `6794aff`, `72d1cac` |
| B5 web outputs | Spotify links per row, rail actions, copy as text, corpus banner, funnel milestones | `c3d3956`, `d6c0a0c`, `11dc47f`, `40ae6b1` |
| C4 iOS outputs | same, share sheet with iPad origin, TuneMyMusic handoff | `2d85478`, `a2e7122` |
| C5 Files and Mail hand-over | `AppDelegate.swift` document open, security-scoped temp copy, `mixtape/open-archive` channel, purge on launch | `69e83cc`, `ff09a6d` |

Departures from the approved board are recorded in `docs/mockups/approved/2026-09-04-web-spotify-import-implementation.md`.

### Verification state (D1, 2026-09-04)

| Surface | Command | Result |
|---|---|---|
| Server | `npx vitest run --no-file-parallelism` in `server/`; `npm run typecheck` | 57 files / 1084 tests green; typecheck clean |
| Web | `npm test`; `npm run build` in `web/` | 32 files / 310 tests green; build clean, parser worker chunk emitted |
| iOS | `flutter test`; `flutter analyze`; `flutter build ios --simulator --no-codesign` in `client/` | 535 tests green; analyzer clean; `Runner.app` built |
| Fixtures | `node fixtures/listening-exports/build.mjs --check` (run by the server suite) | 15 cases match their committed archives and expectations |

Every task ran implementer → adversarial reviewer → fix round. Every finding is fixed or recorded below.

## Left

### Founder gates, in order (nothing here runs without an explicit go)

1. **Push.** `main` is 102 commits ahead of `origin/main`. Nothing from either phase is on GitHub yet.
2. **Migrations 0018–0019, then the Worker deploy.** From a clean worktree of committed HEAD, never the working tree (`docs/decisions.md` incident rule). Migrations apply with `npm run db:migrate` in `server/` with the production `DATABASE_URL` set; deploy with `npm run deploy`. Existing listeners are unaffected until a client calls the new endpoints, but both clients now do, so the web and iOS releases depend on this step.
3. **Web deploy** to Netlify after step 2.
4. **TestFlight build.** The simulator build is proven; signing and upload are the founder's.
5. **Fixture-layout check against real exports.** The fixture folder names, file names, and playlist item shapes are assumptions recorded in `fixtures/listening-exports/README.md`. When the founder's Spotify (both packages, requested 2026-09-01) and Apple exports arrive, put the archives in a folder outside the repo and give a session the paths; it verifies the layout, corrects the fixtures and both parsers if needed, and only then runs the smoke.
6. **Real-export smoke** (spec "Real-world smoke"): import the founder's Spotify export in the iOS app, on desktop Chrome, and on Android Chrome. Ledger date ranges match the export; play counts for three known heavy-rotation tracks match a manual count, including one under two Spotify ids; a mix generates with observed counts and the top candidates get features and meanings within one cron cycle; re-import yields identical summaries.
7. **Funnel baseline.** `scripts/funnel-report.ts` shows the founder's events in order: chose_spotify, marked_requested, interview_completed, file_inspected, import_completed, first_personal_mix, first_output.

### Later phases (spec "Phasing")

- **Phase 3, enrichment.** ReccoBeats-by-id stage (batch limit 40, verified) with artist correction (`artist_source = 'reccobeats'`), ISRC → Apple catalog cross-link (`filter[isrc]`; storefront choice for Spotify listeners is open), Spotify oEmbed artwork with Deezer fallback. Needs its own plan.
- **Phase 4, probes.** Scrobble relay (ListenBrainz or Last.fm as the live feed; terms and latency unknown) and the Spotify iFrame embed player (five open questions in the spec). Each gets a short spec only if it holds. Gated on the funnel showing listeners reach `import_completed` and `first_output`.
- **Phase 5, Apple "go deeper", web first.** Parser for `Apple Media Services information` (Daily Tracks CSV, Library Tracks JSON, nested archive stored or deflated, random access for a 1 GB archive). The server already accepts `apple_media` runs. iOS build waits for the web proof and funnel evidence.

### Recorded follow-ups (not gates)

Server:
- Playlist entry snapshots carry no `addedAt`, so export playlist added-dates are dropped on the wire until a server field exists.
- The playlist browse summary does not expose `user_playlists.source` and hardcodes `capability: 'copy_only'`; a mixed Apple + Spotify listing cannot badge per source yet.
- Playlist sync allows one open run per user across sources; clients must not run an Apple and a Spotify playlist sync concurrently (move the partial unique index to `(user_id, source)` when it matters).
- Dual-id rows (both `spotify_id` and `apple_id`, rare until phase 3 creates them) are swept by the Spotify liked-removal and delete-source rules even when their membership came from Apple.
- Re-running the interview appends notes rather than replacing them (default kept in phase 2).
- `resolvePoolMode` scans the corpus for seed matches on every generate; gate it behind the personal check or index `lower(btrim(artist))` if latency shows it.
- Staged-days lookup uses a row-value `IN` list of up to 2 000 tuples; switch to `unnest` if import latency shows it.
- A loop-level test that a swap never lands a queued recording's sibling is still owed.
- A legacy Apple library (no `user_music_sources` row) that adds a Spotify export before its next live sync prefers Spotify rows until that sync writes `apple_live`.

Clients:
- The web demo tile on the service-choice dialog is disabled until a demo mechanism exists.
- An archive opened on iOS while signed out is held on the device and handed to whoever signs in next (deliberate).
- `web/src/import/worker.test.ts` abort test flaked once on timing; make its wait deterministic if it recurs.
- "Your music" Apple sync UI on the web is a separate, older track (see `docs/backlog.md` "Ship web sync and consumption").

### Accepted edges

- A re-import cannot lower a play count; delete-source is the reset.
- A Spotify account-only import leaves `play_count_observed = false`.
- Spotify liked-track removal on re-import is skipped for listeners with an `apple_live` source and counted in the summary.

## Working rules a next session must keep

- **Working tree.** `AGENTS.md`, `CLAUDE.md`, and `.claude/launch.json` carry the founder's uncommitted local edits. Never `git add -A` or `git add .`; stage by explicit path. Do not commit those three.
- **Deploys** only from a clean `git worktree` of committed HEAD and only on the founder's explicit go.
- **Privacy.** Never log or display track, artist, album, or playlist names or raw export rows; counts and categories only. Never store lyric text. Parse on the device; the ZIP never leaves it. Diagnostics reports contain no names.
- **Commits.** One-line subject, conventional prefix, no body, no attribution of any kind.
- **Cadence.** Spec → plan → task-by-task: fresh implementer, adversarial reviewer, fix round. TDD red first. UI work needs a state board in `docs/mockups/` and an approval record in `docs/mockups/approved/` before screens are built.
- **Models.** Implementers, reviewers, and fix rounds run on Opus; Fable only plans and orchestrates. At most two subagents in flight.
- **Test gating.** Do not pipe vitest into `grep` or `head` before committing; the pipe masks the exit code (this bit twice in phase 2).
- **iOS.** New Swift files need pbxproj target membership; C5 deliberately added none. User-scoped Riverpod providers `ref.watch(authProvider)` in build and cancel via `ref.onDispose`.

## Where things live

Server (`server/src/`): `db/schema.ts`; `listening/{contracts,import-store,cleanup}.ts`; `routes/{listening-ingest,music-sources,onboarding,artist-seeds,seed-tracks,interview,funnel-events,uuid-param}.ts`; `dj/pool.ts` (candidate CTE, dedupe, corpus mode); `enrich/reccobeats-by-id.ts`; `enrich/runner.ts`; `playlists/{contracts,sync-store,browse-store}.ts`; `scripts/funnel-report.ts`.

Web (`web/src/`): `import/` (snapshot, canonical, zip-reader, spotify-parser, diagnostics, worker protocol and host, `parser.worker.ts`, `import-service.ts`, `import-run.ts`); `api/client.ts`; `lib/{onboarding,service-preference,funnel-once}.ts`; components `ChooseServiceDialog`, `SpotifyMusicView`, `InterviewDialog`, `PasteSongsBox`, `MusicSourcesList`, `ImportPanel`, `QueuePanel`, `Sidebar`, `App.tsx`.

iOS (`client/`): `lib/import/` (snapshot, zip_reader, spotify_parser, diagnostics, import_isolate, listening_import_service); `lib/data/listening/`, `lib/data/onboarding/`, `lib/data/files/` (archive picker, opened-archive channel), `lib/data/share/`, `lib/data/reminders/`; providers `onboarding`, `device`, `listening_import`, `funnel`, `opened_archive`; screens `choose_service_screen`, `spotify_request_screen`, `interview_screen`, `import_sheet`, `music_sources_screen`, `home_screen`, `queue_screen`; `ios/Runner/AppDelegate.swift`, `ios/Runner/Info.plist`.

Fixtures: `fixtures/listening-exports/` (`README.md` is the contract, `build.mjs`, `verify.test.mjs`, `src/<case>/case.json`, committed `archive.zip` and `expected.<option>.json`).

Docs: spec, two phase plans, decisions entry (2026-09-01), `docs/backlog.md` "Owed right now", `docs/product/vision.md` (Spotify facts corrected), state board and two approval records dated 2026-09-04.
