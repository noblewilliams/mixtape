import { describe, expect, it } from 'vitest'
import { diagnoseExport } from './diagnostics'
import { PARSER_VERSION } from './spotify-parser'
import { openZipArchive } from './zip-reader'
import { listFixtureCases, readExpected, readFixtureArchive, recordingArchive } from '../test/listening-export-fixtures'

describe('diagnoseExport', () => {
  it('lists sentinel files with byte sizes only and never reads them', async () => {
    const piiCase = listFixtureCases().find((fixture) => fixture.name === 'account-pii-present')!
    const archive = recordingArchive(await openZipArchive(readFixtureArchive(piiCase.name)))
    const diagnostics = await diagnoseExport(archive)
    expect(diagnostics.source).toBe('spotify_export')
    expect(diagnostics.parserVersion).toBe(PARSER_VERSION)
    const expected = readExpected(piiCase.name, 'default')
    for (const ignored of expected.inventory.ignored) {
      expect(diagnostics.files).toContainEqual({ path: ignored.path, bytes: ignored.bytes, rows: null, headers: null })
    }
    for (const sentinel of piiCase.sentinelPaths) expect(archive.readPaths).not.toContain(sentinel)
    expect(JSON.stringify(diagnostics)).not.toContain('DO-NOT-READ')
    expect(diagnostics.files.map((file) => file.path)).toEqual(
      [...expected.inventory.read.map((file) => file.path), ...expected.inventory.ignored.map((file) => file.path)].sort(),
    )
  })

  it('reports row counts and top-level key names for the files the package reads, never values', async () => {
    const archive = await openZipArchive(readFixtureArchive('account-pii-present'))
    const { files } = await diagnoseExport(archive)
    const expected = readExpected('account-pii-present', 'default')
    const library = files.find((file) => file.path.endsWith('/YourLibrary.json'))!
    const playlist = files.find((file) => file.path.endsWith('/Playlist1.json'))!
    expect(library.rows).toBe(expected.inventory.read.find((file) => file.path === library.path)?.rows)
    expect(library.headers).toEqual(expect.arrayContaining(['tracks', 'artists']))
    expect(playlist.rows).toBe(1)
    expect(playlist.headers).toEqual(['playlists'])
    const snapshot = expected.snapshot as { tracks: { title: string; artist: string }[]; playlists: { name: string }[] }
    const text = JSON.stringify(files)
    for (const track of snapshot.tracks) {
      expect(text).not.toContain(track.title)
      expect(text).not.toContain(track.artist)
    }
    for (const playlistRow of snapshot.playlists) expect(text).not.toContain(playlistRow.name)
  })

  it('marks a broken file with null rows and headers and keeps the valid one', async () => {
    const { files } = await diagnoseExport(await openZipArchive(readFixtureArchive('extended-malformed')))
    expect(files).toEqual([
      {
        path: 'Spotify Extended Streaming History/Streaming_History_Audio_2024-2025_0.json',
        bytes: expect.any(Number),
        rows: 2,
        headers: expect.arrayContaining(['ts', 'ms_played', 'spotify_track_uri']),
      },
      {
        path: 'Spotify Extended Streaming History/Streaming_History_Audio_2025-2026_1.json',
        bytes: expect.any(Number),
        rows: null,
        headers: null,
      },
    ])
  })

  it('does not read a library file travelling with an extended package', async () => {
    const archive = recordingArchive(await openZipArchive(readFixtureArchive('extended-nested-folder')))
    const { files } = await diagnoseExport(archive)
    const library = files.find((file) => file.path.toLowerCase().endsWith('yourlibrary.json'))!
    expect(library).toMatchObject({ rows: null, headers: null })
    expect(archive.readPaths).not.toContain(library.path)
    expect(archive.readPaths.length).toBeGreaterThan(0)
  })
})
