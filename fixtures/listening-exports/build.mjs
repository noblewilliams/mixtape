#!/usr/bin/env node
// Deterministic builder for the listening-export fixture suite.
//
//   node fixtures/listening-exports/build.mjs          rebuild every case
//   node fixtures/listening-exports/build.mjs --check  rebuild to memory, exit 1 on any diff
//
// For each `src/<case>/case.json` this writes `<case>/archive.zip` and one
// `<case>/expected.<option>.json` per option, by running the reference
// implementation of the parsing contract documented in README.md. Node >= 18,
// ESM, no dependencies. See README.md for the contract; this file is its
// executable form and the two real parsers (web, iOS) must agree with it
// byte for byte.

import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { deflateRawSync } from 'node:zlib'

export const ROOT = dirname(fileURLToPath(import.meta.url))
export const SRC = join(ROOT, 'src')

// ---------------------------------------------------------------------------
// Small helpers shared by the builder and verify.test.mjs
// ---------------------------------------------------------------------------

// Ordinal comparison by UTF-16 code unit: the only string order the contract
// uses (JS `<` and Dart `String.compareTo` agree on it).
export const compare = (a, b) => (a < b ? -1 : a > b ? 1 : 0)
const compareNullLast = (a, b) =>
  a === null ? (b === null ? 0 : 1) : b === null ? -1 : compare(a, b)

export const baseName = (path) => path.slice(path.lastIndexOf('/') + 1)

export const PLAY_THRESHOLD_MS = 30_000
export const SPOTIFY_ID = /^[0-9A-Za-z]{22}$/

export const SENTINEL_TARGET_BYTES = 2048

// The body of an entry a parser must never open: `DO-NOT-READ:<path>\n`
// repeated until the body is at least SENTINEL_TARGET_BYTES long.
export function sentinelBody(path) {
  const unit = `DO-NOT-READ:${path}\n`
  const repeats = Math.ceil(SENTINEL_TARGET_BYTES / Buffer.byteLength(unit, 'utf8'))
  return Buffer.from(unit.repeat(repeats), 'utf8')
}

// Bytes of a case entry as written into the archive.
export function entryBody(entry) {
  if (entry.sentinel === true) return sentinelBody(entry.path)
  if (typeof entry.text === 'string') return Buffer.from(entry.text, 'utf8')
  if (Object.hasOwn(entry, 'json')) {
    return Buffer.from(`${JSON.stringify(entry.json, null, 2)}\n`, 'utf8')
  }
  throw new Error(`entry ${entry.path}: needs exactly one of json, text, sentinel`)
}

export const serializeExpected = (value) => `${JSON.stringify(value, null, 2)}\n`

// ---------------------------------------------------------------------------
// CRC-32 (IEEE, as ZIP uses)
// ---------------------------------------------------------------------------

const CRC_TABLE = new Int32Array(256)
for (let n = 0; n < 256; n += 1) {
  let c = n
  for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1
  CRC_TABLE[n] = c
}

export function crc32(buffer) {
  let c = -1
  for (let i = 0; i < buffer.length; i += 1) c = CRC_TABLE[(c ^ buffer[i]) & 0xff] ^ (c >>> 8)
  return (c ^ -1) >>> 0
}

// ---------------------------------------------------------------------------
// ZIP writer: sorted entries, deflate, fixed timestamp, no extra fields
// ---------------------------------------------------------------------------

export const DOS_TIME = 0 // 00:00:00
export const DOS_DATE = ((2026 - 1980) << 9) | (1 << 5) | 1 // 2026-01-01
const METHOD_DEFLATE = 8
const VERSION = 20

const sortEntries = (entries) => [...entries].sort((a, b) => compare(a.path, b.path))

export function buildZip(entries) {
  const sorted = sortEntries(entries)
  const locals = []
  const centrals = []
  let offset = 0
  for (const entry of sorted) {
    const name = Buffer.from(entry.path, 'utf8')
    const data = entryBody(entry)
    const crc = crc32(data)
    const compressed = deflateRawSync(data)
    // Bit 11 (UTF-8 names) only when the path is not plain ASCII.
    const flags = /^[\x20-\x7e]*$/.test(entry.path) ? 0 : 0x0800

    const local = Buffer.alloc(30)
    local.writeUInt32LE(0x04034b50, 0)
    local.writeUInt16LE(VERSION, 4)
    local.writeUInt16LE(flags, 6)
    local.writeUInt16LE(METHOD_DEFLATE, 8)
    local.writeUInt16LE(DOS_TIME, 10)
    local.writeUInt16LE(DOS_DATE, 12)
    local.writeUInt32LE(crc, 14)
    local.writeUInt32LE(compressed.length, 18)
    local.writeUInt32LE(data.length, 22)
    local.writeUInt16LE(name.length, 26)
    local.writeUInt16LE(0, 28)

    const central = Buffer.alloc(46)
    central.writeUInt32LE(0x02014b50, 0)
    central.writeUInt16LE(VERSION, 4) // version made by: MS-DOS, 2.0
    central.writeUInt16LE(VERSION, 6)
    central.writeUInt16LE(flags, 8)
    central.writeUInt16LE(METHOD_DEFLATE, 10)
    central.writeUInt16LE(DOS_TIME, 12)
    central.writeUInt16LE(DOS_DATE, 14)
    central.writeUInt32LE(crc, 16)
    central.writeUInt32LE(compressed.length, 20)
    central.writeUInt32LE(data.length, 24)
    central.writeUInt16LE(name.length, 28)
    central.writeUInt16LE(0, 30) // extra
    central.writeUInt16LE(0, 32) // comment
    central.writeUInt16LE(0, 34) // disk number start
    central.writeUInt16LE(0, 36) // internal attributes
    central.writeUInt32LE(0, 38) // external attributes
    central.writeUInt32LE(offset, 42)

    locals.push(local, name, compressed)
    centrals.push(central, name)
    offset += local.length + name.length + compressed.length
  }
  const directory = Buffer.concat(centrals)
  const eocd = Buffer.alloc(22)
  eocd.writeUInt32LE(0x06054b50, 0)
  eocd.writeUInt16LE(0, 4)
  eocd.writeUInt16LE(0, 6)
  eocd.writeUInt16LE(sorted.length, 8)
  eocd.writeUInt16LE(sorted.length, 10)
  eocd.writeUInt32LE(directory.length, 12)
  eocd.writeUInt32LE(offset, 16)
  eocd.writeUInt16LE(0, 20)
  return Buffer.concat([...locals, directory, eocd])
}

// ---------------------------------------------------------------------------
// Reference parser: the contract both real parsers implement
// ---------------------------------------------------------------------------

const KIND_PATTERNS = [
  ['history', /^streaming_history_audio_.*\.json$/i],
  ['library', /^yourlibrary\.json$/i],
  ['playlist', /^playlist.*\.json$/i],
]

// Which allow-list an entry's base name matches, or null when the entry must
// never be opened.
export function classifyEntry(path) {
  const base = baseName(path)
  for (const [kind, pattern] of KIND_PATTERNS) if (pattern.test(base)) return kind
  return null
}

const isObject = (value) => typeof value === 'object' && value !== null && !Array.isArray(value)

// UTF-8 text, standard JSON. Anything JSON.parse rejects (including a BOM) is
// `unreadable`; the parsers fail closed rather than guess.
const decodeJson = (body) => JSON.parse(body.toString('utf8'))

// Decodes a read file and counts its rows; throws when the JSON is broken or
// the top-level shape is wrong (both are `unreadable`).
function loadRecords(kind, body) {
  const data = decodeJson(body)
  if (kind === 'history') {
    if (!Array.isArray(data)) throw new Error('history file is not an array')
    return { rows: data.length, data }
  }
  if (!isObject(data)) throw new Error(`${kind} file is not an object`)
  if (kind === 'library') {
    const tracks = Array.isArray(data.tracks) ? data.tracks : []
    const artists = Array.isArray(data.artists) ? data.artists : []
    return { rows: tracks.length + artists.length, data: { tracks, artists } }
  }
  const playlists = Array.isArray(data.playlists) ? data.playlists : []
  let rows = 0
  const normalized = playlists.map((playlist) => {
    const items = isObject(playlist) && Array.isArray(playlist.items) ? playlist.items : []
    rows += items.length
    return { ...(isObject(playlist) ? playlist : {}), items }
  })
  return { rows, data: normalized }
}

// Inventory: what would be read (with row counts) and what is ignored (bytes
// only). `files` carries the decoded read files for `parse`; `error` is set
// when the archive is unreadable.
export function inspect(entries) {
  const classified = sortEntries(entries).map((entry) => ({
    path: entry.path,
    kind: classifyEntry(entry.path),
    body: entryBody(entry),
  }))
  const hasHistory = classified.some((file) => file.kind === 'history')
  const hasAccount = classified.some((file) => file.kind === 'library' || file.kind === 'playlist')
  const pkg = hasHistory ? 'spotify_extended' : hasAccount ? 'spotify_account' : null
  const readKinds = pkg === 'spotify_extended' ? ['history'] : pkg === 'spotify_account' ? ['library', 'playlist'] : []

  const read = []
  const ignored = []
  const files = []
  let error = pkg === null ? { code: 'unreadable', file: null } : null
  for (const file of classified) {
    if (!readKinds.includes(file.kind)) {
      ignored.push({ path: file.path, bytes: file.body.length })
      continue
    }
    let loaded = null
    try {
      loaded = loadRecords(file.kind, file.body)
    } catch {
      if (error === null) error = { code: 'unreadable', file: baseName(file.path) }
    }
    read.push({ path: file.path, rows: loaded === null ? null : loaded.rows })
    if (loaded !== null) files.push({ path: file.path, kind: file.kind, data: loaded.data })
  }
  return { inventory: { package: pkg, read, ignored }, files, error }
}

// Spotify id from a `spotify:track:<id>` / `spotify:artist:<id>` URI; null
// for anything else (null, wrong prefix, malformed tail).
export function spotifyIdFromUri(uri, kind) {
  if (typeof uri !== 'string') return null
  const prefix = `spotify:${kind}:`
  if (!uri.startsWith(prefix)) return null
  const tail = uri.slice(prefix.length)
  return SPOTIFY_ID.test(tail) ? tail : null
}

const asInteger = (value) => (typeof value === 'number' && Number.isFinite(value) ? Math.trunc(value) : 0)
// A JSON string, else null. Names and codes: an empty string is still a value.
const asString = (value) => (typeof value === 'string' ? value : null)
// A non-empty JSON string, else null. Only playlist descriptions use this.
const asText = (value) => (typeof value === 'string' && value.length > 0 ? value : null)

// Local day and hour for a UTC instant in an IANA zone. The zone offset is
// resolved with Intl once per UTC hour (at the hour's start) and cached; day
// and hour are then derived arithmetically from `ts + offset`, which stays
// correct for half-hour and quarter-hour zones.
export class ZoneClock {
  constructor(timeZone) {
    this.timeZone = timeZone
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
    this.offsets = new Map()
  }

  offsetMs(utcMs) {
    const hourStart = Math.floor(utcMs / 3_600_000) * 3_600_000
    let offset = this.offsets.get(hourStart)
    if (offset === undefined) {
      const parts = {}
      for (const part of this.format.formatToParts(new Date(hourStart))) {
        if (part.type !== 'literal') parts[part.type] = Number(part.value)
      }
      // Some ICU builds print midnight as "24" even with h23; normalize.
      const wall = Date.UTC(parts.year, parts.month - 1, parts.day, parts.hour % 24, parts.minute, parts.second)
      offset = wall - hourStart
      this.offsets.set(hourStart, offset)
    }
    return offset
  }

  local(utcMs) {
    const shifted = new Date(utcMs + this.offsetMs(utcMs))
    return { day: shifted.toISOString().slice(0, 10), hour: shifted.getUTCHours() }
  }
}

function parseExtended(files, option) {
  const clock = new ZoneClock(option.timeZone)
  const tracks = new Map() // platformId -> track row (insertion = first seen)
  const days = new Map() // `${platformId}|${day}` -> day row
  const countries = new Map()
  let unresolvedRows = 0
  let unresolvedPlays = 0

  for (const file of files) {
    for (const row of file.data) {
      if (!isObject(row)) continue
      if (row.incognito_mode === true && !option.includePrivateSessions) continue
      if (row.spotify_episode_uri != null || row.audiobook_uri != null) continue
      const msPlayed = asInteger(row.ms_played)
      const isPlay = msPlayed >= PLAY_THRESHOLD_MS
      const platformId = spotifyIdFromUri(row.spotify_track_uri, 'track')
      if (platformId === null) {
        unresolvedRows += 1
        if (isPlay) unresolvedPlays += 1
        continue
      }
      const utcMs = typeof row.ts === 'string' ? Date.parse(row.ts) : Number.NaN
      if (Number.isNaN(utcMs)) continue

      const isSkip = row.skipped === true || (row.skipped == null && row.reason_end === 'fwdbtn')
      const isComplete = row.reason_end === 'trackdone'
      const { day, hour } = clock.local(utcMs)

      let track = tracks.get(platformId)
      if (track === undefined) {
        track = { platformId, title: null, artist: null, album: null, durationMs: null }
        tracks.set(platformId, track)
      }
      if (track.title === null) track.title = asString(row.master_metadata_track_name)
      if (track.artist === null) track.artist = asString(row.master_metadata_album_artist_name)
      if (track.album === null) track.album = asString(row.master_metadata_album_album_name)
      if (isComplete && (track.durationMs === null || msPlayed > track.durationMs)) track.durationMs = msPlayed

      const key = `${platformId}|${day}`
      let dayRow = days.get(key)
      if (dayRow === undefined) {
        dayRow = { platformId, day, plays: 0, skips: 0, completes: 0, msPlayed: 0, hoursMask: 0 }
        days.set(key, dayRow)
      }
      dayRow.msPlayed += msPlayed
      if (isPlay) {
        dayRow.plays += 1
        dayRow.hoursMask |= 1 << hour
      }
      if (isSkip) dayRow.skips += 1
      if (isComplete) dayRow.completes += 1

      const country = asString(row.conn_country)
      if (country !== null) countries.set(country, (countries.get(country) ?? 0) + 1)
    }
  }

  const trackRows = [...tracks.values()]
    .sort((a, b) => compare(a.platformId, b.platformId))
    .map((track) => ({
      platformId: track.platformId,
      title: track.title ?? '',
      artist: track.artist ?? '',
      album: track.album,
      durationMs: track.durationMs,
    }))
  const dayRows = [...days.values()]
    .filter((row) => row.plays > 0 || row.skips > 0)
    .sort((a, b) => compare(a.platformId, b.platformId) || compare(a.day, b.day))
    .map((row) => ({
      platformId: row.platformId,
      day: row.day,
      plays: row.plays,
      skips: row.skips,
      completes: row.completes,
      msPlayed: row.msPlayed,
      hoursMask: row.hoursMask,
    }))

  let country = null
  let countryCount = 0
  for (const [code, count] of countries) {
    if (count > countryCount || (count === countryCount && compare(code, country) < 0)) {
      country = code
      countryCount = count
    }
  }
  const dayValues = dayRows.map((row) => row.day).sort(compare)

  return {
    source: 'spotify_export',
    package: 'spotify_extended',
    timeZone: option.timeZone,
    country,
    tracks: trackRows,
    days: dayRows,
    library: [],
    artists: [],
    playlists: [],
    unresolved: { rows: unresolvedRows, plays: unresolvedPlays },
    ledgerFrom: dayValues.length > 0 ? dayValues[0] : null,
    ledgerTo: dayValues.length > 0 ? dayValues[dayValues.length - 1] : null,
  }
}

const DATE_ONLY = /^(\d{4})-(\d{2})-(\d{2})$/

// `YYYY-MM-DD` -> epoch ms of that date's midnight UTC; anything else -> null.
export function epochMsFromExportDate(value) {
  if (typeof value !== 'string') return null
  const match = DATE_ONLY.exec(value)
  if (match === null) return null
  const ms = Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3]))
  return Number.isNaN(ms) ? null : ms
}

export const playlistKey = (name, ordinal) =>
  createHash('sha256').update(`${name} ${ordinal}`, 'utf8').digest('hex')

function parseAccount(files, option) {
  const tracks = new Map() // platformId -> track row, library naming first
  const library = new Map()
  const artists = []
  const playlists = []
  let unresolvedRows = 0

  const rememberTrack = (platformId, title, artist, album) => {
    if (tracks.has(platformId)) return
    tracks.set(platformId, { platformId, title: title ?? '', artist: artist ?? '', album, durationMs: null })
  }

  for (const file of files) {
    if (file.kind !== 'library') continue
    for (const liked of file.data.tracks) {
      if (!isObject(liked)) continue
      const platformId = spotifyIdFromUri(liked.uri, 'track')
      if (platformId === null) continue
      rememberTrack(platformId, asString(liked.track), asString(liked.artist), asString(liked.album))
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
    for (const followed of file.data.artists) {
      if (!isObject(followed)) continue
      const name = asString(followed.name)
      if (name === null) continue
      artists.push({ name, spotifyId: spotifyIdFromUri(followed.uri, 'artist') })
    }
  }

  let ordinal = 0
  for (const file of files) {
    if (file.kind !== 'playlist') continue
    for (const playlist of file.data) {
      const name = asString(playlist.name) ?? ''
      const entries = playlist.items.map((item, position) => {
        const entry = { position, platformId: null, title: '', artist: '', album: null, addedAt: null }
        const record = isObject(item) ? item : {}
        if (isObject(record.track)) {
          entry.platformId = spotifyIdFromUri(record.track.trackUri, 'track')
          entry.title = asString(record.track.trackName) ?? ''
          entry.artist = asString(record.track.artistName) ?? ''
          entry.album = asString(record.track.albumName)
        } else if (isObject(record.localTrack)) {
          entry.title = asString(record.localTrack.trackName) ?? ''
          entry.artist = asString(record.localTrack.artistName) ?? ''
          entry.album = asString(record.localTrack.albumName)
        } else if (isObject(record.episode)) {
          entry.title = asString(record.episode.episodeName) ?? ''
          entry.artist = asString(record.episode.showName) ?? ''
        }
        entry.addedAt = epochMsFromExportDate(record.addedDate)
        if (entry.platformId === null) unresolvedRows += 1
        else rememberTrack(entry.platformId, entry.title, entry.artist, entry.album)
        return entry
      })
      playlists.push({
        ordinal,
        key: playlistKey(name, ordinal),
        name,
        description: asText(playlist.description),
        lastModifiedAt: epochMsFromExportDate(playlist.lastModifiedDate),
        entries,
      })
      ordinal += 1
    }
  }

  return {
    source: 'spotify_export',
    package: 'spotify_account',
    timeZone: option.timeZone,
    country: null,
    tracks: [...tracks.values()].sort((a, b) => compare(a.platformId, b.platformId)),
    days: [],
    library: [...library.values()].sort((a, b) => compare(a.platformId, b.platformId)),
    artists: artists.sort((a, b) => compare(a.name, b.name) || compareNullLast(a.spotifyId, b.spotifyId)),
    playlists,
    unresolved: { rows: unresolvedRows, plays: 0 },
    ledgerFrom: null,
    ledgerTo: null,
  }
}

// The expected document for one case and option.
export function expectedFor(entries, option) {
  const { inventory, files, error } = inspect(entries)
  if (error !== null) return { inventory, error }
  const snapshot = inventory.package === 'spotify_extended'
    ? parseExtended(files, option)
    : parseAccount(files, option)
  return { inventory, snapshot }
}

// ---------------------------------------------------------------------------
// Case loading and validation
// ---------------------------------------------------------------------------

const CASE_NAME = /^[a-z0-9][a-z0-9-]*$/
const OPTION_NAME = /^[a-z0-9][a-z0-9-]*$/
const PACKAGES = new Set(['spotify_extended', 'spotify_account', null])

function walkStrings(value, visit) {
  if (typeof value === 'string') visit(value)
  else if (Array.isArray(value)) for (const item of value) walkStrings(item, visit)
  else if (isObject(value)) for (const item of Object.values(value)) walkStrings(item, visit)
}

function validateCase(name, def) {
  const fail = (message) => {
    throw new Error(`case ${name}: ${message}`)
  }
  if (!CASE_NAME.test(name)) fail('directory name must be lowercase letters, digits, and hyphens')
  if (!isObject(def)) fail('case.json must be an object')
  if (!PACKAGES.has(def.package)) fail('package must be spotify_extended, spotify_account, or null')
  if (!Array.isArray(def.entries) || def.entries.length === 0) fail('entries must be a non-empty array')
  const paths = new Set()
  for (const entry of def.entries) {
    if (!isObject(entry) || typeof entry.path !== 'string') fail('every entry needs a string path')
    const { path } = entry
    if (path.length === 0 || path.startsWith('/') || path.includes('\\') || path.split('/').includes('..') || path.endsWith('/')) {
      fail(`entry path ${JSON.stringify(path)} must be a relative file path with forward slashes`)
    }
    if (paths.has(path)) fail(`duplicate entry path ${path}`)
    paths.add(path)
    const kinds = ['json', 'text', 'sentinel'].filter((key) => Object.hasOwn(entry, key))
    if (kinds.length !== 1) fail(`entry ${path} needs exactly one of json, text, sentinel`)
    if (kinds[0] === 'sentinel' && entry.sentinel !== true) fail(`entry ${path}: sentinel must be true`)
    if (kinds[0] === 'text' && typeof entry.text !== 'string') fail(`entry ${path}: text must be a string`)
    if (kinds[0] === 'json') {
      // Authoring guard: every Spotify track/artist URI in fixture JSON has a
      // well-formed 22-character id, so a typo cannot silently become an
      // "unresolved" row.
      walkStrings(entry.json, (text) => {
        for (const kind of ['track', 'artist']) {
          if (text.startsWith(`spotify:${kind}:`) && spotifyIdFromUri(text, kind) === null) {
            fail(`entry ${path}: malformed ${kind} URI ${text}`)
          }
        }
      })
    }
  }
  if (!Array.isArray(def.options) || def.options.length === 0) fail('options must be a non-empty array')
  const optionNames = new Set()
  for (const option of def.options) {
    if (!isObject(option) || !OPTION_NAME.test(option.name ?? '')) fail('every option needs a file-safe name')
    if (optionNames.has(option.name)) fail(`duplicate option ${option.name}`)
    optionNames.add(option.name)
    if (typeof option.timeZone !== 'string' || option.timeZone.length === 0) fail(`option ${option.name}: timeZone required`)
    try {
      new Intl.DateTimeFormat('en-US', { timeZone: option.timeZone })
    } catch {
      fail(`option ${option.name}: unknown time zone ${option.timeZone}`)
    }
    if (typeof option.includePrivateSessions !== 'boolean') fail(`option ${option.name}: includePrivateSessions must be a boolean`)
  }
  if (!optionNames.has('default')) fail('an option named "default" is required')
  const { inventory } = inspect(def.entries)
  if (inventory.package !== def.package) {
    fail(`declared package ${def.package} but the entries classify as ${inventory.package}`)
  }
}

export function loadCases() {
  const names = readdirSync(SRC, { withFileTypes: true })
    .filter((dirent) => dirent.isDirectory())
    .map((dirent) => dirent.name)
    .sort(compare)
  return names.map((name) => {
    const def = JSON.parse(readFileSync(join(SRC, name, 'case.json'), 'utf8'))
    validateCase(name, def)
    return { name, ...def }
  })
}

// ---------------------------------------------------------------------------
// Build and check
// ---------------------------------------------------------------------------

// Every output the suite consists of, keyed by path relative to ROOT.
export function buildAll(cases = loadCases()) {
  const outputs = new Map()
  for (const def of cases) {
    outputs.set(`${def.name}/archive.zip`, buildZip(def.entries))
    for (const option of def.options) {
      outputs.set(
        `${def.name}/expected.${option.name}.json`,
        Buffer.from(serializeExpected(expectedFor(def.entries, option)), 'utf8'),
      )
    }
  }
  return outputs
}

const OUTPUT_FILE = /^(archive\.zip|expected\.[a-z0-9-]+\.json)$/

// Problems found by comparing a fresh in-memory build with the committed
// files: missing, differing, and stale outputs. Empty when up to date.
export function check(cases = loadCases()) {
  const problems = []
  const outputs = buildAll(cases)
  for (const [relative, bytes] of outputs) {
    const absolute = join(ROOT, relative)
    if (!existsSync(absolute)) problems.push(`missing: ${relative}`)
    else if (!readFileSync(absolute).equals(bytes)) problems.push(`differs: ${relative}`)
  }
  const caseNames = new Set(cases.map((def) => def.name))
  for (const dirent of readdirSync(ROOT, { withFileTypes: true })) {
    if (!dirent.isDirectory() || dirent.name === 'src' || dirent.name.startsWith('.')) continue
    if (!caseNames.has(dirent.name)) {
      problems.push(`stale case directory: ${dirent.name}`)
      continue
    }
    for (const file of readdirSync(join(ROOT, dirent.name))) {
      const relative = `${dirent.name}/${file}`
      if (!outputs.has(relative)) problems.push(OUTPUT_FILE.test(file) ? `stale: ${relative}` : `unexpected: ${relative}`)
    }
  }
  return problems
}

export function writeAll(cases = loadCases()) {
  const outputs = buildAll(cases)
  for (const [relative, bytes] of outputs) {
    const absolute = join(ROOT, relative)
    mkdirSync(dirname(absolute), { recursive: true })
    writeFileSync(absolute, bytes)
  }
  return outputs
}

function main(argv) {
  if (argv.includes('--check')) {
    const problems = check()
    if (problems.length > 0) {
      for (const problem of problems) console.error(problem)
      console.error(`${problems.length} fixture file(s) out of date; run: node fixtures/listening-exports/build.mjs`)
      process.exit(1)
    }
    console.log('listening-export fixtures are up to date')
    return
  }
  const cases = loadCases()
  const outputs = writeAll(cases)
  console.log(`wrote ${outputs.size} files for ${cases.length} cases`)
}

if (process.argv[1] !== undefined && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2))
}
