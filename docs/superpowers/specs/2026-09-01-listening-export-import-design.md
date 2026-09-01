# Listening-export import — design

*Status: draft for founder review · 2026-09-01 · revision 3 (both Spotify packages; playlists, likes, followed artists)*
*Companion docs: [vision](../../product/vision.md) · [web sync and consumption](2026-09-01-web-sync-consumption-design.md) · [decisions](../../decisions.md) · [backlog](../../backlog.md)*

## Product decision

Listeners can hand Mixtape the listening history their streaming service already lets them download. One importer, two adapters:

- **Spotify** — the only Mixtape path for Spotify listeners. Mixtape never talks to Spotify's API. The listener requests two packages from Spotify's privacy page, *Account data* and *Extended streaming history*, receives each as a ZIP by email, and gives them to Mixtape in the iOS app or on the web. Either package alone yields a usable import; together they are the full picture.
- **Apple Music** — an optional "go deeper" step for Apple listeners. The iOS app's live sync stays the primary Apple path. The export adds what live sync cannot see: a day-by-day ledger, skips, and like ratings. For an Apple listener on the web it also supplies the play counts the web API withholds.

Parsing happens on the listener's device. The archive and its personal-data files never reach Mixtape. Only normalized listening data crosses the API, and only the fields this spec names.

**Surfaces.** The Spotify import ships on both the iOS app and the web, built from one snapshot contract and one fixture suite. Whichever is ready ships first and neither waits on the other. The phone is the natural home for it: the email lands there, the archive is small, and the DJ interview and reminder live in the app. The web carries the desktop-only affordances: pasting songs in, copying a playlist out, and the embed player. The Apple "go deeper" adapter is web-first, because its archive handling is the one part that is expensive to build twice.

**Continuity.** An export is backfill. The intended live feed is a scrobble relay (ListenBrainz or Last.fm), which receives a Spotify listener's plays within minutes and exposes them through an open API. This delivery probes the relay; if it holds, it gets its own short spec.

This does not reopen the 2026-08-29 "Apple Music first; Spotify deferred" decision. That decision was about the Web API, and the API is more closed today than when it was written.

Playback inside Spotify is addressed only as far as what needs no API.

## Immediate actions

- Request both exports today from the founder's own accounts. Apple takes up to 7 days and Spotify up to 30; the fixtures and the parser field names depend on real files.
- If no Spotify account with real history is available, a friend's export is the fallback. They run the parser locally and hand over the snapshot JSON, never the raw ZIP, so their IP addresses never leave their machine.

## Platform facts (verified 2026-09-01)

**Spotify Web API.** February 2026 Development Mode changes: 5 authorized users per app, developer must hold Premium, batch `GET /tracks` removed. Extended access requires a registered business with 250k+ monthly actives. The vision doc's "~25 users" figure is stale; correct it on approval.

**Spotify export.** Three packages on the Account Privacy page. We ask for two.

| Package | We read | We ignore | Delivery |
|---|---|---|---|
| Extended streaming history | `Streaming_History_Audio_*.json`: every play since sign-up with track URI, names, ms played, skipped flag, start/end reason, shuffle, offline, private-session flag | Video and podcast history files | Usually 1–5 days, officially up to 30 |
| Account data | `YourLibrary.json` (liked tracks and followed artists, with URIs) and `Playlist*.json` (own playlists with order, added dates, and track URIs) | `StreamingHistory_*` (12 months, no URIs, a subset of the extended history), identity, user data, payments, inferences, search queries, follow, and every other file | Usually days, officially up to 5 |
| Technical log | Nothing | Everything | Not requested |

The two packages arrive separately and are imported in either order. Account data usually lands first and already gives a personal mix through library and playlist membership; the extended history then upgrades familiarity to observed play counts. The history's artist field is the **album** artist, so compilations and soundtracks arrive as "Various Artists"; enrichment corrects this (see Enrichment).

Expected account-data shapes, to be confirmed against a real export:

```jsonc
// YourLibrary.json
{ "tracks": [{ "artist": "The Weeknd", "album": "After Hours", "track": "Blinding Lights", "uri": "spotify:track:…" }],
  "artists": [{ "name": "…", "uri": "spotify:artist:…" }], "albums": [], "shows": [], "episodes": [] }

// Playlist1.json
{ "playlists": [{ "name": "Late nights", "lastModifiedDate": "2026-08-01", "description": null,
  "items": [{ "track": { "trackName": "…", "artistName": "…", "albumName": "…", "trackUri": "spotify:track:…" },
              "episode": null, "localTrack": null, "addedDate": "2025-11-02" }] }] }
```

Expected extended-history record, to be confirmed against a real export before the parser is written:

```jsonc
{ "ts": "2024-03-02T21:14:07Z", "platform": "android", "ms_played": 200040,
  "conn_country": "NG", "ip_addr": "…",
  "master_metadata_track_name": "Blinding Lights",
  "master_metadata_album_artist_name": "The Weeknd",
  "master_metadata_album_album_name": "After Hours",
  "spotify_track_uri": "spotify:track:0VjIjW4GlUZAMYd2vXMi3b",
  "episode_name": null, "episode_show_name": null, "spotify_episode_uri": null,
  "reason_start": "clickrow", "reason_end": "trackdone",
  "shuffle": false, "skipped": false, "offline": false, "incognito_mode": false }
```

**Apple export.** At privacy.apple.com, "Request a copy of your data" → "Apple Media Services information". Up to 7 days, usually less. Apple emails when ready; the download comes from the same page and stays available 14 days. It may be split into parts and nests the real archive as `Apple_Media_Services.zip`. Apple Music files live under `Apple Music Activity/`. The whole archive can approach a gigabyte because Play Activity is inside it. One open request per data type at a time.

| File | We read | Keyed by |
|---|---|---|
| `Apple Music - Play History Daily Tracks.csv` | Yes: one row per track per day with play count, play duration, "Artist - Title" description; community parsers also report `Track Identifier`, `Skip Count`, `Hours`, `End Reason Type` | Catalog id when present, else description |
| `Apple Music Library Tracks.json` | Yes: `Apple Music Track Identifier`, `Track Play Count`, `Skip Count`, `Last Played Date`, `Date Added To Library`, `Track Duration`, `Track Like Rating` | Catalog id |
| `Apple Music Play Activity.csv` | No. 2026 exports have no artist column and no track id, and it carries IP coordinates, Apple ID number, and device ids | — |
| Likes and Dislikes, Recently Played, Library Playlists, Library Activity | No, in this delivery | — |

**Enrichment.** ReccoBeats accepts raw Spotify track ids on its track and audio-features endpoints and returns credited artists, ISRC, duration, and the full feature set (probed live with `0VjIjW4GlUZAMYd2vXMi3b`). Spotify's public oEmbed returns a thumbnail per track without authentication. Apple's catalog API accepts `filter[isrc]` with a developer token, and the Worker already calls that API for artwork. Deezer's public API resolves artist + title to ISRC, duration, and cover.

**Scrobble relays.** ListenBrainz and Last.fm both connect to a Spotify account on their own side and receive every play within minutes. ListenBrainz data is open (CC0) and its API is free; Last.fm's API terms are non-commercial by default. Neither carries Spotify ids; tracks resolve by name.

**Playback without an API.** Spotify's iFrame API loads from `open.spotify.com/embed/iframe-api/v1` with no registration and exposes load, play, pause, seek, and a `playback_update` event with position and duration. Full tracks play when the listener is logged in to Spotify in that browser, previews otherwise; the iframe must keep `allow="encrypted-media"`. Spotify desktop accepts pasted track links into a playlist and copies selected tracks as links. Anything that controls the Spotify app itself needs a Client ID and is capped at 5 users.

## Scope

### Included

- Guided data-request flows for Spotify and Apple, with all the steps the listener needs.
- Spotify liked tracks, followed artists, and own playlists from the Account data package, published through the existing playlist tables.
- A waiting state that gathers taste context, an iOS local reminder, and a labeled corpus mix gated on enough seeds.
- iOS and web parsers that read only the named files and emit one shared snapshot contract.
- A staged, idempotent import protocol; a day-granularity listening ledger; derived play counts, recent counts, recency, skips, and completion.
- A play-derived candidate rule and ISRC-level dedupe so the pool works for listeners who stream without saving and never shows one recording twice.
- Enrichment ordered by pool relevance; ReccoBeats-by-id for Spotify rows with artist correction; ISRC-driven Apple catalog cross-link and artwork.
- Funnel instrumentation from "I use Spotify" to first output.
- A diagnostics report for unreadable exports that carries no content.
- API-free outputs: per-track links, copy-for-desktop, transfer-tool handoff, and an embed-player probe.
- A scrobble-relay probe.

### Excluded

- Any Spotify Web API call, including client-credentials metadata lookups.
- Every file in either archive other than the ones named above, including Spotify's 12-month streaming history and Apple's Play Activity.
- Per-play event storage. The ledger is per track per day (reopen clause below).
- Merging duplicate `tracks` rows. Rows link by ISRC and the pool dedupes on it; a physical merge is a later task.
- Name-only rows that cannot be resolved inside the export. Counted and reported, not ingested.
- Relay ingestion beyond the probe. Playing a whole mix inside the Spotify app. Creating a Spotify playlist directly.

## Capability model

Extends the table in the web sync and consumption spec. Missing is still not zero.

| Signal | iOS live sync | Web MusicKit | Spotify export | Apple export |
|---|---|---|---|---|
| Library membership | Yes | Yes | Yes, liked tracks | Yes |
| Playlists with order and added dates | Yes | Yes | Yes | No |
| Followed artists | No | No | Yes | No |
| Exact play count | Yes | No | Yes, derived | Yes |
| Last-played per track | Sometimes | No | Yes | Yes |
| Skips | No | No | Yes | Yes |
| Completion | No | No | Yes | Only if Daily Tracks carries end reason |
| Per-day ledger | Only by diffing snapshots | No | Lifetime | Lifetime |
| Hour-of-day | No | No | Yes | Only if Daily Tracks carries `Hours` |
| Like / dislike | No | No | No | Library songs |
| Duration | Yes | Yes | Derived from complete plays, else ReccoBeats | Yes |
| Artwork | Apple catalog | Apple catalog | Apple catalog via ISRC, else oEmbed | Apple catalog |
| Playback | System player | MusicKit on the Web | Links, embed where it works | Existing |

Export rows with ledger data enter `user_tracks` with `play_count_observed = true`, so the familiarity term takes the native branch with no scoring change. An account-data-only import leaves `play_count_observed = false`, and familiarity falls back to playlist membership exactly as it does for web MusicKit listeners.

## Product flow

### Choosing a service

```text
sign in -> "Which do you use?"
  Apple   -> iOS: live sync (existing). Web: MusicKit sync (existing).
             Music view offers "Go deeper: import your Apple Music history".
  Spotify -> request flow below
```

A listener can hold more than one source. Connected sources are a set (see Schema), never a single platform value.

### Spotify request flow

The steps below are the in-app copy, shown on one screen and kept visible in the waiting state. Each address is a tappable link.

1. Open **spotify.com/account/privacy** and log in with the account that has your listening history. A laptop is easier than a phone for this part.
2. Scroll to **Download your data**.
3. Select **Account data** and **Extended streaming history**. Leave *Technical log information* unselected.
4. Press **Request data**.
5. Check your email. Spotify sends a **confirmation** message first. Open it and press **Confirm**. Nothing is prepared until you do, and this is the step most people miss.
6. Wait. The two packages arrive as separate emails, each with a **Download** button, usually within days; the extended history can take up to 30. Each link expires after about two weeks, so download it when you see it.
7. Save the ZIPs as they are. Don't unzip them.
8. Come back to Mixtape and give it each ZIP as it arrives. You don't have to wait for both.

On iOS the last step is: tap the download link in Mail, Safari saves the ZIP to Files, then share it to Mixtape or pick it from inside the app. On the web, drop the file on the import page.

Mixtape sends no email in this delivery; Spotify's two emails are the triggers. The screen shows what each email looks like and lets the listener mark **I've requested it**, which shows the elapsed wait and, on iOS, schedules a local notification three days later saying to check the inbox and confirm the request if they have not yet.

### Apple "go deeper" flow

Offered, never required, from the Music view for Apple listeners. The steps below are the in-app copy, with each address a tappable link.

1. Open **privacy.apple.com** and sign in with the Apple Account you use for Apple Music. Two-factor is required. A laptop is easier than a phone for this part.
2. Under **Get a copy of your data**, choose **Request a copy of your data**.
3. Tick **Apple Media Services information** only. Its description also mentions the App Store, iTunes, Apple Books, and Podcasts; that is normal, it is one bundle. Leave everything else unticked.
4. Press **Continue**, then choose the **largest maximum file size** offered so the export arrives as one file instead of several parts.
5. Press **Complete request**. Apple says up to 7 days, usually less.
6. When the "Your data is ready" email arrives, return to **privacy.apple.com**, sign in, open **Data and Privacy**, and download. It stays available for 14 days.
7. Save the ZIP as it is. On a Mac, Safari may unzip it automatically; that is fine, Mixtape accepts the unzipped folder too.
8. Come back to Mixtape and give it the ZIP or the folder.

Apple allows one open request per data type at a time. If nothing has arrived after a week, the screen links back to the same page to check status rather than suggesting a second request. If Mixtape reports the archive is too large to read on this device, the fallback instruction is to unzip it once and pick the *Apple Music Activity* folder.

The screen says plainly what this adds for the listener: day-by-day history, skips, and likes for iOS listeners; real play counts as well for web listeners. It also lets the listener mark **I've requested it** for the elapsed wait and the iOS reminder.

### Before the data arrives

The waiting state has two jobs: keep the listener coming back, and collect taste signal that is useful now and still useful after the import. In order:

1. **DJ interview (required before any mix).** Five short turns: artists you would never skip; what you play most these days; when you listen and to what; anything you never want to hear; an era you keep returning to. Answers are stored as DJ memories (existing table, 50-note cap leaves room) and named artists as `user_artist_seeds`.
2. **Paste songs (desktop web).** Selecting tracks in Spotify desktop and copying puts one link per line on the clipboard. Pasting into Mixtape yields exact Spotify ids; ReccoBeats resolves them. Rows become `user_tracks` with `seeded = true`.
3. **A "not personal yet" mix.** Unlocked only after the interview, and only when the seeds match at least 25 enriched corpus tracks across at least 3 artists. Below that the DJ says it does not know enough yet and points back to the interview or paste. When unlocked, the session and queue carry a prominent label.
4. **Demo tape.** The existing demo sessions, to learn the refine loop.

Seeds and memories survive the import as explicit taste. Observed plays win where they conflict.

Corpus mode for the pool: when the listener has no ledger and no synced library, candidates are all tracks with a meaning or feature row; the familiarity term is 1.0 for seeded rows, 0.7 for rows whose artist matches a seed, else 0; the session carries `not_personal = true` for the UI banner. Everything else in the scoring formula is unchanged.

### Import

```text
pick a ZIP -> inventory (package detected, files found, tracks, playlists,
              days covered, time zone used, private-session toggle for Spotify)
  -> upload with progress -> summary -> first personal mix
```

Spotify listeners import each package as it arrives, in either order, and a package can be re-imported without touching the other's data. Re-import is the refresh. It is idempotent: day rows are replaced, derived counts recompute, and the summary matches the previous run when the archive is unchanged.

### Outputs for Spotify listeners

| Output | iOS | Web | Notes |
|---|---|---|---|
| Open in Spotify, per track | Yes | Yes | Deep link from `spotify_id`; opens the Spotify app on the phone |
| Send to a transfer tool | Yes | Yes | Text handoff to TuneMyMusic or Soundiiz, which create the playlist |
| Copy for Spotify | — | Desktop | One track link per line; paste into a new playlist in Spotify desktop |
| Embed player | Probe | Desktop first | Chained through the iFrame API; ships only if the probe holds |
| 30-second previews | Yes | Yes | Deezer or iTunes previews to vet a mix before exporting it |

Embed-player probe, before any UI is built: can `play()` follow `loadUri()` without a fresh user gesture; does playback continue on Android Chrome with the screen off; what does a free account hear; does a WKWebView on iOS keep playing in the background; do Spotify's embed terms tolerate a chained player. Keep Spotify's branding intact in any case. Founder-only dev mode with 5 accounts is for dogfooding real playback, not a product path.

### Funnel

Every step records a typed event so the next investment is decided on numbers, not guesses:

```text
chose_spotify -> marked_requested -> interview_completed -> file_inspected
  -> import_completed -> first_personal_mix -> first_output
```

Events carry user, surface, and time only. A script reports conversion between steps and median days from `marked_requested` to `import_completed`.

## Client parsers

Two implementations, one contract. `web/src/import/` in TypeScript and `client/lib/import/` in Dart. Both are tested against the same fixtures in a top-level `fixtures/listening-exports/` directory: synthetic archives (no real listening data) paired with the exact snapshot each must produce. A parser change that alters a fixture's expected output updates the fixture in the same PR, and both parsers must pass.

```ts
type ListeningExportImporter = {
  inspect(file: File, options: { signal: AbortSignal }): Promise<ListeningExportInventory>
  parse(file: File, options: {
    signal: AbortSignal
    timeZone: string                 // IANA zone from the device
    includePrivateSessions: boolean  // Spotify only
    onProgress: (progress: ImportProgress) => void
  }): Promise<ListeningExportSnapshot>
  diagnostics(file: File): Promise<ExportDiagnostics>  // file names, headers, row counts; no content
}
```

Shared rules:

- Open the archive on the device by reading its central directory and decompress only the named entries. Never load the whole archive into memory; Apple's can approach a gigabyte. Unwrap nested ZIPs up to 5 levels and merge multiple parts. If a nested archive is deflated and too large to inflate on the device, fail closed with the "unzip once and pick the folder" guidance. An already-unzipped folder is accepted as input too, with the same file-name matching.
- Process one file at a time and release it before the next. Stream CSVs line by line; Daily Tracks alone can be tens of megabytes.
- Aggregate plays into `(track, local day)` rows on the device. Local day and hour come from the device's time zone, shown at the inventory step and recorded on the run as an assumption about the listener's history.
- On any unrecognized layout, fail closed and offer the diagnostics report. It lists file names, column headers, and row counts, and the listener chooses whether to send it.
- Emit the snapshot below. Nothing else crosses the API.

Spotify rules:

- Drop rows with an episode or audiobook URI, and rows with no track URI (local files). Count the latter as unresolved.
- Drop `ip_addr`, `platform`, `user_agent`, `offline_timestamp`, `username`. Keep `conn_country` only as its most common value.
- Drop rows with `incognito_mode = true` unless the listener opted in.
- A play counts when `ms_played >= 30_000`. A skip is `skipped = true`, or `reason_end = "fwdbtn"` when the flag is absent. A complete is `reason_end = "trackdone"`.
- Derived duration per track: the maximum `ms_played` over completes.
- Account data: read `YourLibrary.json` and `Playlist*.json` only. Liked tracks and followed artists come from the library file. Each playlist gets a fingerprint key, `sha256(name + ordinal)`, because the file carries no playlist URI; entries keep their order and `addedDate`, and entries with no track URI (local files, episodes) stay as name-only snapshots so order is preserved, as the Apple playlist sync does for unresolved entries. Ignore `StreamingHistory_*`, albums, shows, episodes, and everything else. The snapshot's `tracks` list is the union of tracks seen in any file, so likes and playlists link even when no history has been imported yet.

Apple rules:

- Read Daily Tracks and Library Tracks only.
- Library Tracks rows carry the catalog id directly. Daily Tracks rows resolve to a catalog id by `Track Identifier` when present and valid, else by normalized "Artist - Title" match against Library Tracks, else unresolved and counted. The split is a heuristic; the summary shows the unresolved share.
- Plays, skips, and play duration come from the row's own counts. `Hours` and `End Reason Type` are used only when present.
- Like rating maps to -1, 0, 1.

iOS specifics:

- Declare the ZIP document type in `Info.plist` so Files and the share sheet can hand an archive to Mixtape, and use the document picker in-app.
- Any new Swift file needs pbxproj target membership (recurring lesson, see CLAUDE.md).
- The Spotify archive is tens of megabytes and parses comfortably on a phone. The Apple archive is the reason the Apple adapter is web-first.

Snapshot contract:

```ts
type ListeningExportSnapshot = {
  source: 'spotify_export' | 'apple_export'
  timeZone: string
  country: string | null
  tracks: { platformId: string; title: string; artist: string; album: string | null; durationMs: number | null }[]
  days: { platformId: string; day: string /* YYYY-MM-DD */; plays: number; skips: number | null; completes: number | null; msPlayed: number; hoursMask: number | null }[]
  library: { platformId: string; playCount: number | null; skipCount: number | null; lastPlayedAt: number | null; dateAdded: number | null; likeRating: -1 | 0 | 1 | null }[]  // Apple only
  likedTrackIds: string[]                                   // Spotify account data
  followedArtists: { name: string; spotifyId: string }[]     // Spotify account data
  playlists: {                                               // Spotify account data
    ordinal: number; key: string; name: string; description: string | null; lastModifiedAt: number | null
    entries: { position: number; platformId: string | null; title: string; artist: string; album: string | null; addedAt: number | null }[]
  }[]
  unresolved: { rows: number; plays: number }
  ledgerFrom: string | null
  ledgerTo: string | null
}

type ExportDiagnostics = {
  source: 'spotify_export' | 'apple_export' | 'unknown'
  files: { path: string; bytes: number; rows: number | null; headers: string[] | null }[]
  parserVersion: string
}
```

`platformId` is a 22-character base62 Spotify id or an Apple catalog id validated by `isAppleSongId`.

## Import protocol

Same staging discipline as the library sync store: begin with expected counts, idempotent chunk puts, one-transaction complete, count verification, bounded expiry and cleanup, one open run per user and source.

```text
POST /ingest/listening/imports
  { source, package: 'spotify_account' | 'spotify_extended' | 'apple_media', timeZone, country,
    expectedTracks, expectedDays, expectedLibraryTracks, expectedArtists }
  -> { importId, expiresAt }

PUT /ingest/listening/imports/:importId/tracks    { tracks[] }   -- max 500
PUT /ingest/listening/imports/:importId/days      { days[] }     -- max 2000
PUT /ingest/listening/imports/:importId/library   { tracks[] }   -- max 500, Apple library rows or Spotify liked tracks
PUT /ingest/listening/imports/:importId/artists   { artists[] }  -- max 500, Spotify followed artists

POST /ingest/listening/imports/:importId/complete
  -> { tracks, days, libraryTracks, unresolvedRows, unresolvedPlays, ledgerFrom, ledgerTo }
```

Complete, in one transaction:

1. Upsert `tracks` on `spotify_id` or `apple_id`. Export title and artist win on insert; on an existing row, artist is kept if enrichment has already corrected it (see Enrichment); album and duration coalesce.
2. Upsert `listening_days` on `(user_id, source, track_id, day)`, replacing values. Delete this source's day rows for tracks in the run that the run no longer covers.
3. Recompute `user_tracks` for every track in the run: `play_count` = lifetime counted plays across sources, merged with `greatest()` against native counts as today; `play_count_recent` = counted plays in the last 730 days; `play_count_observed = true` when any ledger row exists for the track, else unchanged; `last_played_at` = latest day; `skip_count` from the ledger or the Apple library row; `like_rating` from the Apple library row. Apple library rows and Spotify liked tracks set `in_library = true` (and `date_added` when known). A re-import of the Spotify account package marks liked tracks no longer present `in_library = false`, mirroring library-sync removal. Followed artists upsert into `user_artist_seeds` with source `spotify_export`.
4. Upsert `user_music_sources` for this source with `last_imported_at`, `ledger_from`, `ledger_to`, and update `country` and `time_zone` on the profile.
5. Queue enrichment for the run's tracks in pool order (see Enrichment).

Playlists from the Spotify account package go through the existing playlist sync protocol with `source = 'spotify_export'`, started by the client after the listening import completes so entries link to the tracks it created. The playlist key is the opaque library id and `key:position` the entry id; entry snapshots gain `spotifyId` alongside `appleCatalogId`, and the store links entries by `spotify_id` for that source. Imported playlists are `kind = 'user'`, `canEdit = false`. The Apple-flavored column names are a naming debt for the backlog, not a blocker.

Interrupted, expired, or count-mismatched runs leave canonical state untouched.

## Schema

- `tracks.spotify_id text`, partial unique index where not null. Peer of `apple_id`. `tracks.artist_source` (`export` | `reccobeats` | `apple_catalog` | `sync`) so a corrected artist is never overwritten by a later export.
- `listening_days`: `user_id`, `source` (`spotify_export` | `apple_export`, with room for `apple_snapshot_diff` and relay sources), `track_id`, `day date`, `plays`, `skips` nullable, `completes` nullable, `ms_played`, `hours_mask` nullable 24-bit. Primary key `(user_id, source, track_id, day)`; index `(user_id, day)`.
- `user_tracks`: add `play_count_recent`, `skip_count` nullable, `like_rating` nullable, `seeded boolean default false`.
- `user_artist_seeds`: `user_id`, `name`, `spotify_id` nullable, `source` (`interview` | `pasted` | `spotify_export`), `created_at`. Unique `(user_id, name)`.
- Playlist tables: the existing `user_playlists`, `playlist_entries`, and their staging tables, with `source` gaining `spotify_export` and entries gaining `spotify_id`.
- `user_music_sources`: `user_id`, `source` (`apple_live` | `apple_export` | `spotify_export`, later relay values), `connected_at`, `last_imported_at`, `ledger_from`, `ledger_to`. Primary key `(user_id, source)`. Replaces the idea of a single platform column.
- `user_music_profiles`: add `country`, `time_zone`; make `apple_storefront` nullable.
- `dj_sessions.not_personal boolean default false`.
- `funnel_events`: `user_id`, `type`, `surface` (`ios` | `web`), `created_at`. Index `(type, created_at)`.
- Staging: `listening_import_runs`, `listening_import_tracks`, `listening_import_days`, `listening_import_library`.
- `user_recent_track_observations` is untouched; export recency comes from the ledger.

Reopen clause on day granularity: store per-play events only when a feature needs play order or exact timestamps (for example sequencing analysis). The parsers already see the events, so this is an additive contract change.

## Pool

Two changes, both implemented as CTEs so a 20k-row `user_tracks` scan stays cheap.

**Candidate rule** for every user:

```sql
recent_plays AS (
  SELECT track_id
  FROM listening_days
  WHERE user_id = $user AND day >= CURRENT_DATE - INTERVAL '730 days'
  GROUP BY track_id
  HAVING SUM(plays) >= 3
)
-- candidate when ut.in_library OR ut.seeded OR ut.track_id IN recent_plays
```

Three counted plays within the last two years is the founder's threshold. Computed live, so the window drifts with time and needs no recompute job. Accepted edge: an Apple listener's removed library song that still had three plays in the window re-enters the pool; session removals still penalize it.

**Recording dedupe.** Spotify relinks tracks across re-releases and regions, and Apple reissues catalog ids, so one recording can hold several `tracks` rows in a lifetime history. Rows group on `COALESCE(t.isrc, t.id::text)`: familiarity uses the summed play count across the group, and only the best-scoring row of each group survives into the pool, preferring a row with an `apple_id` for Apple listeners and a `spotify_id` for Spotify listeners.

No scoring change beyond that in this delivery. Skip rate, completion, like rating, and `play_count_recent` are computed but enter the score only with evidence, per the P4 tuning rule. The lifetime-versus-recent familiarity question is the first thing that tuning pass should look at. The queue UI must render a track with no Apple id: no play control, an "Open in Spotify" link.

## Enrichment

**Ordering.** A lifetime Spotify history can hold 20k unique tracks, and the cron runner would take days to reach them all while the first mixes lean on whichever tracks were enriched first. The import queues its tracks with a priority: pool candidates first, ordered by `play_count_recent` descending, then the rest. The runner drains by priority.

**By-id stage** ahead of the existing ReccoBeats title search, taken only when `spotify_id` is set:

1. ReccoBeats track and audio-features by Spotify id, in batches (limit to be probed; docs indicate 40). Backfill `isrc` and `duration_ms`. Overwrite `tracks.artist` with the credited artists ReccoBeats returns and set `artist_source = 'reccobeats'`, because the export supplied the album artist.
2. With an ISRC, query the Apple catalog through the existing client. If exactly one match and no other row holds that `apple_id`, set it and let artwork, genre, release year, and explicit backfills run unchanged. Otherwise leave `apple_id` null; the ISRC link is enough for the pool's dedupe.
3. Rows with no Apple match get artwork from Spotify oEmbed; the artwork normalizer must accept a fixed URL.
4. LRCLIB and the embedding stage run unchanged. Lyric text still never persists.

Apple export rows already carry a catalog id and need nothing new.

## Error and privacy posture

- No server endpoint accepts a file. The archive never leaves the device.
- The parser fails closed on an unrecognized layout, names the expected files, and offers the content-free diagnostics report.
- The inventory step shows, in plain words, exactly what will be uploaded before upload starts, the time zone used for local days, and the private-session toggle for Spotify.
- Never log track names, artist names, or raw export rows. Counts and categories only.
- Deleting an import is a first-class action per source: it removes that source's ledger rows and recomputes `user_tracks`; rows left with no plays, no library membership, and no seed are deleted. Track rows in the shared corpus stay.
- Third-party lookups carry ids and titles only, never user identity.
- Listening history is personal data. Before the import ships, the privacy policy states what is stored, for how long, and how to delete it, and the iOS build's App Store privacy labels are updated to match.
- Shared accounts produce a blended history. Private sessions catch some of it; the product does not promise more than the data supports.

## Verification gates

### Automated

- Fixture suite in `fixtures/listening-exports/` run by both parsers: Spotify extended history with podcasts, local files, private sessions on and off, missing `skipped` flag, "Various Artists" rows, malformed JSON, nested folders, and a 300 MB synthetic archive with memory assertions; Spotify account data with an empty playlist, a playlist with duplicates, local-file and episode entries, a liked track absent from the history, and a package with the identity and payment files present but never read; Apple with nested `Apple_Media_Services.zip` both stored and deflated, two parts, a synthetic 1 GB archive that must parse without loading the whole file, Daily Tracks with and without `Track Identifier`, description-only rows, and a Library Tracks row with no catalog id.
- Diagnostics report contains no track, artist, or album text for any fixture.
- Server: either Spotify package alone, both in either order, account-only familiarity falling to the playlist branch, liked-track removal on re-import, playlist linking by `spotify_id`; cross-tenant, idempotent re-import producing an identical summary, count mismatch, atomic publish, expiry cleanup, the 30-second play rule, duration derivation, `greatest()` merge against native counts, `play_count_recent` at the 730-day boundary, the candidate CTE, ISRC dedupe choosing the platform-preferred row and summing plays, artist-source protection on re-import, enrichment priority order, delete-import recompute, funnel event recording.
- Enrichment: by-id stage hit, miss, 429, malformed, artist overwrite; Apple ISRC single match, multi match, existing `apple_id` conflict.
- iOS and web: request-flow screens, "I've requested it" with the iOS local notification scheduled, interview gating with the seed-match threshold both above and below, paste parsing, inventory, cancellation mid-file, progress, summary, the "not personal yet" banner, document-picker and share-sheet entry on iOS.

### Real-world smoke

- Import the founder's Spotify export in the iOS app, on desktop Chrome, and on Android Chrome.
- Import the founder's Apple export on the web.
- Ledger date ranges match the exports. Play counts for three known heavy-rotation tracks match a manual count, including one that exists under two Spotify ids.
- Create a mix; pool rows show observed play counts; the top candidates have features and meanings within one cron cycle.
- Re-import the same archives: identical summaries.

## Open implementation facts

- Exact current field names in both exports. The founder's own exports settle this and seed the fixtures.
- Whether Daily Tracks' `Track Identifier` is the catalog id, and how often it is present.
- Whether current `Playlist*.json` files carry playlist URIs; the fingerprint key stands in until they do.
- Whether Apple's nested archive is stored or deflated, which decides whether random access reaches inside it.
- ReccoBeats batch size and rate limits for the id endpoints.
- Which storefront to use for Apple catalog lookups on behalf of a Spotify listener.
- oEmbed behavior from datacenter IPs at batch volume.
- Relay probe: ListenBrainz's Spotify import latency and completeness, its API terms for a commercial app, Last.fm's commercial terms, and how well name-only listens resolve to our tracks.
- All five embed-player probe questions above.

None of these block the schema, the protocol, or the fixture-driven parsers.

## Decisions proposed for `docs/decisions.md` on approval

1. Spotify support ships via the listener's own export, not the Web API. Reopens only if Spotify's API policy changes.
2. Apple export is an optional "go deeper" step; live sync stays the primary Apple path.
3. Export parsing happens on the device; archives and personal-data files never reach Mixtape.
4. The listening ledger is per track per day; per-play rows only when a feature needs them.
5. `spotify_id` joins `apple_id` as a peer identity column; rows for one recording link by ISRC, the pool dedupes on it, and a physical merge is deferred.
6. A play is 30 seconds or more. Pool candidates are library, seeded, or three plays in the last two years.
7. Private-session plays are excluded unless the listener opts in.
8. A mix before any data requires the DJ interview and enough seed matches, and is labeled "not personal yet".
9. iOS and web parsers share one contract and one fixture suite; the Spotify import ships on each surface as soon as it is ready, and the Apple adapter is web-first.
10. An export is backfill; a scrobble relay is the intended live feed, pending the probe.
11. Connected music sources are a set per listener, not a single platform.

## Phasing

1. **Server.** Schema, protocol, derivations, candidate CTE and ISRC dedupe, corpus mode with the seed threshold, seeds and interview storage, funnel events, enrichment priority.
2. **Spotify import, iOS and web in parallel** from the shared fixtures; each ships when ready. Both packages: history into the ledger, likes and followed artists into the taste graph, playlists through the playlist sync. iOS: request flow, interview, local notification, document picker and share sheet, import, deep links, transfer handoff. Web: the same plus paste and copy-for-desktop.
3. **Enrichment.** ReccoBeats-by-id with artist correction, ISRC to Apple cross-link, oEmbed fallback artwork.
4. **Probes.** Scrobble relay and embed player. Each gets its own short spec if it holds.
5. **Apple "go deeper", web first.** The iOS build follows once the random-access archive handling is proven on the web and the funnel shows Apple listeners taking the step.

Gates between phases are read from the funnel: phase 5's iOS build and the embed player's UI both wait for evidence that listeners reach `import_completed` and `first_output`.
