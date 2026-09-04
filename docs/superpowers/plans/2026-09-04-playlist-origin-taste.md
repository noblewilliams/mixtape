# Playlist origin and bounded taste

Status: implemented and locally verified — production/device rollout pending.

## Contract

- Keep creation receipts separately from sync snapshots, keyed by listener,
  source and exact provider playlist ID. A receipt may arrive before the first
  sync; later syncs/renames must not erase it. Only the owner of the referenced
  mix can record a Mixtape creation receipt. This is client-attested provenance,
  not an assertion that the Worker independently authenticated to Apple.
- Existing and imported playlists default to unknown origin. Names, authors,
  descriptions, editable flags and missing receipts do not prove user curation.
- Expose explicit, reversible user-curation confirmation by internal playlist ID.
  Reject automatic/editorial kinds and Mixtape creations. Confirmation UI remains
  a separately approved browse-screen task; do not silently confirm on sync.
- Read origin in browse responses and scoring from the same persisted evidence.
  Creation receipts take precedence over user confirmation and the existing
  `is_mixtape_owned` flag also remains an exclusion.
- Playlist taste reranks existing personal candidates only: user-confirmed active
  playlists, resolved recordings, distinct playlist counts, 0.10 maximum weight,
  diminishing returns (first playlist 0.05; second 0.075; asymptote 0.10).
  Remove playlist evidence from familiarity to avoid counting it twice. Keep
  learned taste at 0.12, scale the other personal weights to total 0.78. Corpus
  mode retains its current weights and ignores playlists. Hard filters win.
- No new library membership, negative signal for disappearance, cross-platform
  identity merging, Apple playlist editing, or playlist-only pool admission.
- Native creation must return a typed MusicKit playlist ID (not a guessed
  MediaPlayer persistent-ID conversion). Use MusicLibrary creation and sequential
  additions with existing added/failed reporting. A real-device creation smoke is
  required before release; this does not grant exact-rebuild capability.
- Web creation returns the ID from Apple's library-playlist response. A missing
  or malformed receipt never turns successful creation into a retryable failure
  that could create a duplicate. Receipt upload failure leaves origin unknown.

## Work

1. [x] Persist origin and authenticated receipt/confirmation routes; browse result;
   tenant isolation, idempotence, precedence and sync-survival tests.
2. [x] Client creation IDs and receipt handoff; keep existing save outcomes and
   session events. Test response parsing, upload failure, account/session binding.
3. [x] Shared pool scoring, recording-level counting and exclusions; red/green
   structural ranking tests, corpus regression and adversarial review/fix round.
4. [x] Full server/client/web checks and native compile where available; docs.

Production migrations/deployment, private reads, new Apple playlists, commit and
push are not part of this local run. Earlier catalog migration 0020 and export
migrations remain separately release-gated. Existing playlists need an explicit
confirmation surface before they can provide positive signal.

## Verification and review notes

- Final authoritative server rerun: **61 files / 1,154 tests passed** with
  `npx vitest run --no-file-parallelism` (206.65 seconds). This shared-checkout
  total includes the other task's Spotify enrichment tests. Server typecheck
  and `git diff --check` passed. The earlier run had loaded source-deletion
  code before its review fix and is superseded by this completed rerun.

- Web: 32 files / 315 tests passed; production build and TypeScript checks passed.
- Flutter: 540 tests passed; analyzer clean. Simulator app compiled successfully
  with `flutter build ios --simulator --no-pub --no-codesign` using the installed
  Ruby 3.3/CocoaPods binaries first on PATH (the stale system pod executable
  otherwise loads Ruby 3.3 gems under Ruby 2.6). No tools were reinstalled.
  The build-generated lockfile additions for pre-existing export dependencies
  were reverted; they are not part of the origin change.
- Server focused tests cover origin precedence/auth/validation, sync survival,
  source deletion, native/web play-count parity, diminishing returns, duplicate
  and ISRC-sibling counting, prompt filters, unknown/generated/editorial/removed
  exclusions, other-user isolation, and unchanged corpus-mode behavior.
- Adversarial review fix: Spotify source deletion also removes confirmation
  records, and confirmation shares the existing profile lock order with
  sync/deletion. Creation upload failures remain non-fatal on both clients.
- Migration 0021 was generated and is exercised through migrated PGlite tests;
  not applied to production. It adds one table with a listener/source/ID primary
  key, source/origin/ID checks and account-delete cascade.
- Shared-checkout enrichment and web-board work belong to other active tasks;
  neither task's changes are staged, reverted, or released here.

## Next release checks

Review a committed release snapshot and migrations 0018–0021 together, without
implicitly releasing other unfinished work. Obtain action-time approval before
production migration/deployment or creating a founder playlist. Device smoke:
create one disposable mix playlist, confirm author/order/added-failed reporting,
sync and prove the returned typed ID matches the collected playlist and origin
is `mixtape`. Verify rename/resync preserves it. Separately approve the browse
confirmation control before expecting existing playlists to boost ranking.
