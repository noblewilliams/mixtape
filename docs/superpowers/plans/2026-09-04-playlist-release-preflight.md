# Playlist release preflight

Status: committed release pushed and production migrations applied; Worker deployment and private smoke remain held.

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

No Worker deployment, private-library query, catalog job, playlist mutation, or
device smoke was performed as part of this execution.

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

1. Obtain separate approval for the Worker deployment. Production migrations
   are complete, but the existing Worker does not expose the newly committed
   server behavior until deployed. Worker rollback does not undo schema changes
   or completed data jobs; do not drop the additive tables as an automatic
   rollback.
2. Deploy only the already-pushed `05dad49` snapshot from a fresh clean
   worktree, then verify public health and auth guards.
3. Separately authorize private catalog
   checks. The deployed scheduler will start bounded catalog resolution; its
   activation is part of rollout approval, not a passive deployment detail.
4. With device access and approval to create one disposable playlist, smoke the
   new typed MusicKit creation path: author, order, added/failed reporting,
   returned ID, sync-origin reconciliation, and rename/resync survival. Existing
   playlists must remain untouched. Simulator compilation is not this proof.
5. Coordinate a separately approved browse confirmation control before expecting
   existing unknown-origin playlists to provide positive taste evidence.
