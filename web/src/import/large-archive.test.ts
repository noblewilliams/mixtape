import { writeFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import { parseExport } from './spotify-parser'
import { openZipArchive } from './zip-reader'
import { HISTORY_DIR } from '../test/spotify-export-rows'
import { buildZipBlob } from '../test/zip-builder'

const FILES = 15
const ROWS_PER_FILE = 13_334
const TRACKS = 500
const BASE = Date.UTC(2025, 0, 1)
const LAGOS_OFFSET_MS = 3_600_000
const SPOT_TRACK = 123

const trackId = (track: number) => `T${String(track).padStart(21, '0')}`
const instant = (index: number) => BASE + index * 60_000
const msPlayed = (index: number) => 20_000 + (index % 11) * 2_000

function row(index: number): Record<string, unknown> {
  const track = index % TRACKS
  return {
    ts: new Date(instant(index)).toISOString().replace(/\.\d{3}Z$/, 'Z'),
    ms_played: msPlayed(index),
    conn_country: 'NG',
    master_metadata_track_name: `Invented Track ${track}`,
    master_metadata_album_artist_name: `Invented Artist ${track % 40}`,
    master_metadata_album_album_name: `Invented Album ${track % 90}`,
    spotify_track_uri: `spotify:track:${trackId(track)}`,
    spotify_episode_uri: null,
    audiobook_uri: null,
    reason_end: index % 5 === 0 ? 'trackdone' : 'fwdbtn',
    skipped: index % 3 === 0,
    incognito_mode: false,
  }
}

describe('large archive', () => {
  it('aggregates 200k rows across 15 files under the wall-clock ceiling', { timeout: 180_000 }, async () => {
    const buildStart = performance.now()
    const entries = Array.from({ length: FILES }, (_, file) => {
      const rows: Record<string, unknown>[] = []
      for (let index = file * ROWS_PER_FILE; index < (file + 1) * ROWS_PER_FILE; index += 1) rows.push(row(index))
      return { path: `${HISTORY_DIR}/Streaming_History_Audio_2025-2026_${file}.json`, text: JSON.stringify(rows) }
    })
    const blob = await buildZipBlob(entries)
    const buildMs = performance.now() - buildStart

    const parseStart = performance.now()
    const archive = await openZipArchive(blob)
    const { inventory, snapshot } = await parseExport(archive, { timeZone: 'Africa/Lagos', includePrivateSessions: false })
    const parseMs = performance.now() - parseStart
    const timing = `large archive: ${FILES * ROWS_PER_FILE} rows, ${Math.round(blob.size / 1024)} KiB zip, build ${Math.round(buildMs)} ms, parse ${Math.round(parseMs)} ms`
    if (process.env.LARGE_ARCHIVE_TIMING_OUT !== undefined) writeFileSync(process.env.LARGE_ARCHIVE_TIMING_OUT, `${timing}\n`)
    expect(parseMs, timing).toBeLessThan(30_000)

    expect(inventory.package).toBe('spotify_extended')
    expect(inventory.read).toHaveLength(FILES)
    expect(inventory.read.every((file) => file.rows === ROWS_PER_FILE)).toBe(true)
    expect(snapshot.tracks).toHaveLength(TRACKS)
    expect(snapshot.unresolved).toEqual({ rows: 0, plays: 0 })
    expect(snapshot.country).toBe('NG')

    // Independent aggregation of one track's rows by local day.
    const total = FILES * ROWS_PER_FILE
    const expectedDays = new Map<string, { plays: number; skips: number; completes: number; msPlayed: number; hoursMask: number }>()
    for (let index = SPOT_TRACK; index < total; index += TRACKS) {
      const local = new Date(instant(index) + LAGOS_OFFSET_MS)
      const day = local.toISOString().slice(0, 10)
      let dayRow = expectedDays.get(day)
      if (dayRow === undefined) {
        dayRow = { plays: 0, skips: 0, completes: 0, msPlayed: 0, hoursMask: 0 }
        expectedDays.set(day, dayRow)
      }
      dayRow.msPlayed += msPlayed(index)
      if (msPlayed(index) >= 30_000) {
        dayRow.plays += 1
        dayRow.hoursMask |= 1 << local.getUTCHours()
      }
      if (index % 3 === 0) dayRow.skips += 1
      if (index % 5 === 0) dayRow.completes += 1
    }
    const actualDays = snapshot.days.filter((dayRow) => dayRow.platformId === trackId(SPOT_TRACK))
    expect(actualDays).toEqual(
      [...expectedDays.entries()]
        .sort(([a], [b]) => (a < b ? -1 : 1))
        .map(([day, counts]) => ({ platformId: trackId(SPOT_TRACK), day, ...counts }))
        .filter((dayRow) => dayRow.plays > 0 || dayRow.skips > 0),
    )

    let expectedPlays = 0
    let expectedMs = 0
    for (let index = 0; index < total; index += 1) {
      expectedMs += msPlayed(index)
      if (msPlayed(index) >= 30_000) expectedPlays += 1
    }
    expect(snapshot.days.reduce((sum, dayRow) => sum + dayRow.plays, 0)).toBe(expectedPlays)
    expect(snapshot.days.reduce((sum, dayRow) => sum + dayRow.msPlayed, 0)).toBe(expectedMs)
    expect(snapshot.ledgerFrom).toBe('2025-01-01')
    expect(snapshot.ledgerTo).toBe(new Date(instant(total - 1) + LAGOS_OFFSET_MS).toISOString().slice(0, 10))
  })
})
