// Spotify export parser: the TypeScript half of the contract in
// fixtures/listening-exports/README.md. build.mjs there is the reference
// implementation; every rule and numbered interpretation here follows it.
// Nothing in this module logs, and no track, artist, album, or playlist name
// ever lands in an error message.

import { canonicalize, compareOrdinal } from './canonical'
import type {
  ExportInventory,
  ListeningExportPackage,
  ListeningExportSnapshot,
  SnapshotArtist,
  SnapshotDay,
  SnapshotLibraryRow,
  SnapshotPlaylist,
  SnapshotPlaylistEntry,
  SnapshotTrack,
} from './snapshot'
import { UnreadableExportError } from './unreadable-error'
import type { ExportArchive } from './zip-reader'

export const PARSER_VERSION = 'web-spotify-export/1'
export const PLAY_THRESHOLD_MS = 30_000
/** Snapshot fallbacks for names never seen as a non-empty string ("Names and numbers"). */
export const UNKNOWN_ARTIST = 'Unknown Artist'
export const UNTITLED = 'Untitled'
/** Rows processed between event-loop yields (lets an abort message reach a Worker mid-file). */
export const YIELD_EVERY_ROWS = 4096

export type EntryKind = 'history' | 'library' | 'playlist'

export type ParseStage = 'listing' | 'reading' | 'complete'

export type ParseProgress = {
  stage: ParseStage
  /** The entry being read, or null outside the reading stage. */
  file: string | null
  /** Files fully processed so far, out of the files the package reads. */
  completed: number
  total: number
}

export type InspectOptions = {
  signal?: AbortSignal
  onProgress?: (progress: ParseProgress) => void
}

export type ParseOptions = InspectOptions & {
  /** IANA zone the device reports; days and hours are local to it. */
  timeZone: string
  includePrivateSessions: boolean
}

/**
 * What the extended parse dropped, by reason, for the inventory preview. Not
 * part of the fixture contract (never canonicalized or compared); zeros for
 * the account package, which drops no rows this way.
 */
export type ExportStats = {
  /** Rows with an episode or audiobook URI (step 2). */
  podcastOrAudiobook: number
  /** Rows with no usable track URI (step 3); these are the snapshot's unresolved rows. */
  localFile: number
  /** Private-session rows the toggle dropped (step 1); 0 when they were included. */
  privateSession: number
  /** Resolved rows whose `ts` was outside the grammar (step 4). */
  badTimestamp: number
  /** Among the dropped private-session rows, those at or over the 30 s play rule. */
  privatePlays: number
}

export const zeroStats = (): ExportStats => ({
  podcastOrAudiobook: 0,
  localFile: 0,
  privateSession: 0,
  badTimestamp: 0,
  privatePlays: 0,
})

export type ParseResult = {
  inventory: ExportInventory
  snapshot: ListeningExportSnapshot
  stats: ExportStats
}

// The fail-closed error (no Spotify files, or one of them broken) lives in
// its own module so the page's Worker client can revive it without pulling
// the parser into the main bundle; re-exported here for the parser's callers.
export { UnreadableExportError }

// ---------------------------------------------------------------------------
// Entries and packages
// ---------------------------------------------------------------------------

const KIND_PATTERNS: readonly (readonly [EntryKind, RegExp])[] = [
  ['history', /^streaming_history_audio_.*\.json$/],
  ['library', /^yourlibrary\.json$/],
  ['playlist', /^playlist.*\.json$/],
]

export const baseName = (path: string): string => path.slice(path.lastIndexOf('/') + 1)

/** ASCII case folding only (interpretation 16): non-ASCII letters never fold into the allow-list. */
const foldAscii = (text: string): string => text.replace(/[A-Z]/g, (letter) => letter.toLowerCase())

/** Which allow-list an entry's whole base name matches, or null when it must never be opened. */
export function classifyEntry(path: string): EntryKind | null {
  const base = foldAscii(baseName(path))
  for (const [kind, pattern] of KIND_PATTERNS) if (pattern.test(base)) return kind
  return null
}

export type PlannedFile = {
  path: string
  bytes: number
  kind: EntryKind | null
  /** True when this package reads the file; everything else is inventoried by size only. */
  read: boolean
}

export type ArchivePlan = {
  package: ListeningExportPackage | null
  /** Every file entry in path order (ordinal). */
  files: PlannedFile[]
}

export async function planArchive(archive: ExportArchive): Promise<ArchivePlan> {
  const entries = [...(await archive.entries())].sort((a, b) => compareOrdinal(a.path, b.path))
  const classified = entries.map((entry) => ({ path: entry.path, bytes: entry.bytes, kind: classifyEntry(entry.path) }))
  const hasHistory = classified.some((file) => file.kind === 'history')
  const hasAccount = classified.some((file) => file.kind === 'library' || file.kind === 'playlist')
  const pkg: ListeningExportPackage | null = hasHistory ? 'spotify_extended' : hasAccount ? 'spotify_account' : null
  const readKinds: EntryKind[] = pkg === 'spotify_extended' ? ['history'] : pkg === 'spotify_account' ? ['library', 'playlist'] : []
  return {
    package: pkg,
    files: classified.map((file) => ({ ...file, read: file.kind !== null && readKinds.includes(file.kind) })),
  }
}

// ---------------------------------------------------------------------------
// Decoding
// ---------------------------------------------------------------------------

type JsonObject = Record<string, unknown>

const isObject = (value: unknown): value is JsonObject =>
  typeof value === 'object' && value !== null && !Array.isArray(value)

export type LoadedHistory = { kind: 'history'; rows: number; headers: string[]; data: unknown[] }
export type LoadedLibrary = { kind: 'library'; rows: number; headers: string[]; tracks: unknown[]; artists: unknown[] }
export type LoadedPlaylistFile = {
  kind: 'playlist'
  rows: number
  headers: string[]
  playlists: { playlist: JsonObject; items: unknown[] }[]
}
export type LoadedFile = LoadedHistory | LoadedLibrary | LoadedPlaylistFile

/**
 * Decodes one allow-listed file. Throws when the text is not JSON or the top
 * level has the wrong shape (history: array; library, playlist: object); both
 * make the archive unreadable. `headers` are top-level key names only.
 */
export function loadRecords(kind: EntryKind, text: string): LoadedFile {
  const data: unknown = JSON.parse(text)
  if (kind === 'history') {
    if (!Array.isArray(data)) throw new Error('history file is not an array')
    const first: unknown = data[0]
    return { kind, rows: data.length, headers: isObject(first) ? Object.keys(first) : [], data }
  }
  if (!isObject(data)) throw new Error('account file is not an object')
  const headers = Object.keys(data)
  if (kind === 'library') {
    const tracks = Array.isArray(data.tracks) ? data.tracks : []
    const artists = Array.isArray(data.artists) ? data.artists : []
    return { kind, rows: tracks.length + artists.length, headers, tracks, artists }
  }
  const playlists = Array.isArray(data.playlists) ? data.playlists : []
  let rows = 0
  const normalized = playlists.map((playlist: unknown) => {
    const record = isObject(playlist) ? playlist : {}
    const items = Array.isArray(record.items) ? record.items : []
    rows += items.length
    return { playlist: record, items }
  })
  return { kind, rows, headers, playlists: normalized }
}

// ---------------------------------------------------------------------------
// Values
// ---------------------------------------------------------------------------

const SPOTIFY_ID = /^[0-9A-Za-z]{22}$/

/** The 22-character id of a `spotify:<kind>:<id>` URI; null for anything else (interpretation 6). */
export function spotifyIdFromUri(uri: unknown, kind: 'track' | 'artist'): string | null {
  if (typeof uri !== 'string') return null
  const prefix = `spotify:${kind}:`
  if (!uri.startsWith(prefix)) return null
  const tail = uri.slice(prefix.length)
  return SPOTIFY_ID.test(tail) ? tail : null
}

/** A JSON number truncated toward zero; anything else counts as 0 (interpretation 8). */
const asInteger = (value: unknown): number =>
  typeof value === 'number' && Number.isFinite(value) ? Math.trunc(value) : 0
/** A non-empty JSON string, else null: every name and text field; `""`, null, and non-strings are absent. */
const asText = (value: unknown): string | null =>
  typeof value === 'string' && value.length > 0 ? value : null

const COUNTRY_CODE = /^[A-Z]{2}$/

const TIMESTAMP = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,3}))?Z$/

/**
 * Epoch ms of a history `ts`: the only grammar accepted is
 * `YYYY-MM-DDTHH:MM:SS[.fff]Z`, and the instant is `Date.UTC` of the captured
 * fields with the fraction right-padded to milliseconds. Anything else is
 * null and the row is dropped (step 4, interpretation 7).
 */
export function parseTimestamp(value: unknown): number | null {
  if (typeof value !== 'string') return null
  const match = TIMESTAMP.exec(value)
  if (match === null) return null
  if (Number(match[1]) < 1900) return null // years before 1900 are outside the grammar (interpretation 7)
  const millis = match[7] === undefined ? 0 : Number(match[7].padEnd(3, '0'))
  return Date.UTC(
    Number(match[1]),
    Number(match[2]) - 1,
    Number(match[3]),
    Number(match[4]),
    Number(match[5]),
    Number(match[6]),
    millis,
  )
}

const DATE_ONLY = /^(\d{4})-(\d{2})-(\d{2})$/

/** `YYYY-MM-DD` -> epoch ms of that date's midnight UTC; anything else -> null (interpretation 13). */
export function epochMsFromExportDate(value: unknown): number | null {
  if (typeof value !== 'string') return null
  const match = DATE_ONLY.exec(value)
  if (match === null) return null
  if (Number(match[1]) < 1900) return null // same year floor as `ts` (interpretation 13)
  const ms = Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3]))
  return Number.isNaN(ms) ? null : ms
}

const encoder = new TextEncoder()

export async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', encoder.encode(text))
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, '0')).join('')
}

/** Playlist fingerprint: lowercase hex SHA-256 of `name + " " + ordinal`. */
export const playlistKey = (name: string, ordinal: number): Promise<string> => sha256Hex(`${name} ${ordinal}`)

// ---------------------------------------------------------------------------
// Time zone conversion
// ---------------------------------------------------------------------------

const HOUR_MS = 3_600_000

/**
 * Local day and hour of a UTC instant in an IANA zone. The offset is resolved
 * with Intl and cached per UTC hour, but only when it is the same at both ends
 * of that hour; an hour containing a transition is resolved exactly, per
 * timestamp. Day and hour then come from `ts + offset`, which stays correct
 * for half-hour and quarter-hour zones.
 */
export class ZoneClock {
  private readonly format: Intl.DateTimeFormat
  private readonly hourOffsets = new Map<number, number | null>()

  constructor(readonly timeZone: string) {
    this.format = new Intl.DateTimeFormat('en-US', {
      timeZone,
      hourCycle: 'h23',
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
    })
  }

  /** The zone offset at one instant, from the wall clock Intl prints for it. */
  offsetAt(utcMs: number): number {
    const wall: Record<string, number> = {}
    for (const part of this.format.formatToParts(new Date(utcMs))) {
      if (part.type !== 'literal') wall[part.type] = Number(part.value)
    }
    // Some ICU builds print midnight as "24" even with h23; normalize.
    const wallMs = Date.UTC(
      wall.year ?? 1970,
      (wall.month ?? 1) - 1,
      wall.day ?? 1,
      (wall.hour ?? 0) % 24,
      wall.minute ?? 0,
      wall.second ?? 0,
    )
    return wallMs - Math.floor(utcMs / 1000) * 1000
  }

  offsetMs(utcMs: number): number {
    const hourStart = Math.floor(utcMs / HOUR_MS) * HOUR_MS
    let cached = this.hourOffsets.get(hourStart)
    if (cached === undefined) {
      const atStart = this.offsetAt(hourStart)
      cached = atStart === this.offsetAt(hourStart + HOUR_MS) ? atStart : null
      this.hourOffsets.set(hourStart, cached)
    }
    return cached ?? this.offsetAt(utcMs)
  }

  local(utcMs: number): { day: string; hour: number } {
    const shifted = new Date(utcMs + this.offsetMs(utcMs))
    return { day: shifted.toISOString().slice(0, 10), hour: shifted.getUTCHours() }
  }
}

// ---------------------------------------------------------------------------
// Cooperative scheduling
// ---------------------------------------------------------------------------

/** Lets queued messages (an abort, in a Worker) run before the next batch of rows. */
export function yieldToEventLoop(): Promise<void> {
  if (typeof MessageChannel === 'function') {
    return new Promise((resolve) => {
      const channel = new MessageChannel()
      channel.port1.onmessage = () => {
        channel.port1.close()
        resolve()
      }
      channel.port2.postMessage(null)
    })
  }
  return new Promise((resolve) => setTimeout(resolve, 0))
}

// ---------------------------------------------------------------------------
// Extended streaming history
// ---------------------------------------------------------------------------

type MutableTrack = {
  platformId: string
  title: string | null
  artist: string | null
  album: string | null
  durationMs: number | null
}

interface SnapshotBuilder {
  readonly stats: ExportStats
  add(loaded: LoadedFile): Promise<void>
  finish(): Promise<ListeningExportSnapshot>
}

class ExtendedBuilder implements SnapshotBuilder {
  readonly stats = zeroStats()
  private readonly clock: ZoneClock
  private readonly tracks = new Map<string, MutableTrack>()
  private readonly days = new Map<string, SnapshotDay>()
  private readonly countries = new Map<string, number>()
  private unresolvedRows = 0
  private unresolvedPlays = 0
  private rowsSinceYield = 0

  constructor(private readonly options: ParseOptions) {
    this.clock = new ZoneClock(options.timeZone)
  }

  async add(loaded: LoadedFile): Promise<void> {
    if (loaded.kind !== 'history') return
    for (const row of loaded.data) {
      this.rowsSinceYield += 1
      if (this.rowsSinceYield >= YIELD_EVERY_ROWS) {
        this.rowsSinceYield = 0
        await yieldToEventLoop()
        this.options.signal?.throwIfAborted()
      }
      this.addRow(row)
    }
  }

  private addRow(row: unknown): void {
    if (!isObject(row)) return
    const msPlayed = asInteger(row.ms_played)
    const isPlay = msPlayed >= PLAY_THRESHOLD_MS
    // 1. Private rows first (interpretation 1): they count toward nothing
    // in the snapshot; the stats remember how many plays the toggle hides.
    if (row.incognito_mode === true && !this.options.includePrivateSessions) {
      this.stats.privateSession += 1
      if (isPlay) this.stats.privatePlays += 1
      return
    }
    // 2. Podcasts and audiobooks are dropped silently.
    if (row.spotify_episode_uri != null || row.audiobook_uri != null) {
      this.stats.podcastOrAudiobook += 1
      return
    }
    // 3. No usable track URI: unresolved.
    const platformId = spotifyIdFromUri(row.spotify_track_uri, 'track')
    if (platformId === null) {
      this.stats.localFile += 1
      this.unresolvedRows += 1
      if (isPlay) this.unresolvedPlays += 1
      return
    }
    // 4. Timestamp, strictly.
    const utcMs = parseTimestamp(row.ts)
    if (utcMs === null) {
      this.stats.badTimestamp += 1
      return
    }
    // 5. Classify.
    const isSkip = row.skipped === true || (row.skipped == null && row.reason_end === 'fwdbtn')
    const isComplete = row.reason_end === 'trackdone'
    const { day, hour } = this.clock.local(utcMs)
    // 6. Register the track: first non-empty string wins, duration is the longest complete.
    let track = this.tracks.get(platformId)
    if (track === undefined) {
      track = { platformId, title: null, artist: null, album: null, durationMs: null }
      this.tracks.set(platformId, track)
    }
    if (track.title === null) track.title = asText(row.master_metadata_track_name)
    if (track.artist === null) track.artist = asText(row.master_metadata_album_artist_name)
    if (track.album === null) track.album = asText(row.master_metadata_album_album_name)
    if (isComplete && (track.durationMs === null || msPlayed > track.durationMs)) track.durationMs = msPlayed
    // 7. Aggregate per track and local day.
    const key = `${platformId}|${day}`
    let dayRow = this.days.get(key)
    if (dayRow === undefined) {
      dayRow = { platformId, day, plays: 0, skips: 0, completes: 0, msPlayed: 0, hoursMask: 0 }
      this.days.set(key, dayRow)
    }
    dayRow.msPlayed += msPlayed
    if (isPlay) {
      dayRow.plays += 1
      dayRow.hoursMask |= 1 << hour
    }
    if (isSkip) dayRow.skips += 1
    if (isComplete) dayRow.completes += 1
    // 8. Country, kept rows only.
    const country = row.conn_country
    if (typeof country === 'string' && COUNTRY_CODE.test(country)) {
      this.countries.set(country, (this.countries.get(country) ?? 0) + 1)
    }
  }

  finish(): Promise<ListeningExportSnapshot> {
    const tracks: SnapshotTrack[] = [...this.tracks.values()].map((track) => ({
      platformId: track.platformId,
      title: track.title ?? track.platformId,
      artist: track.artist ?? UNKNOWN_ARTIST,
      album: track.album,
      durationMs: track.durationMs,
    }))
    const days = [...this.days.values()].filter((row) => row.plays > 0 || row.skips > 0)

    let country: string | null = null
    let countryCount = 0
    for (const [code, count] of this.countries) {
      if (count > countryCount || (count === countryCount && country !== null && compareOrdinal(code, country) < 0)) {
        country = code
        countryCount = count
      }
    }
    let ledgerFrom: string | null = null
    let ledgerTo: string | null = null
    for (const row of days) {
      if (ledgerFrom === null || compareOrdinal(row.day, ledgerFrom) < 0) ledgerFrom = row.day
      if (ledgerTo === null || compareOrdinal(row.day, ledgerTo) > 0) ledgerTo = row.day
    }

    return Promise.resolve(
      canonicalize({
        source: 'spotify_export',
        package: 'spotify_extended',
        timeZone: this.options.timeZone,
        country,
        tracks,
        days,
        library: [],
        artists: [],
        playlists: [],
        unresolved: { rows: this.unresolvedRows, plays: this.unresolvedPlays },
        ledgerFrom,
        ledgerTo,
      }),
    )
  }
}

// ---------------------------------------------------------------------------
// Account data
// ---------------------------------------------------------------------------

class AccountBuilder implements SnapshotBuilder {
  readonly stats = zeroStats()
  private readonly libraries: LoadedLibrary[] = []
  private readonly playlistFiles: LoadedPlaylistFile[] = []

  constructor(private readonly options: ParseOptions) {}

  add(loaded: LoadedFile): Promise<void> {
    if (loaded.kind === 'library') this.libraries.push(loaded)
    else if (loaded.kind === 'playlist') this.playlistFiles.push(loaded)
    return Promise.resolve()
  }

  async finish(): Promise<ListeningExportSnapshot> {
    // Each name is the first non-empty value seen for the id, library first.
    const tracks = new Map<string, MutableTrack>()
    const library = new Map<string, SnapshotLibraryRow>()
    const artists: SnapshotArtist[] = []
    const playlists: SnapshotPlaylist[] = []
    let unresolvedRows = 0

    const noteTrack = (platformId: string, title: string | null, artist: string | null, album: string | null) => {
      let track = tracks.get(platformId)
      if (track === undefined) {
        track = { platformId, title: null, artist: null, album: null, durationMs: null }
        tracks.set(platformId, track)
      }
      if (track.title === null) track.title = title
      if (track.artist === null) track.artist = artist
      if (track.album === null) track.album = album
    }

    for (const file of this.libraries) {
      for (const liked of file.tracks) {
        if (!isObject(liked)) continue
        const platformId = spotifyIdFromUri(liked.uri, 'track')
        if (platformId === null) continue // null, local, or malformed uri: dropped entirely (interpretation 18)
        noteTrack(platformId, asText(liked.track), asText(liked.artist), asText(liked.album))
        if (!library.has(platformId)) {
          library.set(platformId, {
            platformId,
            playCount: null,
            skipCount: null,
            lastPlayedAt: null,
            dateAdded: null,
            likeRating: null,
          })
        }
      }
      for (const followed of file.artists) {
        if (!isObject(followed)) continue
        const name = asText(followed.name)
        if (name === null) continue
        artists.push({ name, spotifyId: spotifyIdFromUri(followed.uri, 'artist') })
      }
    }

    // Playlists in file order, files in path order; the ordinal runs on across files.
    let ordinal = 0
    for (const file of this.playlistFiles) {
      for (const { playlist, items } of file.playlists) {
        this.options.signal?.throwIfAborted()
        const name = asText(playlist.name) ?? UNTITLED
        const entries = items.map((item, position): SnapshotPlaylistEntry => {
          const record = isObject(item) ? item : {}
          let platformId: string | null = null
          let title: string | null = null
          let artist: string | null = null
          let album: string | null = null
          if (isObject(record.track)) {
            platformId = spotifyIdFromUri(record.track.trackUri, 'track')
            title = asText(record.track.trackName)
            artist = asText(record.track.artistName)
            album = asText(record.track.albumName)
          } else if (isObject(record.localTrack)) {
            title = asText(record.localTrack.trackName)
            artist = asText(record.localTrack.artistName)
            album = asText(record.localTrack.albumName)
          } else if (isObject(record.episode)) {
            title = asText(record.episode.episodeName)
            artist = asText(record.episode.showName)
          }
          if (platformId === null) unresolvedRows += 1
          else noteTrack(platformId, title, artist, album)
          return {
            position,
            platformId,
            title: title ?? platformId ?? UNTITLED,
            artist: artist ?? UNKNOWN_ARTIST,
            album,
            addedAt: epochMsFromExportDate(record.addedDate),
          }
        })
        playlists.push({
          ordinal,
          key: await playlistKey(name, ordinal),
          name,
          description: asText(playlist.description),
          lastModifiedAt: epochMsFromExportDate(playlist.lastModifiedDate),
          entries,
        })
        ordinal += 1
      }
    }

    return canonicalize({
      source: 'spotify_export',
      package: 'spotify_account',
      timeZone: this.options.timeZone,
      country: null,
      tracks: [...tracks.values()].map((track) => ({
        platformId: track.platformId,
        title: track.title ?? track.platformId,
        artist: track.artist ?? UNKNOWN_ARTIST,
        album: track.album,
        durationMs: null,
      })),
      days: [],
      library: [...library.values()],
      artists,
      playlists,
      unresolved: { rows: unresolvedRows, plays: 0 },
      ledgerFrom: null,
      ledgerTo: null,
    })
  }
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

type FileVisitor = (file: PlannedFile, loaded: LoadedFile) => Promise<void>

/**
 * Reads the files the package reads, in path order, one at a time, and builds
 * the inventory. A file that fails to decode is inventoried with `rows: null`
 * and the rest are still counted; `visit` runs for decoded files until the
 * first failure. An abort always propagates as the signal's reason.
 */
async function readPlannedFiles(
  archive: ExportArchive,
  plan: ArchivePlan,
  options: InspectOptions,
  visit: FileVisitor,
): Promise<ExportInventory> {
  const total = plan.files.filter((file) => file.read).length
  const inventory: ExportInventory = { package: plan.package, read: [], ignored: [] }
  options.signal?.throwIfAborted()
  options.onProgress?.({ stage: 'listing', file: null, completed: 0, total })
  let completed = 0
  let failed = false
  for (const file of plan.files) {
    if (!file.read || file.kind === null) {
      inventory.ignored.push({ path: file.path, bytes: file.bytes })
      continue
    }
    options.signal?.throwIfAborted()
    options.onProgress?.({ stage: 'reading', file: file.path, completed, total })
    // A progress callback may abort; never request the entry after that.
    options.signal?.throwIfAborted()
    let loaded: LoadedFile | null = null
    try {
      loaded = loadRecords(file.kind, await archive.readText(file.path, { signal: options.signal }))
    } catch (error) {
      options.signal?.throwIfAborted()
      // Broken JSON, wrong shape, malformed UTF-8, or a corrupt entry: the
      // message may quote file content, so it is dropped here.
      void error
      loaded = null
    }
    inventory.read.push({ path: file.path, rows: loaded === null ? null : loaded.rows })
    if (loaded === null) failed = true
    else if (!failed) await visit(file, loaded)
    completed += 1
  }
  options.signal?.throwIfAborted()
  options.onProgress?.({ stage: 'complete', file: null, completed, total })
  return inventory
}

const noVisit: FileVisitor = () => Promise.resolve()

/** The inventory: package, files read with row counts, everything else with byte sizes. Never throws for broken content. */
export async function inspectExport(archive: ExportArchive, options: InspectOptions = {}): Promise<ExportInventory> {
  const plan = await planArchive(archive)
  return readPlannedFiles(archive, plan, options, noVisit)
}

/** The inventory, the canonical snapshot, and the drop stats; throws UnreadableExportError when the archive fails closed. */
export async function parseExport(archive: ExportArchive, options: ParseOptions): Promise<ParseResult> {
  const plan = await planArchive(archive)
  if (plan.package === null) {
    throw new UnreadableExportError(null, await readPlannedFiles(archive, plan, options, noVisit))
  }
  const builder: SnapshotBuilder =
    plan.package === 'spotify_extended' ? new ExtendedBuilder(options) : new AccountBuilder(options)
  const inventory = await readPlannedFiles(archive, plan, options, (_file, loaded) => builder.add(loaded))
  const broken = inventory.read.find((file) => file.rows === null)
  if (broken !== undefined) throw new UnreadableExportError(baseName(broken.path), inventory)
  const snapshot = await builder.finish()
  options.signal?.throwIfAborted()
  return { inventory, snapshot, stats: builder.stats }
}
