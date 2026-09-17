# Exportify quick import and manual refresh

Status: implemented locally after approval of all 17 visual states on 2026-09-08,
with compact secondary actions and no decorative left borders anywhere in the
app. Approval: `../../mockups/approved/2026-09-08-exportify-import.md`.
Date: 2026-09-08.
Board: `../../mockups/2026-09-08-exportify-import-states.html`.

## Product direction

Spotify onboarding leads with a guided Exportify ZIP/CSV import. The listener
opens Exportify, exports their music, and picks the downloaded files in Mixtape.
No embedded login, token extraction, hosted Exportify API, or automatic Spotify
sync is involved. Repeat imports are manual updates. The official Account data
and Extended streaming history routes remain available under Go deeper and in
the common file picker. An existing history request never blocks quick import.

Preserve the existing interview requirement before the first mix. Successful
import offers Make a mix if that requirement is satisfied, or Tell the DJ about
your taste otherwise. Do not advertise in-app Spotify playback or write-back.

## Source findings, verified 2026-09-08

Upstream source, rather than an authenticated personal export, is the current
format evidence. A real ZIP remains an acceptance check before release.

- [PlaylistExporter](https://github.com/watsonbox/exportify/blob/master/src/components/PlaylistExporter.tsx)
  quotes every CSV field and escapes quotes by doubling them. Headers use i18n
  translations. Filenames are lowercased and punctuation/spaces become `_`.
  Playlist IDs, original names, ownership, and snapshot timestamps are absent
  from the CSV wrapper. Row order preserves occurrences.
- [PlaylistsExporter](https://github.com/watsonbox/exportify/blob/master/src/components/PlaylistsExporter.tsx)
  produces `spotify_playlists.zip` for both all and filtered exports. Duplicate
  normalized filenames get ` (1)`, ` (2)`, etc. These suffixes are not stable
  playlist identities. There is no completeness manifest.
- [PlaylistsData](https://github.com/watsonbox/exportify/blob/master/src/components/data/PlaylistsData.ts)
  adds the synthetic `Liked` collection to `all()`, but not search results.
  A file named `liked.csv` alone is not proof of collection type: an ordinary
  playlist can share that name, and arbitrary CSVs can be renamed.
- [Documented columns](https://github.com/watsonbox/exportify#export-format)
  include track URI, credited artist names, album, duration, ISRC, image URL,
  added timestamp, and optional provider data. No listening ledger is present.

## Review contract

One picker supports an Exportify ZIP, one or several CSVs, and the existing
official ZIP packages. Mixed official/Exportify archives are rejected with
clear separate-import instructions, rather than guessing which family wins.
Detect content, not extension alone. Parse on the device and show inventory
before uploading. Render all file/track text as plain text, never markup.

For each CSV, show filename, row count, editable display name, and role:
Playlist (default), Liked Songs, or Skip. `liked.csv` gets a suggestion requiring
listener confirmation; it is never silently converted to likes. At most one
file is designated Liked Songs in a run. Files in that role do not also produce
a playlist. Collection filenames are suggestions, not recovered original names.

Playlist choices are Create new, Replace a selected imported playlist, or Skip.
On refresh, present previously saved mappings as suggestions, not identity
proof. Replacements always require explicit per-collection review. A playlist
rename, suffix change, or same-name collision must never redirect a replacement
silently. Preserve both order and duplicate occurrences. Unknown local-file
entries retain their position as unresolved names, matching the existing import.

For Liked Songs, default to Add songs. Replace imported Liked Songs is an
explicit mode with a separate removal confirmation. Missing or unselected
files never imply a removal. Neither mode affects another provider's membership.
The summary distinguishes unique songs from ordered playlist entries.

## Storage and synchronization boundary

Add a distinct `spotify_exportify` package within the Spotify import source;
never disguise it as `spotify_account`. Carry reviewed collection targets and
coverage explicitly. Current account import replaces saved membership, and the
playlist sync publishes a full source snapshot, so routing partial CSVs through
those paths unchanged would be destructive.

Library and playlist refresh need source-scoped, collection-scoped operations.
Do not emulate patch sync by downloading all old playlists and uploading a
merged full snapshot: concurrent imports could overwrite each other. Validate
replacement targets for authenticated ownership and Spotify source; fence
replacement against the reviewed prior fingerprint. If it changed, require a
new preview. Use stable internal collection IDs and persist reviewed mappings.

An exact re-import has no duplicate effects. Idempotency must include the file
content, collection role, reviewed target, and action; the same filename is not
an idempotency key. An explicit Create new remains a distinct intentional action.

History imports preserve newer Exportify saved-collection state. Quick imports
carry no plays and must not erase ledger bounds, counts, or followed artists.
Official Account data also needs a review of overlapping saved collections;
an older account snapshot must not silently roll back a newer quick import.

Track IDs are validated Spotify identities. Optional ISRC, artwork, and other
metadata need explicit validation and provenance; client-supplied metadata must
not overwrite trusted global enrichment or silently merge recording identities.
Missing optional fields never block an otherwise valid music import. Retain the
current enrichment path and exact identity safeguards.

## Interaction and recovery

- Start: Open Exportify (external destination stated), Choose files, Go deeper.
- Return: picker remains available, and opening the external page does not
  mark a data request, claim success, or connect a source.
- Inspect: real file progress with Cancel; no network upload before review.
- Review: names, roles, targets, counts, omitted files, and unavailable history.
- Empty/unsupported: no upload; choose other files or use the official route.
- Refresh conflict: preserve current data and request a new review.
- Upload: honest stage progress; existing signed-in app lifetime owns the run.
- Failure: distinguish nothing published from music published/playlists pending.
  Retry uses the same intent and cannot duplicate playlist creation.
- Success: last imported time and manual refresh; optional history upgrade.
- Go deeper: preserve existing request instructions/checkpoint and email reminder
  semantics, with quick import available throughout the wait.

Web retains the Your music > Sources shell; iOS retains the Flutter Material 3
app bar and sheet conventions in `client/lib/main.dart` and `import_sheet.dart`.
The board covers light/dark, desktop/mobile web, iOS, large text, reduced motion,
and all decision-bearing states. It does not redesign the mix editor or playback.

## Implementation sequence after visual review

1. Shared synthetic fixtures and pure CSV/ZIP adapters on web and Dart. Red-first
   coverage through parser entry points: quoting, multiline fields, UTF-8 BOM,
   translated headers, optional columns, invalid IDs, empty collections,
   collisions, duplicate occurrences, mixed formats, cancellation, and limits.
2. Server contract and migrations for reviewed partial updates. Load the
   Postgres and Cloudflare skills before writing those changes. Red-first route
   tests for cross-user targets, stale review, add/replace semantics, repeat
   import, concurrent runs, official-package overlap, and history preservation.
3. Wire the reviewed flow into web and iOS, preserving existing history support,
   app-owned run lifetime, upload gate, auth disposal, interview, and accessibility.
4. Reviewer pass and fix round per task; focused tests, full authoritative server
   suite, web build, Dart analysis, and rendered comparison against the board.
5. Real Export All plus filtered/CSV refresh acceptance on desktop Chrome,
   Android Chrome, and iOS. No production migration or deployment in this review.

## Current work boundary

Implemented locally on web and Flutter, with the staged server protocol and
migrations `0027_exportify_collection_review` and `0028_exportify_saved_music`.
The web and Dart parsers share synthetic CSV and translated-header fixtures.
Review assigns file roles and targets explicitly; header-only quick exports
cannot publish or clear Liked Songs. Unresolved occurrences retain their order.

`GET /ingest/listening/spotify/review` returns caller-owned current collection
fingerprints. Listening imports carry an additive or reviewed replacement mode;
playlist syncs carry a reviewed list and update only those collections. Exact
replays compare imported metadata as well as ordered content. After a quick
import, unreviewed official Account snapshots cannot replace saved collections.
The existing listening ledger and other providers' membership are preserved.

Web runs remain app-owned across navigation. Native multi-file selections create
a bounded temporary archive that is removed on reset, replacement, or auth
teardown. Existing history parsing, upload gating, and the taste interview remain
in place. Buttons use compact actions and no decorative left rails remain in
app source. The synthetic component preview is `web/qa/exportify.html`.

Validation evidence is recorded in
`docs/testing/2026-09-08-exportify-import.md`. Real Export All, filtered CSV
refreshes, production migrations, deployment, and signed device acceptance remain
release checks. No personal library was read and nothing was deployed. Existing
unrelated release/control changes in the shared tree are not part of this work.
