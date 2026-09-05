# Apple catalog linking by ISRC

Status: implemented and verified; committed in `bba5de9`, with migration 0023 and the matching Worker deployed.

The user authorized this Phase 3 slice after source ownership. Spotify records
with an exact ISRC can acquire an Apple catalog ID only when Apple returns one
unambiguous song and no other canonical row already owns that ID. No row merge,
listener membership, play counts, or playlist snapshots change.

## Contract

- Storefront: use the listener's persisted Apple storefront first; otherwise use
  their import country in lowercase. Defer when neither is known. The user
  approved this country rule on 2026-09-04; do not use a global fallback.
- Extend the existing bounded, server-token catalog transport with exact ISRC
  lookup. Batch at most 25 codes, preserve all matches, reject incomplete or
  malformed responses rather than mistake one visible result for uniqueness.
- A cron pass claims at most 25 Spotify tracks in one storefront, ordered by
  enrichment priority. Require a completed Spotify source and a user-track row.
  Key retry state by track, storefront, and ISRC so identity/market changes can
  be retried independently. Keep requests outside transactions; fence expired or
  superseded leases and recheck current source/storefront/identity before writing.
- Zero matches, ambiguous results, owned Apple IDs, and upstream failures stay
  unlinked with bounded retry delays. A unique-index conflict must not abort
  unrelated matches or overwrite an existing ID. Never physically merge rows.
- Fill missing catalog metadata and validated Apple artwork without replacing
  existing trusted metadata. Record the successful catalog storefront so the
  existing artwork runner refreshes that track in the same market. Existing
  records without a catalog storefront keep the configured artwork default.
- Run after Spotify metadata enrichment and before artwork; isolate failures
  from other maintenance. Logs/results contain counts and fixed categories only.
- Migration 0022 and this slice's migration 0023 must precede deployment. Both
  were applied as part of the reviewed `0015–0024` chain on 2026-09-05. The
  implementation made no provider calls or private-library reads. The matching
  Worker was later deployed through a separately approved release action.

## Tasks

1. [x] Extend/test the Apple client for exact ISRC, batching, ambiguity,
   malformed/paginated responses, and the existing sanitized failure paths.
2. [x] Add retry schema and source-aware bounded runner. Test exact linking,
   metadata preservation, conflicts, source deletion, market/identity changes,
   lease/retry behavior, and unchanged listener data.
3. [x] Wire cron and preserve artwork storefront. Test scheduling isolation and
   market-specific refresh, review the change, run focused/full verification,
   and update handoff/backlog/decisions.

## Ownership

This task owns `musickit/catalog.ts`, the new ISRC runner/tests, migration 0023,
its schema/journal entries, `enrich/scheduled.ts`, index wiring, and the small
artwork-market integration. The web task owns UI and playlist browse contracts;
the playlist task owns playlist-inspired session context and the pool. Hand
schema/journal back after generating 0023 so its later migration follows safely.

## Sources

- [Apple ISRC lookup](https://developer.apple.com/documentation/applemusicapi/get-multiple-catalog-songs-by-isrc): multiple matches are possible; maximum fetch limit 25.
- [Storefronts and localization](https://developer.apple.com/documentation/applemusicapi/storefronts_and_localization): catalogs vary by region.
- [Workers best practices](https://developers.cloudflare.com/workers/best-practices/workers-best-practices/): bounded response reads, awaited work, server secrets, invocation-scoped database connections.

Fallback Spotify artwork is also committed in `bba5de9`. Real-provider,
real-export layout, and device/browser smoke remain release gates.


## Review and verification

- Added 40 regressions: catalog ISRC adapter (11), resolver (23), migration (2),
  scheduling/real-adapter integration (3), and recorded-market artwork refresh (1).
  New behavior was checked red before its implementation, including unsafe partial
  response acceptance and the missing scheduler/artwork-market behavior.
- The resolver test suite exercises both an existing Apple owner and a real
  PostgreSQL unique-violation condition injected during UPDATE. The latter proves
  the savepoint recovers without aborting an unrelated match. Lease tests call a
  second runner while the first request is outstanding, then exercise expiry and
  takeover; the old result cannot overwrite the new owner.
- Rechecks cover deleted sources, changed country/ISRC, and an Apple ID assigned
  during the request. Other cases pin ambiguity, a 25-track cap, deduplicated
  ISRC requests, priority ordering, unknown country, per-market retries, absent
  source completion, orphan tracks, metadata preservation, and unchanged user
  rows. The real-adapter integration verifies newly observed Spotify ISRC to
  Apple metadata/artwork in a single maintenance pass, with counts-only results.
- Migration upgrade tests restore the pre-0023 boundary and execute the actual
  SQL against an existing catalog row. Storefront defaults remain unknown;
  malformed retry keys are rejected, and track deletion cascades retry state.
- Adversarial review traced all write predicates, transaction/lease boundaries,
  retry-key isolation, unique-index recovery, output privacy, existing Apple
  artwork behavior, and the index/runner type wiring. Catalog responses cannot
  create a false singleton through dropped malformed items or pagination. No
  unresolved implementation findings remain within this slice.
- Focused checks passed: catalog old/new 40 tests; artwork/scheduler 31 tests;
  resolver/upgrade/scheduler integration 28 tests. These sets overlap.
- Final stable combined server check: `npx vitest run --no-file-parallelism`
  passed **67 files / 1,211 tests in 209.59 seconds**. The web task's browse server
  changes were stable for this run. It predates the playlist task's new
  playlist-inspired session implementation and does not verify that later work.
- Server `npm run typecheck`, `npx drizzle-kit check`, and diff/new-file whitespace
  checks passed. Snapshot 0023 follows 0022 and adds only the retry table plus the
  nullable catalog-storefront column/check on tracks.
- No real Apple API request, private-library access, deployment, or real-export
  smoke was performed. Commit/push and migration application happened later as
  controlled release actions, not during this implementation slice.

## Release and next work

The reviewed candidate `05dad49` was pushed, production migrations `0015–0024`
were applied from its clean detached worktree after ledger/hash verification,
and clean snapshot `fd5f66b` was deployed as the Worker. Initial health/auth and
aggregate private smoke passed; exact Apple-ISRC provider categories still need
observation as the bounded scheduler runs.

Spotify fallback artwork (oEmbed then guarded Deezer fallback) is committed in
`bba5de9`. Real-provider/runtime checks and the requested export
layout/device/browser smoke are still pending. Historical legacy membership
reconciliation remains a separate, documented limitation of migration 0022.
