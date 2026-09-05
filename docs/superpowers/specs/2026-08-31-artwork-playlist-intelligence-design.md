# Artwork + Playlist Intelligence — System Design

*Status: founder-approved 2026-08-31 · iOS 16 minimum locked · Phase 0–1 production-complete · Phase 2 code-complete, rollout pending*
*Companion docs: [vision](../../product/vision.md) · [v1 design](2026-08-29-mixtape-v1-design.md) · [decisions](../../decisions.md) · [backlog](../../backlog.md)*
*Phase 0–1 plan: [capability spikes + artwork metadata](../plans/2026-08-31-artwork-capability-spikes.md)*
*Phase 2 plan: [read-only playlist sync + browse](../plans/2026-08-31-playlist-sync-browse.md)*

## Summary

Mixtape will ingest Apple artwork metadata and the listener's Apple Music playlists, use hand-built playlists as an explicit taste signal, make playlists browsable, and let the listener edit a playlist by talking to the DJ.

The canonical example is:

> Open a playlist and say: "Add a couple more songs by Daniel Caesar, but put them where they fit best."

The DJ searches the Apple Music catalog when the listener's library is insufficient, selects a bounded set of fitting tracks, constructs an ordered draft, explains the proposed changes, and waits for the listener to apply them. Apple Music is mutated only from an explicit apply action.

This does **not** replace the sessions-first product model. A **mix** remains the ephemeral result of an ordinary DJ conversation. A **playlist** is an existing durable Apple Music object that can become the target of a separate editing conversation.

## Founder decisions locked by this spec

- Store album artwork as an Apple URL template plus dimensions and `artwork_bg_color`; do not store image bytes in Postgres or proxy every image through the Worker.
- Playlists serve two roles: a taste signal and a user-visible collection that can be browsed.
- A playlist can be opened as a conversational DJ workspace.
- DJ playlist edits are staged as a draft and reviewed before Apple Music is changed.
- Mixtape-owned playlists can be rebuilt in an exact order when Apple permits it.
- For a playlist Mixtape cannot rebuild, append-only changes may be applied directly; any change requiring insertion, removal, or reordering creates a revised copy rather than silently degrading the requested order.
- A revised copy uses the full desired order and leaves the source playlist untouched.
- Playlist names, descriptions, and entries are user-derived data. When included in an LLM request they are sanitized with the existing `sanitizeForPrompt` posture and injected at USER altitude only.
- Playlist editing may use Apple catalog tracks outside the listener's library. This deliberately opens the catalog-discovery work deferred from v1.
- Existing database names such as `queue_tracks` remain unchanged. Product copy continues to use **mix**, **play now**, and **create playlist**.

## Goals

1. Every resolved catalog track can carry appropriate Apple artwork metadata in API responses.
2. A completed sync produces an ordered, deletion-safe snapshot of the listener's playlists.
3. The listener can browse playlists and their tracks even when some entries are local imports with no Apple catalog ID.
4. User-curated playlist membership improves ordinary mix ranking without overwhelming the prompt, play counts, or learned taste.
5. A listener can ask for a mix inspired by a named playlist.
6. A listener can open a playlist, converse about changes, preview a precise diff, and safely apply the result within Apple's capabilities.
7. The server never stores an Apple Music User Token.

## Non-goals

- Downloading, resizing, or permanently hosting Apple artwork.
- Editing Apple editorial or personalized playlists that Apple reports as non-editable.
- Silently replacing, renaming, or deleting a source playlist.
- Pretending an append-only Apple API can insert tracks in the middle.
- Treating Apple editorial, Replay, or personal-mix playlist membership as direct evidence of user taste.
- Inferring a negative taste signal merely because a track disappeared during a later sync.
- Android playlist mutation in this phase.
- Full web mutation parity in the first implementation. Web may browse and draft against the shared server model; native iOS remains the first apply surface.
- Mixing playlist edits into the ordinary mix queue tables. Playlists permit duplicates and unresolved library entries; the current mix store deliberately deduplicates tracks and therefore has the wrong invariants.

## Apple capability boundary

Apple exposes three materially different operations:

| Target | Read | Append | Exact rebuild / reorder | Mixtape behavior |
|---|---:|---:|---:|---|
| Current Mixtape-created playlist (`MPMediaLibrary`) | Yes, device-verified | Pending append verification | No, device-rejected | Append only after separate verification; otherwise create a revised copy |
| User playlist created outside Mixtape | Yes, device-verified | Usually, when Apple reports editable; still requires device verification | No, device-rejected | Append only when the desired result is append-only and verified; otherwise create a revised copy |
| Future MusicKit-created playlist | Expected | Expected | Unverified | Never return `rebuild` until this creation path passes a separate device probe |
| Apple editorial/personalized/non-editable playlist | Yes | No | No | Browse/use as context; create a new playlist from a desired revision |

Apple's REST `POST /v1/me/library/playlists/{id}/tracks` adds tracks only to the end. MusicKit for Swift exposes a full `edit(...items:)` rebuild, but documents that it fails for a playlist another app created. These constraints are product behavior, not errors to hide.

Authoritative Apple references:

- [Add Tracks to a Library Playlist](https://developer.apple.com/documentation/applemusicapi/add-tracks-to-a-library-playlist)
- [MusicLibrary](https://developer.apple.com/documentation/musickit/musiclibrary)
- [Edit a playlist including its items](https://developer.apple.com/documentation/musickit/musiclibrary/edit%28_%3Aname%3Adescription%3Aauthordisplayname%3Aitems%3A%29)
- [Get Multiple Catalog Songs by ID](https://developer.apple.com/documentation/applemusicapi/get-multiple-catalog-songs-by-id)
- [User Authentication for MusicKit](https://developer.apple.com/documentation/applemusicapi/user-authentication-for-musickit)

### iOS availability decision — locked

The Flutter target now declares iOS 16 consistently. The installed Apple SDK marks the playlist APIs this design depends on—`MusicLibraryRequest` and `MusicLibrary`—as iOS 16 or newer.

Mixtape's minimum deployment target is **iOS 16** before playlist sync ships. This matches the founder/friends distribution, keeps one honest playlist contract, and avoids building a second MediaPlayer-only browse path that still cannot deliver exact conversational editing. iOS 13–15 compatibility and its degraded playlist fallback are out of scope.

### Required capability spikes

Before the implementation plan is finalized, run two thin, device-backed spikes:

1. **Catalog from Workers:** use a server-scoped developer token to call `GET /v1/catalog/{storefront}/songs?ids=...` from the deployed Worker and verify Nigerian-storefront artwork responses. This must not use the blocked iTunes endpoint.
2. **Playlist ownership:** create a playlist through the current `MPMediaLibrary.getPlaylist` bridge, refetch it through MusicKit for Swift, and verify whether `MusicLibrary.edit(...items:)` recognizes it as app-created. Also attempt the same operation against a playlist created in Music to pin the failure shape.

Observed on the founder's iPhone on 2026-08-31: both disposable candidates were found and their non-empty ordered entries resolved, but `MusicLibrary.shared.edit(...items:)` rejected the same-order rebuild for both the current Mixtape-created playlist and the playlist created directly in Music. The founder later reported that the current ordering looked intact but was unsure whether the Music-created candidate had lost one song; no pre-probe snapshot exists to resolve that possible side effect. Treat the manual no-op verification as inconclusive, run no further mutation probe in Phase 2, and use the new read-only snapshot pipeline to establish future baselines. Already-created Mixtape playlists may still be marked owned from trusted create-confirmation provenance, but ownership does not grant `rebuild`. The first implementation must use `append` only after that narrower operation is separately verified and `revised_copy` for insertion, removal, or reordering.

### Read-only playlist contract — founder iPhone, 2026-08-31

The approved aggregate-only probe enumerated **36 playlists and 1,333 entries** through `MusicLibraryRequest<Playlist>` plus `playlist.with(.entries, preferredSource: .library)`. All playlist IDs were non-empty and unique. Every entry exposed an underlying song item; 16 repeated underlying-song groups used distinct entry IDs, confirming that duplicate playlist occurrences must remain separate rows.

The contract is deliberately conservative:

- Storefront resolution succeeded and produced a valid lowercase two-letter country code.
- Enumeration order is canonical. Thirty-five playlists reported clean zero-based positions, but one playlist contained 91 repeated/non-increasing position values. Persist `enumerated()` index as `position`; retain Apple's raw position only as optional diagnostics if ever needed, never as the canonical key.
- Observed kinds were 23 `userShared`, 6 `editorial`, 2 `external`, and 5 nil. Nil remains `unknown`; do not infer user curation or editability from a missing kind.
- Every underlying item ID differed from its playlist-entry ID, but no entry exposed an ISRC and the probe did not prove that the item ID was a catalog ID. Store it as an opaque library item ID. Keep `apple_catalog_id` and `track_id` null until an exact, evidence-backed resolver succeeds.
- Typed MusicKit returned artwork objects for all 36 playlists and all 1,333 entries. All reported zero maximum dimensions, and a fixed 512×512 `Artwork.url(width:height:)` request returned no HTTPS URL. Background colour remained available for 1,363 of 1,369 artwork objects. Therefore `artwork_bg_color` is first-class while playlist/entry artwork URL and dimensions remain nullable.
- Apple's documented `GET /v1/me/library/playlists` response can include artwork URL templates, `canEdit`, `hasCatalog`, and a global playlist ID. A local `MusicDataRequest` attempt failed before yielding a usable response body on this app setup. Phase 2 does not depend on that route, does not forward a Music User Token to the Worker, and defaults edit/catalog capability conservatively. Reopen the raw route only with a separate authenticated-client test and the same no-token/no-private-log constraints.

The temporary probe, probe-only Profile compilation flag, aggregate result file, and method-channel entry point were removed after the run.

## Architecture

```text
Apple Music library on device
        │
        │ MusicKit/MediaPlayer snapshot
        ▼
Flutter sync orchestrator ───────────────┐
        │                               │
        │ chunked snapshot              │ apply exact rebuild / append / copy
        ▼                               ▼
Hono ingest API                    Native MusicKit bridge
        │                               ▲
        ▼                               │ apply plan + desired ordered entries
Neon playlist snapshot                  │
        │                               │
        ├── taste scoring               │
        ├── browse APIs                 │
        └── playlist edit draft ────────┘
                  │
                  ├── Apple catalog search
                  ├── bounded on-demand enrichment
                  └── Sonnet selection + sequencing
```

### Responsibility split

- **MediaPlayer remains the song/play-count source.** The current native query provides real per-song play counts and stable catalog IDs for eligible tracks.
- **MusicKit for Swift becomes the playlist read/mutation source.** It provides playlist resources, ordered entry collections, artwork background colours, and automatic user-token handling on iOS. Typed library artwork URLs are nullable because the founder-device contract returned no usable URL or dimensions.
- **The Worker owns catalog metadata and curation.** It uses only a developer token for public catalog calls and never receives or stores the listener's Music User Token.
- **Neon owns the synchronized snapshot and edit drafts.** Apple Music remains the external durable source; the database is a queryable mirror plus Mixtape workflow state.
- **The client applies Apple mutations.** It refetches immediately before apply, detects conflicts, performs the supported mutation, then confirms the resulting Apple identifiers and fingerprint to the server.

## MusicKit token separation

The in-progress web integration introduces a MusicKit ES256 signer and an origin-bound `/musickit/token` response. Reuse that signer, but do not reuse an origin-bound browser JWT for server-to-Apple calls.

The signer must support two explicit modes:

- **Browser token:** short-lived, includes `origin: [allowedOrigin]`, returned only to an authenticated request from the allowlisted origin.
- **Server catalog token:** short-lived/cached in Worker memory, omits `origin`, never returned to a client, used only by the Apple catalog client.

The MusicKit private key remains a Worker secret. Logging must contain fixed error categories and Apple status codes only—never tokens, response bodies, playlist names, or track metadata.

## Data model

Names below are the proposed Drizzle/API names. The implementation plan may split migrations by phase, but it must preserve these contracts.

### Track artwork

Add nullable fields to `tracks`:

```text
artwork_url_template text
artwork_width integer
artwork_height integer
artwork_bg_color text
artwork_fetched_at timestamptz
```

Rules:

- `artwork_url_template` stores Apple's `{w}`/`{h}` template unchanged after URL validation.
- `artwork_bg_color` is normalized to lowercase six-character hexadecimal without `#` and validated with `^[0-9a-f]{6}$`.
- Width and height must be positive when present.
- A later null response never erases known artwork.
- A 404/no-match is retryable only after a long refresh interval; 429/5xx use bounded backoff.
- The UI chooses dimensions by replacing `{w}` and `{h}`. It uses `artwork_bg_color` while the image loads and a neutral product fallback when the colour is absent.

If an Apple framework surface exposes only a concrete requested-size URL, store that valid URL in the same field; the shared renderer replaces `{w}`/`{h}` only when the tokens are present. Prefer raw Apple Music API responses through MusicKit's authenticated `MusicDataRequest` when preserving the template is practical.

Do not create an albums table merely to deduplicate an artwork URL across tracks. Introduce real album entities only when album browsing, album-level actions, or provider-equivalence requires them.

### User music profile

```text
user_music_profiles
  user_id text primary key references user(id) on delete cascade
  apple_storefront text not null
  library_synced_at timestamptz
  playlists_synced_at timestamptz
  created_at timestamptz not null
  updated_at timestamptz not null
```

The client retrieves the listener's storefront during authorization/sync. Catalog lookups group IDs by a known owning user's storefront; the existing `ng` default remains only a founder-compatible fallback, not the long-term multi-user contract.

### Canonical playlists

```text
user_playlists
  id uuid primary key
  user_id text not null references user(id) on delete cascade
  apple_library_id text not null
  apple_catalog_id text
  name text not null
  description text
  curator_name text
  artwork_url_template text
  artwork_width integer
  artwork_height integer
  artwork_bg_color text
  kind text                         -- user, editorial, external, personal_mix, replay, user_shared, unknown
  can_edit boolean not null default false
  is_mixtape_owned boolean not null default false
  apple_date_added timestamptz
  apple_last_modified_at timestamptz
  source_fingerprint text not null
  in_library boolean not null default true
  created_at timestamptz not null
  updated_at timestamptz not null

unique(user_id, apple_library_id)
index(user_id, in_library, updated_at)
```

`is_mixtape_owned` is not inferred from the playlist name, author string, description, or `can_edit`. It is set only by a successful Mixtape create-confirmation or another trusted creation record. It is provenance for product behavior and taste-loop prevention, not proof of exact-rebuild capability. The founder-device spike rejected rebuild for the current `MPMediaLibrary` creation flow.

`can_edit` defaults to false because the typed MusicKit surface used by Phase 2 exposes no editability flag and the authenticated raw endpoint was not proven on-device. `artwork_url_template`, width, and height are nullable independently of `artwork_bg_color`; a valid colour must not be discarded merely because the image URL is absent.

`source_fingerprint` is an opaque client-produced SHA-256 value. The native bridge hashes a version hash when Apple exposes one; otherwise it hashes a documented canonical serialization of playlist ID, last-modified time, and the ordered entry identifiers. The same native function produces the sync fingerprint and the pre-apply fingerprint so server/client JSON serialization differences cannot create false conflicts.

### Canonical playlist entries

Use `playlist_entries`, not `playlist_tracks`: an Apple playlist entry can be a local import, may lack a catalog match, and duplicates are valid.

```text
playlist_entries
  id uuid primary key
  playlist_id uuid not null references user_playlists(id) on delete cascade
  position integer not null
  track_id uuid references tracks(id) on delete set null
  apple_library_entry_id text not null
  apple_library_track_id text
  apple_catalog_id text
  title_snapshot text not null
  artist_snapshot text not null
  album_snapshot text
  duration_ms_snapshot integer
  artwork_url_template_snapshot text
  artwork_bg_color_snapshot text
  created_at timestamptz not null

unique(playlist_id, position)
unique(playlist_id, apple_library_entry_id)
index(track_id)
```

Snapshots keep browsing honest when no global `tracks` row exists or catalog metadata later changes. A resolved `track_id` drives taste, enrichment, and catalog actions. An unresolved entry remains visible and remains in any full rebuild when the native client can resolve its Apple library ID. It is never silently dropped. Canonical rows merge on `(playlist_id, apple_library_entry_id)`, so their internal UUIDs survive reorders and metadata refreshes; duplicate songs remain distinct because Apple supplies a distinct entry ID for each occurrence.

### Deletion-safe sync staging

Playlist sync is a replaceable snapshot, not a series of independent canonical upserts.

```text
playlist_sync_runs
  id uuid primary key
  user_id text not null
  status text not null              -- open, completed, failed, expired
  apple_storefront text not null
  expected_playlists integer not null
  expected_entries integer not null
  received_playlists integer not null
  received_entries integer not null
  result_* integer                  -- immutable completion summary
  started_at timestamptz not null
  expires_at timestamptz not null
  completed_at timestamptz

playlist_sync_playlists
  sync_id uuid not null
  ordinal integer not null
  apple_library_id text not null
  normalized playlist fields       -- bounded text, artwork, kind, dates, fingerprint, count
  primary key(sync_id, apple_library_id)
  unique(sync_id, ordinal)

playlist_sync_entries
  sync_id uuid not null
  apple_playlist_id text not null
  position integer not null
  normalized entry fields          -- library IDs, nullable resolver IDs, snapshots, artwork
  primary key(sync_id, apple_playlist_id, position)
```

Staging uses typed, constrained columns rather than opaque JSON payloads. This lets Postgres enforce ordering, colour, duration, relationship, and identifier invariants before publish, while still preserving valid Unicode display text unchanged.

Staging rows are user-scoped through their run. Chunk uploads are idempotent. Canonical playlists are untouched until completion validates counts and commits the new snapshot in one transaction:

1. Upsert every staged playlist.
2. Merge entries by stable Apple entry identity, safely apply exact order, add new occurrences, and remove stale occurrences.
3. Mark previously present but now absent playlists `in_library = false`.
4. Update `user_music_profiles.playlists_synced_at`.
5. Mark the run completed.

An interrupted, cancelled, or expired run never produces a half-old/half-new browse result. Scheduled cleanup marks open runs older than 24 hours expired. Expired and completed staging becomes eligible after seven days; each pass locks at most 25 oldest runs, skips concurrent locks, and deletes at most 5,000 entry rows plus 500 empty playlist headers. Completed run summaries remain intact.

### Playlist edit conversations and drafts

Extend `dj_sessions`:

```text
context_type text not null default 'mix'    -- mix | playlist_edit
target_playlist_id uuid references user_playlists(id) on delete set null
```

Constraint: `target_playlist_id` is required for `playlist_edit` and null for `mix`.

Do not seed `queue_tracks` with playlist contents. Add separate draft tables:

```text
playlist_edit_drafts
  id uuid primary key
  session_id uuid not null unique references dj_sessions(id) on delete cascade
  playlist_id uuid not null references user_playlists(id)
  base_fingerprint text not null
  version integer not null default 1
  status text not null                 -- active, applying, applied, conflicted, abandoned
  apply_mode text                      -- rebuild, append, revised_copy
  applied_apple_playlist_id text
  created_at timestamptz not null
  updated_at timestamptz not null

playlist_draft_entries
  id uuid primary key
  draft_id uuid not null references playlist_edit_drafts(id) on delete cascade
  position integer not null
  source_entry_id uuid references playlist_entries(id) on delete set null
  track_id uuid references tracks(id) on delete set null
  apple_library_track_id text
  apple_catalog_id text
  title_snapshot text not null
  artist_snapshot text not null
  reason text
  added_by text not null                -- source, dj, user
  created_at timestamptz not null

unique(draft_id, position)
```

Draft entries preserve duplicates. A draft starts as an exact copy of the canonical playlist snapshot. Each successful operation bumps `version`; the client sends the version with manual and apply requests to prevent stale writes.

Record durable provenance separately from the current snapshot:

```text
playlist_edit_events
  id uuid primary key
  draft_id uuid not null
  playlist_id uuid not null
  type text not null                   -- add, remove, move, replace, apply
  track_id uuid
  actor text not null                  -- user, dj
  created_at timestamptz not null
```

Only explicit Mixtape actions become behavioral signals. Passive sync differences do not.

## Artwork enrichment flow

1. Library ingest upserts the track immediately as today.
2. Tracks missing artwork become eligible for an artwork batch.
3. The Worker requests Apple catalog songs in batches of at most 300, grouped by storefront.
4. Validate response IDs against requested IDs; never trust position-only correspondence.
5. Upsert artwork metadata monotonically.
6. Include artwork in mix queue, playlist entry, catalog search, and session response contracts.

The artwork job is separate from ReccoBeats/lyrics enrichment. An artwork failure must not consume or poison feature/meaning attempts, and a feature failure must not delay a cover.

## Playlist sync flow

### Native snapshot

The Swift bridge exposes an immutable, fully materialized playlist snapshot backed by MusicKit for Swift:

```text
beginPlaylistSnapshot()
  -> { snapshotId, storefront, totalPlaylists, totalEntries }
fetchPlaylistSnapshotPage(snapshotId, offset, limit)
releasePlaylistSnapshot(snapshotId)
```

The native snapshot follows every MusicKit entry page before exposing the snapshot to Flutter. It assigns canonical zero-based positions from enumeration order, preserves duplicates by entry ID, and treats playlist/item IDs as opaque library IDs. It returns a catalog ID only when a documented field or exact cross-source match proves that identity; the founder-device read proved none, so null is the correct initial value.

Playlist and entry artwork carry `artwork_bg_color` whenever MusicKit supplies it. URL and dimension fields remain null when `Artwork.url(width:height:)` or maximum dimensions are unavailable; the bridge does not render a `UIImage` into a Flutter payload or invent a URL from an opaque ID.

The native layer holds a per-run snapshot or opaque snapshot token so a library mutation cannot shift offsets mid-sync. As with the existing song bridge, a cold fetch at a nonzero offset fails loudly.

### HTTP contract

Phase 2 implements these authenticated endpoints:

```text
POST /ingest/playlists/syncs
  { storefront, expectedPlaylists, expectedEntries }
  -> { syncId, expiresAt }

PUT /ingest/playlists/syncs/:syncId/playlists
  { playlists[] }                       -- max 50, exactly idempotent

PUT /ingest/playlists/syncs/:syncId/entries
  { playlistAppleId, entries[] }        -- max 200, empty list is meaningful

POST /ingest/playlists/syncs/:syncId/complete
  -> { playlists, entries, resolvedEntries, unresolvedEntries }
```

Every route requires the existing Mixtape session and verifies ownership of the sync run. Malformed IDs, negative positions, duplicate positions inside one chunk, out-of-range colours, and oversized chunks are rejected before database work.

The Flutter sync orchestrator runs song sync first, then playlist sync. This maximizes `track_id` resolution during canonicalization. Cancellation stops before the next await and leaves the open run harmless; it does not call complete.

## Browse API

```text
GET /playlists?status=active&cursor=...
  -> { playlists[], nextCursor }

GET /playlists/:id?entryLimit=200&entryCursor=...
  -> { playlist, entries[], nextEntryCursor }
```

Future editing phase:

```text
POST /playlists/:id/edit-sessions
  -> existing active edit session or a new session + exact initial draft
```

Playlist IDs exposed by the API are internal UUIDs, never accepted as proof of ownership. Every lookup joins on `user_id` and returns 404 for another user's resource.

Browse ordering defaults to Apple's latest-modified value, falling back to local `updated_at`. Search by playlist name is literal, case-insensitive, and user-scoped. Phase 2 returns the conservative capability `copy_only` for every playlist: browse and collection contracts are implemented, but taste scoring, conversational editing, mutation, and browse UI are not yet shipped.

## Playlist taste signal

Playlist membership is an explicit curation signal, but not all playlists mean the same thing.

### Eligible positive signal

**2026-09-04 implementation refinement:** eligibility also requires explicit
owner confirmation (`playlist_origins.origin = user_confirmed`), because playlist
kind/editability does not establish authorship. Exact Mixtape creation receipts
and the legacy ownership flag always exclude a playlist. Missing origin is
unknown, not user-created. The confirmation API is implemented separately from
the future approved browse UI; collection never confirms automatically.

- `kind = user` or equivalent editable user collection.
- Not an Apple editorial, Replay, chart, or personal-mix playlist.
- Not automatically counted merely because Mixtape generated it.
- Entry resolves to a global track.

For a track appearing in `n` eligible distinct playlists, use a bounded diminishing-return term rather than a raw count. The implementation plan will pin the exact curve and weight with tests; the target behavior is:

- first hand-built playlist: meaningful lift;
- second/third: smaller additional lift;
- ten playlists: never enough to overwhelm a direct prompt mismatch.

Add this as a distinct `playlist` term in `buildPool`, initially around 0.08–0.12 of the convex score. Rebalance similarity, features, familiarity, and existing learned taste so all terms still sum to 1. Playlist signal reranks; it never hard-gates the pool.

The initial implementation pins the weight to 0.10 and the curve to
`1 - 0.5^min(n,10)`, counting distinct playlists per resolved recording (ISRC,
otherwise track ID). Learned taste remains 0.12; the other personal weights
retain their proportions over 0.78. Remove playlist membership from familiarity
to avoid double-counting. Corpus-mode weights and eligibility are unchanged.
No playlist-only songs enter the personal pool until a separate candidate/seed
contract is approved. See `../plans/2026-09-04-playlist-origin-taste.md`.

### Negative and neutral behavior

- A track removed through an applied Mixtape playlist edit is an explicit negative signal, weaker than a durable "never play" memory but stronger than passive non-membership.
- A track missing in a later sync is neutral: it may reflect edits on another device, playlist deletion, or Apple sync delay.
- Mixtape-generated additions are neutral until the listener explicitly keeps/acts on them in a later signal design; this prevents the DJ from training on its own output.
- Moves affect sequencing context, not global like/dislike.

### Playlist-as-seed

When the listener asks for "something like Late Nights":

1. Resolve the playlist by internal ID when selected in UI; otherwise fuzzy-match only within that user's playlist names and ask when ambiguous.
2. Build a seed profile from its resolved tracks: aggregate meaning embeddings, tempo/energy distribution, era, genres, and artists with bounded per-artist influence.
3. Combine that seed profile with the current prompt. The prompt wins conflicts.
4. Exclude source entries only when the listener asks for something new; otherwise source tracks may compete normally.

Playlist names/descriptions help identify and frame the seed but are not system instructions.

## Conversational playlist editing

**2026-09-05 implementation refinement:** the standalone
[conversational source-playlist editing spec](./2026-09-05-conversational-source-playlist-editing-design.md)
supersedes this section for data shape, route, capability, retry, and rollout
details. The product promise below remains unchanged.

### Opening a playlist

Opening a playlist detail and choosing **Talk to the DJ** creates or resumes one `playlist_edit` session and its active draft. The initial message context contains:

- playlist name and sanitized description;
- current ordered entries, bounded in prompt rendering;
- unresolved-entry markers;
- edit capability (`rebuild`, `append_only`, or `copy_only`);
- draft version and any unapplied changes.

The UI can browse without creating a DJ session. A session begins only when the listener enters the editing conversation.

### DJ tools

Playlist-edit sessions expose context-specific tools rather than reusing the ordinary mix generator blindly:

```text
search_catalog(query, artist?, album?, limit?)
edit_playlist(ops[], expectedVersion)
```

Supported draft operations:

```text
add(trackId, nearPosition?, placementIntent?)
remove(entryId)
move(entryId, toPosition)
replace(entryId, trackId, placementIntent?)
```

`edit_playlist` mutates only the server draft. It never calls Apple. The same "standing mix is precious" principle applies: make the smallest change satisfying the request and preserve every unrelated entry and duplicate exactly.

For "add a couple more songs by Daniel Caesar, but put them where they fit best":

1. Parse "a couple" as 2 unless the conversation establishes another meaning.
2. Search the catalog with an artist-constrained query.
3. Remove tracks already present unless the listener explicitly permits duplicates.
4. Score candidates against the listener's taste and the playlist's aggregate profile.
5. Enrich a bounded shortlist when useful metadata is missing.
6. Select exactly two.
7. Sequence them against neighbouring tracks and insert at the best positions.
8. Return a short explanation plus a deterministic diff.

### Catalog discovery and on-demand enrichment

The server adds an Apple catalog client behind dependency injection:

```text
searchSongs(storefront, query, limit)
getSongs(storefront, ids)
```

Search results upsert global `tracks` metadata, including artwork and ISRC. Artist constraints use Apple artist identity when available, normalized name equality only as a fallback.

Do not synchronously enrich hundreds of results. Bound the flow:

- catalog search: at most 25 song candidates per operation;
- exact/structural filtering in code;
- targeted enrichment: at most 12 missing candidates, with a turn-level time budget;
- partial metadata remains eligible but ranks with lower confidence.

The current ReccoBeats/meaning pipeline is reused. An enrichment timeout degrades placement quality honestly; it does not empty the draft or invent features.

### Draft diff

Every successful draft mutation returns:

```text
draftVersion
entries[]
diff:
  added[]
  removed[]
  moved[]
capability:
  applyMode: rebuild | append | revised_copy
  sourceWillRemainUntouched: boolean
```

The diff is computed in code from stable entry IDs, never generated by the LLM. The DJ may explain it, but the UI's counts and positions come from deterministic server data.

## Apply protocol

Apple mutation is an explicit two-step operation.

### 1. Prepare

```text
POST /playlist-drafts/:id/prepare-apply
  { expectedVersion, currentAppleFingerprint }
```

The server verifies ownership, active status, draft version, and base fingerprint. It returns a short-lived apply plan containing the desired ordered Apple library/catalog IDs and one mode:

- `rebuild`: reserved for a future playlist creation path that separately passes an exact-rebuild device probe; the current implementation never returns this mode;
- `append`: add only a trailing suffix to an editable external playlist;
- `revised_copy`: create a new playlist with the complete desired order.

If the device fingerprint differs from the draft base, return 409 and mark the draft conflicted. The listener can refresh/rebase; Mixtape never overwrites external changes silently.

### 2. Execute and confirm

The Swift bridge executes the plan, then the client posts:

```text
POST /playlist-drafts/:id/confirm-apply
  {
    expectedVersion,
    operationId,
    applePlaylistId,
    resultingFingerprint,
    appliedMode
  }
```

Confirmation marks the draft applied, records explicit edit events, and triggers/resumes playlist sync. A revised copy is immediately recorded as Mixtape-owned after successful creation confirmation.

### Retry safety

Apple does not provide a general idempotency key for playlist mutations. `operationId` prevents duplicate server confirmation but cannot by itself prevent Apple from applying a retried append twice.

Before retrying after an unknown client/network outcome:

- refetch the target playlist;
- compare its fingerprint with both the base and desired result;
- treat a desired-result match as success;
- treat a base match as safe to retry;
- otherwise stop and show a conflict.

Never automatically retry an append when the outcome cannot be proven, because duplicate songs are valid playlist content and therefore cannot be guessed away safely.

## UI contract for the later design board

The playlist interface is a substantial UI addition and receives an approval-ready state board before implementation. That board must cover:

- playlist browse: loading, populated, empty, search, sync stale/error;
- playlist detail: artwork-led header, ordered tracks, unresolved/local entry;
- edit conversation: untouched draft, preparing suggestions, changed draft, failure;
- deterministic change summary: additions, removals, moves;
- capability disclosure: exact update, append-only, revised-copy fallback;
- apply confirmation, applying, success, partial/unknown outcome, conflict;
- revised-copy result with a clear link/action to the new playlist.

Artwork background colour may influence the cover container only. It must not automatically recolour the whole interface or reduce text contrast.

## Error handling

- Playlist permission denied: keep server history; prompt for Music authorization.
- Playlist deleted between browse and open: mark `in_library = false`, return a recoverable unavailable state.
- Sync interrupted: canonical snapshot remains unchanged.
- Malformed Apple response: reject the affected item, report fixed-category counts, never log personal metadata.
- Catalog 429/5xx: bounded retry/circuit breaker; existing draft remains untouched.
- Catalog no-match: DJ explains it could not find an eligible match; no mutation.
- On-demand enrichment failure: use partial metadata with reduced confidence.
- Draft version conflict: 409, no partial draft mutation.
- Source playlist changed before apply: conflicted draft, explicit refresh/rebase.
- Unsupported exact edit: revised-copy mode, never silent append.
- Native apply partially completes: do not confirm; refetch and reconcile before another action.
- Local/unresolved entry cannot be rebuilt: block exact apply and offer a revised copy that preserves every resolvable item while explicitly listing the unsupported entry; never drop it silently.

## Privacy and prompt safety

- Playlist library data is private and user-scoped at every query.
- Raw Music User Tokens stay in MusicKit-managed client state and never enter Mixtape's API or database.
- Playlist names, descriptions, and entry snapshots are sanitized before prompt rendering.
- They appear only inside the leading USER context message, following the existing memory/queue injection posture.
- Catalog metadata is untrusted external text and receives the same sanitation.
- Prompt listings are bounded by entry and character count; full playlists remain available to code-based scoring without dumping every title into the model context.
- No lyric text is stored or displayed; catalog discovery does not reopen the lyrics stance.

## Testing strategy

### Server

- Artwork parser: template URL, dimensions, lower-case background colour, invalid colour rejection, null-does-not-clobber.
- Developer-token modes: browser JWT has the correct origin; server catalog JWT has no origin and never reaches an HTTP response.
- Apple catalog client: batching at 300, storefront grouping, ID-based response reconciliation, 429/5xx handling, fixed-category logs.
- Sync routes: authentication, cross-tenant denial, chunk limits, idempotent retries, count validation, cancelled run leaves canonical state untouched.
- Sync completion: atomic replace, order/duplicates preserved, absent playlist soft-removal, unresolved entry preservation.
- Browse routes: ownership, pagination, search, durations/counts, artwork contract.
- Taste scoring: editorial zero, first user playlist lifts, diminishing returns, Mixtape-generated output neutral, convex weights still sum to 1.
- Playlist seed: correct owner resolution, ambiguous-name handling, prompt overrides seed, source-exclusion option.
- Draft store: exact initial copy, duplicate preservation, smallest-op behavior, version conflicts, deterministic diff.
- DJ loop: playlist tools available only in playlist context; catalog and playlist text remain at user altitude; no Apple mutation from a tool call.
- Apply preparation: correct capability mode, stale fingerprint conflict, cross-tenant denial, unresolved-entry guard.
- Confirmation: operation dedupe, ownership mapping, edit-event provenance, revised-copy ownership.

Authoritative full suite remains `npx vitest run --no-file-parallelism`.

### Flutter/Dart

- Playlist sync orchestration: songs before playlists, paging, progress, cancellation, no completion on failure.
- API models tolerate nullable artwork and unresolved entries.
- Browse/detail/draft providers watch `authProvider` and cancel owned work on dispose.
- Draft version conflicts refresh rather than overwrite.
- Apply plan dispatch maps rebuild/append/copy correctly.
- Unknown native outcome triggers refetch/reconcile rather than blind retry.
- Widget tests for every state in the approved UI board.

### Swift/device

- MusicKit authorization and target membership in the Xcode project.
- Paged playlist and entry snapshots preserve duplicates/order.
- Local imports carry a library ID when Apple exposes one.
- Artwork URL and background colour mapping.
- External playlist append.
- MusicKit-created playlist exact-rebuild re-spike before enabling `rebuild`.
- Revised-copy creation preserving the desired order.
- Device smoke: browse playlist → ask for two Daniel Caesar tracks → review positions → apply → verify exact result in Music.

## Observability

Record only operational facts:

- sync run duration and playlist/entry/resolution counts;
- artwork lookup requested/hit/no-match/error counts;
- catalog search/enrichment latency and fixed failure category;
- draft operation counts by type;
- apply mode and success/conflict/unknown-outcome counts.

Never log playlist names, descriptions, user prompts, track titles, Apple tokens, developer tokens, or Apple response bodies.

## Rollout phases

### Phase 0 — capability spikes

Worker catalog call + device playlist ownership/rebuild verification. Update this spec and `docs/decisions.md` with the observed contract before implementation planning continues.

### Phase 1 — artwork metadata

Schema, Apple catalog client, backfill, queue/API fields, client model support. UI may continue using placeholders until the approved playlist/artwork board lands.

### Phase 2 — playlist sync + browse API

MusicKit playlist read bridge, staged snapshot protocol, canonical tables, browse endpoints, server/client tests.

### Phase 3 — playlist taste + playlist seeds

Bounded scoring term and named-playlist inspiration for ordinary mixes.

### Phase 4 — conversational draft engine

Playlist-context sessions, catalog discovery, on-demand enrichment, deterministic draft store/diff, prepare/confirm apply protocol.

### Phase 5 — native apply + approved UI

Exact rebuild/append/revised-copy bridge, state-board implementation, device smoke, production migration/deploy from a clean committed worktree.

Each rollout phase receives its own task-by-task implementation plan and adversarial review/fix round. Do not combine all five into one long-lived implementation branch.

## Acceptance criteria

- Existing mix APIs return valid artwork metadata without making artwork required for playback or curation.
- A completed playlist sync reproduces Apple playlist count, order, duplicates, and local/unresolved entries; an interrupted sync changes none of them.
- User-created playlist membership creates a bounded ranking lift; Apple editorial and Mixtape-generated membership do not self-train the DJ.
- Selecting a playlist allows a new mix to use its sound/taste profile.
- Opening a playlist and asking for two Daniel Caesar songs produces exactly two nonduplicate eligible additions at deterministic proposed positions.
- No Apple playlist changes before review/apply.
- Current `MPMediaLibrary`-created and externally-created playlists never receive a `rebuild` apply plan.
- A future MusicKit-created playlist receives the exact approved order only after that creation path passes a separate device probe.
- External playlists use append only when the approved result is truly append-only; otherwise a revised copy is created and the source stays untouched.
- A playlist changed on another device cannot be overwritten without an explicit rebase.
- No Music User Token or lyric text is stored or logged.

## Open questions resolved by Phase 0 evidence

Resolved 2026-08-31: Apple catalog access works from Cloudflare's remote Worker runtime. A server-only token successfully queried the Nigerian storefront for an existing catalog ID and returned valid artwork plus a six-digit background colour. The unknown-ID path returned zero matches without upstream content, and the admin guard rejected an invalid token before making a catalog request. This approves the server-side artwork enrichment path.

Resolved 2026-08-31: the current `MPMediaLibrary.getPlaylist` creation flow is not editable through MusicKit's full rebuild API. The Mixtape-created and Music-created disposable playlists were both found with resolvable non-empty ordered entries, and the same-order `MusicLibrary.edit(...items:)` call was rejected for each. This removes `rebuild` from the current apply contract; trusted Mixtape ownership remains useful provenance but does not confer write capability.

Still to resolve during playlist sync/apply planning:

- Whether append-only mutation is reliable for the current Mixtape-created and editable external playlist classes.
- Whether a future `MusicLibrary.createPlaylist` flow is exact-rebuildable and can replace the legacy creation bridge.
- The exact stable identifier/fingerprint fields MusicKit exposes for user playlists and entries on the deployment iOS target.
- Whether every local/imported entry needed for a rebuild can be resolved back to a MusicKit playlist-addable item.

These are implementation-contract questions, not product questions. Their answers may narrow direct-apply capability, but do not change the locked revised-copy fallback.
