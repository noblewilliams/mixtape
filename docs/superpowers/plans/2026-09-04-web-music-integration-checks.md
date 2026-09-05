# Web music integration — regression matrix

Status: implementation and local verification, 2026-09-04. Original test specification follows the execution record below. No production data changed; this slice adds no schema migration.

## Execution record — approved integration

- Web: `npm test` — 36 files / 349 tests passed. `npm run build` — both TypeScript configs and Vite production build passed. The former static sync overlay and its progress styles are removed. A new style contract pins 44px controls, visible focus, mobile track layout, dark/reduced-transparency fields, and the 10px type floor. Final adversarial review also removed the duplicate completion action and makes either approved completion exit clear the in-memory result, so a later Apple refresh is reachable without reloading.
- Server browse: 11 route tests passed, including full-source filtering, tenant isolation, per-playlist freshness, aggregate counts, and legacy membership returning an unknown song count. Browse + origin + membership focused run also passed (26 tests before the final aggregate regression was added).
- Final frozen combined server checkpoint: the authoritative serial run passed 73 files / 1,259 tests in 192.63 seconds. It includes source ownership and ISRC linking, playlist-inspired mixes and migration 0024, fallback artwork, this web browse/API work, and the `0014`-to-current migration rehearsal. Server typecheck also passed against that frozen checkout. Earlier moving-checkout totals remain historical only; this is the release-candidate local verification result.
- R1/R2/R3: shared lease tests, Spotify integration suite, Apple navigation-completion App test, and coordinator disposal/late-result test. The MusicKit factory is now per keyed sign-in. Inspecting a Spotify ZIP does not acquire the upload lease; uploading does.
- R4/R5/R6/R9/R10: service fault injection covers pre-publish cancellation, saved-library/failed-playlist partial results, between-publication cancellation, lost library and playlist confirmations, and same-ID reconciliation. Component tests pin unknown reading totals, stage-only percentages, cancelled, permission, unavailable, login-expired, offline, empty-complete, partial, blocked, and unconfirmed copy.
- R7: the service never automatically restarts a superseded run. Failed completion checks remain visibly unconfirmed, retain the lease, and expose fixed conflict guidance; no assertion that a lost earlier response means nothing was published. A dedicated multi-device live smoke remains part of the release gate.
- B1–B6/B8/B9: source-aware routes/types, server-side query filters, retained pages after a failed next-page request, stale-response suppression, exact duplicate/local rows and Spotify links, durable source counts without browser authorization, preserved Spotify tests and exact creation-receipt/origin coverage.
- B7: actual local UI measured at 320/390/760/768/1020/1240px for Playlists and Sources: no horizontal overflow and no visible action targets below 44px. Visually inspected desktop collection, mobile Sources, dark 320px playlist detail, partial sync, and same-run unconfirmed → complete. Sources and the two-column playlist collection were also visually checked at 200% browser zoom in the production component harness with no clipped copy, controls, or horizontal overflow. Found and fixed late initial navigation overriding an explicit section, detail scroll carry-over, heading focus, and typography specificity. Exhaustive reduced-preference, all-state large-text, and physical browser/device coverage remain open; the earlier 396 board checks are separate evidence.
- Migration rehearsal: a PGlite database is first migrated only through the production `0014` boundary, seeded with representative existing user, track membership, profile, playlist, and DJ-session rows, then upgraded through the current `0024` journal. The test passed, including default preservation, migration-0022 legacy membership backfill, playlist source default, session default, 0024 foreign keys, and all 25 ledger entries. This is local upgrade evidence only; no production connection or write was made.

Local visual entry: run `npm run dev -- --host 127.0.0.1 --port 4180` in `web/`, then open `/qa/your-music.html`. It imports actual App/components with synthetic API/MusicKit adapters and makes no provider or application API calls. Query `state=partial`, `checking`, `reading`, `sources-failed`, or `collection-failed` selects fault scenarios. It is not a production Vite entry and is absent from `dist/`.

Implementation boundaries: the handoff task owns source membership (0022), Spotify enrichment and ISRC linking (0023); the playlist task owns backend playlist-inspired mixes (0024). This task owns no catalog, schema, scheduler, curation, or seed implementation changes; it adds only the cross-chain migration rehearsal outside those ownership paths. No commit, push, deploy, migration application, or real-account operation performed.

## Ownership and execution

The active playlist catalog-resolution task owns migration `0020`, schema, catalog/artwork normalization, and scheduler files. Wait for that task's reviewed commit before any schema edit. Use synthetic data and the existing PGlite helpers for server coverage; use injected APIs/MusicKit and the existing fake API on web. Add tests red first at the named seam, then implement and review each bounded fix. Do not check in `.todo` tests and call them coverage, or leave intentionally failing tests in another task's active full-suite run.

Ownership expanded and was confirmed directly during this preparation: the same task owns playlist-origin migration `0021`, browse/routes, pool scoring, native creation and web `App`, API client, MusicKit client and test fixtures for creation receipts. A separate Spotify enrichment slice also has local edits. Do not modify or stage any of those files until the owners' work is integrated and re-inspected. Reported test totals from those tasks are not executions of this matrix.

End-of-preparation update: catalog/origin work is committed as `1fb6c92`, and its owner released the shared paths. Use that baseline for the next integration pass. Browse source/freshness and the M1/M3 membership cases remain open. Its new source-deletion test covers Spotify-origin confirmation cleanup while preserving Apple creation receipts; reuse that coverage rather than duplicating it. Spotify enrichment remains a separate dirty slice.

## Mixed-source persistence

| Case | Setup and action | Required assertion / decision | Test owner |
|---|---|---|---|
| M1 | Spotify account-only import with a liked song and no ledger; then a full Apple snapshot lacking that song | Proposed combined-source invariant: Spotify membership survives the Apple refresh. Pin its mix eligibility, not just row survival. Current Apple completion clears `in_library` across all user tracks absent from its snapshot; reproduce before selecting the membership model. | New focused test under `server/test/library/` using listening + library stores |
| M2 | Reverse M1: Apple snapshot, then Spotify import | Same final source memberships in either order; no fabricated plays, no wiped native count. This must match M1, not encode last-writer-wins behavior. | Same cross-source test |
| M3 | Apple-only, Spotify-only, and dual-id synthetic rows; remove/re-import Spotify | Apple membership and its counts remain. Spotify-only cleanup follows documented semantics. Dual-id cleanup is a known handoff edge; establish provenance before changing the accepted live-Apple skip rule. Do not infer ownership from the presence of a platform ID. | `server/test/listening/delete-source.test.ts` plus cross-source test |
| M4 | Native count 27 → web snapshot with unavailable count → imported ledger | Web never replaces 27 with zero/null; imported counts follow the existing GREATEST rule. Account-only import still means unobserved, and re-import does not lower a count. | Existing library/listening derivation tests |
| M5 | Apple/Spotify playlist snapshots in both orders; remove a playlist in one source | Only the publishing source's absent playlists leave its collection. The other source's order, duplicates, membership, and storefront remain intact. | `server/test/playlists/sync-store.test.ts` |
| M6 | Catalog task resolves a previously unresolved playlist entry | Track resolution/artwork changes, not `user_tracks`, observed plays, library membership, or source connections. Reuse its tests; add only cross-feature assertions not already owned there. | Coordinate after catalog commit |

M1 is separate from M3: Apple refresh → Spotify loss versus Spotify cleanup → Apple loss. Both require coverage before advertising a safely combined account. The desired invariant is source-local replacement and union membership; the exact schema/interface change remains a reviewed implementation decision after the catalog migration lands.

## Run lifetime, publication, and concurrency

| Case | Sequence | Expected behavior | Test owner |
|---|---|---|---|
| R1 | Spotify upload active; request Apple sync, then reverse | Only one upload pipeline holds the shared playlist gate. The second action explains which task is running; no second playlist begin request is made. Busy release occurs on success, failure, cancellation, and sign-out. | New app-owned coordinator tests + `web/src/App.spotify.test.tsx` |
| R2 | Navigate to a mix while syncing, return to Your music | The same run continues; no duplicate authorization, snapshot read, upload, or event. Navigation remains usable. | App integration tests |
| R3 | Sign out during read/upload; sign in as someone else | Abort the old run, drop private in-memory data, ignore late callbacks, never publish old status into the new account. | Coordinator/App tests |
| R4 | Failure/cancel before library complete starts | Previous completed library and playlists remain. No success copy or synthetic completion event. | Sync-service + server rollback tests |
| R5 | Library complete succeeds; playlist upload fails/cancels | Return a typed partial result rather than a generic failure. New songs remain usable; old playlists remain. Retry is idempotent and cannot duplicate rows. | `web/src/sync/music-sync-service.test.ts` + App states |
| R6 | Completion request reaches server but response is lost | UI does not claim nothing was published. Reconcile via idempotent completion retry/authoritative state before declaring success/failure. A 401, tab close, and network error need explicit terminal/unknown behavior. | API/service fault-injection tests |
| R7 | A newer run starts on another browser/device | Expired/conflicting current run stops with fixed recovery copy. Do not loop-start new runs and repeatedly expire the other device. | Service conflict tests |
| R8 | Apple authorization denied/unavailable/expired | Mixtape login and existing server music remain. Retry comes from a user gesture; unsupported playback does not hide browsing. Tokens never enter app API payloads or persistent storage. | MusicKit/App tests |
| R9 | Reading pages with unknown totals; known upload batches | Progress announces stage/counts; percentages only with a real denominator for that stage. One stage cannot masquerade as total sync progress. | Service and component tests |
| R10 | Empty library; empty playlists; completed no-playlist Spotify account package | Publish a real empty snapshot for that source only. Show completed-empty separately from not-connected, loading, and failed. | Store/service/component tests |

Apple sync currently completes the song snapshot before beginning playlists. Do not claim cross-snapshot atomicity. The shared upload gate should be above the views, like the current Spotify `importRun`; do not put a second cancellation owner inside a route component.

## Browse contract and UI parity

| Case | Assertion | Owner |
|---|---|---|
| B1 | Playlist summary/detail identifies `apple` vs `spotify_export`; web types and fake API carry it. Never derive provider from name, opaque ID, editability, or artwork. | `server/src/playlists/browse-store.ts`, route tests, `web/src/api/client.ts` |
| B2 | Refreshing Spotify must not make an old Apple playlist display a new sync time. Add truthful source/playlist freshness or omit unsupported precision; the current summary uses a shared profile playlist timestamp. | Browse contract tests |
| B3 | Search/filter runs against the full collection, not merely the first loaded page; cursor reset on query/source change; empty, no-results, initial failure, and next-page failure are distinct. | Browse route + new playlist-view tests |
| B4 | Duplicate entries remain separate; unresolved/local tracks retain positions and truthful non-playable copy. Missing art has a stable fallback. | Playlist detail tests |
| B5 | Preserve Spotify import states, one source row per service, removal copy, milestones, and mixed-mix output gating from the 2026-09-04 approval/departure records. | Existing Spotify/App/QueuePanel tests |
| B6 | Source overview distinguishes account-level synced music from browser Apple authorization. A new browser does not say disconnected data was lost; a native sync is not described as synced from this browser. | Source overview tests |
| B7 | Mobile at 320/390/760px, tablet 768/1020px, desktop; keyboard focus, reduced motion/transparency, dark, large text. Compare against the approved board using actual browser measurements, not only snapshots. | Component/style tests and visual verification |
| B8 | Source overview totals come from persistent server summaries, not the last in-memory sync result or the first playlist page. Do not show made-up totals after reload or in a new browser. Omit counts until a supported aggregate is available. | Source summary contract + reload tests |
| B9 | Preserve the other task's `origin` contract and exact creation receipts. Existing playlists default unknown; never call taste confirmation automatically on sync, browse, or receipt failure. Confirmation UI needs separate approval. | Existing origin tests plus later integration regressions |

## After the integration slice

- Run targeted tests after each red-green-fix round, then the authoritative serial server suite, server typecheck, web tests and build against the current combined checkout.
- Record exact commit/test evidence here or in the existing web plan, not by overwriting the handoff's historic totals.
- Memories and mix rename/archive/unarchive require their own bounded visual coverage. They are not silently included in approval of the music board.
- Before release, verify every unapplied production migration (including earlier sync migrations), validate real-export layouts outside the repo, review privacy disclosures, and obtain explicit authorization for deployment and real-account actions.
