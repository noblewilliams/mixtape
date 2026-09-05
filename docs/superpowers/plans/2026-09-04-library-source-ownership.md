# Library source ownership

Status: implemented and verified; committed in `bba5de9`, with migration 0022 and the matching Worker deployed.

A shared track's provider IDs identify the recording, not the source of a
listener's saved-library membership. Before ISRC cross-linking adds more dual-ID
tracks, removal must use per-listener source evidence.

## Contract

- Persist membership by `(user_id, track_id, source)` for `apple_live`,
  `apple_export`, and `spotify_export`. `user_tracks.in_library` is the union.
- Spotify account imports replace only Spotify membership; extended history
  never changes membership. Apple media imports remain additive, as before.
- Completed native/web Apple snapshots replace only `apple_live`. The legacy
  paged native ingest records additive `apple_live` membership.
- Removing an export removes only that source's membership. Other sources,
  seeds, and remaining ledger rows retain their existing protection. Preserve
  playlist-origin cleanup from commit `1fb6c92`.
- The blanket `apple_live` removal bypass becomes unnecessary. Keep the response
  field `likedRemovalSkipped` for compatibility, returning false for new runs;
  `likedRemoved` counts tracks that actually leave the combined saved library.
- Migrate existing saved rows to `legacy` membership because historical origin
  cannot be reconstructed reliably from catalog IDs or expiring staging rows.
  Preserve these memberships through source removal and sync. A later explicit
  reconciliation is needed to retire unknown historical membership; do not guess.
- Serialize source changes with the existing listener-profile lock, and publish
  membership plus derived flags in the same transaction. No changes to lifetime
  counts, source receipts, or public response shapes beyond the corrected flags.

## Tasks

1. [x] Pin dual-ID deletion/re-import, cross-source snapshot, legacy preservation,
   transaction rollback, idempotency, and tenant isolation through public stores.
2. [x] Add migration 0022, schema constraints/indexes, one membership module,
   and wire all three saved-library writers and source deletion.
3. [x] Review adversarially and verify migration upgrade plus focused/full server
   suites and typecheck. Update spec, decisions, backlog, and handoff status.

## Boundaries

Owned: new membership module/tests/migration, schema and migration journal,
`listening/import-store.ts`, `library/sync-store.ts`, legacy `routes/ingest.ts`,
related focused tests and docs. The playlist task handed these back after its
scoped commit. Web UI and playlist catalog/artwork jobs remain separate.

Real ZIP validation waits for the exports. Commit/push, migration application,
and Worker deployment were handled later as controlled release actions.


## Review and verification

- Added 15 regressions: 13 source-ownership cases through public stores/routes
  and two migration/constraint tests. Initial red run reproduced eight failures
  before the implementation. Existing tests that encoded the blanket Apple-live
  bypass now use real membership evidence or assert source-specific removal.
- Upgrade rehearsal restores the pre-0022 table boundary, applies the actual SQL
  migration to saved dual-ID/seed/two-listener fixtures, and checks that saved
  flags and play counts are unchanged. Invalid sources, duplicate evidence,
  cross-listener foreign keys, and user-track/account cascades are checked.
- Adversarial review followed every saved-library writer, profile-lock order,
  seed/ledger retention, import retry, both transaction rollback seams, shared
  catalog identity, and playlist-origin cleanup. It found a rollout-gap edge:
  the old runtime can clear a saved flag after migration has copied it. A red
  regression pinned that failure; legacy evidence now respects an already-cleared
  flag before union recomputation. Current saved legacy evidence remains protected.
- Full server suite before that final fix: `npx vitest run --no-file-parallelism`
  passed 63 files / 1,168 tests in 175.91 seconds.
- After the fix: `npx vitest run test/library test/listening test/ingest.test.ts
  --no-file-parallelism` passed all 16 files / 296 tests in 49.54 seconds, including
  the additional rollout-gap regression. This is focused post-fix verification,
  not a claim that the full suite was rerun afterward.
- Final server typecheck and diff hygiene passed. `npx drizzle-kit check` passed;
  snapshot 0022 correctly follows 0021, adds only `user_track_library_sources`,
  and changes no existing table definition.
- The web task owns combined Your music UI, sync coordination, and playlist
  browse source/freshness contracts. It will reuse these membership regressions.
- The separate release preflight records that production advanced from 0014
  through 0024 using the clean `05dad49` worktree, including this fix. The
  matching Worker is deployed; real-export smoke and historical legacy
  reconciliation remain open.
