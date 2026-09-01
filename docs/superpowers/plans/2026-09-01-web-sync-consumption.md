# Web sync and consumption — delivery plan

*Status: active · 2026-09-01*
*Design: [web sync and consumption](../specs/2026-09-01-web-sync-consumption-design.md)*
*Approval board: [sync and playlist states](../../mockups/2026-09-01-web-sync-playlist-states.html)*

This is one continuous delivery track. Playlist intelligence is not paused: the existing native staging and browse work is reused by the browser adapter, then exposed through the web product flow.

## Delivery order

### 1. Source-aware library foundation — complete locally

- [x] Add deletion-safe staged song snapshots with start, chunk, and atomic completion routes.
- [x] Preserve known native play counts when web MusicKit reports the signal as unavailable.
- [x] Mark songs absent from a fully completed snapshot out of the active library.
- [x] Add bounded recent-track staging and canonical web observations.
- [x] Record iOS versus web source capability on song and playlist sync runs.
- [x] Add migrations 0015–0017 and tenant/idempotency/rollback coverage.

### 2. Browser MusicKit adapter — complete locally

- [x] Page library songs, playlists, playlist tracks, and recent tracks.
- [x] Normalize catalog-resolvable songs and retain unresolved playlist entries for honest browse.
- [x] Preserve duplicate playlist occurrences through deterministic browser identities.
- [x] Reject off-origin pagination and clear in-memory Apple authorization on 401/403.
- [x] Keep Music User Tokens in memory and out of Mixtape requests and persistence.
- [x] Upload songs before playlists through bounded retry-safe chunks with cancellation checks.

### 3. Web taste quality — complete locally

- [x] Represent unavailable play count as unknown rather than zero.
- [x] Use bounded recent-play rank for web-only familiarity.
- [x] Use active playlist membership as a second deliberate familiarity signal.
- [x] Keep native lifetime play counts authoritative whenever they have been observed.
- [x] Render unknown play count as `-` in the curation context.

### 4. Product UI approval — awaiting founder decision

- [x] Draft first-connect, progress, failure, synced, playlist list, playlist detail, mobile, dark, large-text, reduced-motion, and unresolved-track states.
- [ ] Approve the dedicated `Your music` destination and state hierarchy.
- [ ] Browser-render the board through the local dev origin; direct local-file rendering is blocked by the in-app browser security policy.

### 5. Real sync UI — next after approval

- [ ] Replace the static 68% overlay with `MusicSyncService` progress.
- [ ] Wire connect, cancel, retry, terminal summary, last-sync time, and reconnect states.
- [ ] Keep the previous completed server snapshot usable during a failed new attempt.
- [ ] Cancel and release in-memory snapshot work on sign-out or component disposal.
- [ ] Add component coverage for every approved state and responsive breakpoint.

### 6. Web consumption parity — follows the same implementation pass

- [ ] Add the `Your music` route/view and paginated playlist collection.
- [ ] Add search, playlist detail pagination, unresolved/local-track treatment, and artwork fallbacks.
- [ ] Surface DJ memories with explicit delete confirmation.
- [ ] Surface session rename, archive, and unarchive.
- [ ] Keep existing mix creation, refinement, playback, queue editing, and create-playlist flows intact.

### 7. Operations and real-device gates

- [x] Add bounded cleanup for old library-sync staging rows to the maintenance cron.
- [ ] Run the authoritative server suite, complete web suite, typechecks, and production build after UI integration.
- [ ] Across the launch browser matrix, probe duplicate playlist identity, background playback, auth expiry, empty playlists, and local/unresolved songs; Android Chrome is launch-critical coverage.
- [ ] Compare browser-visible counts/order against Apple Music without logging names, tokens, or Apple bodies.
- [ ] Apply migrations and deploy from a clean worktree only after review and action-time approval.

## Current verification

- Server: 701 tests passed with `npx vitest run --no-file-parallelism`.
- Web: 72 tests passed with `npm test`.
- Web: production TypeScript and Vite build passed with `npm run build`.
- Server: TypeScript passed with `npm run typecheck`.

No migration has been applied, no Worker or web build has been deployed, and no Apple Music library has been accessed during this implementation pass.
