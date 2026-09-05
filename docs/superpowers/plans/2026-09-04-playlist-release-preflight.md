# Playlist release preflight

Status: release pushed, production migrations applied, Worker deployed, and initial public/private smokes passed; device-only creation smoke remains.

## Reviewed snapshot

- Original preflight candidate: `1fb6c92` (`feat(playlists): Add catalog resolution and taste`).
- Final migrated candidate: `05dad49` (`docs(playlists): Specify conversational editing`).
- Migration worktree: `/private/tmp/mixtape-prod-migrate.tDzwfJ`, detached at the final candidate.
- Clean dependency install from the committed lockfile, with lifecycle scripts disabled.
- Worker dry run passed using Wrangler 4.127.1: 1,803.31 KiB uncompressed,
  460.64 KiB gzip; only the existing AI binding. No upload or deployment occurred.
- Server typecheck passed and the isolated worktree remained clean.
- Prior commit verification remains applicable: isolated staged snapshot passed
  188 focused tests; full shared-checkout server suite passed 1,154 tests, web
  315 tests, Flutter 540 tests, and simulator compilation. The full-suite total
  included another task's uncommitted enrichment tests; it is not a claim that
  this release snapshot alone ran those tests.

Dry-run command, from the isolated worktree's `server/` directory:

```sh
WRANGLER_LOG_PATH=/tmp/mixtape-release-wrangler.log WRANGLER_SEND_METRICS=false ./node_modules/.bin/wrangler deploy --dry-run --minify --outdir /tmp/mixtape-playlist-release.7lK4x5-bundle
```

The command compiles without deploying, as documented in the
[Wrangler command reference](https://developers.cloudflare.com/workers/wrangler/commands/workers/#deploy).

## Release execution, 2026-09-05

- Refetched `origin/main`; the final candidate was a fast-forward with zero
  remote-only commits.
- Pushed the full reviewed 107-commit foundation release from `c24d189` through
  `05dad49` to `origin/main` after explicit approval of that breadth.
- Re-read only the Drizzle migration ledger. Production contained 15 migrations
  through `0014_mute_lester`; all stored hashes matched the committed files.
- Confirmed the only pending entries were the ordered `0015–0024` chain.
- Checked relation metadata before writing. The largest affected existing
  relation estimate was 10,001 rows / 2.7 MB, and no other database session was
  active.
- Applied the committed migration folder from the detached clean worktree in one
  migrator run.
- Re-read the ledger after completion: 25 migrations are applied through
  `0024_playlist_session_seeds`, every hash matches, and no migration remains
  pending.
- Verified that `user_track_library_sources`, `playlist_origins`,
  `apple_isrc_lookups`, and `session_playlist_seeds` resolve in production.
- Deployed the exact clean `fd5f66b` snapshot as Worker version
  `7a6ec181-2292-4d56-b8a4-abb996d6857a`, message
  `playlist intelligence fd5f66b`, with 100% traffic. The recorded rollback
  version is `e35b134c-c045-4267-92b6-31c42c918159`.
- Production startup time was 110 ms. The minified upload was 1,839.25 KiB /
  470.31 KiB gzip and the five-minute scheduled trigger deployed.
- Public smoke: `/health` returned 200; `/me`, `/enrich/status`, and
  `/musickit/token` returned the expected unauthenticated 401.
- Aggregate private smoke: enrichment/artwork status returned 200 for 4,714
  tracks; 4,711 had artwork, three were missing, and none was retryable.
- The first bounded scheduled catalog pass is visible in aggregate state:
  compared with the recorded pre-release baseline, 25 catalog tracks were
  materialized and linked playlist entries rose from 353 to 379. The remaining
  954 exact-ID entries will continue through bounded five-minute batches.

No playlist mutation or device smoke was performed as part of this execution.
Private checks read aggregate counts only; no playlist names, prompts, or track
metadata were returned.

## Playlist-edit follow-on, 2026-09-05

- Pushed conversational draft foundation and isolated playlist DJ through clean
  commit `a5f8185`.
- Re-read only the Drizzle ledger and verified all 25 production hashes through
  0024 before writing.
- Applied the exact pending suffix, migrations 0025 and 0026, from a clean
  detached `a5f8185` worktree.
- Post-run verification found 27 matching ledger entries, no pending migration,
  and resolvable draft, entry, event, message, and message-index objects.
- No playlist/account rows were read, no Worker was deployed, and no Apple
  Music mutation ran. The live Worker remains version
  `7a6ec181-2292-4d56-b8a4-abb996d6857a` until a separate approved deployment.

## Pre-migration production ledger: read-only check, 2026-09-04

Read only `drizzle.__drizzle_migrations` through the configured Neon connection.
All 15 applied hashes and timestamps match committed migrations `0000–0014`.
No account, playlist, song, or listening-history rows were read. No writes ran.

Pending at that time, in journal order:

| Migration | Scope |
| --- | --- |
| 0015 | Staged library sync and observed-play-count flag |
| 0016 | Staged recent tracks and per-user recent observations |
| 0017 | Playlist sync source |
| 0018 | Listening exports, ledger, source records, seeds and platform fields |
| 0019 | Import liked-removal result fields |
| 0020 | Playlist catalog lookup leases and unresolved-entry index |
| 0021 | Playlist creation/curation origin records |

This was a combined foundation release, not a two-migration playlist-only
deploy. The final release added migrations 0022–0024 after this first check.
Migration 0018 relaxes existing constraints/nullability and adds indexes on
existing tables. The final upgrade rehearsal covered `0014–0024`, and the
production migrator ran from a clean committed worktree rather than the shared
checkout.

## Resolved release hold

The committed Apple snapshot completion clears `user_tracks.in_library` for any
saved track absent from that Apple snapshot, without retaining independently
owned Spotify membership (`server/src/library/sync-store.ts`). The export task
also confirmed the documented dual-ID source-deletion defect. These concern
Mixtape's saved-song evidence, not deletion of songs from Apple or Spotify.

The final candidate includes the reviewed per-listener source-membership fix and
migration 0022, including the older native ingest path. The combined migration
rehearsal verified preservation of representative `0014` data through `0024`.
This clears the database prerequisite for source-safe cross-platform linking; it
does not itself activate Worker jobs or prove a private catalog smoke.

## Next release gates

1. Let bounded scheduled catalog resolution drain normally; investigate only if
   aggregate failure/retry categories appear or counts stop moving across
   multiple scheduled windows.
2. With device access and approval to create one disposable playlist, smoke the
   new typed MusicKit creation path: author, order, added/failed reporting,
   returned ID, sync-origin reconciliation, and rename/resync survival. Existing
   playlists must remain untouched. Simulator compilation is not this proof.
3. Coordinate a separately approved browse confirmation control before expecting
   existing unknown-origin playlists to provide positive taste evidence.
