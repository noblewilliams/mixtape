# Playlist catalog resolution — first shared-enrichment slice

Status: implemented, verified, and deployed; migration 0020 is applied and bounded catalog resolution is running · 2026-09-05

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
- Migration 0020 was later applied in the reviewed `0015–0024` production chain.
  The Worker was later deployed with approval. The initial aggregate smoke
  passed; private item-level and founder-device smoke still need separate approval.

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
  index. PGlite tests exercise the schema and queries. It was later applied in
  production from the clean `05dad49` worktree, and its table resolves.
- During implementation, no private library read, production write, deployment,
  commit, or push was performed. The slice was later committed and pushed with
  the combined candidate. Existing instruction-file and launch-config changes
  were left untouched.

## Release gate

The reviewed combined candidate is committed/pushed, migrations through 0024 are
applied, and the exact Worker code is deployed. The initial bounded scheduled
pass materialized 25 catalog tracks and raised linked entries from 353 to 379,
leaving 954. Let bounded batches drain and investigate only if aggregate
failure/retry categories appear or progress stops across several windows.
Item-level private and device smoke still require separate authorization.

## Later slices (not claimed complete here)

Spotify-by-ID features/artist correction, source-safe membership, ISRC-to-Apple
cross-link, fallback artwork, playlist taste/seeds, and browse/detail UI are now
committed. Conversational drafts and verified apply remain later work. The last
founder count of 980 unresolved entries is historical, not a live count.

References: [Apple catalog songs](https://developer.apple.com/documentation/applemusicapi/get-multiple-catalog-songs-by-id),
[Worker practices](https://developers.cloudflare.com/workers/best-practices/workers-best-practices/).
