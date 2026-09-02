import { BlobReader, ZipReader } from '@zip.js/zip.js'
import { describe, expect, it } from 'vitest'
import { canonicalize } from './canonical'
import {
  UnreadableExportError,
  YIELD_EVERY_ROWS,
  ZoneClock,
  classifyEntry,
  epochMsFromExportDate,
  inspectExport,
  parseExport,
  parseTimestamp,
  spotifyIdFromUri,
  type ParseProgress,
} from './spotify-parser'
import { openZipArchive, type ExportArchive } from './zip-reader'
import {
  listFixtureCases,
  readExpected,
  readFixtureArchive,
  readFixtureArchiveBytes,
  recordingArchive,
} from '../test/listening-export-fixtures'
import { ACCOUNT_DIR, HISTORY_DIR, LIBRARY, PLAYLISTS, TRACK_A, TRACK_B, historyRow } from '../test/spotify-export-rows'
import { buildZipBlob, type ZipEntrySpec } from '../test/zip-builder'

const lagos = { timeZone: 'Africa/Lagos', includePrivateSessions: false }

async function extendedArchive(files: Record<string, unknown[]>, extra: ZipEntrySpec[] = []): Promise<ExportArchive> {
  const entries: ZipEntrySpec[] = Object.entries(files).map(([name, rows]) => ({ path: `${HISTORY_DIR}/${name}`, json: rows }))
  return openZipArchive(await buildZipBlob([...entries, ...extra]))
}

describe('classifyEntry', () => {
  it('matches the three allow-lists by whole base name, case-insensitively, at any depth', () => {
    expect(classifyEntry('Spotify Extended Streaming History/Streaming_History_Audio_2024-2025_0.json')).toBe('history')
    expect(classifyEntry('wrap/deeper/STREAMING_HISTORY_AUDIO_2019_3.JSON')).toBe('history')
    expect(classifyEntry('Spotify Account Data/YourLibrary.json')).toBe('library')
    expect(classifyEntry('yourlibrary.json')).toBe('library')
    expect(classifyEntry('Spotify Account Data/Playlist1.json')).toBe('playlist')
    expect(classifyEntry('x/Playlist10.json')).toBe('playlist')
    expect(classifyEntry('x/Playlist.JSON')).toBe('playlist')
  })

  it('never matches resource forks, video history, the account streaming history, or anything else', () => {
    expect(classifyEntry('__MACOSX/Spotify Account Data/._YourLibrary.json')).toBeNull()
    expect(classifyEntry('__MACOSX/._Streaming_History_Audio_2024_0.json')).toBeNull()
    expect(classifyEntry('Spotify Extended Streaming History/Streaming_History_Video_2024_0.json')).toBeNull()
    expect(classifyEntry('Spotify Account Data/StreamingHistory_music_0.json')).toBeNull()
    expect(classifyEntry('Spotify Account Data/Identity.json')).toBeNull()
    expect(classifyEntry('Spotify Account Data/YourLibrary.json.bak')).toBeNull()
    expect(classifyEntry('ReadMeFirst_ExtendedStreamingHistory.pdf')).toBeNull()
  })
})

describe('value helpers', () => {
  it('extracts only well-formed 22-character ids from Spotify URIs', () => {
    expect(spotifyIdFromUri(`spotify:track:${TRACK_A}`, 'track')).toBe(TRACK_A)
    expect(spotifyIdFromUri(`spotify:track:${TRACK_A}`, 'artist')).toBeNull()
    expect(spotifyIdFromUri('spotify:track:short', 'track')).toBeNull()
    expect(spotifyIdFromUri('spotify:track:GlassCorridor00000000-1', 'track')).toBeNull()
    expect(spotifyIdFromUri(null, 'track')).toBeNull()
    expect(spotifyIdFromUri(42, 'track')).toBeNull()
  })

  it('accepts only the strict instant grammar and takes Date.UTC of the captured fields', () => {
    expect(parseTimestamp('2024-03-02T07:10:07Z')).toBe(Date.UTC(2024, 2, 2, 7, 10, 7))
    expect(parseTimestamp('2024-03-02T07:10:07.5Z')).toBe(Date.UTC(2024, 2, 2, 7, 10, 7, 500))
    expect(parseTimestamp('2024-03-02T07:10:07.123Z')).toBe(Date.UTC(2024, 2, 2, 7, 10, 7, 123))
    expect(parseTimestamp('2024-02-29T00:00:00Z')).toBe(Date.UTC(2024, 1, 29))
    // In-grammar fields out of range follow Date.UTC, as the reference does.
    expect(parseTimestamp('2023-02-29T00:00:00Z')).toBe(Date.UTC(2023, 1, 29))
    expect(parseTimestamp('2024-03-02T24:00:00Z')).toBe(Date.UTC(2024, 2, 3))
    expect(parseTimestamp('2024-03-02 07:10:07')).toBeNull()
    expect(parseTimestamp('2024-03-02T07:10:07')).toBeNull()
    expect(parseTimestamp('2024-03-02T07:10:07+00:00')).toBeNull()
    expect(parseTimestamp('2024-03-02T07:10:07.1234Z')).toBeNull()
    expect(parseTimestamp('Wed, 01 Apr 2026 11:00:00 GMT')).toBeNull()
    expect(parseTimestamp(1709363407000)).toBeNull()
    expect(parseTimestamp(null)).toBeNull()
  })

  it('converts only YYYY-MM-DD dates to midnight UTC', () => {
    expect(epochMsFromExportDate('2026-08-01')).toBe(1785542400000)
    expect(epochMsFromExportDate('2026-8-1')).toBeNull()
    expect(epochMsFromExportDate('2026-08-01T00:00:00Z')).toBeNull()
    expect(epochMsFromExportDate(null)).toBeNull()
  })
})

describe('ZoneClock', () => {
  function expectedLocal(timeZone: string, utcMs: number): { day: string; hour: number } {
    const parts: Record<string, string> = {}
    for (const part of new Intl.DateTimeFormat('en-US', {
      timeZone,
      hourCycle: 'h23',
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
    }).formatToParts(new Date(utcMs))) {
      parts[part.type] = part.value
    }
    return { day: `${parts.year}-${parts.month}-${parts.day}`, hour: Number(parts.hour) % 24 }
  }

  it('is exact through the Los Angeles spring-forward hour', () => {
    const clock = new ZoneClock('America/Los_Angeles')
    expect(clock.local(Date.UTC(2026, 2, 8, 9, 30))).toEqual({ day: '2026-03-08', hour: 1 })
    expect(clock.local(Date.UTC(2026, 2, 8, 10, 30))).toEqual({ day: '2026-03-08', hour: 3 })
    expect(clock.local(Date.UTC(2026, 2, 8, 7, 59, 59))).toEqual({ day: '2026-03-07', hour: 23 })
  })

  it('handles half-hour zones and a transition inside a UTC hour exactly', () => {
    expect(new ZoneClock('Asia/Kolkata').local(Date.UTC(2025, 0, 1, 18, 45))).toEqual({ day: '2025-01-02', hour: 0 })
    // Lord Howe Island shifts by 30 minutes at 02:00 local, which is 15:30 UTC
    // on the way into summer time: the offset differs at the two ends of that
    // UTC hour, so the per-hour cache must not be used for it.
    const clock = new ZoneClock('Australia/Lord_Howe')
    for (const transition of [Date.UTC(2025, 9, 4, 15, 30), Date.UTC(2025, 3, 5, 15, 0)]) {
      for (let delta = -90 * 60_000; delta <= 90 * 60_000; delta += 5 * 60_000) {
        const instant = transition + delta
        expect(clock.local(instant), new Date(instant).toISOString()).toEqual(expectedLocal('Australia/Lord_Howe', instant))
      }
    }
  })

  it('caches per UTC hour only when both ends of the hour share the offset', () => {
    const clock = new ZoneClock('Australia/Lord_Howe')
    const plain = Date.UTC(2025, 5, 1, 12, 0)
    expect(clock.offsetMs(plain + 17 * 60_000)).toBe(clock.offsetAt(plain))
    const mixed = Date.UTC(2025, 9, 4, 15, 0)
    expect(clock.offsetMs(mixed + 10 * 60_000)).toBe(10.5 * 3_600_000)
    expect(clock.offsetMs(mixed + 40 * 60_000)).toBe(11 * 3_600_000)
  })
})

describe('parseExport progress and abort', () => {
  it('reports listing, one reading event per file in path order, and completion', async () => {
    const archive = await extendedArchive({
      'Streaming_History_Audio_2025-2026_1.json': [historyRow()],
      'Streaming_History_Audio_2024-2025_0.json': [historyRow({ ts: '2024-05-01T10:00:00Z' })],
    })
    const events: ParseProgress[] = []
    await parseExport(archive, { ...lagos, onProgress: (progress) => events.push(progress) })
    expect(events).toEqual([
      { stage: 'listing', file: null, completed: 0, total: 2 },
      { stage: 'reading', file: `${HISTORY_DIR}/Streaming_History_Audio_2024-2025_0.json`, completed: 0, total: 2 },
      { stage: 'reading', file: `${HISTORY_DIR}/Streaming_History_Audio_2025-2026_1.json`, completed: 1, total: 2 },
      { stage: 'complete', file: null, completed: 2, total: 2 },
    ])
  })

  it('rejects with AbortError when aborted between files and reads nothing further', async () => {
    const archive = recordingArchive(
      await extendedArchive({
        'Streaming_History_Audio_2024-2025_0.json': [historyRow()],
        'Streaming_History_Audio_2025-2026_1.json': [historyRow()],
      }),
    )
    const controller = new AbortController()
    const events: ParseProgress[] = []
    const failure = await parseExport(archive, {
      ...lagos,
      signal: controller.signal,
      onProgress: (progress) => {
        events.push(progress)
        if (progress.stage === 'reading' && progress.completed === 1) controller.abort()
      },
    }).then(
      () => null,
      (error: unknown) => error,
    )
    expect(failure).toMatchObject({ name: 'AbortError' })
    expect(archive.readPaths).toEqual([`${HISTORY_DIR}/Streaming_History_Audio_2024-2025_0.json`])
    expect(events.some((event) => event.stage === 'complete')).toBe(false)
  })

  it('rejects with AbortError when aborted mid-file', async () => {
    const rows = Array.from({ length: YIELD_EVERY_ROWS * 3 }, (_, index) =>
      historyRow({ ts: new Date(Date.UTC(2025, 0, 1) + index * 60_000).toISOString().replace(/\.\d{3}Z$/, 'Z') }),
    )
    const archive = await extendedArchive({ 'Streaming_History_Audio_2025_0.json': rows })
    const controller = new AbortController()
    const failure = await parseExport(archive, {
      ...lagos,
      signal: controller.signal,
      onProgress: (progress) => {
        if (progress.stage === 'reading') setTimeout(() => controller.abort(), 0)
      },
    }).then(
      () => null,
      (error: unknown) => error,
    )
    expect(failure).toMatchObject({ name: 'AbortError' })
  })

  it('rejects an already-aborted signal before reading any entry', async () => {
    const archive = recordingArchive(await openZipArchive(readFixtureArchive('extended-basic')))
    const controller = new AbortController()
    controller.abort()
    await expect(parseExport(archive, { ...lagos, signal: controller.signal })).rejects.toMatchObject({ name: 'AbortError' })
    expect(archive.readPaths).toEqual([])
  })
})

describe('parseExport never opens files outside the allow-list', () => {
  const piiCase = listFixtureCases().find((fixture) => fixture.name === 'account-pii-present')!

  it('requests only the allow-listed entries of the PII fixture', async () => {
    const archive = recordingArchive(await openZipArchive(readFixtureArchive(piiCase.name)))
    await inspectExport(archive)
    await parseExport(archive, lagos)
    expect(piiCase.sentinelPaths.length).toBeGreaterThanOrEqual(4)
    const neverRead = new Set([
      ...piiCase.sentinelPaths,
      ...readExpected(piiCase.name, 'default').inventory.ignored.map((file) => file.path),
    ])
    for (const path of neverRead) expect(archive.readPaths).not.toContain(path)
    expect(new Set(archive.readPaths)).toEqual(
      new Set([`${ACCOUNT_DIR}/Playlist1.json`, `${ACCOUNT_DIR}/YourLibrary.json`]),
    )
  })

  it('never slices the bytes of a sentinel entry out of the blob', async () => {
    const bytes = readFixtureArchiveBytes(piiCase.name)
    const listed = await new ZipReader(new BlobReader(new Blob([bytes])), { useWebWorkers: false }).getEntries()
    const spans = listed
      .filter((entry) => piiCase.sentinelPaths.includes(entry.filename))
      .map((entry) => [entry.offset, entry.offset + 30 + entry.rawFilename.length + entry.compressedSize] as const)
    expect(spans).toHaveLength(piiCase.sentinelPaths.length)

    class RecordingBlob extends Blob {
      readonly ranges: [number, number][] = []
      override slice(start = 0, end = this.size, contentType?: string): Blob {
        this.ranges.push([start, end])
        return super.slice(start, end, contentType)
      }
    }
    const blob = new RecordingBlob([bytes], { type: 'application/zip' })
    const archive = await openZipArchive(blob)
    await parseExport(archive, lagos)
    expect(blob.ranges.length).toBeGreaterThan(0)
    for (const [start, end] of blob.ranges) {
      for (const [spanStart, spanEnd] of spans) {
        expect(start < spanEnd && end > spanStart, `read ${start}-${end} overlaps a sentinel`).toBe(false)
      }
    }
  })

  it('lists a resource fork beside a library file as ignored and never reads it', async () => {
    const archive = recordingArchive(
      await openZipArchive(
        await buildZipBlob([
          { path: `__MACOSX/${ACCOUNT_DIR}/._YourLibrary.json`, text: 'DO-NOT-READ' },
          { path: `${ACCOUNT_DIR}/YourLibrary.json`, json: LIBRARY },
        ]),
      ),
    )
    const { inventory } = await parseExport(archive, lagos)
    expect(inventory).toEqual({
      package: 'spotify_account',
      read: [{ path: `${ACCOUNT_DIR}/YourLibrary.json`, rows: 2 }],
      ignored: [{ path: `__MACOSX/${ACCOUNT_DIR}/._YourLibrary.json`, bytes: 11 }],
    })
    expect(archive.readPaths).toEqual([`${ACCOUNT_DIR}/YourLibrary.json`])
  })
})

describe('parseExport decoding', () => {
  it('tolerates a byte order mark and reads data-descriptor entries', async () => {
    const plain = await openZipArchive(
      await buildZipBlob([
        { path: `${ACCOUNT_DIR}/YourLibrary.json`, json: LIBRARY },
        { path: `${ACCOUNT_DIR}/Playlist1.json`, json: PLAYLISTS },
      ]),
    )
    const encoded = new TextEncoder().encode(JSON.stringify(LIBRARY))
    const streamed = await openZipArchive(
      await buildZipBlob([
        { path: `${ACCOUNT_DIR}/YourLibrary.json`, bytes: new Uint8Array([0xef, 0xbb, 0xbf, ...encoded]), dataDescriptor: true },
        { path: `${ACCOUNT_DIR}/Playlist1.json`, json: PLAYLISTS, dataDescriptor: true },
      ]),
    )
    const expected = await parseExport(plain, lagos)
    const actual = await parseExport(streamed, lagos)
    expect(actual.snapshot).toEqual(expected.snapshot)
    expect(actual.inventory).toEqual(expected.inventory)
    expect(actual.snapshot.playlists[0]?.entries).toHaveLength(1)
  })

  it('fails closed on malformed UTF-8 and names the first broken file in path order', async () => {
    const archive = await openZipArchive(
      await buildZipBlob([
        { path: `${ACCOUNT_DIR}/YourLibrary.json`, bytes: new Uint8Array([0x7b, 0x22, 0xff, 0x22, 0x3a, 0x31, 0x7d]) },
        { path: `${ACCOUNT_DIR}/Playlist2.json`, text: '{"playlists": [' },
        { path: `${ACCOUNT_DIR}/Playlist1.json`, json: PLAYLISTS },
      ]),
    )
    const failure = await parseExport(archive, lagos).then(
      () => null,
      (error: unknown) => error,
    )
    expect(failure).toBeInstanceOf(UnreadableExportError)
    const unreadable = failure as UnreadableExportError
    expect(unreadable.file).toBe('Playlist2.json')
    expect(unreadable.inventory).toEqual({
      package: 'spotify_account',
      read: [
        { path: `${ACCOUNT_DIR}/Playlist1.json`, rows: 1 },
        { path: `${ACCOUNT_DIR}/Playlist2.json`, rows: null },
        { path: `${ACCOUNT_DIR}/YourLibrary.json`, rows: null },
      ],
      ignored: [],
    })
    expect(unreadable.message).not.toContain('playlists')
  })

  it('treats a wrong top-level shape as unreadable but a missing array as empty', async () => {
    const wrongShape = await extendedArchive({ 'Streaming_History_Audio_2025_0.json': [] }, [
      { path: `${HISTORY_DIR}/Streaming_History_Audio_2025_1.json`, json: { rows: [] } },
    ])
    await expect(parseExport(wrongShape, lagos)).rejects.toMatchObject({
      name: 'UnreadableExportError',
      file: 'Streaming_History_Audio_2025_1.json',
    })
    const emptyLibrary = await openZipArchive(
      await buildZipBlob([{ path: `${ACCOUNT_DIR}/YourLibrary.json`, json: { albums: [] } }]),
    )
    const { inventory, snapshot } = await parseExport(emptyLibrary, lagos)
    expect(inventory.read).toEqual([{ path: `${ACCOUNT_DIR}/YourLibrary.json`, rows: 0 }])
    expect(snapshot.tracks).toEqual([])
  })

  it('reports no package for an archive without Spotify files', async () => {
    const archive = await openZipArchive(
      await buildZipBlob([
        { path: 'notes.txt', text: 'hello' },
        { path: 'photos/', directory: true },
        { path: 'photos/holiday.jpg', bytes: new Uint8Array([1, 2, 3]) },
      ]),
    )
    const inventory = await inspectExport(archive)
    expect(inventory).toEqual({
      package: null,
      read: [],
      ignored: [
        { path: 'notes.txt', bytes: 5 },
        { path: 'photos/holiday.jpg', bytes: 3 },
      ],
    })
    await expect(parseExport(archive, lagos)).rejects.toMatchObject({ name: 'UnreadableExportError', file: null, inventory })
  })
})

describe('parseExport history rules', () => {
  it('drops rows whose ts is outside the grammar, without counting them as unresolved', async () => {
    const archive = await extendedArchive({
      'Streaming_History_Audio_2024_0.json': [
        historyRow({ ts: '2024-03-02T07:10:07Z' }),
        historyRow({ ts: '2024-03-02T08:10:07.5Z' }),
        historyRow({ ts: '2024-03-02 09:10:07' }),
        historyRow({ ts: '2024-03-02T09:10:07+01:00' }),
        historyRow({ ts: '2024-03-02T09:10:07' }),
        historyRow({ ts: 'Sat, 02 Mar 2024 09:10:07 GMT' }),
        historyRow({ ts: 1709363407000 }),
      ],
    })
    const { inventory, snapshot } = await parseExport(archive, lagos)
    expect(inventory.read[0]?.rows).toBe(7)
    expect(snapshot.unresolved).toEqual({ rows: 0, plays: 0 })
    expect(snapshot.days).toEqual([
      { platformId: TRACK_A, day: '2024-03-02', plays: 2, skips: 0, completes: 2, msPlayed: 374000, hoursMask: (1 << 8) | (1 << 9) },
    ])
  })

  it('truncates ms_played to an integer and treats non-numbers as 0', async () => {
    const archive = await extendedArchive({
      'Streaming_History_Audio_2024_0.json': [
        historyRow({ ms_played: 29999.9, reason_end: 'endplay' }),
        historyRow({ ms_played: 30000.7, reason_end: 'endplay' }),
        historyRow({ ms_played: '45000', reason_end: 'endplay' }),
        historyRow({ ms_played: 30000.2, spotify_track_uri: null }),
        historyRow({ ms_played: 29999.99, spotify_track_uri: null }),
      ],
    })
    const { snapshot } = await parseExport(archive, lagos)
    expect(snapshot.days).toEqual([
      { platformId: TRACK_A, day: '2025-01-15', plays: 1, skips: 0, completes: 0, msPlayed: 59999, hoursMask: 1 << 19 },
    ])
    expect(snapshot.unresolved).toEqual({ rows: 2, plays: 1 })
    expect(snapshot.tracks[0]?.durationMs).toBeNull()
  })

  it('counts conn_country only as an upper-case two-letter code and breaks ties by ordinal order', async () => {
    const majority = await extendedArchive({
      'Streaming_History_Audio_2024_0.json': [
        historyRow({ conn_country: 'ng' }),
        historyRow({ conn_country: 'NGA' }),
        historyRow({ conn_country: '' }),
        historyRow({ conn_country: null }),
        historyRow({ conn_country: 'GB' }),
        historyRow({ conn_country: 'GB' }),
        historyRow({ conn_country: 'NG' }),
        historyRow({ conn_country: 'NG', incognito_mode: true }),
        historyRow({ conn_country: 'NG', spotify_episode_uri: 'spotify:episode:Ep0000000000000000000001' }),
        historyRow({ conn_country: 'NG', spotify_track_uri: null }),
        historyRow({ conn_country: 'NG', ts: 'yesterday' }),
      ],
    })
    expect((await parseExport(majority, lagos)).snapshot.country).toBe('GB')
    const tie = await extendedArchive({
      'Streaming_History_Audio_2024_0.json': [historyRow({ conn_country: 'NG' }), historyRow({ conn_country: 'GB' })],
    })
    expect((await parseExport(tie, lagos)).snapshot.country).toBe('GB')
    const none = await extendedArchive({ 'Streaming_History_Audio_2024_0.json': [historyRow({ conn_country: 'nigeria' })] })
    expect((await parseExport(none, lagos)).snapshot.country).toBeNull()
  })

  it('counts every array element as a row but aggregates only objects', async () => {
    const archive = await extendedArchive({
      'Streaming_History_Audio_2024_0.json': [null, 7, 'row', [], historyRow({ spotify_track_uri: `spotify:track:${TRACK_B}` })],
    })
    const { inventory, snapshot } = await parseExport(archive, lagos)
    expect(inventory.read[0]?.rows).toBe(5)
    expect(snapshot.tracks.map((track) => track.platformId)).toEqual([TRACK_B])
    expect(snapshot.unresolved).toEqual({ rows: 0, plays: 0 })
  })

  it('returns a snapshot that is already canonical', async () => {
    const { snapshot } = await parseExport(await openZipArchive(readFixtureArchive('account-duplicates')), lagos)
    expect(canonicalize(snapshot)).toEqual(snapshot)
    expect(JSON.stringify(canonicalize(snapshot))).toBe(JSON.stringify(snapshot))
    expect(snapshot).toEqual(readExpected('account-duplicates', 'default').snapshot)
  })
})
