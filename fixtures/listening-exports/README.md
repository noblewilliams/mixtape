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
  build.mjs                       deterministic builder + reference parser + structural checker (Node >= 18, no deps)
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
needs are `Africa/Lagos`, `America/Los_Angeles`, and `America/St_Johns`.

### `case.json`

```jsonc
{
  "package": "spotify_extended" | "spotify_account",   // what the entries classify as
  "entries": [
    { "path": "Spotify Account Data/YourLibrary.json", "json": { ... } },  // JSON, pretty-printed
    { "path": "Spotify Extended Streaming History/Streaming_History_Audio_2025_1.json", "text": "[{" },  // UTF-8 text
    { "path": "Spotify Extended Streaming History/Streaming_History_Audio_2025_2.json", "bytes": "W3sidHMi..." },  // raw bytes, base64 (invalid UTF-8)
    { "path": "Spotify Account Data/Identity.json", "sentinel": true },  // a file a parser must never open
    { "path": "my_spotify_data/", "directory": true },  // a directory entry: no body
    { "path": "...", "json": [ ... ], "dataDescriptor": true }  // sizes and CRC in a trailing data descriptor
  ],
  "options": [ { "name": "default", "timeZone": "Africa/Lagos", "includePrivateSessions": false }, ... ]
}
```

Entry paths are relative, forward-slash, no `..`, unique. A directory entry's
path ends with `/`, and only a directory entry's may; a file entry has exactly
one of `json`, `text`, `bytes`, `sentinel`, and may add `dataDescriptor`. Every
case needs an option named `default`. A sentinel entry's body is
`DO-NOT-READ:<path>\n` repeated until it is at least 2 048 bytes long; the pii
and nested-folder cases use them for identity, payment, inference, user-data,
PDF, video-history, and `__MACOSX` files. The builder refuses fixture JSON
containing a `spotify:track:` or `spotify:artist:` URI whose tail is not exactly
22 base62 characters, so a typo cannot silently become an "unresolved" row.

### `archive.zip`

Built by `build.mjs`: entries sorted by path (ordinal, by UTF-16 code unit),
fixed DOS date/time 2026-01-01 00:00:00, no extra fields, no comments, correct
CRC-32, a central directory, and an end-of-central-directory record. File
entries are deflated (`zlib.deflateRawSync`, default level). Directory entries
are stored with size 0, CRC 0, and the MS-DOS directory attribute (external
attributes `0x10`). An entry with `dataDescriptor: true` has general-purpose
bit 3 set, zeros for CRC and sizes in its local header, and a 16-byte data
descriptor (signature `0x08074b50`, CRC, compressed size, size) after its data;
the central directory carries the real values for every entry. Rebuilding twice
on one machine produces identical bytes; across zlib builds the deflate stream
may differ, which is why `--check` compares archives structurally (see
"Rebuilding and checking").

## Contract

The parsing rules below are what both parsers implement. `build.mjs` is the
executable form; where the spec's prose left something open, the choice is
listed under "Interpretations" and is pinned by a fixture where noted.

### Entries and packages

- Directory entries (paths ending in `/`) are not files: skip them entirely.
  They are neither read nor listed in the inventory.
- Only entries whose **base name** (the segment after the last `/`) matches
  `Streaming_History_Audio_*.json`, `YourLibrary.json`, or `Playlist*.json` may
  be opened. Matching is ASCII case folding of the whole base name, at any
  depth: `yourlibrary.json` and `YOURLIBRARY.JSON` match, `._YourLibrary.json`
  (a `__MACOSX` resource fork) does not. Every other entry is never read: the
  parser knows its path and its byte size (from the central directory) and
  nothing else. "Never read" means never inflated, decoded, or parsed, and no
  byte range of such an entry is requested on its own. One exception is
  inherent to the format and allowed: a standard ZIP reader must load the
  archive's trailing bytes (at most 65 557) raw to find the end-of-central-
  directory record, and those bytes may belong to any entry.
- Package: `spotify_extended` when any history file is present; otherwise
  `spotify_account` when a library or playlist file is present; a ZIP with
  neither is unreadable. In the extended package, library and playlist files
  are not read and are listed as ignored.
- Files are processed, and listed in the inventory, in path order (ordinal).
  Rows are processed in file order. "First seen" below means this order.
- Decoding: a read file's bytes are UTF-8; a leading byte-order mark is
  stripped; any malformed sequence makes the file unreadable (the reference
  uses `new TextDecoder('utf-8', { fatal: true })`). The text must be standard
  JSON whose top level has the right shape (history: an array; library or
  playlist: an object); anything else makes the archive unreadable: the
  expected file carries `error` and no `snapshot`. Missing `tracks`,
  `artists`, `playlists`, or `items` arrays are treated as empty, not as
  errors.
- Inventory row counts: history file = array length; library file =
  `tracks.length + artists.length`; playlist file = total `items` across its
  `playlists`.

### Names and numbers

- A name field (`title`, `artist`, `album`, playlist `name` and `description`,
  entry `title` / `artist` / `album`, followed-artist `name`) reads a non-empty
  JSON string; `""`, null, and non-strings all count as absent. Nothing is
  dropped for a missing name. Where the snapshot needs a name and none was
  seen: a track `title` is its `platformId`, an `artist` is `Unknown Artist`,
  a playlist `name` is `Untitled`, an entry `title` is the entry's
  `platformId` when it has one, else `Untitled`, an entry `artist` is
  `Unknown Artist`; `album` and `description` stay null. (The server rejects
  empty names.) The one exception is a followed artist without a name, which
  has no identity and is dropped.
- Every number in the snapshot (`durationMs`, `plays`, `skips`, `completes`,
  `msPlayed`, `hoursMask`, `lastModifiedAt`, `addedAt`, `ordinal`, `position`,
  `unresolved.*`) is an integer, serialized without a fraction.

### Extended history

For each row in each history file, in order:

1. Drop the row when `incognito_mode === true`, unless
   `includePrivateSessions` is true. A dropped private row counts toward
   nothing, including `unresolved` and `country`.
2. Drop the row when `spotify_episode_uri` or `audiobook_uri` is non-null
   (podcasts, audiobooks). These are not unresolved.
3. `ms_played`: a JSON number truncated toward zero; anything else (missing,
   null, a string) counts as 0. `platformId` is the 22-character tail after
   `spotify:track:`. When `spotify_track_uri` is null (local files), the row
   is **unresolved**: add 1 to `unresolved.rows`, and 1 to `unresolved.plays`
   when `ms_played >= 30000`; then stop processing the row.
4. `ts` must match `^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,3})?Z$`; the
   instant is `Date.UTC` (or the platform equivalent) of the captured fields,
   with the fraction right-padded to milliseconds. Any other value, including
   an offset-less `2026-04-01T10:00:00`, a `+00:00` offset, or an RFC 2822
   date, drops the row. Convert the instant to the option's IANA zone: local
   day `YYYY-MM-DD` and local hour 0–23 (see "Time zone conversion").
5. Classify: a **play** when `ms_played >= 30000`; a **skip** when
   `skipped === true` (whatever `reason_end` says), or, when the `skipped` key
   is absent or null, when `reason_end === "fwdbtn"` (a present
   `skipped: false` beats `fwdbtn`); a **complete** when
   `reason_end === "trackdone"`, whatever `ms_played` is.
6. Register the track (every row that reaches this step does, even one that
   yields no day row): `title`, `artist`, `album` are the first non-empty
   string values of `master_metadata_track_name`,
   `master_metadata_album_artist_name`, `master_metadata_album_album_name`;
   `durationMs` is the maximum `ms_played` over completes, else null.
7. Aggregate per (`platformId`, local day): `plays`, `skips`, `completes`
   counts; `msPlayed` = sum of `ms_played` over **all** kept rows for that
   track-day, including rows under 30 s; `hoursMask` = OR of `1 << localHour`
   over counted plays only (0 when none).
8. Count `conn_country` for `country` when it is a string matching
   `^[A-Z]{2}$`. Only rows that reach this step count: not private, episode,
   audiobook, unresolved, or dropped-`ts` rows.

After all files: emit a day row only when `plays > 0` or `skips > 0` (a day
whose only row is a complete under 30 s is not emitted, even though that
complete set the track's `durationMs`); `country` = the most common counted
code, ties to the smallest code by ordinal comparison, else null;
`ledgerFrom` / `ledgerTo` = min / max `day` over the emitted day rows, else
null. `library`, `artists`, `playlists` are empty.

**Time zone conversion.** Exact conversion of each row's instant to the option
zone is normative: the local day and hour are the date and hour of the wall
clock that `Intl.DateTimeFormat` with `timeZone` and `hourCycle: "h23"` (or
the platform equivalent) gives for that instant. A per-UTC-hour cache is
allowed as an optimization only when the zone offset at the start and at the
end of that UTC hour are equal (`offset = Date.UTC(wall(H)) - H` for
`H = floor(ts / 3600000) * 3600000` and for `H + 3600000`); otherwise the hour
contains a transition and every row in it is converted exactly. Caching the
hour-start offset unconditionally is wrong in half-hour zones: at
`2025-03-09T05:45:00Z` St. John's is already on −2:30 although the hour began
on −3:30 (local hour 3, not 2), and at `2025-11-02T04:45:00Z` the reverse
(local hour 1, not 2).

### Account data

- `YourLibrary.json`: `tracks[]` items `{ artist, album, track, uri }` are the
  liked tracks, but only those whose `uri` is `spotify:track:` plus 22 base62
  characters; a liked track with a null uri, a `spotify:local:` uri, or any
  other uri is dropped entirely (no library row, not unresolved, not in
  `tracks`). `artists[]` items `{ name, uri }` are the followed artists
  (`spotifyId` = the tail after `spotify:artist:`; a null or other uri gives
  null; an item without a name is dropped). `albums`, `shows`, `episodes`,
  `bannedTracks`, and everything else are ignored.
- `Playlist*.json`: `playlists[]` in file order, files in path order; the
  `ordinal` is the running index across files. `name` falls back to
  `Untitled`. `key` = lowercase hex SHA-256 of the UTF-8 bytes of
  `name + " " + ordinal` (for example `"Late Nights on the Ferry 0"`, or
  `"Untitled 1"` for a nameless second playlist). `description` is null when
  absent or empty. `lastModifiedAt` = epoch ms of `lastModifiedDate` when it
  is `YYYY-MM-DD` (midnight UTC), else null.
- Entries follow `items` order with `position` from 0. An item is a `track`
  (`trackName`, `artistName`, `albumName`, `trackUri`), a `localTrack`
  (`trackName`, `artistName`, `albumName`), or an `episode` (`episodeName` as
  title, `showName` as artist, album null), checked in that order. `platformId`
  comes from `track.trackUri` only, so local tracks, episodes, and track items
  with a null uri have `platformId: null` and count toward `unresolved.rows`
  (`unresolved.plays` stays 0). `title` / `artist` fall back as in "Names and
  numbers". `addedAt` = epoch ms of `addedDate` (`YYYY-MM-DD`, midnight UTC),
  else null.
- `tracks` = the union of liked tracks and playlist entries with a `platformId`.
  Each of `title`, `artist`, `album` is the first non-empty value seen for that
  id, the library file first and then playlists in order; the fallbacks apply
  only when no source named it. `durationMs` is null.
- `library` = one row per liked track:
  `{ platformId, playCount: null, skipCount: null, lastPlayedAt: null, dateAdded: null, likeRating: null }`.
- `days` is empty; `country`, `ledgerFrom`, `ledgerTo` are null.

### Expected file

```jsonc
{
  "inventory": {
    "package": "spotify_extended" | "spotify_account" | null,
    "read": [ { "path": "...", "rows": 9 } ],          // allow-listed files, path order; rows null when the file failed to decode
    "ignored": [ { "path": "...", "bytes": 2068 } ]    // every other file entry, path order; byte size only; never a directory entry
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
   `tracks` and has no day row. A `trackdone` under 30 s is a complete: it
   counts toward `completes` and sets `durationMs`, and its `ms_played` counts
   toward `msPlayed`, but a day with `plays` 0 and `skips` 0 is not emitted,
   so a track whose only row is such a complete has a `durationMs` and no
   ledger. Pinned: `extended-podcasts-and-local` (Slow Orbit, 2.5 s, no
   `durationMs`); `extended-basic` (Short Reprise, a 25 s `trackdone`:
   `durationMs` 25000, no day row).
3. `ledgerFrom` / `ledgerTo` span the emitted day rows, not every kept row.
   Pinned: `extended-basic` (a 5 s row on 2026-03-01 and the Short Reprise
   complete on 2026-04-04 do not extend the ledger).
4. "First seen" is the first non-empty JSON string value in file-then-row
   order; `""`, null, and non-strings are absent. Pinned for order:
   `extended-basic` (a later remastered title does not replace the first).
   Fallbacks when never seen: `title` → `platformId`, `artist` →
   `Unknown Artist`, `album` → null. Pinned: `extended-basic` (a resolved row
   with null title and artist yields `Nameless00000000000001` /
   `Unknown Artist`). That `""` is absent is not pinned.
5. `skipped: null` counts as absent (so `fwdbtn` decides), and `skipped: true`
   is a skip whatever `reason_end` says. Pinned: `extended-basic` (a
   `skipped: null` + `fwdbtn` row is a skip; a `skipped: true` + `endplay` row
   is a skip).
6. A `spotify_track_uri` that is a string but not `spotify:track:` plus 22
   base62 characters is treated like null (unresolved). Not pinned; the builder
   refuses such fixtures.
7. `ts` accepts only the grammar in step 4; any other value drops the row,
   after step 3, so an unresolved row with a bad `ts` still counts as
   unresolved. Pinned: `extended-basic` (an offset-less
   `2026-04-01T10:00:00` and an RFC 2822 `Wed, 01 Apr 2026 11:00:00 GMT`, both
   resolved, are dropped; a lenient `Date.parse` would keep them).
8. `ms_played` that is a JSON number is truncated toward zero; anything else
   counts as 0, and the row is kept. Pinned: `extended-basic` (`45000.7`
   counts 45000 and is a play; `"oops"` counts 0 and the row's
   `skipped: true` still counts).
9. `country` counts only `^[A-Z]{2}$` codes, only on rows that reach step 8,
   and ties go to the smallest code. Pinned for scope and ties:
   `extended-podcasts-and-local` (the kept rows say US, NG, US, NG → `NG`;
   the unresolved, episode, and audiobook rows all say GB, so a parser that
   counts them, or counts plays only, or keeps the first seen, gets `GB` or
   `US`). The format rule is not pinned.
10. For an unreadable archive the inventory still lists every allow-listed
    file, the broken one with `rows: null`, and `error.file` is the base name
    of the first broken file in path order. Pinned: `extended-malformed`,
    `extended-bad-utf8`. A ZIP with no allow-listed file has `package: null`
    and `file: null`. Not pinned.
11. Playlist files are ordered by full path, ordinal: `Playlist10.json` sorts
    before `Playlist2.json`. The ordinal runs on across files. Pinned for the
    running ordinal: `account-empty-playlist`.
12. A playlist `name` that is not a non-empty string becomes `Untitled` (and
    hashes as `"Untitled <ordinal>"`); an entry `title` falls back to its
    `platformId` when present, else `Untitled`; an entry `artist` to
    `Unknown Artist`. Pinned: `account-local-and-episode-entries` (a null
    playlist name; a track entry and a local entry with null names).
13. Only `YYYY-MM-DD` dates convert; any other `lastModifiedDate` /
    `addedDate` gives null. Not pinned.
14. In the extended package a library file travelling with the history is
    ignored, not read. Pinned: `extended-nested-folder`.
15. A UTF-8 byte-order mark is stripped; malformed UTF-8 is unreadable.
    Pinned: `extended-bom` (readable), `extended-bad-utf8` (unreadable).
16. Allow-list matching is ASCII case folding of the whole base name. Pinned:
    `account-liked-absent-from-history` (`yourlibrary.json` is read);
    `account-pii-present` (`__MACOSX/._YourLibrary.json` is ignored, bytes
    only).
17. Directory entries are skipped and never listed; an entry whose sizes and
    CRC live in a data descriptor (bit 3) reads like any other, since the
    central directory has them. Pinned: `extended-nested-folder` (three
    directory entries absent from the inventory; the history file is a
    data-descriptor entry).
18. A liked track whose `uri` is null or not a track uri vanishes: no library
    row, not unresolved, not in `tracks`. A liked track with a null `track`
    name keeps its library row and takes its platform id as title. Pinned:
    `account-basic` (a `spotify:local:` uri, a null uri, a null name).
19. A library file without an `artists` key and a playlist without an `items`
    key are empty, not errors. Pinned: `account-empty-playlist`.

## Cases

| Case | Package | Pins |
|---|---|---|
| `extended-basic` | extended | 6 ids over 3 files (2024–2026), one recording under two ids, plays either side of 30 s, `skipped` true/false in one file and absent (`fwdbtn`) in another, `trackdone` completes and derived duration, several hours in one day, msPlayed including sub-30 s rows, a day row with 0 plays and 1 skip, the Lagos midnight boundary, first-seen naming, ledger over emitted days; a resolved row with null title and artist, offset-less and RFC 2822 `ts` rows (dropped), `ms_played` 45000.7 and `"oops"`, `skipped: true` + `endplay`, a 90 s `fwdbtn` play with no complete, a `trackdone` under 30 s with no day row, a `skipped: null` row |
| `extended-podcasts-and-local` | extended | episode and audiobook rows dropped silently, URI-less rows counted as unresolved (rows and plays), a track with no day row; `country` scope (GB on every dropped or unresolved row) and a 2-2 tie among kept rows |
| `extended-private-sessions` | extended | `default` excludes `incognito_mode` rows; `private-included` keeps them (country, duration, an extra track and day, an unresolved private row) |
| `extended-various-artists` | extended | compilation and soundtrack rows carry the album artist "Various Artists" unchanged |
| `extended-timezone` | extended | plays at 23:30 and 00:30 UTC on consecutive days in summer and winter, a pair across the Los Angeles spring-forward, and a row inside each St. John's half-hour transition hour; `default` (Africa/Lagos), `los-angeles` (America/Los_Angeles), `st-johns` (America/St_Johns) |
| `extended-nested-folder` | extended | files two directories deep, three directory entries, a data-descriptor history file, a PDF and a video-history sentinel, a library file ignored in the extended package |
| `extended-malformed` | extended | one valid file and one truncated file: unreadable, inventory only |
| `extended-bom` | extended | a history file that starts with a UTF-8 byte-order mark: readable |
| `extended-bad-utf8` | extended | one valid file and one with a lone `0xE9` byte in a track name: unreadable, inventory only |
| `account-basic` | account | 4 liked tracks plus one with a null name, one with a `spotify:local:` uri, and one with a null uri; 2 followed artists; albums/shows/episodes ignored; 2 playlists with descriptions (one empty) and dates; a `StreamingHistory_music_0.json` sentinel |
| `account-empty-playlist` | account | an empty playlist, a playlist without an `items` key, ordinal continuing into `Playlist2.json`, a library file without an `artists` key |
| `account-duplicates` | account | one track twice in a playlist, in two playlists, and liked with different album naming (library naming wins in `tracks`) |
| `account-local-and-episode-entries` | account | episode, local-track, and URI-less track items as name-only entries with positions preserved; a nameless playlist with a nameless track entry and a nameless local entry |
| `account-liked-absent-from-history` | account | a library file alone, named `yourlibrary.json`: liked tracks land in `tracks` and `library` with null counts, no artists, no playlists |
| `account-pii-present` | account | `Identity.json`, `Inferences.json`, `Payments.json`, `Userdata.json`, and `__MACOSX/._YourLibrary.json` sentinels beside a valid library and playlist file; listed as ignored with byte sizes only |

## Adding a case

1. Create `src/<package>-<name>/case.json` (lowercase, digits, hyphens). Invent
   every name; ids are 22 base62 characters (the existing ones are a label
   padded with digits so they read as what they are). Use `bytes` (base64)
   only for bodies that are not valid UTF-8, `directory: true` for directory
   entries, `dataDescriptor: true` to exercise bit 3.
2. `node fixtures/listening-exports/build.mjs` writes `<case>/archive.zip` and
   `<case>/expected.<option>.json`.
3. Read the expected file and check it by hand against the rules above. The
   reference implementation is the contract's executable form, not its proof.
4. `node --test fixtures/listening-exports/verify.test.mjs` (add assertions for
   what the case pins), then run both parser suites.
5. Commit `src/<case>/case.json` and the built files together, add the case
   to the table above, and note what it pins under "Interpretations".

## Rebuilding and checking

```
node fixtures/listening-exports/build.mjs            # rebuild every case
node fixtures/listening-exports/build.mjs --check    # compare the committed files with a fresh build; exit 1 on any problem
node --test fixtures/listening-exports/verify.test.mjs
```

`--check` compares every `expected.*.json` byte for byte, and every
`archive.zip` structurally against its case definition: entry names and order,
flags, method, DOS date/time, CRC-32, sizes, local-header and data-descriptor
consistency, attributes, and the inflated bodies. The compressed bytes are not
compared, so a deflate difference between Node's zlib builds never fails the
check; a rebuild on another machine may rewrite an archive with a different
deflate stream, and that archive is equally valid to commit or to leave alone.
Missing, stale, and unexpected files under `<case>/` fail the check too.

The gate in the authoritative suite is
`server/test/fixtures/listening-exports.test.ts` (vitest), which runs
`build.mjs --check` and `verify.test.mjs` from the repo root, so `case.json`
and the built files cannot drift apart without failing the server tests.

## Layout assumption

To verify against the founder's real exports before B1 and C1 close:

- Extended history: `Spotify Extended Streaming History/Streaming_History_Audio_<years>_<n>.json`,
  alongside `Streaming_History_Video_*.json` and a `ReadMeFirst_*.pdf`.
- Account data: `Spotify Account Data/YourLibrary.json` and
  `Spotify Account Data/Playlist1.json` (more `Playlist<n>.json` for large
  accounts), alongside `StreamingHistory_music_<n>.json`, `Identity.json`,
  `Userdata.json`, `Payments.json`, `Inferences.json`, and others.
- The archive may wrap these in one more directory (`my_spotify_data/...`).
  Parsers match by base name at any depth, ASCII case-insensitive, and never
  depend on the directory names.
- Record shapes to confirm: the history record fields used above; the library
  `tracks[]` / `artists[]` item fields; the playlist `items[]` fields, in
  particular the `localTrack` and `episode` shapes, which are modelled here as
  `{ trackName, artistName, albumName, uri }` and
  `{ episodeName, showName, episodeUri }`.

If the real layout differs, update the affected `case.json` files, rebuild, and
adjust this section in the same PR.

## Not pinned by fixtures

Guidance for real archives that no fixture exercises:

- Nested ZIPs and split archives are outside this suite; the spec covers them.
