#!/usr/bin/env node
// Deterministic builder for the listening-export fixture suite.
//
//   node fixtures/listening-exports/build.mjs          rebuild every case
//   node fixtures/listening-exports/build.mjs --check  compare the committed files with a fresh build, exit 1 on any problem
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
import { deflateRawSync, inflateRawSync } from 'node:zlib'

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

// Name fallbacks: the server rejects empty names, so a snapshot never carries one.
export const UNKNOWN_ARTIST = 'Unknown Artist'
export const UNTITLED = 'Untitled'

export const SENTINEL_TARGET_BYTES = 2048

// The body of an entry a parser must never open: `DO-NOT-READ:<path>\n`
// repeated until the body is at least SENTINEL_TARGET_BYTES long.
export function sentinelBody(path) {
  const unit = `DO-NOT-READ:${path}\n`
  const repeats = Math.ceil(SENTINEL_TARGET_BYTES / Buffer.byteLength(unit, 'utf8'))
  return Buffer.from(unit.repeat(repeats), 'utf8')
}

export const isDirectoryEntry = (entry) => entry.directory === true

// Bytes of a case entry as written into the archive. A directory entry has none.
export function entryBody(entry) {
  if (isDirectoryEntry(entry)) return Buffer.alloc(0)
  if (entry.sentinel === true) return sentinelBody(entry.path)
  if (typeof entry.text === 'string') return Buffer.from(entry.text, 'utf8')
  if (typeof entry.bytes === 'string') return Buffer.from(entry.bytes, 'base64')
  if (Object.hasOwn(entry, 'json')) {
    return Buffer.from(`${JSON.stringify(entry.json, null, 2)}\n`, 'utf8')
  }
  throw new Error(`entry ${entry.path}: needs exactly one of json, text, bytes, sentinel, directory`)
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
export const METHOD_STORED = 0
export const METHOD_DEFLATE = 8
export const FLAG_DATA_DESCRIPTOR = 0x0008 // bit 3: CRC and sizes follow the data
export const FLAG_UTF8 = 0x0800 // bit 11: the name is UTF-8
export const DIRECTORY_ATTRIBUTE = 0x10 // MS-DOS directory bit, external attributes
const VERSION = 20
const LOCAL_SIGNATURE = 0x04034b50
const CENTRAL_SIGNATURE = 0x02014b50
const EOCD_SIGNATURE = 0x06054b50
const DESCRIPTOR_SIGNATURE = 0x08074b50

const sortEntries = (entries) => [...entries].sort((a, b) => compare(a.path, b.path))

// Everything about an entry's encoding that does not depend on the deflate
// stream: what the structural check compares a committed archive against.
export function encodedEntry(entry) {
  const data = entryBody(entry)
  const directory = isDirectoryEntry(entry)
  const dataDescriptor = entry.dataDescriptor === true
  return {
    name: entry.path,
    directory,
    dataDescriptor,
    // Bit 11 (UTF-8 names) only when the path is not plain ASCII.
    flags: (/^[\x20-\x7e]*$/.test(entry.path) ? 0 : FLAG_UTF8) | (dataDescriptor ? FLAG_DATA_DESCRIPTOR : 0),
    method: directory ? METHOD_STORED : METHOD_DEFLATE,
    externalAttributes: directory ? DIRECTORY_ATTRIBUTE : 0,
    crc: crc32(data),
    size: data.length,
    data,
  }
}

export function buildZip(entries) {
  const sorted = sortEntries(entries)
  const parts = []
  const centrals = []
  let offset = 0
  for (const entry of sorted) {
    const spec = encodedEntry(entry)
    const name = Buffer.from(spec.name, 'utf8')
    const compressed = spec.method === METHOD_DEFLATE ? deflateRawSync(spec.data) : spec.data

    // With a data descriptor the local header carries zeros and the real
    // values trail the data; the central directory always has them.
    const local = Buffer.alloc(30)
    local.writeUInt32LE(LOCAL_SIGNATURE, 0)
    local.writeUInt16LE(VERSION, 4)
    local.writeUInt16LE(spec.flags, 6)
    local.writeUInt16LE(spec.method, 8)
    local.writeUInt16LE(DOS_TIME, 10)
    local.writeUInt16LE(DOS_DATE, 12)
    local.writeUInt32LE(spec.dataDescriptor ? 0 : spec.crc, 14)
    local.writeUInt32LE(spec.dataDescriptor ? 0 : compressed.length, 18)
    local.writeUInt32LE(spec.dataDescriptor ? 0 : spec.size, 22)
    local.writeUInt16LE(name.length, 26)
    local.writeUInt16LE(0, 28)
    const pieces = [local, name, compressed]
    if (spec.dataDescriptor) {
      const descriptor = Buffer.alloc(16)
      descriptor.writeUInt32LE(DESCRIPTOR_SIGNATURE, 0)
      descriptor.writeUInt32LE(spec.crc, 4)
      descriptor.writeUInt32LE(compressed.length, 8)
      descriptor.writeUInt32LE(spec.size, 12)
      pieces.push(descriptor)
    }

    const central = Buffer.alloc(46)
    central.writeUInt32LE(CENTRAL_SIGNATURE, 0)
    central.writeUInt16LE(VERSION, 4) // version made by: MS-DOS, 2.0
    central.writeUInt16LE(VERSION, 6)
    central.writeUInt16LE(spec.flags, 8)
    central.writeUInt16LE(spec.method, 10)
    central.writeUInt16LE(DOS_TIME, 12)
    central.writeUInt16LE(DOS_DATE, 14)
    central.writeUInt32LE(spec.crc, 16)
    central.writeUInt32LE(compressed.length, 20)
    central.writeUInt32LE(spec.size, 24)
    central.writeUInt16LE(name.length, 28)
    central.writeUInt16LE(0, 30) // extra
    central.writeUInt16LE(0, 32) // comment
    central.writeUInt16LE(0, 34) // disk number start
    central.writeUInt16LE(0, 36) // internal attributes
    central.writeUInt32LE(spec.externalAttributes, 38)
    central.writeUInt32LE(offset, 42)

    parts.push(...pieces)
    centrals.push(central, name)
    for (const piece of pieces) offset += piece.length
  }
  const directory = Buffer.concat(centrals)
  const eocd = Buffer.alloc(22)
  eocd.writeUInt32LE(EOCD_SIGNATURE, 0)
  eocd.writeUInt16LE(0, 4)
  eocd.writeUInt16LE(0, 6)
  eocd.writeUInt16LE(sorted.length, 8)
  eocd.writeUInt16LE(sorted.length, 10)
  eocd.writeUInt32LE(directory.length, 12)
  eocd.writeUInt32LE(offset, 16)
  eocd.writeUInt16LE(0, 20)
  return Buffer.concat([...parts, directory, eocd])
}

// ---------------------------------------------------------------------------
// ZIP reader: central directory -> local headers -> (data descriptor) -> body
// ---------------------------------------------------------------------------

// Reads an archive the way the structural check and verify.test.mjs need it:
// every central-directory record, its local header, the trailing data
// descriptor when bit 3 is set, and the inflated body. Throws on anything
// malformed or unsupported.
export function readArchive(buffer) {
  const fail = (message) => {
    throw new Error(message)
  }
  if (buffer.length < 22) fail('too short for an end-of-central-directory record')
  const eocd = buffer.length - 22
  if (buffer.readUInt32LE(eocd) !== EOCD_SIGNATURE) fail('no end-of-central-directory record at the end (archive comment?)')
  if (buffer.readUInt16LE(eocd + 4) !== 0 || buffer.readUInt16LE(eocd + 6) !== 0) fail('multi-disk archive')
  const count = buffer.readUInt16LE(eocd + 10)
  if (buffer.readUInt16LE(eocd + 8) !== count) fail('entry counts disagree')
  const dirSize = buffer.readUInt32LE(eocd + 12)
  const dirOffset = buffer.readUInt32LE(eocd + 16)
  if (buffer.readUInt16LE(eocd + 20) !== 0) fail('archive comment present')
  if (dirOffset + dirSize !== eocd) fail('central directory does not end at the EOCD record')

  const entries = []
  let p = dirOffset
  for (let i = 0; i < count; i += 1) {
    if (p + 46 > eocd || buffer.readUInt32LE(p) !== CENTRAL_SIGNATURE) fail(`central header ${i}: bad signature`)
    const flags = buffer.readUInt16LE(p + 8)
    const method = buffer.readUInt16LE(p + 10)
    const time = buffer.readUInt16LE(p + 12)
    const date = buffer.readUInt16LE(p + 14)
    const crc = buffer.readUInt32LE(p + 16)
    const compressedSize = buffer.readUInt32LE(p + 20)
    const size = buffer.readUInt32LE(p + 24)
    const nameLength = buffer.readUInt16LE(p + 28)
    const extraLength = buffer.readUInt16LE(p + 30)
    const commentLength = buffer.readUInt16LE(p + 32)
    const internalAttributes = buffer.readUInt16LE(p + 36)
    const externalAttributes = buffer.readUInt32LE(p + 38)
    const localOffset = buffer.readUInt32LE(p + 42)
    const name = buffer.toString('utf8', p + 46, p + 46 + nameLength)
    p += 46 + nameLength + extraLength + commentLength

    if (localOffset + 30 > dirOffset || buffer.readUInt32LE(localOffset) !== LOCAL_SIGNATURE) fail(`${name}: bad local header signature`)
    const local = {
      flags: buffer.readUInt16LE(localOffset + 6),
      method: buffer.readUInt16LE(localOffset + 8),
      time: buffer.readUInt16LE(localOffset + 10),
      date: buffer.readUInt16LE(localOffset + 12),
      crc: buffer.readUInt32LE(localOffset + 14),
      compressedSize: buffer.readUInt32LE(localOffset + 18),
      size: buffer.readUInt32LE(localOffset + 22),
      extraLength: buffer.readUInt16LE(localOffset + 28),
    }
    const localNameLength = buffer.readUInt16LE(localOffset + 26)
    if (buffer.toString('utf8', localOffset + 30, localOffset + 30 + localNameLength) !== name) fail(`${name}: local header name differs`)
    const dataStart = localOffset + 30 + localNameLength + local.extraLength
    if (dataStart + compressedSize > dirOffset) fail(`${name}: data runs past the central directory`)
    const compressed = buffer.subarray(dataStart, dataStart + compressedSize)
    let descriptor = null
    if (flags & FLAG_DATA_DESCRIPTOR) {
      const d = dataStart + compressedSize
      if (d + 16 > dirOffset || buffer.readUInt32LE(d) !== DESCRIPTOR_SIGNATURE) fail(`${name}: data descriptor missing`)
      descriptor = {
        crc: buffer.readUInt32LE(d + 4),
        compressedSize: buffer.readUInt32LE(d + 8),
        size: buffer.readUInt32LE(d + 12),
      }
    }
    let data
    if (method === METHOD_DEFLATE) {
      try {
        data = inflateRawSync(compressed)
      } catch (error) {
        fail(`${name}: inflate failed: ${error.message}`)
      }
    } else if (method === METHOD_STORED) {
      data = Buffer.from(compressed)
    } else {
      fail(`${name}: unsupported method ${method}`)
    }
    entries.push({
      name,
      flags,
      method,
      time,
      date,
      crc,
      compressedSize,
      size,
      extraLength,
      commentLength,
      internalAttributes,
      externalAttributes,
      localOffset,
      local,
      descriptor,
      data,
    })
  }
  if (p !== dirOffset + dirSize) fail('central directory size does not match its records')
  return entries
}

// Structural comparison of an archive with its case definition: entry names
// and order, flags, method, DOS date/time, CRC-32, sizes, local-header and
// data-descriptor consistency, attributes, and the inflated bodies. The
// compressed bytes are never compared, so a deflate difference between zlib
// builds cannot fail the check. Empty when the archive is exactly the case.
export function archiveProblems(buffer, entries) {
  let archive
  try {
    archive = readArchive(buffer)
  } catch (error) {
    return [error.message]
  }
  const expected = sortEntries(entries).map(encodedEntry)
  const names = archive.map((entry) => entry.name)
  const expectedNames = expected.map((entry) => entry.name)
  if (names.length !== expectedNames.length || names.some((name, i) => name !== expectedNames[i])) {
    return [`entries are ${JSON.stringify(names)}, expected ${JSON.stringify(expectedNames)}`]
  }
  const problems = []
  expected.forEach((spec, i) => {
    const entry = archive[i]
    const check = (field, actual, wanted) => {
      if (actual !== wanted) problems.push(`${spec.name}: ${field} is ${actual}, expected ${wanted}`)
    }
    check('flags', entry.flags, spec.flags)
    check('method', entry.method, spec.method)
    check('time', entry.time, DOS_TIME)
    check('date', entry.date, DOS_DATE)
    check('crc', entry.crc, spec.crc)
    check('size', entry.size, spec.size)
    check('extra field length', entry.extraLength, 0)
    check('comment length', entry.commentLength, 0)
    check('internal attributes', entry.internalAttributes, 0)
    check('external attributes', entry.externalAttributes, spec.externalAttributes)
    check('local flags', entry.local.flags, spec.flags)
    check('local method', entry.local.method, spec.method)
    check('local time', entry.local.time, DOS_TIME)
    check('local date', entry.local.date, DOS_DATE)
    check('local extra field length', entry.local.extraLength, 0)
    if (spec.dataDescriptor) {
      check('local crc (data descriptor entry)', entry.local.crc, 0)
      check('local compressed size (data descriptor entry)', entry.local.compressedSize, 0)
      check('local size (data descriptor entry)', entry.local.size, 0)
      check('descriptor crc', entry.descriptor.crc, spec.crc)
      check('descriptor compressed size', entry.descriptor.compressedSize, entry.compressedSize)
      check('descriptor size', entry.descriptor.size, spec.size)
    } else {
      check('local crc', entry.local.crc, spec.crc)
      check('local compressed size', entry.local.compressedSize, entry.compressedSize)
      check('local size', entry.local.size, spec.size)
    }
    if (spec.method === METHOD_STORED) check('stored compressed size', entry.compressedSize, spec.size)
    if (!entry.data.equals(spec.data)) problems.push(`${spec.name}: body differs from the case entry`)
  })
  return problems
}

// ---------------------------------------------------------------------------
// Reference parser: the contract both real parsers implement
// ---------------------------------------------------------------------------

// Allow-list matching folds ASCII letters only, on the whole base name.
const asciiLower = (text) => text.replace(/[A-Z]/g, (letter) => String.fromCharCode(letter.charCodeAt(0) + 32))

const KIND_PATTERNS = [
  ['history', /^streaming_history_audio_.*\.json$/],
  ['library', /^yourlibrary\.json$/],
  ['playlist', /^playlist.*\.json$/],
]

// Which allow-list an entry's base name matches, or null when the entry must
// never be opened.
export function classifyEntry(path) {
  const base = asciiLower(baseName(path))
  for (const [kind, pattern] of KIND_PATTERNS) if (pattern.test(base)) return kind
  return null
}

const isObject = (value) => typeof value === 'object' && value !== null && !Array.isArray(value)

// UTF-8 with a leading byte-order mark stripped; any malformed sequence
// throws (fatal decoding), and so does anything JSON.parse rejects. Both are
// `unreadable`: the parsers fail closed rather than guess.
const utf8 = new TextDecoder('utf-8', { fatal: true })
const decodeJson = (body) => JSON.parse(utf8.decode(body))

// Decodes a read file and counts its rows; throws when the bytes or the JSON
// are broken or the top-level shape is wrong (all `unreadable`).
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
// only). Directory entries are skipped entirely. `files` carries the decoded
// read files for `parse`; `error` is set when the archive is unreadable.
export function inspect(entries) {
  const classified = sortEntries(entries)
    .filter((entry) => !isDirectoryEntry(entry))
    .map((entry) => ({ path: entry.path, kind: classifyEntry(entry.path), body: entryBody(entry) }))
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

// A JSON number truncated toward zero; anything else counts as 0.
const asInteger = (value) => (typeof value === 'number' && Number.isFinite(value) ? Math.trunc(value) : 0)
// A non-empty JSON string, else null. Every name and text field uses this:
// `""`, null, and non-strings all count as absent.
const asText = (value) => (typeof value === 'string' && value.length > 0 ? value : null)

// The only `ts` grammar accepted: `YYYY-MM-DDTHH:MM:SS[.fff]Z`. The instant is
// Date.UTC of the captured fields; anything else is null (the row is dropped).
const TS = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,3}))?Z$/
export function instantFromTs(value) {
  if (typeof value !== 'string') return null
  const match = TS.exec(value)
  if (match === null) return null
  if (Number(match[1]) < 1900) return null // years before 1900 are outside the grammar (step 4)
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

const COUNTRY = /^[A-Z]{2}$/

// Local day and hour for a UTC instant in an IANA zone. Exact conversion of
// each instant is normative. Per UTC hour the zone offset is cached only when
// it is the same at the start and at the end of that hour; an hour that
// contains a transition (a half-hour zone's DST change, for example) converts
// every instant in it exactly.
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
    this.hours = new Map() // UTC hour start -> offset ms, or null when the hour must convert exactly
  }

  // The zone's offset at one instant, from the wall clock Intl gives for it.
  offsetAt(utcMs) {
    const parts = {}
    for (const part of this.format.formatToParts(new Date(utcMs))) {
      if (part.type !== 'literal') parts[part.type] = Number(part.value)
    }
    // Some ICU builds print midnight as "24" even with h23; normalize.
    const wall = Date.UTC(parts.year, parts.month - 1, parts.day, parts.hour % 24, parts.minute, parts.second)
    return wall - Math.floor(utcMs / 1000) * 1000
  }

  offsetMs(utcMs) {
    const hourStart = Math.floor(utcMs / 3_600_000) * 3_600_000
    let cached = this.hours.get(hourStart)
    if (cached === undefined) {
      const start = this.offsetAt(hourStart)
      cached = start === this.offsetAt(hourStart + 3_600_000) ? start : null
      this.hours.set(hourStart, cached)
    }
    return cached ?? this.offsetAt(utcMs)
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
      const utcMs = instantFromTs(row.ts)
      if (utcMs === null) continue

      const isSkip = row.skipped === true || (row.skipped == null && row.reason_end === 'fwdbtn')
      const isComplete = row.reason_end === 'trackdone'
      const { day, hour } = clock.local(utcMs)

      let track = tracks.get(platformId)
      if (track === undefined) {
        track = { platformId, title: null, artist: null, album: null, durationMs: null }
        tracks.set(platformId, track)
      }
      if (track.title === null) track.title = asText(row.master_metadata_track_name)
      if (track.artist === null) track.artist = asText(row.master_metadata_album_artist_name)
      if (track.album === null) track.album = asText(row.master_metadata_album_album_name)
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

      // Only rows that get this far (kept, resolved, with a valid `ts`) count.
      const country = row.conn_country
      if (typeof country === 'string' && COUNTRY.test(country)) countries.set(country, (countries.get(country) ?? 0) + 1)
    }
  }

  const trackRows = [...tracks.values()]
    .sort((a, b) => compare(a.platformId, b.platformId))
    .map((track) => ({
      platformId: track.platformId,
      title: track.title ?? track.platformId,
      artist: track.artist ?? UNKNOWN_ARTIST,
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
  if (Number(match[1]) < 1900) return null // same year floor as `ts` (interpretation 13)
  const ms = Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3]))
  return Number.isNaN(ms) ? null : ms
}

export const playlistKey = (name, ordinal) =>
  createHash('sha256').update(`${name} ${ordinal}`, 'utf8').digest('hex')

function parseAccount(files, option) {
  const tracks = new Map() // platformId -> names, each the first non-empty value seen, library first
  const library = new Map()
  const artists = []
  const playlists = []
  let unresolvedRows = 0

  const noteTrack = (platformId, title, artist, album) => {
    let track = tracks.get(platformId)
    if (track === undefined) {
      track = { platformId, title: null, artist: null, album: null }
      tracks.set(platformId, track)
    }
    if (track.title === null) track.title = title
    if (track.artist === null) track.artist = artist
    if (track.album === null) track.album = album
  }

  for (const file of files) {
    if (file.kind !== 'library') continue
    for (const liked of file.data.tracks) {
      if (!isObject(liked)) continue
      const platformId = spotifyIdFromUri(liked.uri, 'track')
      if (platformId === null) continue // null, local, or malformed uri: dropped entirely
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
    for (const followed of file.data.artists) {
      if (!isObject(followed)) continue
      const name = asText(followed.name)
      if (name === null) continue
      artists.push({ name, spotifyId: spotifyIdFromUri(followed.uri, 'artist') })
    }
  }

  let ordinal = 0
  for (const file of files) {
    if (file.kind !== 'playlist') continue
    for (const playlist of file.data) {
      const name = asText(playlist.name) ?? UNTITLED
      const entries = playlist.items.map((item, position) => {
        const record = isObject(item) ? item : {}
        let platformId = null
        let title = null
        let artist = null
        let album = null
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
        key: playlistKey(name, ordinal),
        name,
        description: asText(playlist.description),
        lastModifiedAt: epochMsFromExportDate(playlist.lastModifiedDate),
        entries,
      })
      ordinal += 1
    }
  }

  const trackRows = [...tracks.values()]
    .sort((a, b) => compare(a.platformId, b.platformId))
    .map((track) => ({
      platformId: track.platformId,
      title: track.title ?? track.platformId,
      artist: track.artist ?? UNKNOWN_ARTIST,
      album: track.album,
      durationMs: null,
    }))

  return {
    source: 'spotify_export',
    package: 'spotify_account',
    timeZone: option.timeZone,
    country: null,
    tracks: trackRows,
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
const BASE64 = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/
const BODY_KINDS = ['json', 'text', 'bytes', 'sentinel']

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
    if (path.length === 0 || path.startsWith('/') || path.includes('\\') || path.split('/').includes('..') || path.split('/').includes('')) {
      // A directory path's trailing slash leaves one empty segment; allow only that.
      if (!(isDirectoryEntry(entry) && path.endsWith('/') && path.length > 1 && !path.slice(0, -1).split('/').includes(''))) {
        fail(`entry path ${JSON.stringify(path)} must be a relative path with forward slashes`)
      }
    }
    if (paths.has(path)) fail(`duplicate entry path ${path}`)
    paths.add(path)
    const kinds = BODY_KINDS.filter((key) => Object.hasOwn(entry, key))
    if (Object.hasOwn(entry, 'directory')) {
      if (entry.directory !== true) fail(`entry ${path}: directory must be true`)
      if (!path.endsWith('/')) fail(`entry ${path}: a directory entry's path must end with /`)
      if (kinds.length !== 0) fail(`entry ${path}: a directory entry has no body`)
      if (Object.hasOwn(entry, 'dataDescriptor')) fail(`entry ${path}: a directory entry cannot have a data descriptor`)
      continue
    }
    if (path.endsWith('/')) fail(`entry ${path}: only a directory entry's path ends with /`)
    if (kinds.length !== 1) fail(`entry ${path} needs exactly one of json, text, bytes, sentinel`)
    if (Object.hasOwn(entry, 'dataDescriptor') && typeof entry.dataDescriptor !== 'boolean') fail(`entry ${path}: dataDescriptor must be a boolean`)
    if (kinds[0] === 'sentinel' && entry.sentinel !== true) fail(`entry ${path}: sentinel must be true`)
    if (kinds[0] === 'text' && typeof entry.text !== 'string') fail(`entry ${path}: text must be a string`)
    if (kinds[0] === 'bytes' && (typeof entry.bytes !== 'string' || !BASE64.test(entry.bytes))) fail(`entry ${path}: bytes must be base64`)
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
const ARCHIVE_SUFFIX = '/archive.zip'

// Problems found by comparing the committed files with a fresh build: missing,
// differing, and stale outputs. `expected.*.json` files are compared byte for
// byte; archives structurally (see archiveProblems), so a deflate difference
// between zlib builds never flaps the check. Empty when up to date.
export function check(cases = loadCases()) {
  const problems = []
  const outputs = buildAll(cases)
  const byName = new Map(cases.map((def) => [def.name, def]))
  for (const [relative, bytes] of outputs) {
    const absolute = join(ROOT, relative)
    if (!existsSync(absolute)) {
      problems.push(`missing: ${relative}`)
      continue
    }
    const committed = readFileSync(absolute)
    if (relative.endsWith(ARCHIVE_SUFFIX)) {
      const def = byName.get(relative.slice(0, -ARCHIVE_SUFFIX.length))
      for (const problem of archiveProblems(committed, def.entries)) problems.push(`differs: ${relative}: ${problem}`)
    } else if (!committed.equals(bytes)) {
      problems.push(`differs: ${relative}`)
    }
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
