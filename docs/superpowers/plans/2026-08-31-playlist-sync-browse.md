# Playlist Intelligence Phase 2 — Read-only Sync + Browse Implementation Plan

> Execute task-by-task with a red-first test, implementation, adversarial review, and fix round for every task. Phase 2 is read-only with respect to Apple Music: no append, rebuild, revised-copy creation, or other playlist mutation belongs in this plan.

**Goal:** Collect the listener's Apple Music playlists as complete ordered snapshots, publish them atomically into a private user-scoped server model, and expose stable browse contracts without allowing an interrupted sync to damage the last known-good snapshot.

**Architecture:** A new native `PlaylistSnapshotStore` actor fully materializes one MusicKit library snapshot and hides Apple pagination, artwork conversion, identifier uncertainty, fingerprinting, and cache lifetime behind a small channel interface. The Flutter sync service uploads that immutable snapshot through an idempotent staging protocol after song sync finishes. A server `PlaylistSyncStore` owns staging and one short publish transaction; routes only authenticate, validate, and translate errors. Browse endpoints read canonical tables with keyset cursors and never expose Apple library IDs as ownership proof.

**Tech stack:** Flutter/Dart + Riverpod; Swift MusicKit/CryptoKit on iOS 16; Hono; Drizzle; Neon Postgres through `neon-serverless` Pool; Vitest/PGlite.

**Working directory:** `/Users/admin/Documents/work/mixtape`. Work directly on `main` as requested. Preserve unrelated working-tree changes and never stage them accidentally.

**Design source:** `docs/superpowers/specs/2026-08-31-artwork-playlist-intelligence-design.md`.

**Public Apple contract checked against the installed iOS 26.5 SDK:**

- [`Playlist`](https://developer.apple.com/documentation/musickit/playlist) exposes an ID, kind, artwork, last-modified date, and entries relationship.
- [`Playlist.Entry`](https://developer.apple.com/documentation/musickit/playlist/entry) exposes an entry ID, position, ISRC, snapshots, artwork, and optional underlying item.
- [`MusicDataRequest.currentCountryCode`](https://developer.apple.com/documentation/musickit/musicdatarequest/currentcountrycode) returns the Apple Music account storefront.
- [`Artwork`](https://developer.apple.com/documentation/musickit/artwork) exposes maximum dimensions, background colour, and a requested-size URL function; the founder-device read proved that URL/dimensions may still be unavailable for library playlist artwork.

## Scope and safety boundary

- This phase adds collection, storage, browse APIs, and client data contracts. It does **not** add playlist taste scoring, playlist-inspired mix generation, conversational drafts, a playlist browse screen, or Apple Music writes.
- The existing sync sheet may report song/playlist totals. A new browse screen is a substantial UI change and remains behind its required approval state board in Phase 5.
- The exact-rebuild probe remains a rejection result. The founder later reported that the current order looked intact but was unsure whether the Music-created disposable playlist lost one song. There is no pre-probe snapshot capable of resolving that uncertainty. Do not run another mutation probe in Phase 2 and do not record the visual check as conclusively passed.
- The installed typed SDK exposes no public playlist `canEdit` flag and no version hash. Apple's raw library-playlist REST response documents `canEdit`, artwork templates, and global IDs, but the local `MusicDataRequest` probe did not yield a usable body. Phase 2 therefore stores typed observable metadata and reports direct-write capability conservatively as unavailable. It never infers editability from name, description, curator, or playlist kind.
- `Playlist.Kind == nil` is not automatically classified as user-curated until the read-only device evidence in Task 1 confirms the observed shape. Unknown stays unknown; uncertain playlists do not become taste signals later by accident.
- A MusicKit item ID is opaque. Apple library playlist/entry IDs are bounded for storage but are not passed through the catalog-song ID validator and are never interpolated into Apple URLs.
- A catalog ID is populated only when a documented MusicKit surface or device evidence proves that identity. Do not relabel `Playlist.Entry.id` or `Playlist.Entry.Item.id` as a catalog ID merely because it looks numeric.
- The Music User Token stays inside MusicKit-managed client state. It is never added to a Flutter payload, server request, database row, error, or log.
- Playlist names, descriptions, curator names, titles, and artists are private user-derived data. Tests use fixtures; operational logs contain counts and fixed categories only.
- Action-time approval remains required for the read-only founder-device contract run, production migration, production deploy, and first production playlist upload.

## Locked implementation refinements

These refine the approved system design without changing its product behavior:

1. **One deep native snapshot module.** `PlaylistSnapshotStore` owns MusicKit requests, bounded pagination, entry ordering, artwork conversion, SHA-256 fingerprints, and memory release. `MusicKitBridge` remains a thin method-channel adapter.
2. **Materialize before upload.** The native module finishes reading every playlist and entry before returning a snapshot ID. Flutter pages only from that cached immutable value, so mutations after materialization cannot shift offsets. MusicKit offers no database-style transaction while materializing; duplicate IDs, non-progressing pagination, and changing counts fail the run instead of publishing a suspect snapshot. Apple's reported entry position is diagnostic only because the founder-device probe found 91 repeated values in one otherwise enumerable playlist.
3. **Typed relational staging.** Replace the design sketch's JSONB staging payloads with typed staging columns that mirror the validated wire contract. This gives database constraints to positions/counts/colours, makes completion an `INSERT … SELECT`-style publish, and avoids reparsing untrusted JSON inside the transaction.
4. **Exact retry semantics.** Re-uploading the same staging key with byte-equivalent normalized values succeeds. Reusing a key with different values returns `409 sync_conflict`; it never silently rewrites a supposedly immutable snapshot.
5. **Short publish transaction.** All Apple reads and HTTP uploads finish outside the transaction. Completion locks the user's music-profile row, validates staged counts, publishes canonical rows, soft-removes absent playlists, and commits. No network call occurs while a lock is held.
6. **Conservative identity resolution.** Link an entry to `tracks` by a proven catalog ID first. Otherwise use ISRC only when it resolves to exactly one global track. Never fuzzy-match title/artist during sync.
7. **Stable canonical IDs.** Upsert playlists by `(user_id, apple_library_id)` and entries by `(playlist_id, apple_library_entry_id)` so both internal UUIDs survive future snapshots and reorders. Preserve duplicate songs as their distinct Apple entry IDs; never deduplicate a playlist by track identity.
8. **Keyset browse cursors.** Playlist pages use `(sort_at, id)` and entry pages use `(position, id)`. Do not use deep SQL `OFFSET` pagination.

## Collision boundary

- A concurrent web task owns `netlify.toml`, `web/`, and currently `docs/decisions.md`. Do not modify or stage those paths until that owner releases them.
- Existing unrelated edits in `AGENTS.md` and `CLAUDE.md` are not part of this plan.
- New Swift files require explicit Runner target membership in `client/ios/Runner.xcodeproj/project.pbxproj`.
- Generate migrations with `npm run db:generate`; inspect generated SQL and metadata. Do not hand-invent migration filenames.
- Production deploys come from a clean worktree at the exact reviewed commit, never the shared working tree.

---

## Task 1: Pin the read-only MusicKit playlist contract on the founder's iPhone

**Files:**

- Temporarily modify: `client/ios/Runner/MusicKitBridge.swift`
- Temporarily modify: `client/lib/data/musickit/musickit_bridge.dart`
- Temporarily modify: `client/lib/main.dart` or add a DEBUG-only trigger
- Modify after evidence: `docs/superpowers/specs/2026-08-31-artwork-playlist-intelligence-design.md`
- Modify after evidence, once its owner releases it: `docs/decisions.md`
- Remove all probe-only source before commit

- [x] **Step 1: Write a temporary DEBUG-only read probe.** Use `MusicLibraryRequest<Playlist>` and `playlist.with(.entries, preferredSource: .library)`. It must not call `MusicLibrary.add`, `createPlaylist`, `edit`, `MPMediaPlaylist.addItem`, or any REST mutation.
- [x] **Step 2: Return fixed categories and counts only.** Capture:
  - storefront present and normalized to two lowercase ASCII letters;
  - total playlists and entries;
  - observed `Playlist.Kind` counts, including nil/unknown;
  - whether playlist IDs are non-empty and unique;
  - whether enumeration order agrees with monotonic `entry.position` and whether Apple's first reported position is zero- or one-based;
  - whether duplicate occurrences receive distinct entry IDs;
  - entry item availability by song/music-video/none;
  - ISRC presence count;
  - whether item IDs differ from entry IDs and whether any known catalog identity can be proven without inference;
  - valid artwork URL/dimension/background-colour counts.
- [x] **Step 3: Keep private data out of output.** Do not return or print playlist names, descriptions, curator names, IDs, track titles, artists, ISRCs, artwork URLs/colours, token data, or localized Apple errors.
- [x] **Step 4: Compile before device access.** Run `cd client && flutter test`, then the unsigned iOS build. If CocoaPods remains unavailable, use the already-established direct `xcodebuild` workspace command and record that boundary honestly.
- [x] **Step 5: Ask for action-time approval** immediately before reading the device playlist library through the probe.
- [x] **Step 6: Run once on the unlocked founder iPhone.** Capture only the fixed aggregate contract. This is read-only; no modified timestamp or playlist entry should change.
- [x] **Step 7: Remove the probe completely.** Search for its flag/method names and verify zero matches. Rebuild after removal.
- [x] **Step 8: Update the design contract.** Pin observed position normalization, kind mapping, identifier posture, and storefront behavior. If a catalog identity cannot be proven, keep `appleCatalogId` null and use ISRC-only exact resolution.
- [x] **Step 9: Adversarial review.** Confirm no mutation method is reachable, private strings cannot appear in logs, and the probe did not create a permanent debug endpoint.
- [x] **Step 10: Commit documentation only.** Headline: `docs: Record playlist read contract`.

**Gate:** Stop before schema implementation if user playlists cannot be enumerated with ordered entries or if MusicKit access changes playlist contents during a read-only run.

**Evidence:** 36 playlists and 1,333 song entries enumerated; IDs complete/unique; 16 duplicate-song groups preserved by distinct entry IDs; storefront valid; 35 playlists reported clean zero-based positions and one reported 91 repeated/non-increasing values, so enumeration index is canonical. Typed artwork exposed 1,363 background colours but no usable dimensions or URL across 1,369 artwork objects. No ISRC or proven catalog identity was observed. The documented raw playlist REST metadata route did not produce a usable body through `MusicDataRequest` and is not a Phase 2 dependency.

## Task 2: Add canonical and staging playlist schema

**Files:**

- Modify: `server/src/db/schema.ts`
- Create: generated migration `server/drizzle/0012_*.sql` and metadata
- Modify: `server/test/db.test.ts`
- Create: `server/test/playlists/schema.test.ts` if separation keeps `db.test.ts` focused

- [x] **Step 1: Write failing schema tests** before adding tables. Cover nullable metadata, artwork checks, nonnegative counts/positions/durations, playlist duplicates at different positions, user-scoped uniqueness, foreign-key cascades, and soft removal.
- [x] **Step 2: Add `user_music_profiles`.** Exact fields:
  - `user_id text primary key` → Better Auth user, cascade delete;
  - `apple_storefront text not null` with `^[a-z]{2}$` check;
  - nullable `library_synced_at`, `playlists_synced_at` timestamptz;
  - `created_at`, `updated_at` timestamptz.
- [x] **Step 3: Add canonical `user_playlists`.** Preserve the approved metadata and add no inferred capability:
  - internal UUID primary key;
  - `user_id`, `apple_library_id`, nullable proven `apple_catalog_id`;
  - name/description/curator snapshots;
  - artwork URL/dimensions/background colour;
  - raw normalized kind: `user | editorial | external | personal_mix | replay | user_shared | unknown`;
  - `can_edit boolean not null default false` and `is_mixtape_owned boolean not null default false`;
  - Apple dates, source fingerprint, `in_library`, created/updated timestamps;
  - unique `(user_id, apple_library_id)`.
- [x] **Step 4: Add canonical `playlist_entries`.** Include position, nullable resolved `track_id`, Apple library entry ID, nullable proven catalog ID, nullable `isrc_snapshot`, title/artist/album/duration/artwork snapshots, and timestamps. Unique `(playlist_id, position)` prevents two entries in one slot; unique `(playlist_id, apple_library_entry_id)` preserves stable internal entry UUIDs across reorders while distinct Apple entry IDs preserve duplicate songs.
- [x] **Step 5: Add `playlist_sync_runs`.** Store user, status (`open | completed | failed | expired`), expected and received counts, storefront, start/expiry/completion timestamps, and the final summary needed for idempotent completion responses. Add a partial unique index for one `open` run per user.
- [x] **Step 6: Add typed staging tables.** `playlist_sync_playlists` is keyed by `(sync_id, apple_library_id)` with a unique `(sync_id, ordinal)`; `playlist_sync_entries` is keyed by `(sync_id, apple_playlist_id, position)` and has a composite foreign key back to the staged playlist. Mirror only normalized wire fields and include each playlist's declared entry count.
- [x] **Step 7: Index every foreign key and actual query shape.** Required indexes include:
  - active browse expression/keyset index on user plus `coalesce(apple_last_modified_at, updated_at)` and ID;
  - canonical entries `(playlist_id, position)`;
  - optional resolved `track_id` index;
  - sync runs `(user_id, status, started_at)`;
  - staging entry lookup `(sync_id, apple_playlist_id, position)`.
- [x] **Step 8: Generate and inspect migration 0012.** It must be expand-only: new tables/checks/indexes only. No rewrite or drop of artwork, tracks, user tracks, sessions, or auth schema.
- [x] **Step 9: Run focused and authoritative checks.** Run schema tests, typecheck, then `npx vitest run --no-file-parallelism`.
- [x] **Step 10: Adversarial review.** Try cross-user duplicate Apple IDs, duplicate positions, empty playlists, 0-playlist snapshots, invalid colours, missing FK indexes, and cascade cleanup of staging/canonical rows.
- [x] **Step 11: Commit.** Headline: `feat(server): Add playlist snapshot schema`.

## Task 3: Implement the native immutable playlist snapshot module

**Files:**

- Create: `client/ios/Runner/PlaylistSnapshotStore.swift`
- Modify: `client/ios/Runner/MusicKitBridge.swift`
- Modify: `client/ios/Runner.xcodeproj/project.pbxproj`
- Modify: `client/lib/data/musickit/musickit_bridge.dart`
- Modify: `client/test/data/musickit_bridge_test.dart`
- Modify: `client/test/native_musickit_contract_test.dart`
- Modify: `client/test/helpers/fake_bridge.dart` and any bridge fakes

- [x] **Step 1: Write failing Dart/native-source contract tests.** Pin method names, defensive decoding, page limits, snapshot-ID requirements, release behavior, and exact Swift/server artwork/ID validation parity where applicable.
- [x] **Step 2: Define the small native interface.** Recommended channel surface:

  ```text
  beginPlaylistSnapshot()
    -> { snapshotId, storefront, totalPlaylists, totalEntries }

  fetchPlaylistSnapshotPage(snapshotId, offset, limit)
    -> { playlists[], total }

  fetchPlaylistEntryPage(snapshotId, playlistAppleId, offset, limit)
    -> { entries[], total }

  cancelPlaylistSnapshot()
    -> true

  releasePlaylistSnapshot(snapshotId)
    -> true
  ```

- [x] **Step 3: Implement `PlaylistSnapshotStore` as an actor.** It owns one active materialization task or immutable snapshot. A new begin cancels/replaces the old one; `cancelPlaylistSnapshot` cancels an in-progress MusicKit task even before a snapshot ID is returned; mismatched IDs and cold nonzero pages fail with fixed `no_snapshot`/`snapshot_mismatch` categories.
- [x] **Step 4: Materialize playlists with bounded MusicKit paging.** Page playlists and each entries relationship until `hasNextBatch` is false. Reject repeated playlist IDs, inconsistent counts, duplicate normalized positions, non-progressing pagination, or hard safety ceilings; never silently truncate.
- [x] **Step 5: Normalize entry order from collection enumeration.** Send zero-based contiguous positions from the materialized collection. Keep Apple's reported `entry.position` only as a validation signal determined in Task 1, not as an unchecked database position.
- [x] **Step 6: Map identifiers conservatively.** Always send bounded playlist ID and entry ID. Send ISRC when valid. Send `appleCatalogId` only under the Task 1 proven rule; otherwise null. Preserve music-video/local/unresolved entries as snapshots instead of dropping them.
- [x] **Step 7: Map artwork safely.** Request a fixed browse source size, retain only positive maximum dimensions, convert `CGColor` through sRGB into lowercase six-digit hex, and allow any unrepresentable colour/URL to become null. Preserve a valid background colour even when URL/dimensions are absent; this was the dominant founder-device shape. The server revalidates every value.
- [x] **Step 8: Compute `sourceFingerprint` with CryptoKit.** Pin a versioned, length-prefixed canonical byte serialization of playlist library ID, last-modified milliseconds, and every ordered entry's stable identifiers/fallback snapshot fields. Do not hash locale-dependent descriptions or Swift `String(describing:)` output.
- [x] **Step 9: Bound time/memory and release deterministically.** Check Swift task cancellation between every page/playlist, give Dart begin a dedicated bounded timeout, and cancel/release on success, error, cancellation, auth transition, or a new begin. A snapshot-too-large condition fails before any server sync begins.
- [x] **Step 10: Add the new Swift file to the Runner target** and compile Debug/Profile/Release through the workspace.
- [x] **Step 11: Run Flutter tests and unsigned iOS build.** No device mutation is involved.
- [x] **Step 12: Adversarial review.** Cover empty playlists, duplicates, music videos, missing item, local import, null artwork, playlist mutation during materialization, wrong snapshot ID, page-after-release, and completion called twice.
- [x] **Step 13: Commit.** Headline: `feat(client): Read Apple Music playlists`.

**Evidence:** 241 Flutter tests and `flutter analyze` pass. The standard unsigned Flutter build remains blocked before compilation by the known broken CocoaPods CLI; direct workspace builds compile successfully in Debug, Profile, and Release. The actor re-reads playlist metadata plus ordered entry IDs/counts before publishing a snapshot, and exposes no mutation or private logging surface.

## Task 4: Add the staged sync store and authenticated ingest routes

**Files:**

- Create: `server/src/playlists/contracts.ts`
- Create: `server/src/playlists/sync-store.ts`
- Create: `server/src/routes/playlist-ingest.ts`
- Modify: `server/src/app.ts`
- Create: `server/test/playlists/sync-store.test.ts`
- Create: `server/test/playlists/ingest-routes.test.ts`

- [x] **Step 1: Write failing contract/route tests.** Cover authentication, cross-tenant 404s, chunk ceilings, invalid IDs/positions/colours, zero-playlist completion, duplicate occurrences, exact idempotent retry, conflicting retry, invalid state, and count mismatch.
- [x] **Step 2: Define normalized wire contracts.** Bound user-derived strings and IDs by length, reject NUL/invalid scalar data while preserving valid Unicode and description line breaks, use the shared artwork normalizer, and cap playlist chunks at 50 and entry chunks at 200. Do not sanitize-for-prompt here; preserve valid display text and sanitize only when later rendered into a prompt.
- [x] **Step 3: Implement the deep `PlaylistSyncStore` interface:**

  ```ts
  begin(userId, storefront, expectedPlaylists, expectedEntries)
  putPlaylists(userId, syncId, playlists)
  putEntries(userId, syncId, playlistAppleId, entries)
  complete(userId, syncId)
  ```

  Routes/tests cross this seam; transaction details remain private.
- [x] **Step 4: Serialize starts per user.** Upsert and lock `user_music_profiles`, expire any prior open run, then create one new run. Two simultaneous starts must converge without leaving two open runs.
- [x] **Step 5: Make chunk writes exactly idempotent.** Sort multi-row writes by stable key to prevent deadlocks. A repeated normalized row succeeds only if every persisted value matches; a changed retry returns a fixed conflict without exposing stored private data.
- [x] **Step 6: Publish in one short transaction.** Lock profile then run in the same consistent order; verify run state, expected totals, per-playlist declared entry counts, and staged foreign references. Then:
  1. upsert canonical playlists while preserving trusted `is_mixtape_owned`;
  2. resolve `track_id` by proven catalog ID or unique exact ISRC only;
  3. merge entries by `(playlist_id, apple_library_entry_id)`, preserving internal UUIDs while safely reordering, inserting new occurrences, and deleting stale occurrences;
  4. mark previously active but absent playlists `in_library = false` without deleting their last snapshot;
  5. update `playlists_synced_at` and received counts;
  6. mark the run completed and return its stored summary.
- [x] **Step 7: Keep publish set-based.** Use staged `INSERT … SELECT`/update/delete statements in deterministic order instead of loading the entire library into Worker memory or constructing one giant bind-parameter list.
- [x] **Step 8: Keep completion retry-safe.** A second completion of the same completed run returns the stored summary. It does not republish or create new canonical IDs.
- [x] **Step 9: Add authenticated endpoints:**

  ```text
  POST /ingest/playlists/syncs
    { storefront, expectedPlaylists, expectedEntries }

  PUT /ingest/playlists/syncs/:syncId/playlists
    { playlists[] }

  PUT /ingest/playlists/syncs/:syncId/entries
    { playlistAppleId, entries[] }

  POST /ingest/playlists/syncs/:syncId/complete
    -> { playlists, entries, resolvedEntries, unresolvedEntries }
  ```

- [x] **Step 10: Add `PUT` to allowed CORS methods.** Preserve current auth/header behavior.
- [x] **Step 11: Test atomicity with PGlite.** Inject a failure immediately before publish completion and prove canonical playlists/entries/profile timestamp remain unchanged.
- [x] **Step 12: Run focused tests, typecheck, and authoritative suite.**
- [x] **Step 13: Adversarial review.** Attempt cross-user sync IDs, conflicting parallel completion, stale open runs, malformed Apple text, duplicate catalog/ISRC mappings, missing profile row, 500-entry attack, and logs containing fixture names.
- [x] **Step 14: Commit.** Headline: `feat(server): Stage playlist snapshots`.

## Task 5: Extend Flutter sync from songs to complete playlist snapshots

**Files:**

- Modify: `client/lib/data/api/api_client.dart`
- Modify: `client/lib/data/library/library_sync_service.dart`
- Modify: `client/lib/presentation/providers/library_sync_provider.dart`
- Modify: `client/lib/presentation/screens/home_screen.dart`
- Modify: `client/test/data/api_client_test.dart`
- Modify: `client/test/data/library_sync_service_test.dart`
- Modify: provider/screen tests and bridge fakes

- [x] **Step 1: Write failing API/sync tests.** Pin `PUT` auth/JSON behavior and the full order: authorize → song pages → native playlist snapshot → server begin → playlist chunks → entry chunks → complete → native release.
- [x] **Step 2: Replace the scalar result with a summary.** `LibrarySyncSummary` contains `songs`, `playlists`, `entries`, `resolvedEntries`, and `unresolvedEntries`. Update `SyncDone` and the existing sync sheet copy without adding a browse screen.
- [x] **Step 3: Add `ApiClient.putJson`.** Match post/patch error and timeout behavior; no new auth mechanism.
- [x] **Step 4: Keep songs first.** Existing song pages finish before `beginPlaylistSnapshot`, maximizing exact track resolution during server completion.
- [x] **Step 5: Upload the immutable snapshot.** Begin the server run with native totals/storefront, page every playlist, page every playlist's entries including empty lists, and call complete only after uploaded counts exactly equal native totals.
- [x] **Step 6: Preserve cancellation discipline.** Check cancellation after every await. Cancellation or any error skips complete. If native materialization is still running, call `cancelPlaylistSnapshot`; a `finally` block releases any completed native snapshot. An open server run remains harmless and is expired by the next begin/cleanup.
- [x] **Step 7: Keep re-entrant behavior.** Concurrent sync taps join one run. Auth transitions cancel the owner and rebuild the user-scoped provider as today.
- [x] **Step 8: Define progress by completed work.** Use monotonic stage weights across song upload and playlist/entry upload; hold at the native-stage boundary while MusicKit materializes because the framework exposes no per-request progress callback. Never report 100% before server completion succeeds.
- [x] **Step 9: Update existing sync UI minimally.** Success reports song and playlist counts; unresolved entries are an informational count only when nonzero. Failure copy remains private and fixed-category.
- [x] **Step 10: Test interruption at every boundary.** Especially: song failure means no playlist begin; playlist upload failure means no complete; cancellation after final upload but before complete means no publish; release happens once on success/failure/cancel.
- [x] **Step 11: Run full Flutter tests and unsigned iOS build.**
- [x] **Step 12: Adversarial review.** Check progress regression, division by zero, snapshot leaks, second-user auth transition, huge empty playlists, and an API error body reaching debug/user output.
- [x] **Step 13: Commit.** Headline: `feat(client): Sync playlist snapshots`.

## Task 6: Add private playlist browse APIs and client data contracts

**Files:**

- Create: `server/src/playlists/browse-store.ts`
- Create: `server/src/routes/playlists.ts`
- Modify: `server/src/app.ts`
- Create: `server/test/playlists/browse.test.ts`
- Create: `client/lib/data/playlists/playlist_models.dart`
- Create: `client/lib/data/playlists/playlist_api.dart`
- Create: `client/test/data/playlist_api_test.dart`

- [x] **Step 1: Write failing browse tests.** Cover auth, tenant isolation, active/all status, case-insensitive name search, stable ordering, cursor tampering, empty result, null artwork, unresolved entries, duplicate entries, and soft-removed detail behavior.
- [x] **Step 2: Define the summary endpoint:**

  ```text
  GET /playlists?status=active&q=&limit=30&cursor=
    -> { playlists[], nextCursor }
  ```

  Each summary includes internal ID, name, curator, kind, artwork, entry count, known duration, last-modified/synced timestamps, and conservative capability (`copy_only` in Phase 2). It does not expose Apple library IDs.
- [x] **Step 3: Define paged detail:**

  ```text
  GET /playlists/:id?entryLimit=200&entryCursor=
    -> { playlist, entries[], nextEntryCursor }
  ```

  Entries include internal entry ID, zero-based position, nullable resolved track ID/catalog ID, title/artist/album/duration/artwork snapshots, and `resolved`. Library-only identifiers remain server-internal until a later apply plan needs them.
- [x] **Step 4: Use keyset cursors.** Base64url-encode a versioned JSON tuple, validate shape/length, and use parameterized comparisons. Playlist order is `coalesce(apple_last_modified_at, updated_at) DESC, id DESC`; entries are `position ASC, id ASC`.
- [x] **Step 5: Avoid N+1 queries.** Fetch page summaries and their count/duration aggregates in one bounded query. Fetch detail metadata and one entry page in at most two queries.
- [x] **Step 6: Enforce ownership in every store query.** Join/filter by `user_id`; another user's UUID and malformed UUID both return the same 404 response.
- [x] **Step 7: Make nulls explicit and consistent.** Artwork fields and unresolved track fields use explicit nulls across server and Dart models.
- [x] **Step 8: Add defensive Dart models/API.** Parse malformed optional fields with the existing tolerant conventions, but fail fixed-category on missing required playlist/entry identity or display fields. Do not add Riverpod providers/screens yet.
- [x] **Step 9: Run server focused/full checks and full Flutter tests.**
- [x] **Step 10: Adversarial review.** Try cursor replay after a newer sync, Unicode/case search, `%`/`_` wildcard input, another user's UUID, a 10,000-entry playlist, and null/local entries.
- [x] **Step 11: Commit.** Headline: `feat: Add playlist browse contracts`.

## Task 7: Expire abandoned staging safely and finalize operational docs

**Files:**

- Create: `server/src/playlists/cleanup.ts`
- Modify: `server/src/enrich/scheduled.ts` or introduce a narrowly named scheduled coordinator
- Modify: `server/src/index.ts`
- Create/modify: cleanup and scheduled tests
- Modify: `docs/superpowers/specs/2026-08-31-artwork-playlist-intelligence-design.md`
- Modify: `docs/backlog.md`
- Modify only after collision release: `docs/decisions.md`

- [x] **Step 1: Write failing cleanup tests.** Runs older than 24 hours in `open` become `expired`; staging for expired runs older than the retention window is deleted in bounded batches. Completed runs retain their summary but may shed staging rows.
- [x] **Step 2: Implement bounded cleanup.** One cron invocation touches at most 25 runs, orders oldest first, and returns counts only. It must not log user IDs, playlist data, or errors.
- [x] **Step 3: Keep maintenance independent.** Playlist cleanup still runs if feature/artwork dependencies are absent; its failure does not suppress enrichment/artwork and vice versa.
- [x] **Step 4: Run focused, authoritative, and type checks.**
- [x] **Step 5: Adversarial review.** Check cleanup racing an active upload/complete, cascade cost, unindexed age/status query, and long transaction scope.
- [x] **Step 6: Update docs.** Record the observed read contract, typed-staging refinement, conservative capability posture, and the inconclusive possible probe side effect. Do not claim playlist taste or editing has shipped.
- [x] **Step 7: Commit.** Headline: `fix(server): Expire playlist sync staging`.

## Task 8: Migrate, deploy, and run the first read-only founder sync

**Files:**

- Create if useful: a counts-only production verification script under `server/scripts/`
- Modify after evidence: `docs/backlog.md`
- Modify after collision release: `docs/decisions.md`

- [x] **Step 1: Run all local gates at committed HEAD:**
  - `cd server && npx vitest run --no-file-parallelism && npm run typecheck`;
  - `cd client && flutter test`;
  - unsigned iOS workspace build;
  - `git diff --check`;
  - search for probe flags/mutation methods introduced by Phase 2; expected: no probe and no new write path.
- [x] **Step 2: Run an independent plan/app/security review and fix every actionable finding.** Re-run the affected focused suites plus all authoritative gates after fixes.
- [x] **Step 3: Create a clean deployment worktree** from the exact reviewed commit and verify it is clean.
- [x] **Step 4: Ask separately for action-time approval** before production migrations 0012–0014, Worker deployment, and the first private playlist upload.
- [x] **Step 5: Apply migrations 0012–0014 from the clean worktree.** Verify all six tables, checks, unique constraints (including stable playlist-entry identity), foreign-key indexes, active-run partial index, browse keyset index, and bounded-cleanup indexes before deploying code.
- [x] **Step 6: Deploy the exact reviewed Worker.** Verify `/health` 200, `/me` 401, existing enrichment/artwork status counts unchanged, unauthorized playlist routes 401, and no missing-secret/startup regression.
- [x] **Step 7: Run the founder sync from the iPhone.** It is read-only toward Apple Music. Record only total playlists, total entries, resolved/unresolved counts, duration, and fixed failure category.
- [ ] **Step 8: Compare the published snapshot to Apple Music.** Founder-approved manual checks:
  - total playlist count matches the library view within a documented Apple-generated exclusion rule;
  - both disposable playlists appear;
  - a duplicate-containing playlist preserves both occurrences and order;
  - an empty playlist stays empty;
  - a local/unresolved entry stays visible;
  - three cover URLs render and background colours are valid when present.
- [x] **Step 9: Prove deletion safety without mutating Apple.** In production, do not manufacture an interrupted sync. Rely on the transaction tests and query that only completed-run data is canonical. A later natural retry must keep stable internal playlist IDs.
- [x] **Step 10: Record exact rollout evidence.** State plainly that collection/browse contracts are shipped while taste, conversational editing, mutation, and browse UI remain deferred.
- [x] **Step 11: Remove the clean worktree** only after confirming it has no unique changes.
- [ ] **Step 12: Commit rollout documentation.** Headline: `docs: Record playlist sync rollout`.

### Production rollout evidence — 2026-09-01

- Migrations `0012`–`0014` applied and all six playlist tables plus their constraints/indexes verified before deploy.
- Reviewed commit `f9d5e91` deployed as Worker version `e35b134c-c045-4267-92b6-31c42c918159`; health/auth smoke checks passed and artwork remained 4,686 present / 3 missing.
- The first client attempt staged 36 playlist headers and 958/1,333 entries, then failed. Canonical tables stayed at zero, proving a real interrupted upload could not leak partial state.
- The natural retry expired that open run and completed in 15 seconds: 36 playlists and 1,333 entries published, with both disposable playlists present, zero ordering gaps, and 16 repeated-song occurrences preserved across three playlists.
- This founder library had no empty playlist, so the production empty-playlist observation remains unexercised; transaction and route tests cover it.
- MusicKit returned background colours for all 36 playlists and 1,329 entries but no usable playlist/entry artwork URLs. Nullable browse contracts behaved as designed; album artwork remains independently populated on canonical tracks.
- All 1,333 entries carried library-track IDs, but none carried a catalog ID or ISRC, so resolved/unresolved was 0/1,333. Collection and browsing are shipped; an on-device library-song-to-catalog crosswalk is required before Phase 3 can use membership as a canonical-track taste signal.
- A follow-up founder-device sync resolved those opaque library-song IDs through typed `MusicLibraryRequest<Song>` batches. All 1,333 staged entries carried an exact Apple catalog ID; 353 linked immediately to existing canonical tracks and 980 remained unresolved for catalog ingestion. MusicKit returned no ISRCs through this path. The sync completed in production without logging tokens, IDs, playlist metadata, or track metadata.

---

## Phase 2 exit gates

- The read-only device contract is recorded without playlist metadata or a mutation path left in source.
- The native snapshot reproduces playlist count, exact order, duplicates, empty playlists, music-video/local/unresolved entries, and artwork metadata without silently truncating.
- A failed, cancelled, expired, or count-mismatched sync leaves the previous canonical snapshot untouched.
- Chunk retry is idempotent; conflicting retries and cross-user access fail safely.
- Canonical publish is one short transaction and concurrent device syncs cannot leave two active snapshots.
- Playlist and entry IDs remain stable across a successful re-sync.
- Browse APIs are authenticated, tenant-scoped, keyset-paginated, and return explicit nullable artwork/unresolved fields.
- The client completes song sync before playlist sync, cancels cleanly on auth transition, and always releases native snapshot memory.
- Production migration/deploy and the first private founder snapshot are measured and recorded.
- Existing artwork, enrichment, mix, playback, create-playlist, auth, web, and memory behavior do not regress.
- No Music User Token, playlist metadata, track metadata, Apple response body, or raw localized error enters operational logs.

## Explicitly deferred

- Phase 3: eligible playlist taste scoring and playlist-as-seed mix generation.
- Phase 4: playlist-edit sessions, catalog search, on-demand enrichment, deterministic drafts/diffs, prepare/confirm protocol.
- Phase 5: append verification, MusicKit-created exact-rebuild spike, revised-copy apply, approval state board, playlist browse/detail/edit UI, and end-to-end device smoke.
- Any attempt to identify or restore the possibly missing disposable-playlist song; no trustworthy pre-probe snapshot exists.
