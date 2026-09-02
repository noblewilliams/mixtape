// Self-checks for the fixture suite. Run from the repo root:
//
//   node --test fixtures/listening-exports/verify.test.mjs
//
// Asserts that the committed files match a fresh build, that every archive
// holds exactly its case's entries (deterministically encoded), that sentinel
// entries are byte-identical to the sentinel body, and that every expected
// file follows the contract's shape, key order, and canonical order.

import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'
import { inflateRawSync } from 'node:zlib'

import {
  DOS_DATE,
  DOS_TIME,
  ROOT,
  buildAll,
  check,
  classifyEntry,
  compare,
  crc32,
  entryBody,
  loadCases,
  sentinelBody,
} from './build.mjs'

const cases = loadCases()

// ---------------------------------------------------------------------------
// A small, independent ZIP reader (central directory -> local headers)
// ---------------------------------------------------------------------------

function readArchive(buffer) {
  const eocd = buffer.length - 22
  assert.equal(buffer.readUInt32LE(eocd), 0x06054b50, 'EOCD signature at the end (no comment)')
  assert.equal(buffer.readUInt16LE(eocd + 4), 0, 'single disk')
  const count = buffer.readUInt16LE(eocd + 10)
  assert.equal(buffer.readUInt16LE(eocd + 8), count)
  const dirSize = buffer.readUInt32LE(eocd + 12)
  const dirOffset = buffer.readUInt32LE(eocd + 16)
  assert.equal(buffer.readUInt16LE(eocd + 20), 0, 'no archive comment')
  assert.equal(dirOffset + dirSize, eocd, 'central directory ends at the EOCD')

  const entries = []
  let p = dirOffset
  for (let i = 0; i < count; i += 1) {
    assert.equal(buffer.readUInt32LE(p), 0x02014b50, 'central header signature')
    const method = buffer.readUInt16LE(p + 10)
    const time = buffer.readUInt16LE(p + 12)
    const date = buffer.readUInt16LE(p + 14)
    const crc = buffer.readUInt32LE(p + 16)
    const compressedSize = buffer.readUInt32LE(p + 20)
    const size = buffer.readUInt32LE(p + 24)
    const nameLength = buffer.readUInt16LE(p + 28)
    const extraLength = buffer.readUInt16LE(p + 30)
    const commentLength = buffer.readUInt16LE(p + 32)
    const localOffset = buffer.readUInt32LE(p + 42)
    const name = buffer.toString('utf8', p + 46, p + 46 + nameLength)
    p += 46 + nameLength + extraLength + commentLength

    assert.equal(buffer.readUInt32LE(localOffset), 0x04034b50, `${name}: local header signature`)
    assert.equal(buffer.readUInt16LE(localOffset + 8), method, `${name}: local method matches`)
    assert.equal(buffer.readUInt16LE(localOffset + 10), time, `${name}: local time matches`)
    assert.equal(buffer.readUInt16LE(localOffset + 12), date, `${name}: local date matches`)
    assert.equal(buffer.readUInt32LE(localOffset + 14), crc, `${name}: local crc matches`)
    const localNameLength = buffer.readUInt16LE(localOffset + 26)
    const localExtraLength = buffer.readUInt16LE(localOffset + 28)
    assert.equal(buffer.toString('utf8', localOffset + 30, localOffset + 30 + localNameLength), name)
    const dataStart = localOffset + 30 + localNameLength + localExtraLength
    const compressed = buffer.subarray(dataStart, dataStart + compressedSize)
    const data = method === 8 ? inflateRawSync(compressed) : Buffer.from(compressed)
    entries.push({ name, method, time, date, crc, size, extraLength, commentLength, localExtraLength, data })
  }
  assert.equal(p, dirOffset + dirSize, 'central directory size matches its records')
  return entries
}

const readCommitted = (relative) => readFileSync(join(ROOT, relative))
const expectedFiles = (def) => def.options.map((option) => `${def.name}/expected.${option.name}.json`)

// ---------------------------------------------------------------------------
// Build determinism and --check
// ---------------------------------------------------------------------------

test('build.mjs --check passes against the committed files', () => {
  const result = spawnSync(process.execPath, [fileURLToPath(new URL('./build.mjs', import.meta.url)), '--check'], {
    encoding: 'utf8',
  })
  assert.equal(result.status, 0, `--check failed:\n${result.stdout}${result.stderr}`)
  assert.deepEqual(check(cases), [])
})

test('building twice produces identical bytes', () => {
  const first = buildAll(cases)
  const second = buildAll(cases)
  assert.deepEqual([...first.keys()], [...second.keys()])
  for (const [relative, bytes] of first) assert.ok(bytes.equals(second.get(relative)), `${relative} differs between builds`)
})

test('every case is covered by the required list', () => {
  const names = cases.map((def) => def.name)
  assert.deepEqual(names, [
    'account-basic',
    'account-duplicates',
    'account-empty-playlist',
    'account-liked-absent-from-history',
    'account-local-and-episode-entries',
    'account-pii-present',
    'extended-basic',
    'extended-malformed',
    'extended-nested-folder',
    'extended-podcasts-and-local',
    'extended-private-sessions',
    'extended-timezone',
    'extended-various-artists',
  ])
})

// ---------------------------------------------------------------------------
// Archives
// ---------------------------------------------------------------------------

for (const def of cases) {
  test(`${def.name}: archive.zip holds exactly the case entries, deterministically encoded`, () => {
    const entries = readArchive(readCommitted(`${def.name}/archive.zip`))
    const expectedPaths = def.entries.map((entry) => entry.path).sort(compare)
    assert.deepEqual(entries.map((entry) => entry.name), expectedPaths)
    for (const entry of entries) {
      const source = def.entries.find((candidate) => candidate.path === entry.name)
      assert.equal(entry.method, 8, `${entry.name}: deflate`)
      assert.equal(entry.time, DOS_TIME, `${entry.name}: fixed DOS time`)
      assert.equal(entry.date, DOS_DATE, `${entry.name}: fixed DOS date`)
      assert.equal(entry.extraLength, 0, `${entry.name}: no central extra field`)
      assert.equal(entry.localExtraLength, 0, `${entry.name}: no local extra field`)
      assert.equal(entry.commentLength, 0, `${entry.name}: no comment`)
      assert.equal(entry.size, entry.data.length, `${entry.name}: uncompressed size`)
      assert.equal(entry.crc, crc32(entry.data), `${entry.name}: CRC-32`)
      assert.ok(entry.data.equals(entryBody(source)), `${entry.name}: body matches the case entry`)
      if (Object.hasOwn(source, 'json')) {
        assert.deepEqual(JSON.parse(entry.data.toString('utf8')), source.json, `${entry.name}: JSON round-trips`)
      }
    }
  })

  const sentinels = def.entries.filter((entry) => entry.sentinel === true)
  if (sentinels.length > 0) {
    test(`${def.name}: sentinel entries are byte-identical to the sentinel body and never allow-listed`, () => {
      const entries = readArchive(readCommitted(`${def.name}/archive.zip`))
      for (const sentinel of sentinels) {
        const entry = entries.find((candidate) => candidate.name === sentinel.path)
        assert.ok(entry, `${sentinel.path} present`)
        const body = sentinelBody(sentinel.path)
        assert.ok(entry.data.equals(body), `${sentinel.path}: body is the sentinel`)
        assert.ok(body.length >= 2048, `${sentinel.path}: at least 2 KB`)
        assert.ok(entry.data.toString('utf8').startsWith(`DO-NOT-READ:${sentinel.path}\n`))
        assert.equal(classifyEntry(sentinel.path), null, `${sentinel.path}: must not match the allow-list`)
      }
    })
  }
}

// ---------------------------------------------------------------------------
// Expected files: shape, key order, canonical order
// ---------------------------------------------------------------------------

const KEYS = {
  top: ['inventory', 'snapshot'],
  topError: ['inventory', 'error'],
  inventory: ['package', 'read', 'ignored'],
  read: ['path', 'rows'],
  ignored: ['path', 'bytes'],
  error: ['code', 'file'],
  snapshot: ['source', 'package', 'timeZone', 'country', 'tracks', 'days', 'library', 'artists', 'playlists', 'unresolved', 'ledgerFrom', 'ledgerTo'],
  track: ['platformId', 'title', 'artist', 'album', 'durationMs'],
  day: ['platformId', 'day', 'plays', 'skips', 'completes', 'msPlayed', 'hoursMask'],
  library: ['platformId', 'playCount', 'skipCount', 'lastPlayedAt', 'dateAdded', 'likeRating'],
  artist: ['name', 'spotifyId'],
  playlist: ['ordinal', 'key', 'name', 'description', 'lastModifiedAt', 'entries'],
  entry: ['position', 'platformId', 'title', 'artist', 'album', 'addedAt'],
  unresolved: ['rows', 'plays'],
}

const assertKeys = (value, keys, label) => assert.deepEqual(Object.keys(value), keys, `${label}: key order`)

function assertSorted(rows, keyOf, label) {
  for (let i = 1; i < rows.length; i += 1) {
    assert.ok(compare(keyOf(rows[i - 1]), keyOf(rows[i])) < 0, `${label}: row ${i} out of canonical order or duplicated`)
  }
}

const SPOTIFY_ID = /^[0-9A-Za-z]{22}$/
const DAY = /^\d{4}-\d{2}-\d{2}$/

for (const def of cases) {
  for (const relative of expectedFiles(def)) {
    test(`${relative}: parses with the contract's shape and key order`, () => {
      const text = readCommitted(relative).toString('utf8')
      const doc = JSON.parse(text)
      assert.equal(text, `${JSON.stringify(doc, null, 2)}\n`, 'pretty-printed with two spaces and a trailing newline')

      const { inventory } = doc
      assertKeys(inventory, KEYS.inventory, 'inventory')
      assert.equal(inventory.package, def.package)
      for (const [i, file] of inventory.read.entries()) {
        assertKeys(file, KEYS.read, `read[${i}]`)
        assert.notEqual(classifyEntry(file.path), null, `${file.path} is allow-listed`)
        assert.ok(file.rows === null || Number.isInteger(file.rows))
      }
      for (const [i, file] of inventory.ignored.entries()) {
        assertKeys(file, KEYS.ignored, `ignored[${i}]`)
        assert.ok(Number.isInteger(file.bytes) && file.bytes >= 0)
        assert.equal(file.bytes, entryBody(def.entries.find((entry) => entry.path === file.path)).length)
      }
      assertSorted(inventory.read, (file) => file.path, 'read')
      assertSorted(inventory.ignored, (file) => file.path, 'ignored')
      const listed = [...inventory.read, ...inventory.ignored].map((file) => file.path).sort(compare)
      assert.deepEqual(listed, def.entries.map((entry) => entry.path).sort(compare), 'every entry is listed exactly once')
      for (const entry of def.entries) {
        if (entry.sentinel === true) {
          assert.ok(inventory.ignored.some((file) => file.path === entry.path), `${entry.path}: sentinel listed as ignored`)
        }
      }

      if (Object.hasOwn(doc, 'error')) {
        assertKeys(doc, KEYS.topError, 'expected')
        assertKeys(doc.error, KEYS.error, 'error')
        assert.equal(doc.error.code, 'unreadable')
        assert.ok(inventory.read.some((file) => file.path.endsWith(`/${doc.error.file}`) && file.rows === null))
        return
      }

      assertKeys(doc, KEYS.top, 'expected')
      const snapshot = doc.snapshot
      assertKeys(snapshot, KEYS.snapshot, 'snapshot')
      assert.equal(snapshot.source, 'spotify_export')
      assert.equal(snapshot.package, def.package)
      assertKeys(snapshot.unresolved, KEYS.unresolved, 'unresolved')

      for (const [i, row] of snapshot.tracks.entries()) {
        assertKeys(row, KEYS.track, `tracks[${i}]`)
        assert.match(row.platformId, SPOTIFY_ID)
        assert.equal(typeof row.title, 'string')
        assert.equal(typeof row.artist, 'string')
      }
      assertSorted(snapshot.tracks, (row) => row.platformId, 'tracks')
      const trackIds = new Set(snapshot.tracks.map((row) => row.platformId))

      for (const [i, row] of snapshot.days.entries()) {
        assertKeys(row, KEYS.day, `days[${i}]`)
        assert.match(row.day, DAY)
        assert.ok(row.plays > 0 || row.skips > 0, `days[${i}]: emitted only with a play or a skip`)
        assert.ok(trackIds.has(row.platformId), `days[${i}]: track present`)
      }
      assertSorted(snapshot.days, (row) => `${row.platformId}|${row.day}`, 'days')

      for (const [i, row] of snapshot.library.entries()) {
        assertKeys(row, KEYS.library, `library[${i}]`)
        assert.ok(trackIds.has(row.platformId), `library[${i}]: track present`)
      }
      assertSorted(snapshot.library, (row) => row.platformId, 'library')

      for (const [i, row] of snapshot.artists.entries()) assertKeys(row, KEYS.artist, `artists[${i}]`)
      assertSorted(snapshot.artists, (row) => `${row.name}|${row.spotifyId ?? '~'}`, 'artists')

      for (const [i, playlist] of snapshot.playlists.entries()) {
        assertKeys(playlist, KEYS.playlist, `playlists[${i}]`)
        assert.equal(playlist.ordinal, i, `playlists[${i}]: ordinal is the index`)
        assert.match(playlist.key, /^[0-9a-f]{64}$/)
        for (const [j, entry] of playlist.entries.entries()) {
          assertKeys(entry, KEYS.entry, `playlists[${i}].entries[${j}]`)
          assert.equal(entry.position, j)
          if (entry.platformId !== null) assert.ok(trackIds.has(entry.platformId), `entry ${i}/${j}: track present`)
        }
      }

      if (def.package === 'spotify_account') {
        assert.deepEqual(snapshot.days, [])
        assert.equal(snapshot.country, null)
        assert.equal(snapshot.ledgerFrom, null)
        assert.equal(snapshot.ledgerTo, null)
        assert.equal(snapshot.unresolved.plays, 0)
      } else {
        assert.deepEqual(snapshot.library, [])
        assert.deepEqual(snapshot.artists, [])
        assert.deepEqual(snapshot.playlists, [])
        const days = snapshot.days.map((row) => row.day).sort(compare)
        assert.equal(snapshot.ledgerFrom, days[0] ?? null)
        assert.equal(snapshot.ledgerTo, days[days.length - 1] ?? null)
      }
    })
  }
}

// ---------------------------------------------------------------------------
// The suite exercises what its README claims
// ---------------------------------------------------------------------------

const loadExpected = (relative) => JSON.parse(readCommitted(relative).toString('utf8'))

test('account-pii-present: the identity, payment, inference, and user-data files are ignored with byte sizes only', () => {
  const { inventory } = loadExpected('account-pii-present/expected.default.json')
  const ignored = inventory.ignored.map((file) => file.path.slice(file.path.lastIndexOf('/') + 1)).sort(compare)
  assert.deepEqual(ignored, ['Identity.json', 'Inferences.json', 'Payments.json', 'Userdata.json'])
  for (const file of inventory.ignored) assert.equal(file.bytes, sentinelBody(file.path).length)
})

test('extended-malformed: unreadable, inventory only', () => {
  const doc = loadExpected('extended-malformed/expected.default.json')
  assert.deepEqual(Object.keys(doc), ['inventory', 'error'])
  assert.equal(doc.error.file, 'Streaming_History_Audio_2025-2026_1.json')
})

test('extended-private-sessions: the toggle changes the snapshot', () => {
  const excluded = loadExpected('extended-private-sessions/expected.default.json').snapshot
  const included = loadExpected('extended-private-sessions/expected.private-included.json').snapshot
  assert.notDeepEqual(excluded, included)
  assert.ok(included.tracks.length > excluded.tracks.length)
  assert.deepEqual(excluded.unresolved, { rows: 0, plays: 0 })
  assert.deepEqual(included.unresolved, { rows: 1, plays: 1 })
})

test('extended-timezone: the zone moves the same plays across a day boundary', () => {
  const lagos = loadExpected('extended-timezone/expected.default.json').snapshot
  const la = loadExpected('extended-timezone/expected.los-angeles.json').snapshot
  assert.equal(lagos.timeZone, 'Africa/Lagos')
  assert.equal(la.timeZone, 'America/Los_Angeles')
  assert.notDeepEqual(lagos.days.map((row) => row.day), la.days.map((row) => row.day))
  assert.deepEqual(lagos.tracks, la.tracks)
})
