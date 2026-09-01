# Web sync and consumption — design

*Status: in progress for founder review · 2026-09-01*
*Companion docs: [vision](../../product/vision.md) · [playlist intelligence](2026-08-31-artwork-playlist-intelligence-design.md) · [decisions](../../decisions.md)*

## Product decision

The web app is a first-class Apple Music product for anyone who cannot or chooses not to use the native iOS app. Android listeners are a launch-critical audience, but the product and implementation are not Android-specific. The web is not merely a viewer for data previously synced from an iPhone.

A web listener with an Apple Music subscription must be able to:

1. sign in to Mixtape with Apple or Google;
2. authorize Apple Music separately in the browser;
3. sync the Apple Music library and playlists from the browser;
4. create and refine a mix from the synced taste graph;
5. play the mix through MusicKit on the Web; and
6. create an Apple Music playlist from the mix.

## Scope

### Included

- MusicKit-on-the-Web authorization across the supported mobile and desktop browser matrix.
- Full paged library-song sync for catalog-resolvable songs.
- Full paged playlist and playlist-entry sync with exact order and duplicates preserved to the strongest identity the web API exposes.
- Recently played tracks as a bounded web-only recency signal.
- Real progress, cancellation, retry, terminal success, and honest partial-capability copy.
- Server-backed playlist browse and detail UI.
- Existing mix creation, conversation, queue editing, playback, and create-playlist flows.
- Web DJ memories plus manual session rename/archive/unarchive parity.

### Excluded from this delivery

- Native Apple Music play counts on the web; Apple does not expose them through the web API.
- Spotify or non-Apple-Music playback.
- Conversational playlist-edit drafts and applying edits to an existing playlist. Those remain later playlist-intelligence phases.
- Sending a Music User Token to the Mixtape Worker or storing it in Mixtape persistence.

## Capability model

Missing is not zero. The server must preserve the difference between a signal a platform measured and a signal that platform cannot provide.

| Signal/capability | iOS native | Web |
|---|---:|---:|
| Library membership | Yes | Yes |
| Catalog song identity | Yes when resolvable | Yes when exposed by Apple |
| Exact play count | Yes | No |
| Last-played timestamp per library song | Yes when MediaPlayer supplies it | No |
| Recently played order | Optional | Yes, bounded Apple history |
| Playlist membership and order | Yes | Yes |
| Stable playlist occurrence identity | Yes | Must be device-probed |
| Playback | System Music player | MusicKit on the Web |
| Create playlist | Native MediaPlayer | Apple Music API from the authorized browser |
| Mixtape behavioral signals | Yes | Yes |

The taste graph uses every available signal without weakening the product for a web-only listener. When play counts are unavailable, familiarity does not invent zero-play evidence; playlist membership, recent order, and explicit Mixtape behavior carry more of the ranking load.

## Client module design

The web application gets one deep `AppleMusicLibrary` module. Callers should not know Apple endpoint paths, response shapes, token headers, pagination rules, or retry categories.

```ts
type AppleMusicLibrary = {
  authorize(): Promise<AppleMusicConnection>
  snapshot(options: {
    signal: AbortSignal
    onProgress: (progress: MusicSnapshotProgress) => void
  }): Promise<MusicSnapshot>
  play(catalogIds: string[]): Promise<void>
  createPlaylist(name: string, catalogIds: string[]): Promise<void>
}
```

`snapshot()` hides:

- MusicKit configuration and Music User Token lifecycle;
- storefront lookup;
- pagination of library songs, playlists, and playlist tracks;
- normalization of Apple library IDs versus catalog IDs;
- duplicate occurrence handling;
- source fingerprint generation through Web Crypto;
- bounded safety ceilings; and
- cancellation between every page.

The `MusicSyncService` owns the upload order and server protocol:

```text
authorize
  -> materialize a bounded immutable browser snapshot
  -> upload songs and complete the library snapshot
  -> upload playlists and entries and complete the playlist snapshot
  -> release in-memory snapshot data
  -> refresh server browse state
```

Only normalized metadata crosses into the Mixtape API. The Music User Token stays inside the browser MusicKit adapter.

## Song-library sync protocol

The current `POST /ingest/library` endpoint is an idempotent chunk upsert. It cannot prove a full snapshot completed, cannot mark removed songs out of the library, and requires a play count that web clients do not possess. Keep it temporarily for the shipped iOS client while introducing a deletion-safe protocol shared by the next iOS and web clients.

```text
POST /ingest/library/syncs
  { source: "ios_native" | "web_musickit", storefront, expectedSongs }
  -> { syncId, expiresAt }

PUT /ingest/library/syncs/:syncId/songs
  { songs[] }                 -- max 500, exactly idempotent

POST /ingest/library/syncs/:syncId/complete
  -> { songs, catalogResolved, playCountsObserved }
```

Normalized song:

```ts
type LibrarySongSnapshot = {
  ordinal: number
  appleLibraryId: string | null
  appleCatalogId: string
  title: string
  artist: string
  album: string | null
  genre: string | null
  releaseYear: number | null
  explicit: boolean | null
  playCount: number | null
  lastPlayedAt: number | null
  dateAdded: number | null
}
```

Rules:

- `playCount: null` means unavailable, never zero.
- A null web play count never overwrites a known native count.
- Completion publishes in one transaction, marks absent prior `user_tracks` rows `in_library = false`, and updates `library_synced_at`.
- Interrupted, cancelled, expired, or count-mismatched runs leave the previous canonical library unchanged.
- One open library run per user; a newer run expires the older one.
- Completed summaries are idempotent.
- Cleanup follows the existing bounded playlist-staging cleanup discipline.

## Playlist sync compatibility

Keep the existing deletion-safe playlist staging protocol and canonical tables. Add a source field to the sync run so diagnostics and capability handling are explicit without branching the browse model.

Before accepting the browser adapter, run counts-only probes across the launch browser matrix to determine whether Apple exposes a distinct stable resource ID for each duplicate playlist occurrence. Android Chrome is launch-critical because those listeners cannot install the native app. If Apple exposes a stable ID, use it unchanged. If it does not, derive a deterministic browser occurrence key from:

```text
playlist library id + track resource type + track library id + duplicate occurrence ordinal
```

That fallback preserves order and duplicates. It does not claim native-strength identity across insertion before an identical duplicate; the source capability records that distinction, and browse correctness remains exact for every completed snapshot.

## Recently played signal

The web can fetch a small ordered recently-played track window but not exact timestamps or lifetime counts. Store it as an observation rather than manufacturing `last_played_at` values:

```text
user_recent_track_observations
  user_id
  track_id
  source = web_musickit
  observed_at
  rank
```

One successful web sync replaces the previous web observation window. This signal may rerank candidates with a bounded recency term; it never rewrites native play counts.

## Web product flow

### First use

```text
Mixtape sign-in
  -> Home explains that Apple Music is separate
  -> Connect Apple Music
  -> Apple authorization
  -> real library + playlist sync
  -> summary
  -> make the first mix
```

### Returning use

- Home and the dedicated Music view show connection and last completed sync.
- A listener can sync again without blocking existing mixes or playlist browse data.
- A failed new sync leaves the previous completed snapshot available.
- Authorization loss asks the listener to reconnect; it does not sign them out of Mixtape.

### Playlist browse

- Desktop: a dedicated `Your music` destination in navigation, with playlist collection and detail in the primary content plane.
- Mobile web: `Your music` is reachable from the persistent top bar without exposing desktop-only navigation.
- Playlist detail is artwork-led, ordered, and honest about unresolved/local entries.
- `Make a mix like this` remains disabled until the playlist-seed server phase ships; browse itself does not fake that behavior.

## Error and privacy posture

- Apple authorization cancelled: fixed user-facing copy; no raw Apple error.
- 401/403 from Apple: clear in-memory authorization and request reconnect.
- 429: bounded retry guidance; do not hammer Apple.
- Offline or background suspension: preserve the previous completed server snapshot and allow a fresh retry.
- Browser snapshot data lives only for the active sync and is released on success, failure, cancellation, sign-out, or replacement by a newer run.
- Never log Music User Tokens, Apple bodies, playlist/track names, prompts, or artwork URLs.

## Verification gates

### Automated

- Server contract, cross-tenant, idempotency, conflict, atomicity, cleanup, and signal-quality tests.
- Web Apple-response normalization fixtures including missing catalog IDs, duplicate playlist tracks, local entries, empty playlists, malformed pages, and non-progressing pagination.
- Web sync-service ordering, progress, cancellation, retry, auth transition, and release tests.
- Component coverage for every approved visual state, mobile breakpoints, reduced motion, dark mode, and large text.

### Real-browser smoke

- Run the full smoke on Android Chrome as a launch-critical target, then cover the supported desktop and mobile browser matrix.
- Authorize Apple Music without exposing the Music User Token.
- Sync counts match Apple Music within documented resource exclusions.
- Create a mix from the new web-only taste graph.
- Play, pause, resume, and recover after authorization expiry.
- Create a playlist and verify its exact order in Apple Music.
- Verify duplicate and empty playlist handling against the device-visible library.

## Open implementation facts

- Exact duplicate playlist-entry identity exposed by Apple Music API across supported browsers.
- Background/lock-screen playback behavior across the supported mobile-browser matrix, including the minimum supported Android Chrome version.
- Whether locally imported library songs expose enough catalog identity to enter the mix candidate pool or remain browse-only unresolved entries.

These facts require a real authorized-device probe. They do not block building the source-aware server contract, the normalized browser adapter, or the approval board.
