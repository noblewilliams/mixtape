// Self-checks for the fixture suite. Run from the repo root:
//
//   node --test fixtures/listening-exports/verify.test.mjs
//
// Asserts that the committed files match a fresh build, that every archive
// holds exactly its case's entries (deterministically encoded), that sentinel
// entries are byte-identical to the sentinel body, that every expected file
// follows the contract's shape, key order, and canonical order, and that the
// cases pin what README.md says they pin. The gate in the authoritative suite
// is server/test/fixtures/listening-exports.test.ts, which runs this file and
// `build.mjs --check`.

import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'

import {
  DIRECTORY_ATTRIBUTE,
  DOS_DATE,
  DOS_TIME,
  FLAG_DATA_DESCRIPTOR,
  METHOD_DEFLATE,
  METHOD_STORED,
  ROOT,
  UNKNOWN_ARTIST,
  UNTITLED,
  ZoneClock,
  archiveProblems,
  buildAll,
  check,
  classifyEntry,
  compare,
  crc32,
  entryBody,
  instantFromTs,
  isDirectoryEntry,
  loadCases,
  playlistKey,
  readArchive,
  sentinelBody,
} from './build.mjs'

const cases = loadCases()

const readCommitted = (relative) => readFileSync(join(ROOT, relative))
const expectedFiles = (def) => def.options.map((option) => `${def.name}/expected.${option.name}.json`)
const fileEntries = (def) => def.entries.filter((entry) => !isDirectoryEntry(entry))

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

test('the structural archive check accepts a fresh build and rejects a wrong body', () => {
  const def = cases.find((candidate) => candidate.name === 'extended-nested-folder')
  const fresh = buildAll([def]).get(`${def.name}/archive.zip`)
  assert.deepEqual(archiveProblems(fresh, def.entries), [])
  const tampered = def.entries.map((entry) => (entry.sentinel === true ? { path: entry.path, text: 'not the sentinel' } : entry))
  assert.ok(archiveProblems(fresh, tampered).some((problem) => problem.includes('crc')))
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
    'extended-bad-utf8',
    'extended-basic',
    'extended-bom',
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
    const buffer = readCommitted(`${def.name}/archive.zip`)
    assert.deepEqual(archiveProblems(buffer, def.entries), [])
    const entries = readArchive(buffer)
    const expectedPaths = def.entries.map((entry) => entry.path).sort(compare)
    assert.deepEqual(entries.map((entry) => entry.name), expectedPaths)
    for (const entry of entries) {
      const source = def.entries.find((candidate) => candidate.path === entry.name)
      assert.equal(entry.time, DOS_TIME, `${entry.name}: fixed DOS time`)
      assert.equal(entry.date, DOS_DATE, `${entry.name}: fixed DOS date`)
      assert.equal(entry.extraLength, 0, `${entry.name}: no central extra field`)
      assert.equal(entry.local.extraLength, 0, `${entry.name}: no local extra field`)
      assert.equal(entry.commentLength, 0, `${entry.name}: no comment`)
      assert.equal(entry.size, entry.data.length, `${entry.name}: uncompressed size`)
      assert.equal(entry.crc, crc32(entry.data), `${entry.name}: CRC-32`)
      assert.ok(entry.data.equals(entryBody(source)), `${entry.name}: body matches the case entry`)
      if (isDirectoryEntry(source)) {
        assert.ok(entry.name.endsWith('/'), `${entry.name}: directory entries end with /`)
        assert.equal(entry.method, METHOD_STORED, `${entry.name}: directories are stored`)
        assert.equal(entry.size, 0)
        assert.equal(entry.compressedSize, 0)
        assert.equal(entry.crc, 0)
        assert.equal(entry.externalAttributes, DIRECTORY_ATTRIBUTE, `${entry.name}: MS-DOS directory attribute`)
        continue
      }
      assert.equal(entry.method, METHOD_DEFLATE, `${entry.name}: deflate`)
      assert.equal(entry.externalAttributes, 0)
      if (source.dataDescriptor === true) {
        assert.ok(entry.flags & FLAG_DATA_DESCRIPTOR, `${entry.name}: bit 3 set`)
        assert.deepEqual([entry.local.crc, entry.local.compressedSize, entry.local.size], [0, 0, 0], `${entry.name}: zeros in the local header`)
        assert.deepEqual(entry.descriptor, { crc: entry.crc, compressedSize: entry.compressedSize, size: entry.size })
      } else {
        assert.equal(entry.flags & FLAG_DATA_DESCRIPTOR, 0, `${entry.name}: no data descriptor`)
        assert.equal(entry.descriptor, null)
        assert.deepEqual([entry.local.crc, entry.local.compressedSize, entry.local.size], [entry.crc, entry.compressedSize, entry.size])
      }
      if (Object.hasOwn(source, 'json')) {
        assert.deepEqual(JSON.parse(entry.data.toString('utf8')), source.json, `${entry.name}: JSON round-trips`)
      }
      if (Object.hasOwn(source, 'bytes')) {
        assert.ok(entry.data.equals(Buffer.from(source.bytes, 'base64')), `${entry.name}: raw bytes`)
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

// Every number anywhere in a document is an integer (no fractions leak in).
function assertIntegers(value, label) {
  if (typeof value === 'number') assert.ok(Number.isInteger(value), `${label}: ${value} is not an integer`)
  else if (Array.isArray(value)) value.forEach((item, i) => assertIntegers(item, `${label}[${i}]`))
  else if (value !== null && typeof value === 'object') {
    for (const [key, item] of Object.entries(value)) assertIntegers(item, `${label}.${key}`)
  }
}

const SPOTIFY_ID = /^[0-9A-Za-z]{22}$/
const DAY = /^\d{4}-\d{2}-\d{2}$/
const COUNTRY = /^[A-Z]{2}$/

for (const def of cases) {
  for (const relative of expectedFiles(def)) {
    test(`${relative}: parses with the contract's shape and key order`, () => {
      const text = readCommitted(relative).toString('utf8')
      const doc = JSON.parse(text)
      assert.equal(text, `${JSON.stringify(doc, null, 2)}\n`, 'pretty-printed with two spaces and a trailing newline')
      assertIntegers(doc, 'expected')

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
      assert.deepEqual(listed, fileEntries(def).map((entry) => entry.path).sort(compare), 'every file entry is listed exactly once')
      for (const path of listed) assert.ok(!path.endsWith('/'), `${path}: directory entries are never listed`)
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
      assert.ok(snapshot.country === null || COUNTRY.test(snapshot.country), 'country is null or two uppercase letters')
      assertKeys(snapshot.unresolved, KEYS.unresolved, 'unresolved')

      for (const [i, row] of snapshot.tracks.entries()) {
        assertKeys(row, KEYS.track, `tracks[${i}]`)
        assert.match(row.platformId, SPOTIFY_ID)
        assert.ok(typeof row.title === 'string' && row.title.length > 0, `tracks[${i}]: title never empty`)
        assert.ok(typeof row.artist === 'string' && row.artist.length > 0, `tracks[${i}]: artist never empty`)
        assert.ok(row.album === null || (typeof row.album === 'string' && row.album.length > 0), `tracks[${i}]: album null or non-empty`)
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

      for (const [i, row] of snapshot.artists.entries()) {
        assertKeys(row, KEYS.artist, `artists[${i}]`)
        assert.ok(typeof row.name === 'string' && row.name.length > 0, `artists[${i}]: name never empty`)
      }
      assertSorted(snapshot.artists, (row) => `${row.name}|${row.spotifyId ?? '~'}`, 'artists')

      for (const [i, playlist] of snapshot.playlists.entries()) {
        assertKeys(playlist, KEYS.playlist, `playlists[${i}]`)
        assert.equal(playlist.ordinal, i, `playlists[${i}]: ordinal is the index`)
        assert.ok(playlist.name.length > 0, `playlists[${i}]: name never empty`)
        assert.equal(playlist.key, playlistKey(playlist.name, playlist.ordinal), `playlists[${i}]: key is sha256(name + " " + ordinal)`)
        for (const [j, entry] of playlist.entries.entries()) {
          assertKeys(entry, KEYS.entry, `playlists[${i}].entries[${j}]`)
          assert.equal(entry.position, j)
          assert.ok(entry.title.length > 0 && entry.artist.length > 0, `entry ${i}/${j}: names never empty`)
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
// The reference implementation's own edges
// ---------------------------------------------------------------------------

test('instantFromTs accepts only YYYY-MM-DDTHH:MM:SS[.fff]Z', () => {
  assert.equal(instantFromTs('2026-04-01T10:00:00Z'), Date.UTC(2026, 3, 1, 10))
  assert.equal(instantFromTs('2026-04-01T10:00:00.5Z'), Date.UTC(2026, 3, 1, 10, 0, 0, 500))
  assert.equal(instantFromTs('2026-04-01T10:00:00.123Z'), Date.UTC(2026, 3, 1, 10, 0, 0, 123))
  for (const rejected of [
    '2026-04-01T10:00:00', // no Z
    '2026-04-01T10:00:00+00:00', // offset
    '2026-04-01T10:00:00.1234Z', // too many fraction digits
    '2026-04-01 10:00:00Z', // space
    '2026-04-01', // date only
    'Wed, 01 Apr 2026 11:00:00 GMT', // RFC 2822 (Date.parse would accept it)
    1_775_037_600_000, // a number
    null,
  ]) {
    assert.equal(instantFromTs(rejected), null, `${rejected} is rejected`)
  }
})

test('ZoneClock agrees with exact Intl conversion across half-hour DST transitions', () => {
  const exact = (timeZone, utcMs) => {
    const format = new Intl.DateTimeFormat('en-US', {
      timeZone,
      hourCycle: 'h23',
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
    })
    const parts = {}
    for (const part of format.formatToParts(new Date(utcMs))) if (part.type !== 'literal') parts[part.type] = part.value
    return { day: `${parts.year}-${parts.month}-${parts.day}`, hour: Number(parts.hour) % 24 }
  }
  for (const timeZone of ['America/St_Johns', 'America/Los_Angeles', 'Africa/Lagos', 'Australia/Lord_Howe']) {
    const clock = new ZoneClock(timeZone)
    for (const start of ['2025-03-09T00:00:00Z', '2025-11-02T00:00:00Z', '2025-04-05T00:00:00Z', '2025-10-04T00:00:00Z']) {
      const from = Date.parse(start)
      for (let utcMs = from; utcMs < from + 36 * 3_600_000; utcMs += 5 * 60_000) {
        assert.deepEqual(clock.local(utcMs), exact(timeZone, utcMs), `${timeZone} at ${new Date(utcMs).toISOString()}`)
      }
    }
  }
})

// ---------------------------------------------------------------------------
// The suite exercises what its README claims
// ---------------------------------------------------------------------------

const loadExpected = (relative) => JSON.parse(readCommitted(relative).toString('utf8'))
const findTrack = (snapshot, platformId) => snapshot.tracks.find((row) => row.platformId === platformId)
const findDay = (snapshot, platformId, day) => snapshot.days.find((row) => row.platformId === platformId && row.day === day)

test('account-pii-present: the identity, payment, inference, user-data, and __MACOSX files are ignored with byte sizes only', () => {
  const { inventory } = loadExpected('account-pii-present/expected.default.json')
  const ignored = inventory.ignored.map((file) => file.path.slice(file.path.lastIndexOf('/') + 1)).sort(compare)
  assert.deepEqual(ignored, ['._YourLibrary.json', 'Identity.json', 'Inferences.json', 'Payments.json', 'Userdata.json'])
  for (const file of inventory.ignored) assert.equal(file.bytes, sentinelBody(file.path).length)
  assert.equal(classifyEntry('__MACOSX/._YourLibrary.json'), null, 'the resource fork does not match the allow-list')
})

test('account-liked-absent-from-history: a case-variant yourlibrary.json is read', () => {
  const doc = loadExpected('account-liked-absent-from-history/expected.default.json')
  assert.deepEqual(doc.inventory.read.map((file) => file.path), ['Spotify Account Data/yourlibrary.json'])
  assert.equal(doc.snapshot.library.length, 3)
  assert.equal(classifyEntry('YOURLIBRARY.JSON'), 'library')
})

test('account-basic: local and null liked uris vanish; a null liked name falls back to the platform id', () => {
  const { snapshot } = loadExpected('account-basic/expected.default.json')
  const ids = snapshot.library.map((row) => row.platformId)
  assert.deepEqual(ids, ['Cartographer0000000001', 'KiteSeason000000000001', 'LowTideRadio0000000001', 'NoName0000000000000001', 'PaperLanterns000000001'])
  assert.deepEqual(snapshot.unresolved, { rows: 0, plays: 0 })
  assert.deepEqual(findTrack(snapshot, 'NoName0000000000000001'), {
    platformId: 'NoName0000000000000001',
    title: 'NoName0000000000000001',
    artist: 'Basement Sessions',
    album: null,
    durationMs: null,
  })
})

test('account-local-and-episode-entries: playlist and entry name fallbacks', () => {
  const { snapshot } = loadExpected('account-local-and-episode-entries/expected.default.json')
  const untitled = snapshot.playlists[1]
  assert.equal(untitled.name, UNTITLED)
  assert.equal(untitled.key, playlistKey(UNTITLED, 1))
  assert.deepEqual(untitled.entries.map((entry) => [entry.platformId, entry.title, entry.artist]), [
    ['SaltAndStatic000000001', 'SaltAndStatic000000001', UNKNOWN_ARTIST],
    [null, UNTITLED, UNKNOWN_ARTIST],
  ])
  assert.deepEqual(findTrack(snapshot, 'SaltAndStatic000000001'), {
    platformId: 'SaltAndStatic000000001',
    title: 'SaltAndStatic000000001',
    artist: UNKNOWN_ARTIST,
    album: null,
    durationMs: null,
  })
  assert.deepEqual(snapshot.unresolved, { rows: 4, plays: 0 })
})

test('account-empty-playlist: a missing artists array and a missing items array are empty', () => {
  const doc = loadExpected('account-empty-playlist/expected.default.json')
  assert.deepEqual(doc.inventory.read.map((file) => [file.path.slice(file.path.lastIndexOf('/') + 1), file.rows]), [
    ['Playlist1.json', 0],
    ['Playlist2.json', 1],
    ['YourLibrary.json', 1],
  ])
  assert.deepEqual(doc.snapshot.artists, [])
  assert.equal(doc.snapshot.library.length, 1)
  assert.deepEqual(doc.snapshot.playlists.map((playlist) => [playlist.ordinal, playlist.name, playlist.entries.length]), [
    [0, 'Empty Shelf', 0],
    [1, 'Kitchen Radio', 1],
    [2, 'Unsorted Shelf', 0],
  ])
})

test('extended-malformed: unreadable, inventory only', () => {
  const doc = loadExpected('extended-malformed/expected.default.json')
  assert.deepEqual(Object.keys(doc), ['inventory', 'error'])
  assert.equal(doc.error.file, 'Streaming_History_Audio_2025-2026_1.json')
})

test('extended-bad-utf8: malformed UTF-8 is unreadable', () => {
  const doc = loadExpected('extended-bad-utf8/expected.default.json')
  assert.deepEqual(Object.keys(doc), ['inventory', 'error'])
  assert.equal(doc.error.file, 'Streaming_History_Audio_2025_1.json')
  assert.deepEqual(doc.inventory.read.map((file) => file.rows), [1, null])
  const def = cases.find((candidate) => candidate.name === 'extended-bad-utf8')
  const broken = def.entries.find((entry) => entry.path.endsWith('_1.json'))
  assert.throws(() => new TextDecoder('utf-8', { fatal: true }).decode(Buffer.from(broken.bytes, 'base64')))
})

test('extended-bom: a UTF-8 byte-order mark is stripped', () => {
  const doc = loadExpected('extended-bom/expected.default.json')
  const def = cases.find((candidate) => candidate.name === 'extended-bom')
  const body = entryBody(def.entries[0])
  assert.deepEqual([...body.subarray(0, 3)], [0xef, 0xbb, 0xbf])
  assert.deepEqual(doc.inventory.read.map((file) => file.rows), [1])
  assert.equal(doc.snapshot.tracks.length, 1)
  assert.equal(doc.snapshot.days.length, 1)
})

test('extended-basic: the coverage rows pin the numeric and naming rules', () => {
  const { snapshot } = loadExpected('extended-basic/expected.default.json')
  assert.equal(snapshot.country, 'NG')
  assert.deepEqual(snapshot.unresolved, { rows: 0, plays: 0 })
  // A resolved row with null title and artist.
  assert.deepEqual(findTrack(snapshot, 'Nameless00000000000001'), {
    platformId: 'Nameless00000000000001',
    title: 'Nameless00000000000001',
    artist: UNKNOWN_ARTIST,
    album: null,
    durationMs: 120000,
  })
  // A 90 s fwdbtn play with no complete.
  assert.equal(findTrack(snapshot, 'HalfwayHome00000000001').durationMs, null)
  assert.deepEqual(findDay(snapshot, 'HalfwayHome00000000001', '2026-04-03'), {
    platformId: 'HalfwayHome00000000001',
    day: '2026-04-03',
    plays: 1,
    skips: 1,
    completes: 0,
    msPlayed: 90000,
    hoursMask: 1 << 10,
  })
  // A trackdone under 30 s: complete and duration count, no day row, ledger unchanged.
  assert.equal(findTrack(snapshot, 'ShortReprise0000000001').durationMs, 25000)
  assert.ok(!snapshot.days.some((row) => row.platformId === 'ShortReprise0000000001'))
  assert.equal(snapshot.ledgerTo, '2026-04-05')
  // ms_played 45000.7 truncates; "oops" counts 0 and the row is kept (its skipped: true counts).
  assert.deepEqual(findDay(snapshot, 'PaperLanterns000000001', '2026-04-02'), {
    platformId: 'PaperLanterns000000001',
    day: '2026-04-02',
    plays: 1,
    skips: 1,
    completes: 1,
    msPlayed: 45000,
    hoursMask: 1 << 13,
  })
  // skipped: true with reason_end endplay is a skip.
  assert.deepEqual(findDay(snapshot, 'LowTideRadio0000000001', '2026-04-03'), {
    platformId: 'LowTideRadio0000000001',
    day: '2026-04-03',
    plays: 0,
    skips: 1,
    completes: 0,
    msPlayed: 20000,
    hoursMask: 0,
  })
  // skipped: null counts as absent, so fwdbtn decides.
  assert.deepEqual(findDay(snapshot, 'HalfwayHome00000000001', '2026-04-05'), {
    platformId: 'HalfwayHome00000000001',
    day: '2026-04-05',
    plays: 0,
    skips: 1,
    completes: 0,
    msPlayed: 10000,
    hoursMask: 0,
  })
  // The offset-less and RFC 2822 ts rows were dropped: no PaperLanterns row on 2026-04-01.
  assert.equal(findDay(snapshot, 'PaperLanterns000000001', '2026-04-01'), undefined)
  // Earlier pins still hold.
  assert.equal(findTrack(snapshot, 'PaperLanterns000000001').durationMs, 201500)
  assert.equal(findTrack(snapshot, 'LowTideRadio0000000001').title, 'Low Tide Radio')
  assert.equal(snapshot.ledgerFrom, '2024-03-02')
})

test('extended-podcasts-and-local: country counts kept resolved rows only, ties to the smallest code', () => {
  const { snapshot } = loadExpected('extended-podcasts-and-local/expected.default.json')
  assert.equal(snapshot.country, 'NG')
  assert.deepEqual(snapshot.unresolved, { rows: 3, plays: 2 })
  const def = cases.find((candidate) => candidate.name === 'extended-podcasts-and-local')
  const rows = def.entries[0].json
  const kept = rows.filter((row) => row.spotify_episode_uri === null && row.audiobook_uri === null && row.spotify_track_uri !== null)
  assert.deepEqual(kept.map((row) => row.conn_country), ['US', 'NG', 'US', 'NG'], 'a 2-2 tie among kept rows, US first seen')
  assert.deepEqual(kept.filter((row) => row.ms_played >= 30000).map((row) => row.conn_country), ['US', 'US', 'NG'], 'plays alone would say US')
  const dropped = rows.filter((row) => !kept.includes(row))
  assert.ok(dropped.length >= 3 && dropped.every((row) => row.conn_country === 'GB'), 'every dropped or unresolved row says GB')
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
  const stJohns = loadExpected('extended-timezone/expected.st-johns.json').snapshot
  assert.equal(lagos.timeZone, 'Africa/Lagos')
  assert.equal(la.timeZone, 'America/Los_Angeles')
  assert.equal(stJohns.timeZone, 'America/St_Johns')
  assert.notDeepEqual(lagos.days.map((row) => row.day), la.days.map((row) => row.day))
  assert.deepEqual(lagos.tracks, la.tracks)
  assert.deepEqual(lagos.tracks, stJohns.tracks)
})

test('extended-timezone (st-johns): rows inside a half-hour DST transition hour convert exactly', () => {
  const stJohns = loadExpected('extended-timezone/expected.st-johns.json').snapshot
  // 2025-03-09T05:45:00Z: the hour starts at -3:30 (NST) but the instant is -2:30 (NDT): 03:15, hour 3 (a cached hour-start offset says 02:15).
  assert.deepEqual(findDay(stJohns, 'KiteSeason000000000001', '2025-03-09').hoursMask, 1 << 3)
  // 2025-11-02T04:45:00Z: the hour starts at -2:30 (NDT) but the instant is -3:30 (NST): 01:15, hour 1 (a cached offset says 02:15).
  assert.deepEqual(findDay(stJohns, 'KiteSeason000000000001', '2025-11-02').hoursMask, 1 << 1)
  const lagos = loadExpected('extended-timezone/expected.default.json').snapshot
  assert.equal(findDay(lagos, 'KiteSeason000000000001', '2025-03-09').hoursMask, 1 << 6)
  assert.equal(findDay(lagos, 'KiteSeason000000000001', '2025-11-02').hoursMask, 1 << 5)
  const la = loadExpected('extended-timezone/expected.los-angeles.json').snapshot
  assert.equal(findDay(la, 'KiteSeason000000000001', '2025-03-08').hoursMask, 1 << 21)
  assert.equal(findDay(la, 'KiteSeason000000000001', '2025-11-01').hoursMask, 1 << 21)
})

test('extended-nested-folder: directory entries and the data-descriptor entry are invisible to the inventory', () => {
  const doc = loadExpected('extended-nested-folder/expected.default.json')
  const def = cases.find((candidate) => candidate.name === 'extended-nested-folder')
  assert.equal(def.entries.filter(isDirectoryEntry).length, 3)
  assert.equal(def.entries.filter((entry) => entry.dataDescriptor === true).length, 1)
  const listed = [...doc.inventory.read, ...doc.inventory.ignored].map((file) => file.path)
  assert.ok(listed.every((path) => !path.endsWith('/')))
  assert.equal(listed.length, def.entries.length - 3)
  assert.equal(doc.inventory.read.length, 1)
  assert.equal(doc.inventory.read[0].rows, 2)
})
