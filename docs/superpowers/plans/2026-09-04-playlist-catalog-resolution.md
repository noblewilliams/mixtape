# Playlist catalog resolution — first shared-enrichment slice

Status: implemented and locally verified; production rollout pending · 2026-09-04

Implements the next server slice of the approved artwork/playlist design. Reuses
the export work's global `tracks` records and existing artwork/features/meaning
jobs. No second import system, new client UI, or Apple Music mutation.

## Contract

- Select exact Apple catalog IDs from active Apple playlist entries only. Use the
  listener's persisted storefront; do not guess a market for missing profiles.
- Link already-existing canonical tracks without an Apple request. Otherwise
  query the existing server-token catalog client in bounded, single-market batches.
- Only catalog-confirmed songs create global tracks; playlist snapshots never
  become authoritative metadata. Keep order, duplicate occurrences, source
  fingerprints, and snapshots untouched. Never create `user_tracks`, observed
  plays, saved-library membership, or a new source connection.
- Insert without overwriting concurrent imports or merging platform records.
  New tracks enter the existing enrichment jobs automatically. Store validated
  artwork plus `artwork_bg_color` when provided; missing artwork stays retryable.
- Short database claims use expiring leases with fenced completion. Network work
  runs outside a transaction. Retry by fixed category; no misses are permanent.
- Schedule before existing enrichment/artwork, with independent failure handling.
  Operational results contain counts only. Tokens and raw errors are never logged.
- Local-only verification now. Migrations, production catalog reads/backfill,
  deployment and founder smoke need separate approval. No push is implied.

## Tasks

1. [x] Exact-ID materialization and bounded relinking: first failing regression,
   retry/claim schema, runner, existing browse contract and integrity assertions.
2. [x] Safety: retry categories, lease fencing, removed/source-local entries,
   duplicate/extra/malformed catalog responses, concurrent insertion, storefronts.
3. [x] Schedule integration: independent failure isolation, shared catalog wiring,
   bounded work and regression coverage for existing enrichment.
4. [x] Adversarial self-review and fix round; full serial server tests/typecheck;
   migration inspection; update rollout/backlog status with local evidence.

## Local verification and review

- Full authoritative server suite: `npx vitest run --no-file-parallelism` —
  **58 files / 1,108 tests passed**. Server `npm run typecheck` and
  `git diff --check` passed.
- Eighteen resolver tests cover exact materialization, duplicate occurrences,
  missing optional metadata, no invented membership, existing-record relinking,
  request bounds, storefront-specific retries, seven failure categories,
  removed playlists, concurrent imports, overlapping/expired leases, and an
  end-to-end scheduled pass through the existing feature/meaning jobs.
- Review fix round: reject duplicate/extra catalog resources and wrong resource
  types; isolate malformed core metadata; keep optional malformed values null;
  reject artwork dimensions beyond the Postgres integer range. Regressions pass.
  Catalog inserts use conflict-safe insertion compatible with the existing
  partial unique Apple-ID index, without replacing concurrent importer metadata.
- Migration `0020_playlist_catalog_resolution.sql` was generated and inspected:
  one lookup-state table with checks/composite key and one partial unresolved-entry
  index. It has not been applied to production. PGlite tests exercise the schema
  and queries; a production migration smoke is still pending.
- No private library read, production write, deployment, commit or push was
  performed for this slice. Existing instruction-file and launch-config changes
  were left untouched.

## Release gate

Review and commit only the owned change set. Reconcile the pending export
migrations 0018–0019 and other local commits before choosing a deployment
snapshot; do not deploy the shared dirty checkout or silently release unrelated
work. After explicit approval, apply reviewed migrations and deploy from a clean
committed worktree, then run a separately authorized private smoke: verify
unresolved counts fall, snapshots/order/duplicates remain unchanged, no saved
library membership is created, and existing enrichment progresses. Historical
counts below are not a substitute for that smoke.

## Later slices (not claimed complete here)

Spotify-by-ID features/artist correction, ISRC-to-Apple cross-link and fallback
artwork remain the export enrichment phase. Fix the documented dual-ID
source-deletion issue before that cross-link writes both IDs. Richer playlist
taste/seeds, browse/detail UI, conversational drafts and verified apply follow.
The last founder count of 980 unresolved entries is historical, not a live count.

References: [Apple catalog songs](https://developer.apple.com/documentation/applemusicapi/get-multiple-catalog-songs-by-id),
[Worker practices](https://developers.cloudflare.com/workers/best-practices/workers-best-practices/).
