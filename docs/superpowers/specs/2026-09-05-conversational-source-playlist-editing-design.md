# Conversational source-playlist editing

**Status:** approved; revised-copy apply implemented locally, release pending

**Date:** 2026-09-05

**Parent:** [artwork + playlist intelligence](./2026-08-31-artwork-playlist-intelligence-design.md)

**Depends on:** playlist sync/browse, catalog resolution, confirmed playlist origin, and playlist-inspired mixes

## Summary

A listener can open a playlist, talk to the DJ about changes, review an exact
ordered draft, and apply the approved result to Apple Music when the device can
do so safely.

The draft is the product truth. The source playlist is not mutated while the DJ
is thinking, searching, or arranging tracks. At apply time Mixtape chooses the
strongest verified operation that preserves the approved result:

1. **Append to source** only when the draft differs by a trailing suffix and an
   on-device capability check permits appending.
2. **Rebuild source** only for a playlist created through Mixtape's typed
   `MusicLibrary.createPlaylist` path after a separate device probe proves that
   exact rebuild is safe for that specific creation receipt.
3. **Create a revised copy** for insertion, removal, replacement, reordering,
   non-editable sources, imported Spotify playlists, and every uncertain case.

This makes the requested experience possible without claiming that Apple's
append-only interface can insert songs in the middle. The first production
release supports `append` after its device probe and `revised_copy`; `rebuild`
stays feature-disabled until independently proven.

## User promise

From an Apple playlist detail, the listener can say:

> Add a couple more songs by Daniel Caesar to this playlist, but put them where
> they fit best.

Mixtape proposes exactly two eligible songs, places them in a full ordered
draft, and shows the changes before Apple Music is touched. If Apple cannot
apply those middle insertions to the original, the confirmation says plainly:

> Apple Music cannot safely reorder this playlist. Mixtape will create a revised
> copy and leave the original unchanged.

The user is approving the desired tracklist, not a hidden degraded operation.
Mixtape never silently turns “put them where they fit best” into “add them at the
end.”

## Scope

### Included

- Start or resume one active edit draft from playlist detail.
- Conversational add, remove, replace, and move operations.
- Apple catalog search for songs not already in the listener's library.
- Exact preservation of source order, duplicate occurrences, and unresolved
  entries in the server draft.
- Deterministic diff and review before apply.
- Optimistic draft-version checks and source-fingerprint conflict checks.
- Native Apple apply through verified append, future verified rebuild, or a
  revised copy.
- Apply receipts, retry reconciliation, resync, and explicit taste events.
- Read-only drafts for Spotify-export playlists, with Apple revised-copy apply
  only when every resulting entry resolves to an Apple-addable song.

### Not included

- Writing back to Spotify from imported export data.
- Android playlist mutation.
- Editing Apple editorial, Replay, chart, personalized, or shared playlists in
  place.
- Silently dropping local, unavailable, or unresolved entries.
- Deleting or replacing the source playlist.
- Background or automatic playlist edits without a review and confirmation.
- Treating a draft suggestion as taste evidence before the user applies it.
- A general-purpose version-history editor; v1 keeps one active draft and one
  immutable base snapshot.

## Provider capability contract

| Source | Browse and draft | Append to source | Exact in-place order | First-release behavior |
| --- | --- | --- | --- | --- |
| Apple playlist created outside Mixtape | Yes | Only after per-device capability verification, and only as a suffix | No documented general path | Append verified suffixes; otherwise revised copy |
| Existing legacy Mixtape playlist | Yes | Only after per-device capability verification | Earlier device probe rejected rebuild | Append verified suffixes; otherwise revised copy |
| Typed MusicKit playlist with a trusted Mixtape receipt | Yes | Expected, still verified before apply | Feature-disabled until a new exact-rebuild probe passes | Append verified suffixes; otherwise revised copy |
| Apple editorial/personalized/non-editable playlist | Yes | No | No | Revised copy |
| Spotify-export playlist | Yes | No Spotify write path | No | Optional Apple revised copy after complete Apple resolution |

Apple's Music API adds tracks to the **end** of a library playlist. MusicKit for
Swift exposes `edit(...items:)`, but Apple documents it for playlists created by
the app and says it throws for a playlist created by another app. Mixtape's
founder-device probe also rejected a same-order rebuild for both tested playlist
classes. Runtime evidence therefore narrows the contract even when a static
`canEdit` field is optimistic.

`can_edit`, playlist kind, title, curator, and `is_mixtape_owned` are not enough
to unlock rebuild. Rebuild requires all of:

- source is Apple;
- an exact trusted typed-MusicKit creation receipt belongs to this user;
- the installed client version has the rebuild implementation;
- the creation class passed the separately recorded device probe;
- the current playlist fingerprint still matches the draft base;
- every desired entry is resolvable as a MusicKit playlist-addable item.

## Experience

### Entry point

Playlist browse remains useful without the DJ. Playlist detail adds **Edit with
the DJ** only when the source can produce a draft. Selecting it creates or
resumes the user's one active draft for that playlist.

The header always identifies both objects:

- **Source:** the last synced playlist from Apple or a Spotify export.
- **Draft:** Mixtape's private proposed version, with its unsaved-change count.

This wording matters because most meaningful edits will initially create a new
Apple playlist rather than overwrite the source.

### Conversation

Playlist editing uses the normal conversational shell but a separate tool and
storage contract. A turn may explain or inspect the playlist without changing
the draft. A mutation turn returns the new ordered draft and a deterministic
change summary.

For “a couple,” use two unless the listener established another count. For an
artist-specific request:

1. Resolve the requested artist through the Apple catalog.
2. Exclude songs already present unless duplicates were explicitly requested.
3. Build a bounded candidate set.
4. Rank candidates against the direct request, playlist profile, and listener
   taste; the direct request wins conflicts.
5. Score neighbouring transitions and choose positions.
6. Apply exactly the requested count to the draft in one versioned write.

The DJ changes the smallest possible region. Existing duplicate occurrences
are separate entries and stay separate unless the listener names one for
removal.

### Review and apply

The review shows:

- every addition with proposed neighbours;
- removals, moves, and replacements;
- unchanged track count;
- unresolved entries that will be preserved or that block apply;
- the actual apply mode before confirmation;
- whether the source will remain untouched.

Draft responses also carry a compact `review` projection for changed
occurrences only. It includes the display snapshot for additions and removals,
the before/after snapshot for replacements, and the current snapshot plus old
position for moves. This lets a reopened client name every change without
shipping a second full copy of the base playlist.

The confirmation verb follows the real action:

- **Add 2 songs to source** for a verified append;
- **Update source playlist** for a future verified rebuild;
- **Create revised playlist** for copy mode.

After a revised copy succeeds, show its name and provider ID and offer **Open in
Apple Music**. Do not imply that the original was edited.

## Data model

Playlist drafts use their own tables. The ordinary mix queue intentionally
deduplicates tracks and therefore has the wrong invariants for playlist editing.

### `playlist_edit_drafts`

```text
id uuid primary key
user_id text not null -> user.id
source_playlist_id uuid not null -> user_playlists.id
status text not null
  active | preparing | ready | applying | applied | conflicted | abandoned
version integer not null default 0
base_source_fingerprint text not null
base_name text not null
source_type text not null                 apple | spotify_export
requested_apply_mode text                 append | rebuild | revised_copy
prepared_operation_id uuid
prepared_expires_at timestamptz
prepared_desired_fingerprint text
applied_playlist_source text              apple
applied_playlist_library_id text
applied_at timestamptz
created_at timestamptz not null
updated_at timestamptz not null
```

Constraints and indexes:

- one partial unique active draft per `(user_id, source_playlist_id)` for
  statuses that can still be resumed;
- all foreign-key lookup columns indexed;
- `version >= 0`;
- fingerprints are lowercase SHA-256 hex;
- prepared fields are either all null or all present;
- terminal drafts cannot return to active.

### `playlist_edit_entries`

Each draft stores two roles: immutable `base` and mutable `draft`.

```text
id uuid primary key
draft_id uuid not null -> playlist_edit_drafts.id on delete cascade
role text not null                         base | draft
entry_key uuid not null
position integer not null
origin text not null                       source | catalog_addition
source_entry_id uuid nullable -> playlist_entries.id on delete set null
track_id uuid nullable -> tracks.id on delete set null
apple_library_track_id text nullable
apple_catalog_id text nullable
spotify_id text nullable
title_snapshot text not null
artist_snapshot text not null
album_snapshot text nullable
duration_ms_snapshot integer nullable
artwork_url_template_snapshot text nullable
artwork_width_snapshot integer nullable
artwork_height_snapshot integer nullable
artwork_bg_color_snapshot text nullable
```

`entry_key` identifies one occurrence across versions and diff calculations. A
duplicate song has a different `entry_key`. The base copy does not point at live
ordering after creation; this lets Mixtape distinguish an external source edit
from its own proposed change.

Indexes and uniqueness:

- unique `(draft_id, role, position)`;
- unique `(draft_id, role, entry_key)`;
- index `(draft_id, role)`;
- partial index on unresolved draft entries;
- the existing artwork, duration, Apple ID, and Spotify ID checks are reused.

### `playlist_edit_events`

```text
id uuid primary key
draft_id uuid not null -> playlist_edit_drafts.id on delete cascade
version integer not null
kind text not null                         add | remove | move | replace | apply
entry_key uuid nullable
from_position integer nullable
to_position integer nullable
track_id uuid nullable -> tracks.id on delete set null
created_at timestamptz not null
```

This is a compact audit and taste-input stream, not the source of truth for the
current draft. It contains identifiers and positions, never prompts or private
playlist names.

### Why snapshot both base and draft

An operation log alone is compact but becomes fragile around duplicates,
unresolved local songs, and a source changing on another device. Two explicit
ordered snapshots make diffing and conflict explanation deterministic. The
storage cost is bounded to one active draft per playlist and is worth the safer
interface.

## Server module boundary

Create `server/src/playlist-editing/` as one deep module:

```text
contracts.ts       request validation and response shapes
store.ts           draft lifecycle and short transactions
diff.ts            deterministic occurrence-aware diff
catalog.ts         bounded catalog discovery adapter
placement.ts       candidate and neighbour scoring
tools.ts           playlist-context DJ tool definitions
apply.ts           capability selection and apply-plan preparation
receipts.ts        confirmation and unknown-outcome reconciliation
```

Routes and the existing DJ loop call this module; they do not manipulate draft
tables directly. Network calls, catalog enrichment, and LLM work happen outside
database transactions. A write transaction only rechecks `version`, replaces
the ordered `draft` role, appends events, and increments the version.

## HTTP contract

All playlist and draft lookups are user-scoped. Another user's existing ID is
reported as 404, matching current playlist browse behavior.

### Create or resume

```http
POST /playlists/:playlistId/edit-draft

200/201
{
  "draft": {
    ...,
    "sourceProviderLibraryId": "opaque provider identifier"
  },
  "entries": [ ... ],
  "diff": { "added": [], "removed": [], "moved": [], "replaced": [] },
  "capability": {
    "possibleModes": ["revised_copy"],
    "sourceWillRemainUntouched": true
  }
}
```

Creation copies one published source snapshot into both `base` and `draft` in a
short transaction. A source with zero entries may still be drafted. A source
that disappeared after browse returns a recoverable unavailable response.
The provider identifier is exposed only inside this authenticated, user-scoped
draft contract so the native adapter can inspect the exact Apple source. It is
never accepted as playlist ownership proof.

### Read and abandon

```http
GET    /playlist-edit-drafts/:draftId
DELETE /playlist-edit-drafts/:draftId
```

Delete means abandon: it marks the draft terminal and retains the operational
audit until account deletion or the normal private-data retention job removes
it.

### Talk to the DJ

```http
POST /playlist-edit-drafts/:draftId/messages
{
  "content": "add a couple more songs by Daniel Caesar where they fit best",
  "expectedVersion": 3
}
```

The playlist-edit loop exposes only:

```text
search_catalog(query, artist?, album?, limit?)
edit_playlist_draft(operations[], expectedVersion)
```

Supported strict operations:

```text
add(trackId, afterEntryKey?, beforeEntryKey?, placementIntent?)
remove(entryKey)
move(entryKey, afterEntryKey?, beforeEntryKey?)
replace(entryKey, trackId, placementIntent?)
```

Positions are not accepted as durable identity. The server normalizes anchors
to the resulting zero-based order and rejects missing or contradictory anchors.
The LLM cannot call Apple or choose the apply mode.

### Prepare apply

```http
POST /playlist-edit-drafts/:draftId/prepare-apply
{
  "expectedVersion": 4,
  "currentSourceFingerprint": "...",
  "clientCapabilities": {
    "revisedCopy": true,
    "append": false,
    "rebuildReceiptClasses": []
  }
}
```

The server first compares the native fingerprint with
`base_source_fingerprint`, then computes the desired fingerprint and chooses:

- `append` only if the base is an exact prefix of the draft and the suffix is
  non-empty and fully Apple-resolved;
- `rebuild` only when every rebuild gate in this spec passes;
- otherwise `revised_copy` if the full desired order is Apple-resolvable;
- `blocked` when a copy/rebuild would omit any unresolved entry.

The stored apply plan includes an opaque `operationId`, draft version, source
and desired fingerprints, ordered Apple catalog/library IDs, mode, and a
10-minute expiry. Calling prepare again for the same version returns the same
operation. After expiry, a fresh source check renews its window without changing
the operation ID; a new ID could duplicate an unknown prior device result.

### Confirm or reconcile

```http
POST /playlist-edit-drafts/:draftId/confirm-apply
{
  "operationId": "...",
  "expectedVersion": 4,
  "appliedMode": "revised_copy",
  "applePlaylistLibraryId": "...",
  "resultingFingerprint": "..."
}
```

Confirmation is idempotent by `operationId`. It records the exact creation
receipt for a revised copy, marks the draft applied, emits explicit edit events,
and requests a fresh playlist sync. It does not trust a playlist name as
ownership proof.

An unknown client/network outcome is reconciled before retry:

- resulting fingerprint equals desired: confirm success;
- resulting fingerprint equals base: the operation may be retried explicitly;
- any other fingerprint: mark conflicted and stop.

Because duplicates are valid, append is never retried just because the expected
suffix happens to appear once somewhere in the playlist.

## Native Apple bridge

Add narrow methods rather than one generic mutation channel. The first shipped
slice exposes source inspection plus revised-copy creation; append and rebuild
remain absent until their own gates pass:

```text
fetchPlaylistFingerprint(playlistLibraryId) -> fingerprint
createRevisedPlaylist(operationId, name, description, appleCatalogIds,
                      desiredFingerprint) -> receipt

# Later gated methods
appendPlaylist(playlistLibraryId, appleCatalogIds) -> receipt
rebuildPlaylist(playlistLibraryId, appleCatalogIds) -> receipt
```

Each method:

- requires Music authorization;
- resolves exact catalog songs before starting a mutation;
- returns fixed error categories, provider playlist ID, added/failed counts,
  and the refetched resulting fingerprint;
- never logs names, tokens, song metadata, or Apple response bodies;
- runs sequential additions where ordering matters;
- exposes partial/unknown outcomes instead of reporting a clean retryable
  failure.

Before revised-copy creation, the native adapter resolves the complete catalog
write set and persists a device marker keyed by `operationId`. It stores the new
Apple library ID immediately after creation, adds songs sequentially to preserve
order and duplicates, then refetches and fingerprints the actual ordered catalog
IDs. Repeating the operation only inspects that stored playlist; it never repeats
creation or additions.

`rebuildPlaylist` is compiled but unavailable behind a server/client capability
flag until the separate typed-creation device probe passes. The plan dispatcher
rejects a mode the installed client did not advertise.

## Spotify-export behavior

Spotify export data is evidence, not a live Spotify connection. Mixtape can
build and converse over the exact imported playlist, but it cannot update the
real Spotify playlist.

For a listener connected to Apple Music:

- catalog-linked Spotify entries can become an Apple revised copy;
- every entry must have an exact Apple mapping before apply;
- ambiguous or missing mappings are shown and block apply;
- the source Spotify snapshot remains untouched;
- the new Apple playlist gets a Mixtape creation receipt and stays neutral as a
  source of self-generated taste.

Without Apple Music, the listener can keep and review the draft, but the first
release offers no provider mutation. A later Spotify OAuth integration would be
a separate capability contract, not an extension of export ingestion.

## Conflict behavior

Draft version conflicts and provider conflicts are separate:

- **Draft conflict:** another client changed the draft. Return 409 with current
  version; refetch before issuing another edit.
- **Source conflict:** Apple changed after the draft base. Mark the draft
  conflicted and require an explicit refresh.

The first release does not auto-merge a changed source. A three-way merge can be
added later, but making a plausible musical guess is not safe enough to rewrite
a durable playlist. Refresh creates a new base and reapplies only operations the
listener explicitly selects.

## Taste behavior

- Applied user-requested removals are explicit negative evidence, weaker than a
  durable “never play” memory and stronger than passive absence.
- Moves are sequencing evidence only.
- DJ-selected additions remain neutral until later listener behavior confirms
  them; this prevents self-training.
- A failed, abandoned, or unapplied draft contributes no taste.
- Revised-copy apply and direct-source apply use the same event meaning because
  the listener approved the same desired change.

## Privacy and prompt safety

- Playlist descriptions, snapshots, and user requests enter the model only at
  USER altitude through `sanitizeForPrompt`.
- The model sees a bounded rendering; code-based scoring may inspect the full
  private draft without placing it all in a prompt.
- Music User Tokens remain on-device or in MusicKit-managed browser state and
  never enter the Worker or database.
- No lyric text is requested, stored, displayed, or logged.
- Operational logs contain only counts, mode, latency, and fixed categories.
- Drafts and events cascade on account deletion and follow the same private-data
  retention posture as playlist snapshots.

## Test contract

### Server

- Create/resume is owner-scoped and copies exact order and duplicates.
- Unresolved and local entries survive every draft-only operation.
- Entry-key anchors remain correct around duplicate songs.
- “A couple” produces exactly two eligible nonduplicate additions.
- Catalog search is bounded and artist constrained.
- Diff is deterministic and never model-authored.
- Expected-version conflict writes nothing.
- Apply selection never returns append for a middle insertion.
- Apply selection never returns rebuild without the trusted receipt and enabled
  probe class.
- Revised copy blocks rather than omits an unresolved entry.
- Prepare is idempotent per draft version and expires safely.
- Source-fingerprint mismatch prevents apply.
- Confirm is idempotent, records ownership, and emits taste events once.
- Network and LLM calls hold no database transaction open.
- Every new foreign key has a covering index.

### Flutter/web

- Playlist detail opens or resumes the correct draft.
- Providers reset on authentication changes and cancel owned work on dispose.
- Untouched, thinking, changed, review, applying, success, conflict, blocked,
  partial, and unknown-outcome states are covered.
- The UI says revised copy before confirmation and never later claims the source
  changed.
- A stale draft refreshes instead of overwriting.
- The apply dispatcher rejects unsupported server modes.
- Spotify exports never show a write-back-to-Spotify action.

### Swift/device

- Append probe on a disposable external playlist, with before/after snapshot.
- Append probe on a disposable typed-MusicKit playlist.
- Exact-rebuild probe only on a disposable playlist created in the same flow,
  including order, duplicates, removal, insertion, and refetch.
- Revised-copy creation preserves the desired order and returns the real ID.
- Partial add and network interruption reconcile without blind retry.
- Full smoke: open playlist, request two Daniel Caesar songs, approve positions,
  apply, and verify both result and untouched-source promise in Music.

The authoritative server command remains:

```sh
npx vitest run --no-file-parallelism
```

## Rollout slices

1. **Draft foundation:** migration, store, deterministic operations/diff, routes,
   and tests. No LLM or Apple writes.
2. **Playlist DJ:** catalog search, placement, playlist-context tool loop, and
   bounded prompt context. Still no Apple writes.
3. **Review UI:** approval-ready state board, then playlist detail/conversation
   implementation on the approved brand.
4. **Revised copy:** native create/apply receipt/reconcile path and disposable
   device smoke. This is the safest first write release.
5. **Verified append:** separate device probes, suffix-only capability, conflict
   and unknown-outcome smoke.
6. **Optional rebuild:** only after typed-MusicKit creation and exact rebuild pass
   the independent probe; otherwise this slice remains closed.

Each slice gets a task-level implementation plan, test-first execution,
adversarial review, and fix round. Production migrations and Worker deployment
remain separately approved release actions.

## Acceptance criteria

- The user can browse a playlist without starting an edit session.
- A source playlist opens into an exact private draft with order, duplicates,
  and unresolved entries preserved.
- Conversational add/remove/move/replace requests produce a deterministic diff.
- The Daniel Caesar example proposes exactly two eligible additions at explicit
  draft positions.
- No provider mutation occurs before a separate confirmation.
- The confirmation accurately says append, update source, or create revised
  playlist.
- Middle insertion, removal, replacement, and reordering never degrade to an
  append.
- A revised copy leaves the source untouched and preserves every entry or blocks.
- A source changed elsewhere cannot be overwritten without explicit refresh.
- Spotify-export drafts never claim to update Spotify.
- Unknown mutation outcomes reconcile before retry.
- No user token, playlist text, prompt, lyric text, or provider body enters logs.

## Reopen clauses

Revisit the capability matrix if Apple adds arbitrary library-playlist mutation,
if a typed-MusicKit playlist passes the exact rebuild probe, if Spotify OAuth is
introduced, or if real device evidence shows that append cannot be reconciled
safely. Until then, revised copy is the honest default for edits that change
playlist structure.
