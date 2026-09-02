# Listening-export import — Phase 1: server

*Status: active · 2026-09-01*
*Design: [listening-export import](../specs/2026-09-01-listening-export-import-design.md) (revision 3)*

**Founder decisions (2026-09-01):** Spotify listeners bring their own data export (Account data + Extended streaming history); Apple export is an optional "go deeper" step; parsing happens on the device; the ledger is per track per day; private sessions are excluded by default; pool candidates are library, seeded, or three counted plays in the last two years; a mix before any data requires the DJ interview and enough seed matches and is labeled "not personal yet"; iOS and web ship the Spotify import in parallel; the Apple adapter is web-first; connected sources are a set per listener. The eleven proposed decisions in the spec are approved and land in `docs/decisions.md` in Task 0.

**Phase 1 scope:** everything server-side that the two parsers and both UIs will talk to. No parser, no UI, no enrichment stage yet (phase 3), no playlist UI. When this phase closes, a snapshot posted by a test harness produces a taste graph and a mix, and the pool works for a listener who streams without saving.

## Binding design facts

Read the spec first. These are the facts an implementer must not drift from.

- **Identity.** `tracks.spotify_id` is a peer of `apple_id`: partial unique index where not null, 22-character base62 (`^[0-9A-Za-z]{22}$`). Apple platform ids validate with `isAppleSongId`. One recording may exist as several rows; rows link by `isrc` and the pool dedupes on `COALESCE(isrc, id::text)`. Never merge rows.
- **Artist provenance.** `tracks.artist_source` in `('sync', 'export', 'reccobeats', 'apple_catalog')`, default `'sync'`. An export upsert sets `artist_source = 'export'` on insert and never overwrites an artist whose source is `reccobeats` or `apple_catalog`. (Phase 3 sets `reccobeats`; Spotify's history carries the album artist.)
- **Ledger.** `listening_days(user_id, source, track_id, day, plays, skips?, completes?, ms_played, hours_mask?)`, primary key `(user_id, source, track_id, day)`, `source IN ('spotify_export', 'apple_export')`. Re-import replaces a day row's values; it never adds to them. Day rows for a run's tracks that the run no longer covers are deleted for that source only.
- **Derived `user_tracks` fields** (recomputed for every track in a run, all sources of the user pooled):
  - `play_count = GREATEST(CASE WHEN user_tracks.play_count_observed THEN user_tracks.play_count ELSE 0 END, GREATEST(ledger_plays, COALESCE(apple_library.play_count, 0)))`. Accepted edge: a re-import cannot lower a count; delete-import is the reset.
  - `play_count_observed = user_tracks.play_count_observed OR ledger rows exist OR apple_library.play_count IS NOT NULL`. A Spotify account-only import leaves it false.
  - `play_count_recent` = ledger plays with `day >= CURRENT_DATE - 730`.
  - `last_played_at = GREATEST(existing, ledger max day at 00:00 UTC, apple_library.last_played_at)`.
  - `skip_count = COALESCE(apple_library.skip_count, ledger skips sum)`; `like_rating = COALESCE(apple_library.like_rating, existing)`.
  - `in_library`: Apple export library rows and Spotify liked tracks set true (`date_added = COALESCE(existing, library.date_added)`). Extended-history rows never touch it (false on insert). A Spotify account re-import sets `in_library = false` on rows with a `spotify_id` that were liked before and are absent now, only for users with no `apple_live` source; otherwise skipped and counted in the summary.
  - `seeded` is never touched by an import.
- **Candidate rule** (every user, personal mode): `in_library OR seeded OR track_id IN recent_plays`, where `recent_plays` is one aggregated CTE per user over `listening_days` with `day >= CURRENT_DATE - INTERVAL '730 days'` and `HAVING SUM(plays) >= 3`. Never a correlated subquery.
- **Recording dedupe** (pool): group scored rows on `COALESCE(t.isrc, t.id::text)`; familiarity uses the group's summed observed play count; keep one row per group, preferring `apple_id IS NOT NULL` for listeners with an `apple_live` or `apple_export` source and `spotify_id IS NOT NULL` otherwise, then highest score.
- **Pool mode.** `personal` when the user has any `user_music_sources` row with `last_imported_at` set (begin registers the source before any data lands, so a bare row means an abandoned import) or any `in_library` row. Otherwise `corpus` when seed matches reach at least 25 tracks across at least 3 artists (seed matches = enriched corpus tracks whose normalized artist equals a `user_artist_seeds` name, plus the user's `seeded` rows). Otherwise `insufficient_seeds`: no pool, the DJ says it does not know enough yet. Corpus candidates are all tracks with a `track_features` or `track_meanings` row; familiarity is 1.0 for seeded rows, 0.7 for seed-artist rows, else 0; every other term unchanged. A corpus-mode generation sets `dj_sessions.not_personal = true`.
- **Enrichment priority.** `tracks.enrich_priority` integer, default 0. An import sets, for its tracks, `enrich_priority = GREATEST(existing, CASE WHEN candidate THEN 1 + play_count_recent ELSE 0 END)`; a pasted seed sets at least 1. The runner orders `enrich_priority DESC, created_at, id`. Cron batch size is not changed in this phase.
- **Protocol.** Same staging discipline as `library/sync-store.ts`: begin with expected counts, idempotent chunk puts that reject conflicting re-sends, one-transaction complete with count verification, bounded expiry and cleanup, one open run per `(user, source)`. Error categories map exactly as the library routes do; add `invalid_id` → 400 for a platform id that fails the run's source validation.
- **Packages.** Begin names `package`: `spotify_extended` (tracks + days), `spotify_account` (tracks + library as liked tracks + artists), `apple_media` (tracks + days + library). A chunk type the package does not carry is rejected with `invalid_state`. Playlists from the Spotify account package go through the playlist sync protocol (Task 8), started by the client after the listening import completes.
- **Privacy.** Never log track, artist, album, or playlist names, or raw rows. Counts and categories only. The staging tables hold titles the same way library staging already does; nothing else from an export is ever sent.
- **Time.** `time_zone` is an IANA string from the device, stored on the run and the profile. `day` values arrive already localized; the server never converts.
- **Conventions.** TDD, red first. Migrations via `npm run db:generate` in `server/` (drizzle-kit, no database needed); the PGlite test helper applies the migrations folder, so a table without a migration does not exist in tests. Authoritative suite: `npx vitest run --no-file-parallelism` in `server/`; also `npm run typecheck`. Commits: one line, conventional prefix, no body, no attribution. Never `git add -A`; the working tree carries another session's uncommitted `AGENTS.md`/`CLAUDE.md` edits — add files by path.

## Tasks

### Task 0: record the decisions (docs)
- Append one dated entry to `docs/decisions.md` listing the eleven approved decisions with their reopen clauses (from the spec's "Decisions proposed" section), in the file's existing voice.
- `docs/product/vision.md`: correct "Dev mode caps at ~25 allowlisted users" to the February 2026 facts (5 users, Premium, batch track endpoint removed) and rewrite the "Someday: Spotify support if/when their API posture allows" milestone as "Spotify via the listener's own data export (spec 2026-09-01)".
- `docs/backlog.md`: add the program under "Owed right now" with a pointer to the spec and this plan; add the Apple-flavored playlist column names as recorded naming debt; add the "re-import cannot lower a count" edge.
- Commit `docs: Record listening-export decisions`.

### Task 1: schema and migration
- `tracks`: `spotify_id` (partial unique index `tracks_spotify_id_idx`, check on the base62 pattern), `artist_source` (check on the four values, default `'sync'`), `enrich_priority` (integer, default 0, check `>= 0`, index `(enrich_priority DESC, created_at, id)`).
- `listening_days` as above, with checks (`plays >= 0`, nullable `skips`/`completes >= 0`, `ms_played >= 0`, `hours_mask BETWEEN 0 AND 16777215`), primary key, index `(user_id, day)`, index `(track_id)`; FKs cascade on user and track.
- `user_tracks`: `play_count_recent` (integer, default 0, check `>= 0`), `skip_count` (nullable, check `>= 0`), `like_rating` (smallint nullable, check `IN (-1, 0, 1)`), `seeded` (boolean, default false).
- `user_artist_seeds(user_id, name, spotify_id?, source, created_at)`: primary key `(user_id, name)`, `source IN ('interview', 'pasted', 'spotify_export')`, `name` length check 1–500, `spotify_id` pattern check.
- `user_music_sources(user_id, source, connected_at, last_imported_at?, ledger_from?, ledger_to?, updated_at)`: primary key `(user_id, source)`, `source IN ('apple_live', 'apple_export', 'spotify_export')`.
- `user_music_profiles`: `apple_storefront` becomes nullable (check allows null), add `country` (nullable, check `^[A-Z]{2}$`), `time_zone` (nullable, length ≤ 64).
- `dj_sessions.not_personal` boolean default false.
- `funnel_events(id, user_id, type, surface, created_at)`: `type IN ('chose_spotify', 'marked_requested', 'interview_completed', 'file_inspected', 'import_completed', 'first_personal_mix', 'first_output')`, `surface IN ('ios', 'web')`, indexes `(type, created_at)` and `(user_id, created_at)`.
- Staging: `listening_import_runs` (id, user_id, source, package, status, time_zone, country?, expected/received counts for tracks, days, library_tracks, artists; `unresolved_rows`, `unresolved_plays`; result columns; `ledger_from`, `ledger_to`; started/expires/completed) with a partial unique index on `(user_id, source)` where `status = 'open'`, the same cleanup indexes as `library_sync_runs`, and checks that `package` matches `source` and that a package's non-carried expected counts are zero. `listening_import_tracks` (import_id, ordinal, platform_id, title, artist, album?, duration_ms?; pk `(import_id, ordinal)`, unique `(import_id, platform_id)`). `listening_import_days` (import_id, ordinal, platform_id, day, plays, skips?, completes?, ms_played, hours_mask?; pk `(import_id, ordinal)`, unique `(import_id, platform_id, day)`). `listening_import_library` (import_id, ordinal, platform_id, play_count?, skip_count?, last_played_at?, date_added?, like_rating?; pk and unique as tracks). `listening_import_artists` (import_id, ordinal, name, spotify_id?; pk `(import_id, ordinal)`, unique `(import_id, name)`). All FK `import_id` cascade.
- Playlist tables: `playlist_sync_runs.source` check gains `'spotify_export'` and `apple_storefront` becomes nullable; `playlist_sync_entries.spotify_id` and `playlist_entries.spotify_id` (nullable, pattern check); `user_playlists.source` (`'apple' | 'spotify_export'`, default `'apple'`, check).
- Generate the migration with `npm run db:generate`; inspect the SQL by hand for the nullable and check changes.
- Tests in `server/test/db.test.ts` style: round-trips, duplicate `spotify_id` rejected, malformed `spotify_id` rejected, `like_rating` check, `listening_days` primary key, one open import per `(user, source)`, package/source mismatch rejected, profile with null storefront accepted.
- Commit `feat(server): Listening import schema`.

### Task 2: contracts and staging (begin, puts, expiry, cleanup)
- `server/src/listening/contracts.ts`: zod schemas for begin (`source`, `package`, `timeZone` ≤ 64 chars, `country` nullable `^[A-Z]{2}$`, expected counts with caps: tracks 100 000, days 2 000 000, library 100 000, artists 10 000; `unresolvedRows`, `unresolvedPlays`), track chunk (max 500), day chunk (max 2 000; `day` as `YYYY-MM-DD`), library chunk (max 500), artist chunk (max 500). Text fields use the same null-byte and surrogate guards as `library/contracts.ts`. `platformId` is a string 1–64 here; the store validates it against the run's source.
- `server/src/listening/import-store.ts`: `begin`, `putTracks`, `putDays`, `putLibrary`, `putArtists` mirroring `library/sync-store.ts` (row locking, exact idempotent re-sends, `conflict` on a differing re-send, `count_mismatch` when received would exceed expected, `invalid_state` for a chunk type the package does not carry, `invalid_id` for a platform id that fails the source's validator). Begin upserts the profile without a storefront, sets `time_zone` and `country`, expires any open run for the same `(user, source)`, and upserts `user_music_sources.connected_at`. TTL default 2 hours.
- `server/src/listening/cleanup.ts` mirroring `library/cleanup.ts` (bounded batches, expiry of stale open runs, purge of completed and expired staging rows); wire into `enrich/scheduled.ts` with its own result key and failure isolation.
- Tests: begin/put idempotency, conflicting re-send, cross-tenant `not_found`, count mismatch, package gating, id validation per source, expiry, cleanup batches and bounds, scheduled wiring.
- Commit `feat(server): Listening import staging`.

### Task 3: complete, derivations, delete-import
- `complete(userId, importId)` in one transaction, following the spec's five steps and the derivation facts above: verify counts and ordinals; verify every day and library row's `platform_id` exists in the run's tracks (`conflict` otherwise); upsert `tracks` on the source's id column; upsert and prune `listening_days`; recompute `user_tracks` for the run's tracks; upsert `user_artist_seeds` from artists; set `enrich_priority`; upsert `user_music_sources` (`last_imported_at`, `ledger_from`/`ledger_to` as min/max day for the user and source); update the profile's `country`/`time_zone`; write result columns; return the summary `{ tracks, days, libraryTracks, artists, unresolvedRows, unresolvedPlays, ledgerFrom, ledgerTo, likedRemoved, likedRemovalSkipped }`. Completed runs return the stored summary idempotently.
- Library sync (`library/sync-store.ts` complete) additionally upserts `user_music_sources('apple_live')` with `last_imported_at`, so pool mode can see live-synced listeners. Existing library tests stay green.
- `deleteSource(userId, source)`: delete that source's `listening_days`, `user_artist_seeds` rows with that source, `user_music_sources` row, and for `spotify_export` mark `user_playlists` with `source = 'spotify_export'` `in_library = false` and, when the user has no `apple_live` source, set `in_library = false` on rows whose track has a `spotify_id`; then delete `user_tracks` rows with no remaining ledger days, `in_library = false`, and `seeded = false`; recompute `play_count_recent` and `skip_count` for surviving rows from the remaining ledger; leave `play_count` as is.
- Tests: each package alone; both Spotify packages in either order producing the same end state; account-only leaves `play_count_observed = false`; extended upgrades it; the `GREATEST` merge against a native count; liked-track removal on re-import and the skip for `apple_live` users; 730-day boundary for `play_count_recent`; day-row replacement and pruning; atomic rollback on count mismatch; idempotent completed summary; `enrich_priority` values; `apple_live` source upsert from library sync; delete-source recompute and row deletion.
- Commit `feat(server): Listening import publish and derivations`.

### Task 4: routes
- `server/src/routes/listening-ingest.ts` mounted under `/ingest` (session middleware already covers `/ingest/*`): `POST /listening/imports`, `PUT /listening/imports/:importId/tracks|days|library|artists`, `POST /listening/imports/:importId/complete`, `DELETE /listening/sources/:source`. Error mapping as `library-ingest.ts` plus `invalid_id` → 400.
- `GET /me/music-sources` under session middleware: the user's `user_music_sources` rows with ledger ranges and `last_imported_at`, for the Music view.
- Tests in `test/library/ingest-routes.test.ts` style: session required on every endpoint, validation failures 400, category mapping, cross-tenant 404, happy path through complete, delete-source, music-sources listing.
- Commit `feat(server): Listening import routes`.

### Task 5: pool candidates, dedupe, corpus mode
- `dj/pool.ts`: candidate CTE per the rule; ISRC-group dedupe with summed familiarity and platform preference (derive the preference from `user_music_sources` inside the same query); existing weights untouched. Keep `PoolTrack` shape; add `spotifyId`.
- `resolvePoolMode(db, userId)` → `{ mode: 'personal' | 'corpus' | 'insufficient_seeds', seedTracks, seedArtists }` per the pool-mode facts. `buildPool` takes `{ mode }`; corpus mode swaps the candidate source and familiarity term as specified.
- `dj/loop.ts`: resolve the mode before `buildPool` in both generate and swap/extend paths; `insufficient_seeds` returns a result text telling the model the listener has not given enough taste yet (interview or paste), no queue change; `corpus` sets `dj_sessions.not_personal = true` on that session. `routes/sessions.ts` exposes `notPersonal` in the shared session columns.
- Tests: existing pool and golden tests unchanged; candidate rule at the 730-day and 3-play boundaries; seeded rows qualify; dedupe keeps one row per ISRC group with summed plays and the platform-preferred row; mode resolution for a live-synced listener, an export-only listener, a seeds-only listener above and below the threshold, and a blank listener; corpus familiarity values; `not_personal` set on the session and surfaced by the sessions routes.
- Commit `feat(server): Play-derived candidates and corpus mode`.

### Task 6: seeds, interview, funnel
- `server/src/enrich/reccobeats-by-id.ts`: `fetchTracksBySpotifyIds(ids, fetchLike)` against `GET /v1/track?ids=` in batches of at most 40 (verified 2026-09-01: 41 ids returns HTTP 400), returning `{ spotifyId, title, artists, isrc, durationMs }` per hit and the missing ids. Same timeout and error discipline as `reccobeats.ts`.
- Routes under session middleware: `GET /me/artist-seeds`; `PUT /me/artist-seeds { names[] }` replacing the user's `interview`-sourced seeds; `POST /me/seed-tracks { spotifyIds[] }` (max 200) resolving through ReccoBeats, inserting `tracks` rows (`spotify_id`, `artist_source = 'reccobeats'`, `isrc`, `duration_ms`, `enrich_priority >= 1`) and `user_tracks` with `seeded = true`, and a `pasted` artist seed per credited artist; responds `{ resolved, unresolved }`; `GET /me/seed-tracks`; `DELETE /me/seed-tracks/:trackId` clearing `seeded` and deleting the row when nothing else keeps it.
- `POST /me/interview { neverSkip: string[], playsMost, listensWhen, neverWants, era }`: seeds from `neverSkip` (replace `interview` seeds), one memory note per non-empty answer with a fixed prefix (`Never skips: …`, `Plays most: …`, `Listens when: …`, `Never wants: …`, `Era: …`), inserted through the same cap, dedupe, and length rules as the DJ's `remember_preference` (refactor that insert into a shared helper rather than duplicating it), then a `funnel_events` row `interview_completed`.
- `POST /me/funnel-events { type, surface }`; `server/scripts/funnel-report.ts` (read-only, neon-http, `.dev.vars` loader) printing per-step counts, step-to-step conversion, and median days from `marked_requested` to `import_completed`.
- Tests: seed routes and ownership; seed-tracks resolution with a stubbed fetch including partial misses and a ReccoBeats error; interview notes land with prefixes, respect the cap and dedupe, and the sanitize-at-render posture is unchanged (a note containing tool-call-looking text stays inert — extend the existing pinning test); funnel event validation and insertion.
- Commit `feat(server): Taste seeds, interview, funnel events`.

### Task 7: enrichment priority
- `enrich/runner.ts`: order candidates by `enrich_priority DESC, created_at, id`; the remaining-count query unchanged.
- Tests: a higher-priority newer track is processed before an older zero-priority one; ties keep creation order.
- Commit `feat(server): Prioritize enrichment by listening relevance`.

### Task 8: Spotify playlists through the playlist sync
- `playlists/contracts.ts`: `source` enum gains `spotify_export`; `storefront` becomes optional and is required unless `source = 'spotify_export'`; entry snapshots gain `spotifyId` (nullable, pattern check); `appleCatalogId` stays nullable.
- `playlists/sync-store.ts`: begin accepts a null storefront for `spotify_export` (profile upsert without storefront); publish links entries through `COALESCE(catalog_track.id, spotify_track.id, unique_isrc.id)` with `spotify_track` joined on `spotify_id`; `user_playlists.source` written from the run; `playlist_entries.spotify_id` carried through.
- `routes/playlist-ingest.ts` and browse routes carry `spotifyId` on entries.
- Tests: a Spotify playlist run with fingerprint keys and `key:position` entry ids publishes in order with duplicates preserved, links entries to `spotify_id` tracks, keeps name-only entries unresolved, and a null storefront is accepted only for that source; existing Apple tests unchanged.
- Commit `feat(server): Spotify playlists through playlist sync`.

### Task 9: verification, docs, migration gate
- `npx vitest run --no-file-parallelism` and `npm run typecheck` green in `server/`; record counts in this plan's "Current verification".
- `docs/backlog.md` and this plan's status updated; the spec's "Open implementation facts" already records the ReccoBeats batch limit (40).
- Migration apply and Worker deploy happen from a clean worktree of committed HEAD and only with the founder's go at action time. Nothing in this phase changes behavior for existing listeners until a client sends the new endpoints, so deploy can wait for phase 2 if the founder prefers.

## Review follow-ups (recorded, not gates)

- Task 2 review: the staged-days lookup uses a row-value `IN` list of up to 2 000 `(platform_id, day)` tuples, which the planner expands into a wide `OR`. Fine at current volumes; if import latency shows it, switch to a join against `unnest(text[], date[])`.
- Task 4 review: one convention across all three staging protocols (library, playlist, listening) — a malformed `:syncId`/`:importId` is a 404 `{ error: 'not_found' }` via a shared `routes/uuid-param.ts` helper (library and playlist routes moved from a zod 400 to this), the conflict category maps to `sync_conflict` everywhere, and `/me/*` read endpoints emit timestamps as ISO strings like `/me/memories`. Invalid JSON bodies are now a 400 (Hono's `HTTPException` is returned from `app.onError` instead of being swallowed into a 500). Phase-2 clients can share one staging-protocol helper.
- Task 3 `complete()` locks the profile row, then the run row, matching `begin()` and the library sibling, so lock order stays deadlock-free.
- Task 3 review: `deleteSource('apple_export')` now un-libraries export-derived Apple rows when the user has no `apple_live` source (fix round), so delete-import is a real reset for both sources. Dual-id rows (a track with both `spotify_id` and `apple_id`) are still swept by the Spotify liked-removal and delete rules when their membership came from an Apple export; rare until phase 3's ISRC cross-link creates such rows, so it is recorded for phase 3 rather than fixed here.
- Task 5 review: queue exclusion in `buildPool` is by recording key (ISRC group), not row id, so a queued song's sibling row can never be picked as its own replacement (fix round). Platform preference treats a legacy library (in_library rows, no `user_music_sources` row) as Apple. For phase 2: the web `ApiSession` type needs `notPersonal`, and `POST /sessions/:id/messages` returns no session summary, so a client must refetch the session to learn a turn went corpus-mode. `resolvePoolMode` runs a corpus-wide seed scan on every generate even for personal listeners; gate it behind the personal check or index `lower(btrim(artist))` if it ever shows in latency. A loop-level test that a swap never lands a queued recording's sibling is still owed once loop.ts is free. Known edge: a legacy Apple library (no source row) that adds a Spotify export before its next live sync prefers Spotify rows until that sync writes `apple_live`.
- Task 6 must insert seeded rows with `in_library = false` explicitly (`user_tracks.in_library` defaults to true), or the Spotify liked-removal and delete-source rules will sweep them.

## Out of scope (resist)
Parsers · any UI · the ReccoBeats-by-id enrichment stage, ISRC cross-link, and oEmbed artwork (phase 3) · relay and embed probes (phase 4) · Apple adapter specifics beyond accepting `apple_media` runs · physical merge of duplicate rows · scoring changes beyond the candidate rule and corpus familiarity · cron batch size changes · email or push.

## Current verification

Not started.
