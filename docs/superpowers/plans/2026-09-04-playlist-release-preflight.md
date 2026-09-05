# Playlist release preflight

Status: preflight completed; production rollout held for source-membership fix and action-time approval.

## Reviewed snapshot

- Candidate: `1fb6c92` (`feat(playlists): Add catalog resolution and taste`).
- Isolated detached worktree: `/private/tmp/mixtape-playlist-release.7lK4x5`.
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

## Production migration ledger: read-only check, 2026-09-04

Read only `drizzle.__drizzle_migrations` through the configured Neon connection.
All 15 applied hashes and timestamps match committed migrations `0000–0014`.
No account, playlist, song, or listening-history rows were read. No writes ran.

Pending in this candidate, in journal order:

| Migration | Scope |
| --- | --- |
| 0015 | Staged library sync and observed-play-count flag |
| 0016 | Staged recent tracks and per-user recent observations |
| 0017 | Playlist sync source |
| 0018 | Listening exports, ledger, source records, seeds and platform fields |
| 0019 | Import liked-removal result fields |
| 0020 | Playlist catalog lookup leases and unresolved-entry index |
| 0021 | Playlist creation/curation origin records |

This is a combined foundation release, not a two-migration playlist-only deploy.
Migration 0018 relaxes existing constraints/nullability and adds indexes on
existing tables; validate locks/timeouts and upgrade behavior in the final
release rehearsal. Do not run a migrator against the shared working directory:
it already contains the other task's uncommitted migration 0022.

## Release hold

The committed Apple snapshot completion clears `user_tracks.in_library` for any
saved track absent from that Apple snapshot, without retaining independently
owned Spotify membership (`server/src/library/sync-store.ts`). The export task
also confirmed the documented dual-ID source-deletion defect. These concern
Mixtape's saved-song evidence, not deletion of songs from Apple or Spotify.

The export task is implementing per-listener source membership and migration
0022, including the older native ingest path. Wait for its reviewed commit and
include that fix before recommending the combined rollout. No ISRC cross-link
writes should be enabled before that protection ships. Its in-progress code is
excluded from this preflight; no claim of verification is made for it here.

## Next release gates

1. Select a new explicit committed snapshot containing the reviewed membership
   fix. Reconcile the web task's concurrent integration work; do not implicitly
   include unfinished UI or runtime changes.
2. Rerun isolated tests/typecheck/dry-run and the migration upgrade rehearsal;
   re-read the production ledger and current Worker deployment at action time.
   Record the prior Worker version, backup/recovery readiness, and bounded lock
   handling before applying any migration.
3. Obtain explicit approval for the exact production migrations and Worker
   deployment. Migrate before deploying code that requires the new columns.
   Worker rollback does not undo schema changes or completed data jobs; do not
   drop new tables as an automatic rollback.
4. Verify public health/auth guards, then separately authorize private catalog
   checks. The deployed scheduler will start bounded catalog resolution; its
   activation is part of rollout approval, not a passive deployment detail.
5. With device access and approval to create one disposable playlist, smoke the
   new typed MusicKit creation path: author, order, added/failed reporting,
   returned ID, sync-origin reconciliation, and rename/resync survival. Existing
   playlists must remain untouched. Simulator compilation is not this proof.
6. Coordinate a separately approved browse confirmation control before expecting
   existing unknown-origin playlists to provide positive taste evidence.

No production migration/deployment, private library access, playlist creation,
Git push, or additional commit was performed during this preflight.
