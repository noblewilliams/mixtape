# Web sync and consumption — delivery plan

*Status: active · reconciled with the listening-export handoff 2026-09-04*
*Design: [web sync and consumption](../specs/2026-09-01-web-sync-consumption-design.md)*
*Approval: [combined Your music decision](../../mockups/approved/2026-09-04-web-your-music-integration.md), 2026-09-04; [board](../../mockups/2026-09-04-web-your-music-integration-states.html). The original Apple board remains historical, not approved.*

This is one continuous delivery track. Playlist intelligence is not paused: the existing native staging and browse work is reused by the browser adapter, then exposed through the web product flow.

## Resumption boundary — 2026-09-04

The listening-export handoff at `75f7e0d` adds completed Spotify import services, approved UI, source management, and mixed-platform mix outputs. Reuse that work; do not recreate the import parser or replace its approved request/waiting/import states. The new board proposes only the shared navigation, source overview, Apple sync states, and source-aware playlist collection/detail.

- **This task now:** the board, the [integration regression matrix](2026-09-04-web-music-integration-checks.md), then narrowly scoped web integration and missing interfaces after approval.
- **Concurrent catalog task:** `server/src/playlists/catalog-resolution.ts`, catalog/artwork normalization, scheduler, schema, migration `0020` and the journal/snapshot. Do not edit those paths or generate another migration until its commit is finished and re-inspected. Its catalog resolution does not establish library membership.
- **Expanded ownership confirmed during preparation:** that task also owns playlist-origin receipts/confirmation, migration `0021`, taste scoring, native playlist creation, and the corresponding web `App`, API client, MusicKit client, fake API, and tests. Another local slice owns Spotify ID enrichment. Leave all of these untouched and unstaged. Its browse `origin` and explicit confirmation API must be re-read after integration; origin confirmation UI is outside this board. Existing playlist familiarity behavior below is historical and is being replaced by the origin/taste task.
- **Shared docs:** the concurrent task is editing `docs/backlog.md` and `docs/decisions.md`; record this pass here until those edits settle. No edits to `docs/handoff.md` or its historical verification totals.
- **Release and other work:** production migration verification, push/deploy, real exports, privacy disclosures, Spotify enrichment/cross-link, relay/embed probes, and Apple history parsing are outside this task. Local Spotify ID enrichment is already underway elsewhere; do not duplicate it.

### Immediate sequence

1. [x] Read the handoff, current implementation, and approved Spotify changes; identify overlapping files.
2. [x] Define mixed-source preservation, upload coordination, partial-completion, and browse-contract regression cases without adding a failing test to another task's active full-suite run.
3. [x] Render and inspect the combined board at desktop, tablet, mobile, dark, large-text, and reduced-motion settings. See the preparation evidence below; no production integration tests are claimed.
4. [x] Obtain approval for the new/shared states only. Founder approved 2026-09-04; existing Spotify approvals remain in force.
5. [x] After the catalog commit, add red-first integration tests and implement browse source/freshness fields and both-direction upload coordination. The handoff task implemented the source-membership boundary; preserve accepted import count semantics.
6. [x] Implement Apple connect → real sync → truthful result → playlists, within the existing app-owned lifetime and auth boundary.
7. [ ] Finish memories and mix rename/archive/unarchive as a subsequent bounded UI slice. Those surfaces are not approved by the new music board.

### Approved interaction contract

- One stable `Your music` destination, with `Playlists` and `Sources` sections. First-use defaults to Sources; a completed music snapshot defaults to Playlists, including a truthful empty collection. Returning within the signed-in app preserves the selected section.
- Sources is a set, not a single mutually exclusive service. Apple authorization is separate from Mixtape login; one browser may need authorization even when another device already synced the account.
- Sources opens each provider's workspace in the same content plane. The Spotify workspace keeps the approved inner states and parser/import-run lifetime; adding Apple cannot reset it.
- Real Apple sync is app-owned and survives navigation, like the Spotify run. Sign-out aborts and releases it. A single shared upload gate prevents Apple and Spotify playlist runs from expiring each other; reading files and browsing do not need this lock.
- Counts are stage-specific. Never present a synthetic overall percentage or turn an unknown denominator into a guessed one.
- Library and playlist completion are separate transactions. If library completion succeeds and playlist completion fails/cancels, show a partial result: new songs are retained and the previous playlist snapshot remains. A lost completion response is unconfirmed until an idempotent retry or authoritative read resolves it; never promise that nothing was published in that state.
- Browsing uses service identity returned by the server, never title/id guessing. Missing artwork gets a neutral fallback; unresolved entries and duplicate occurrences retain their exact positions. No playlist-seed/edit promise, guessed provider playlist URL, or Apple-export upload control is introduced.

## Original foundation delivery

### Preparation evidence — 2026-09-04

- Added a self-contained 33-state board covering the shared source/browse destination, Apple sync and recovery, running-upload navigation, and representative preserved Spotify context. Includes full-window mode for direct responsive checks.
- Browser-measured all 33 states at 320, 390, 760, 768, 1020 and 1240px in light/normal text and dark/large text/opaque modes: 396 checks, with no document horizontal overflow, measured control overflow, cover-title overflow, or visible control heights below 44px. These are mockup layout checks, not application tests.
- Visually inspected desktop collection, narrow dark/large-text sources, mobile partial completion and unresolved playlist tracks, and tablet dark/large-text upload progress. Corrected a template CSS serialization issue, cramped track status, repeated duration, duplicate action, and gradient seams found during review.
- Verified keyboard focus has a visible 3px outline, stop-playlist action enters the partial-result scene, reduced motion disables animation, opaque mode removes sidebar blur and uses solid card fill. Motion-enabled mode retains the current 10-second gradient movement.
- Inline script syntax, four local document links, and scoped whitespace/diff hygiene passed. The board uses synthetic content and no external assets or provider requests.
- Added the regression matrix, including source-local membership, partial/unknown publication, both-direction upload ownership, source freshness/counts, and origin preservation. Those production cases are specified, not executed.
- Coordinated ownership directly with the playlist task. It completed its separate commit `1fb6c92` during this pass; shared paths are available again. Verified the commit adds origin/receipt behavior, not browse source identity or source-specific freshness. Its Spotify deletion change clears Spotify origin confirmations, not the separate dual-ID library-membership edge. Nothing from another task was modified or staged here. No production code, migrations, account data, deployment, or Git commit by this task in this preparation pass.

The founder approved the new/shared states after this preparation. Existing Spotify approvals are not superseded. Implementation starts against `1fb6c92`; the handoff task now owns source membership (migration 0022, library/listening stores) and Spotify enrichment. Leave those files untouched and integrate their verified results. This task owns browse contracts, web sync coordination and approved UI.

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

### 4. Product UI approval — approved September 4

- [x] Draft first-connect, progress, failure, synced, playlist list, playlist detail, mobile, dark, large-text, reduced-motion, and unresolved-track states.
- [x] Approve the dedicated `Your music` destination and state hierarchy.
- [x] Browser-render the board through the local dev origin.

### 5. Real sync UI — implemented locally

- [x] Replace the static 68% overlay with `MusicSyncService` progress.
- [x] Wire connect, cancel, retry, terminal summary, last-sync time, and reconnect states.
- [x] Keep the previous completed server snapshot usable during a failed new attempt.
- [x] Cancel and release in-memory snapshot work on sign-out or app disposal, not view navigation.
- [x] Add component coverage for progress, authorization, cancellation, upload gating, partial, empty-complete, and unconfirmed outcomes; measure the primary layouts at all six approved breakpoints.
- [ ] Complete exhaustive production-UI large-text/reduced-preference and real-device checks; board checks alone are not production-UI verification.

### 6. Web consumption parity — follows the same implementation pass

- [x] Add the `Your music` route/view and paginated playlist collection.
- [x] Add search, playlist detail pagination, unresolved/local-track treatment, and artwork fallbacks.
- [ ] Surface DJ memories with explicit delete confirmation.
- [ ] Surface session rename, archive, and unarchive.
- [x] Keep existing mix creation, refinement, playback, queue editing, and create-playlist flows intact.

### 7. Operations and real-device gates

- [x] Add bounded cleanup for old library-sync staging rows to the maintenance cron.
- [x] Run the authoritative server suite, complete web suite, typechecks, and production build after UI integration. Frozen combined checkpoint: server 73 files / 1,259 tests plus typecheck; web 36 files / 349 tests plus production build.
- [ ] Across the launch browser matrix, probe duplicate playlist identity, background playback, auth expiry, empty playlists, and local/unresolved songs; Android Chrome is launch-critical coverage.
- [ ] Compare browser-visible counts/order against Apple Music without logging names, tokens, or Apple bodies.
- [ ] Apply migrations and deploy from a clean worktree only after review and action-time approval.

## Foundation verification — historical, 2026-09-01

- Server: 701 tests passed with `npx vitest run --no-file-parallelism`.
- Web: 72 tests passed with `npm test`.
- Web: production TypeScript and Vite build passed with `npm run build`.
- Server: TypeScript passed with `npm run typecheck`.

No migration has been applied, no Worker or web build has been deployed, and no Apple Music library has been accessed during this implementation pass.
