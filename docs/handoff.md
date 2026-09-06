# Handoff — listening-export program (Spotify import)

*Initial handoff written 2026-09-04 at `14cdc44`; follow-on status updated 2026-09-06. The completed program work is pushed; production migrations reach 0026; Netlify serves `05dad49`; and the live Worker remains the `fd5f66b` release. Provider-CDN repair, production-browser/TestFlight, and device/real-export gates remain.*

Read with: `docs/superpowers/specs/2026-09-01-listening-export-import-design.md` (rev 3), the phase plans `docs/superpowers/plans/2026-09-01-listening-export-p1-server.md` and `docs/superpowers/plans/2026-09-02-listening-export-p2-spotify-import.md`, and the 2026-09-01 entry in `docs/decisions.md`.

## Follow-on status — 2026-09-05

Phase 3 is implemented and committed in `bba5de9`. Spotify-ID metadata/features feed the
existing enrichment pipeline (plan `superpowers/plans/2026-09-04-spotify-id-enrichment.md`).
Source ownership now has its own plan and migration 0022
(`superpowers/plans/2026-09-04-library-source-ownership.md`): each source changes
only its own saved-library memberships; the combined flag stays true if another
source remains. This fixes dual-ID export deletion and Apple snapshots removing
Spotify-only saved songs. Existing saved rows become protected `legacy`
memberships because their historical source is unknown; retiring those rows needs
explicit reconciliation. The original phase-1 blanket Apple-live skip no longer
applies to new imports, but completed historical summaries retain their values.

Source ownership is verified locally: the full server suite passed 1,168 tests;
a final rollout-gap fix then passed 296 focused tests plus typecheck (details
in its plan). Apple ISRC linking is implemented and committed in `bba5de9`; its
plan is `superpowers/plans/2026-09-04-apple-isrc-linking.md`, with migration 0023. It uses
the saved Apple storefront or the listener's import country (user approved),
defers unknown country, preserves ambiguous/conflicting IDs, and records the
successful market for artwork refresh. The matching Worker code is deployed.
The stable combined server checkpoint passed 67 files / 1,211
tests, plus typecheck and migration checks; it precedes the separate
playlist-inspired session work. The final fallback slice is in
`superpowers/plans/2026-09-04-spotify-fallback-artwork.md`: official Spotify
oEmbed first, then guarded exact-ISRC Deezer, with fixed CDN URLs, bounded
provider reads, source-aware fenced claims, and no new migration. Its focused
checkpoint passed 7 files / 101 tests plus typecheck. After all three sessions
froze server files, the authoritative combined suite passed **73 files / 1,259
tests in 192.63s**, including the 0014-to-current migration rehearsal. A later
binding-free Worker smoke proved Spotify and Deezer provider access, while also
exposing current CDN hostname drift. The strict repair is verified in isolated
commit `b8f8393`; it is not merged or deployed. Deezer remains best effort because
its exact-ISRC route lacks a stable public contract.
Real-export validation remains gated on the missing archives.
The user's requested archives have not arrived. The earlier playlist
catalog/taste slice is `1fb6c92`; the combined music/enrichment work is `bba5de9`
and the completed Your music web integration is `3d18a17`.

The remaining release and validation contract is centralized in
`superpowers/specs/2026-09-05-listening-export-release-validation-design.md`.
It separates provider/release work that can happen before the archives from the
real Spotify validation and Phase 4 evidence gate that require them.

The separate release preflight first found production migrations only through
0014, then recorded the approved push and clean-worktree production migration.
Its report is `superpowers/plans/2026-09-04-playlist-release-preflight.md`.
The original release applied all 25 migrations through 0024 with matching hashes.
The separate playlist-editing follow-on later applied 0025–0026; production now
has 27 matching entries, while the live Worker still runs the exact clean
`fd5f66b` snapshot as version `7a6ec181-2292-4d56-b8a4-abb996d6857a`. Public
health/auth and aggregate private smoke passed; no playlist mutation or device
smoke ran.

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

### Release actions and remaining founder gates

1. **Completed — push.** The reviewed foundation through `05dad49`, release records, and playlist-editing server follow-on through `b45988b` are on `origin/main`.
2. **Completed — migrations 0015–0026.** The original release applied 0015–0024 from clean `05dad49`; the separate playlist-editing action applied 0025–0026 from clean `a5f8185`. The post-run ledger contains 27 matching entries.
3. **Completed — Worker deploy and initial smoke.** Exact clean snapshot `fd5f66b` is live as version `7a6ec181-2292-4d56-b8a4-abb996d6857a`; rollback version `e35b134c-c045-4267-92b6-31c42c918159` is recorded. Health/auth guards and aggregate private status passed.
4. **Provider-CDN repair.** Binding-free edge smoke is complete. Integrate and deploy verified commit `b8f8393`, then repeat the fixed-output production smoke. Because it is based on `b45988b`, deploying it would also activate the playlist-editing server follow-on; approve that combined scope or backport only the provider fix to `fd5f66b`.
5. **Published — web; verification remains.** Netlify production still reports commit `05dad49` as of 2026-09-06. Smoke auth, Your music, playlist browse/detail, and Android Chrome against the deployed Worker before calling the web rollout verified.
6. **TestFlight build.** The simulator build is proven; signing and upload are the founder's.
7. **Fixture-layout check against real exports.** The fixture folder names, file names, and playlist item shapes are assumptions recorded in `fixtures/listening-exports/README.md`. When the founder's Spotify (both packages, requested 2026-09-01) and Apple exports arrive, put the archives in a folder outside the repo and give a session the paths; it verifies the layout, corrects the fixtures and both parsers if needed, and only then runs the smoke.
8. **Real-export smoke** (spec "Real-world smoke"): import the founder's Spotify export in the iOS app, on desktop Chrome, and on Android Chrome. Ledger date ranges match the export; play counts for three known heavy-rotation tracks match a manual count, including one under two Spotify ids; a mix generates with observed counts and the top candidates get features and meanings within one cron cycle; re-import yields identical summaries.
9. **Funnel baseline.** `scripts/funnel-report.ts` shows the founder's events in order: chose_spotify, marked_requested, interview_completed, file_inspected, import_completed, first_personal_mix, first_output.

### Later phases (spec "Phasing")

- **Phase 3, enrichment (committed in `bba5de9`).** Spotify-ID metadata/features, source ownership, exact Apple ISRC linking, and Spotify oEmbed artwork with guarded exact-ISRC Deezer fallback have their follow-on plans above. Provider edge behavior is verified; the CDN-host repair still needs an explicitly scoped production release. Real-export validation remains a gate.
- **Phase 4, probes.** Scrobble relay (ListenBrainz or Last.fm as the live feed; terms and latency unknown) and the Spotify iFrame embed player (five open questions in the spec). Each gets a short spec only if it holds. Gated on the funnel showing listeners reach `import_completed` and `first_output`.
- **Phase 5, Apple "go deeper", web first.** Parser for `Apple Media Services information` (Daily Tracks CSV, Library Tracks JSON, nested archive stored or deflated, random access for a 1 GB archive). The server already accepts `apple_media` runs. iOS build waits for the web proof and funnel evidence.

### Recorded follow-ups (not gates)

Server:
- Playlist entry snapshots carry no `addedAt`, so export playlist added-dates are dropped on the wire until a server field exists.
- The playlist browse summary does not expose `user_playlists.source` and hardcodes `capability: 'copy_only'`; a mixed Apple + Spotify listing cannot badge per source yet.
- Playlist sync allows one open run per user across sources; clients must not run an Apple and a Spotify playlist sync concurrently (move the partial unique index to `(user_id, source)` when it matters).
- The deployed candidate fixes the dual-ID membership deletion defect; migration 0022 and its matching Worker runtime are active.
- Re-running the interview appends notes rather than replacing them (default kept in phase 2).
- `resolvePoolMode` scans the corpus for seed matches on every generate; gate it behind the personal check or index `lower(btrim(artist))` if latency shows it.
- Staged-days lookup uses a row-value `IN` list of up to 2 000 tuples; switch to `unnest` if import latency shows it.
- A loop-level test now pins that a swap never lands a queued recording's sibling.
- A legacy Apple library (no `user_music_sources` row) that adds a Spotify export before its next live sync prefers Spotify rows until that sync writes `apple_live`.

Clients:
- The web demo tile on the service-choice dialog is disabled until a demo mechanism exists.
- An archive opened on iOS while signed out is held on the device and handed to whoever signs in next (deliberate).
- `web/src/import/worker.test.ts` abort test flaked once on timing; make its wait deterministic if it recurs.
- The Your music Apple sync UI is committed in `3d18a17`; its production and launch-browser validation is part of the release spec.

### Accepted edges

- A re-import cannot lower a play count; delete-source is the reset.
- A Spotify account-only import leaves `play_count_observed = false`.
- Historical phase-1 runs skipped Spotify liked-track removal for listeners with an `apple_live` source. The deployed source-ownership runtime now supersedes that rule; migration 0022 provides source-specific membership storage.

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
