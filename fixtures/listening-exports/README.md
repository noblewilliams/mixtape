# Listening-export fixtures

Synthetic Spotify export archives paired with the exact result each parser must
produce. Both parsers, `web/src/import/` (TypeScript) and `client/lib/import/`
(Dart), are tested against every case here and must produce byte-identical
canonical JSON. A parser change that alters an expected file updates the fixture
in the same PR, and both suites must pass.

Every name in these fixtures is invented. Never put real listening data here.

## Layout

```
fixtures/listening-exports/
  README.md                       this contract
  build.mjs                       deterministic builder + reference parser (Node >= 18, no deps)
  verify.test.mjs                 node --test suite for the fixtures themselves
  src/<case>/case.json            the source of a case (entries + options)
  <case>/archive.zip              built: the input archive
  <case>/expected.<option>.json   built: the result for that option
```

`archive.zip` and `expected.*.json` are committed so the parser suites read
them without running the builder. Case directories are prefixed with the
package (`extended-`, `account-`) because both packages have a `basic` case.

A parser test suite iterates `<case>/` directories, opens `archive.zip`, reads
the `options` array of `src/<case>/case.json` (each option's `name`,
`timeZone`, `includePrivateSessions`), runs the parser once per option, and
compares the result with `<case>/expected.<name>.json`. The suites must not use
`entries` from `case.json`; the archive is the input. The only zones the suite
needs are `Africa/Lagos` and `America/Los_Angeles`.

### `case.json`

```jsonc
{
  "package": "spotify_extended" | "spotify_account",   // what the entries classify as
  "entries": [
    { "path": "Spotify Account Data/YourLibrary.json", "json": { ... } },  // JSON, pretty-printed
    { "path": "Spotify Extended Streaming History/Streaming_History_Audio_2025_1.json", "text": "[{" },  // raw bytes
    { "path": "Spotify Account Data/Identity.json", "sentinel": true }  // a file a parser must never open
  ],
  "options": [ { "name": "default", "timeZone": "Africa/Lagos", "includePrivateSessions": false }, ... ]
}
```

Entry paths are relative, forward-slash, no `..`, unique. Every case needs an
option named `default`. A sentinel entry's body is `DO-NOT-READ:<path>\n`
repeated until it is at least 2 048 bytes long; the pii and nested-folder cases
use them for identity, payment, inference, user-data, PDF, and video-history
files. The builder refuses fixture JSON containing a `spotify:track:` or
`spotify:artist:` URI whose tail is not exactly 22 base62 characters, so a typo
cannot silently become an "unresolved" row.

### `archive.zip`

Built by `build.mjs`: entries sorted by path (ordinal, by UTF-16 code unit),
deflate (`zlib.deflateRawSync`, default level), fixed DOS date/time
2026-01-01 00:00:00, no extra fields, no comments, correct CRC-32, a central
directory, and an end-of-central-directory record. Rebuilding twice produces
identical bytes.

## Contract

The parsing rules below are what both parsers implement. `build.mjs` is the
executable form; where the spec's prose left something open, the choice is
listed under "Interpretations" and is pinned by a fixture where noted.

### Entries and packages

- Only entries whose **base name** matches `Streaming_History_Audio_*.json`,
  `YourLibrary.json`, or `Playlist*.json` (case-insensitive, at any depth) may
  be opened. Every other entry is never read: the parser knows its path and its
  byte size (from the central directory) and nothing else.
- Package: `spotify_extended` when any history file is present; otherwise
  `spotify_account` when a library or playlist file is present; a ZIP with
  neither is unreadable. In the extended package, library and playlist files
  are not read and are listed as ignored.
- Files are processed, and listed in the inventory, in path order (ordinal).
  Rows are processed in file order. "First seen" below means this order.
- A file that does not decode as UTF-8 JSON, or whose top level is the wrong
  shape (history: not an array; library or playlist: not an object), makes the
  archive unreadable: the expected file carries `error` and no `snapshot`.
  Missing `tracks`, `artists`, `playlists`, or `items` arrays are treated as
  empty, not as errors.
- Inventory row counts: history file = array length; library file =
  `tracks.length + artists.length`; playlist file = total `items` across its
  `playlists`.

### Extended history

For each row in each history file, in order:

1. Drop the row when `incognito_mode === true`, unless
   `includePrivateSessions` is true. A dropped private row counts toward
   nothing, including `unresolved` and `country`.
2. Drop the row when `spotify_episode_uri` or `audiobook_uri` is non-null
   (podcasts, audiobooks). These are not unresolved.
3. `platformId` is the 22-character tail after `spotify:track:`. When
   `spotify_track_uri` is null (local files), the row is **unresolved**: add 1
   to `unresolved.rows`, and 1 to `unresolved.plays` when
   `ms_played >= 30000`; then stop processing the row.
4. `ts` is an ISO-8601 instant (`YYYY-MM-DDTHH:MM:SSZ`). Convert it to the
   option's IANA zone: local day `YYYY-MM-DD` and local hour 0–23.
5. Classify: a **play** when `ms_played >= 30000`; a **skip** when
   `skipped === true`, or, when the `skipped` key is absent, when
   `reason_end === "fwdbtn"` (a present `skipped: false` beats `fwdbtn`); a
   **complete** when `reason_end === "trackdone"`.
6. Register the track (every kept, resolved row does, even one that yields no
   day row): `title`, `artist`, `album` are the first non-null string values
   of `master_metadata_track_name`, `master_metadata_album_artist_name`,
   `master_metadata_album_album_name`; `durationMs` is the maximum `ms_played`
   over completes, else null.
7. Aggregate per (`platformId`, local day): `plays`, `skips`, `completes`
   counts; `msPlayed` = sum of `ms_played` over **all** kept rows for that
   track-day, including rows under 30 s; `hoursMask` = OR of `1 << localHour`
   over counted plays only (0 when none).
8. Count `conn_country` (non-null string) for `country`.

After all files: emit a day row only when `plays > 0` or `skips > 0`;
`country` = the most common code among kept rows, else null; `ledgerFrom` /
`ledgerTo` = min / max `day` over the emitted day rows, else null. `library`,
`artists`, `playlists` are empty.

**Time zone conversion.** Resolve the zone offset once per UTC hour and cache
it: for the hour start `H = floor(ts / 3600000) * 3600000`, format `H` in the
zone (`Intl.DateTimeFormat` with `timeZone`, `hourCycle: "h23"`,
`formatToParts`, or the platform equivalent) to a wall-clock
`year, month, day, hour, minute, second`, and take
`offset = Date.UTC(wall) - H`. Then `local = ts + offset`; the day and hour are
the UTC date and UTC hour of `local`. This stays correct for half-hour zones
because the offset, not the hour start's wall clock, is cached.

### Account data

- `YourLibrary.json`: `tracks[]` items `{ artist, album, track, uri }` are the
  liked tracks; `artists[]` items `{ name, uri }` are the followed artists
  (`spotifyId` = the tail after `spotify:artist:`; a null uri gives null).
  `albums`, `shows`, `episodes`, `bannedTracks`, and everything else are
  ignored. A liked track whose uri is null is dropped (no library row, not
  unresolved). A followed artist whose name is not a string is dropped.
- `Playlist*.json`: `playlists[]` in file order, files in path order; the
  `ordinal` is the running index across files. `key` = lowercase hex SHA-256
  of the UTF-8 bytes of `name + " " + ordinal` (for example
  `"Late Nights on the Ferry 0"`). `description` is null when absent or empty.
  `lastModifiedAt` = epoch ms of `lastModifiedDate` when it is `YYYY-MM-DD`
  (midnight UTC), else null.
- Entries follow `items` order with `position` from 0. An item is a `track`
  (`trackName`, `artistName`, `albumName`, `trackUri`), a `localTrack`
  (`trackName`, `artistName`, `albumName`), or an `episode` (`episodeName` as
  title, `showName` as artist, album null), checked in that order. `platformId`
  comes from `track.trackUri` only, so local tracks, episodes, and track items
  with a null uri have `platformId: null` and count toward `unresolved.rows`
  (`unresolved.plays` stays 0). `addedAt` = epoch ms of `addedDate`
  (`YYYY-MM-DD`, midnight UTC), else null.
- `tracks` = the union of liked tracks and playlist entries with a `platformId`,
  first naming wins with the library processed first, `durationMs` null.
- `library` = one row per liked track:
  `{ platformId, playCount: null, skipCount: null, lastPlayedAt: null, dateAdded: null, likeRating: null }`.
- `days` is empty; `country`, `ledgerFrom`, `ledgerTo` are null.

### Expected file

```jsonc
{
  "inventory": {
    "package": "spotify_extended" | "spotify_account" | null,
    "read": [ { "path": "...", "rows": 9 } ],          // allow-listed files, path order; rows null when the file failed to decode
    "ignored": [ { "path": "...", "bytes": 2068 } ]    // every other entry, path order; byte size only
  },
  "snapshot": { ... }                                  // or, for an unreadable archive:
  "error": { "code": "unreadable", "file": "Streaming_History_Audio_2025-2026_1.json" }  // base name of the first broken file
}
```

Snapshot key order, exactly: `source` (`"spotify_export"`), `package`,
`timeZone`, `country`, `tracks`, `days`, `library`, `artists`, `playlists`,
`unresolved`, `ledgerFrom`, `ledgerTo`.

Canonical order: `tracks` by `platformId`; `days` by `platformId` then `day`;
`library` by `platformId`; `artists` by `name` (ties by `spotifyId`, null
last); `playlists` by `ordinal`; `entries` by `position`. String comparison is
ordinal (JS `<`, Dart `compareTo`).

Row key orders:

| Row | Keys |
|---|---|
| track | `platformId, title, artist, album, durationMs` |
| day | `platformId, day, plays, skips, completes, msPlayed, hoursMask` |
| library | `platformId, playCount, skipCount, lastPlayedAt, dateAdded, likeRating` |
| artist | `name, spotifyId` |
| playlist | `ordinal, key, name, description, lastModifiedAt, entries` |
| entry | `position, platformId, title, artist, album, addedAt` |
| unresolved | `rows, plays` |

Pretty-printed with two spaces and a trailing newline. A parser suite compares
its canonical JSON with the file's `snapshot` (and its inventory with
`inventory`), so serialize with the same key order.

### Interpretations

Choices made where the spec's prose left room. Pinned ones have a fixture that
fails if a parser chooses differently.

1. Private rows are filtered first, so a private local-file row is not counted
   as unresolved unless private sessions are included. Pinned:
   `extended-private-sessions`.
2. A track seen only in rows under 30 s that were not skipped still appears in
   `tracks` (with `durationMs` null) and has no day row. Pinned:
   `extended-podcasts-and-local` (Slow Orbit).
3. `ledgerFrom` / `ledgerTo` span the emitted day rows, not every kept row.
   Pinned: `extended-basic` (a 5 s row on 2026-03-01 does not extend the
   ledger).
4. "First non-null seen" is the first JSON string value in file-then-row order;
   an empty string is a value. Pinned for order: `extended-basic` (a later
   remastered title does not replace the first). `title` and `artist` fall back
   to `""` when never seen; `album` stays null. Not pinned.
5. `skipped: null` counts as absent (so `fwdbtn` decides). Not pinned.
6. A `spotify_track_uri` that is a string but not `spotify:track:` plus 22
   base62 characters is treated like null (unresolved). Not pinned; the builder
   refuses such fixtures.
7. A row whose `ts` does not parse is dropped, after step 3. Not pinned.
8. Missing or non-numeric `ms_played` counts as 0. Not pinned.
9. `country` ties go to the smallest code by ordinal comparison. Not pinned.
10. For an unreadable archive the inventory still lists every allow-listed
    file, the broken one with `rows: null`, and `error.file` is the base name
    of the first broken file in path order. Pinned: `extended-malformed`. A
    ZIP with no allow-listed file has `package: null` and `file: null`. Not
    pinned.
11. Playlist files are ordered by full path, ordinal: `Playlist10.json` sorts
    before `Playlist2.json`. The ordinal runs on across files. Pinned for the
    running ordinal: `account-empty-playlist`.
12. Playlist `name` that is not a string becomes `""` (and hashes as
    `" 0"`). Entry `title` / `artist` fall back to `""`. Not pinned.
13. Only `YYYY-MM-DD` dates convert; any other `lastModifiedDate` /
    `addedDate` gives null. Not pinned.
14. In the extended package a library file travelling with the history is
    ignored, not read. Pinned: `extended-nested-folder`.

## Cases

| Case | Package | Pins |
|---|---|---|
| `extended-basic` | extended | 3 ids over 2 files (2024–2026), one recording under two ids, plays either side of 30 s, `skipped` true/false in one file and absent (`fwdbtn`) in the other, `trackdone` completes and derived duration, several hours in one day, msPlayed including sub-30 s rows, a day row with 0 plays and 1 skip, the Lagos midnight boundary, first-seen naming, ledger over emitted days |
| `extended-podcasts-and-local` | extended | episode and audiobook rows dropped silently, URI-less rows counted as unresolved (rows and plays), a track with no day row |
| `extended-private-sessions` | extended | `default` excludes `incognito_mode` rows; `private-included` keeps them (country, duration, an extra track and day, an unresolved private row) |
| `extended-various-artists` | extended | compilation and soundtrack rows carry the album artist "Various Artists" unchanged |
| `extended-timezone` | extended | plays at 23:30 and 00:30 UTC on consecutive days in summer and winter, plus a pair across the Los Angeles spring-forward; `default` (Africa/Lagos) and `los-angeles` (America/Los_Angeles) |
| `extended-nested-folder` | extended | files two directories deep, a PDF and a video-history sentinel, a library file ignored in the extended package |
| `extended-malformed` | extended | one valid file and one truncated file: unreadable, inventory only |
| `account-basic` | account | 4 liked tracks, 2 followed artists, albums/shows/episodes ignored, 2 playlists with descriptions (one empty) and dates, a `StreamingHistory_music_0.json` sentinel |
| `account-empty-playlist` | account | playlist files only, an empty playlist, ordinal continuing into `Playlist2.json` |
| `account-duplicates` | account | one track twice in a playlist, in two playlists, and liked with different album naming (library naming wins in `tracks`) |
| `account-local-and-episode-entries` | account | episode, local-track, and URI-less track items as name-only entries with positions preserved |
| `account-liked-absent-from-history` | account | a library file alone: liked tracks land in `tracks` and `library` with null counts, no artists, no playlists |
| `account-pii-present` | account | `Identity.json`, `Inferences.json`, `Payments.json`, `Userdata.json` sentinels beside a valid library and playlist file; listed as ignored with byte sizes only |

## Adding a case

1. Create `src/<package>-<name>/case.json` (lowercase, digits, hyphens). Invent
   every name; ids are 22 base62 characters (the existing ones are a label
   padded with digits so they read as what they are).
2. `node fixtures/listening-exports/build.mjs` writes `<case>/archive.zip` and
   `<case>/expected.<option>.json`.
3. Read the expected file and check it by hand against the rules above. The
   reference implementation is the contract's executable form, not its proof.
4. `node --test fixtures/listening-exports/verify.test.mjs`, then run both
   parser suites.
5. Commit `src/<case>/case.json` and the built files together, and add the case
   to the table above.

## Rebuilding and checking

```
node fixtures/listening-exports/build.mjs            # rebuild every case
node fixtures/listening-exports/build.mjs --check    # rebuild to memory; exit 1 on any missing, differing, or stale file
node --test fixtures/listening-exports/verify.test.mjs
```

`--check` runs in the verify test, so CI fails when `case.json` and the built
files drift apart. Deflate output depends on the zlib Node bundles; if a Node
upgrade ever changes it, `--check` fails on every archive and a rebuild is the
fix (the expected files will not change).

## Layout assumption

To verify against the founder's real exports before B1 and C1 close:

- Extended history: `Spotify Extended Streaming History/Streaming_History_Audio_<years>_<n>.json`,
  alongside `Streaming_History_Video_*.json` and a `ReadMeFirst_*.pdf`.
- Account data: `Spotify Account Data/YourLibrary.json` and
  `Spotify Account Data/Playlist1.json` (more `Playlist<n>.json` for large
  accounts), alongside `StreamingHistory_music_<n>.json`, `Identity.json`,
  `Userdata.json`, `Payments.json`, `Inferences.json`, and others.
- The archive may wrap these in one more directory (`my_spotify_data/...`).
  Parsers match by base name at any depth, case-insensitive, and never depend
  on the directory names.
- Record shapes to confirm: the history record fields used above; the library
  `tracks[]` / `artists[]` item fields; the playlist `items[]` fields, in
  particular the `localTrack` and `episode` shapes, which are modelled here as
  `{ trackName, artistName, albumName, uri }` and
  `{ episodeName, showName, episodeUri }`.

If the real layout differs, update the affected `case.json` files, rebuild, and
adjust this section in the same PR.

## Not pinned by fixtures

Guidance for real archives that no fixture exercises:

- Directory entries (paths ending in `/`) are not files: skip them entirely,
  including in the inventory.
- `__MACOSX/` resource forks (`._YourLibrary.json`) do not match the allow-list
  because the match is anchored on the whole base name.
- Nested ZIPs and split archives are outside this suite; the spec covers them.
