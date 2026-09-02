import { describe, expect, it } from 'vitest'
import { canonicalJson, canonicalize } from './canonical'
import type { ListeningExportSnapshot } from './snapshot'

const day = (platformId: string, date: string) => ({
  hoursMask: 1,
  msPlayed: 40000,
  completes: 0,
  skips: 0,
  plays: 1,
  day: date,
  platformId,
})

const libraryRow = (platformId: string) => ({
  likeRating: null,
  dateAdded: null,
  lastPlayedAt: null,
  skipCount: null,
  playCount: null,
  platformId,
})

function scrambled(): ListeningExportSnapshot {
  return {
    ledgerTo: '2026-02-01',
    ledgerFrom: '2024-03-02',
    unresolved: { plays: 1, rows: 2 },
    playlists: [
      {
        entries: [
          { addedAt: null, album: null, artist: 'Second Artist', title: 'Second', platformId: null, position: 1 },
          { position: 0, platformId: 'a000000000000000000000', title: 'First', artist: 'First Artist', album: 'Album', addedAt: 5 },
        ],
        lastModifiedAt: null,
        description: null,
        name: 'Two',
        key: 'k2',
        ordinal: 1,
      },
      { ordinal: 0, key: 'k1', name: 'One', description: 'd', lastModifiedAt: 1, entries: [] },
    ],
    artists: [
      { spotifyId: null, name: 'Same Name' },
      { name: 'Same Name', spotifyId: 'ArtistId00000000000001' },
      { name: 'Alpha', spotifyId: null },
    ],
    library: [libraryRow('b000000000000000000000'), libraryRow('Z000000000000000000000'), libraryRow('a000000000000000000000')],
    days: [
      day('b000000000000000000000', '2024-01-01'),
      day('a000000000000000000000', '2024-02-01'),
      day('a000000000000000000000', '2024-01-01'),
    ],
    tracks: [
      { durationMs: null, album: null, artist: 'x', title: 'y', platformId: 'b000000000000000000000' },
      { platformId: 'a000000000000000000000', title: 't', artist: 'u', album: 'v', durationMs: 3 },
      { platformId: 'Z000000000000000000000', title: 'upper', artist: 'sorts', album: 'first', durationMs: null },
    ],
    country: 'NG',
    timeZone: 'Africa/Lagos',
    package: 'spotify_extended',
    source: 'spotify_export',
  }
}

describe('canonicalize', () => {
  it('emits the contract key order for the snapshot and every row', () => {
    const canonical = canonicalize(scrambled())
    expect(Object.keys(canonical)).toEqual([
      'source', 'package', 'timeZone', 'country', 'tracks', 'days', 'library', 'artists', 'playlists',
      'unresolved', 'ledgerFrom', 'ledgerTo',
    ])
    expect(Object.keys(canonical.tracks[0]!)).toEqual(['platformId', 'title', 'artist', 'album', 'durationMs'])
    expect(Object.keys(canonical.days[0]!)).toEqual(['platformId', 'day', 'plays', 'skips', 'completes', 'msPlayed', 'hoursMask'])
    expect(Object.keys(canonical.library[0]!)).toEqual(['platformId', 'playCount', 'skipCount', 'lastPlayedAt', 'dateAdded', 'likeRating'])
    expect(Object.keys(canonical.artists[0]!)).toEqual(['name', 'spotifyId'])
    expect(Object.keys(canonical.playlists[0]!)).toEqual(['ordinal', 'key', 'name', 'description', 'lastModifiedAt', 'entries'])
    expect(Object.keys(canonical.playlists[1]!.entries[0]!)).toEqual(['position', 'platformId', 'title', 'artist', 'album', 'addedAt'])
    expect(Object.keys(canonical.unresolved)).toEqual(['rows', 'plays'])
  })

  it('sorts by ordinal string comparison: tracks and library by platformId, days by platformId then day', () => {
    const canonical = canonicalize(scrambled())
    expect(canonical.tracks.map((track) => track.platformId)).toEqual([
      'Z000000000000000000000', 'a000000000000000000000', 'b000000000000000000000',
    ])
    expect(canonical.library.map((row) => row.platformId)).toEqual([
      'Z000000000000000000000', 'a000000000000000000000', 'b000000000000000000000',
    ])
    expect(canonical.days.map((row) => `${row.platformId}|${row.day}`)).toEqual([
      'a000000000000000000000|2024-01-01', 'a000000000000000000000|2024-02-01', 'b000000000000000000000|2024-01-01',
    ])
  })

  it('sorts artists by name with spotifyId ties and null last, playlists by ordinal, entries by position', () => {
    const canonical = canonicalize(scrambled())
    expect(canonical.artists).toEqual([
      { name: 'Alpha', spotifyId: null },
      { name: 'Same Name', spotifyId: 'ArtistId00000000000001' },
      { name: 'Same Name', spotifyId: null },
    ])
    expect(canonical.playlists.map((playlist) => playlist.ordinal)).toEqual([0, 1])
    expect(canonical.playlists[1]!.entries.map((entry) => entry.position)).toEqual([0, 1])
  })

  it('leaves the input untouched', () => {
    const input = scrambled()
    const before = JSON.stringify(input)
    canonicalize(input)
    expect(JSON.stringify(input)).toBe(before)
  })
})

describe('canonicalJson', () => {
  it('pretty prints the canonical snapshot with two spaces and a trailing newline', () => {
    const text = canonicalJson(scrambled())
    expect(text).toBe(`${JSON.stringify(canonicalize(scrambled()), null, 2)}\n`)
    expect(text.startsWith('{\n  "source": "spotify_export",\n  "package": "spotify_extended",\n')).toBe(true)
    expect(text.endsWith('}\n')).toBe(true)
  })
})
