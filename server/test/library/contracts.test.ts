import { describe, expect, it } from 'vitest'
import {
  beginLibrarySyncSchema,
  librarySongChunkSchema,
  libraryRecentTrackChunkSchema,
} from '../../src/library/contracts'

const song = (over: Record<string, unknown> = {}) => ({
  ordinal: 0,
  appleLibraryId: 'i.abc123',
  appleCatalogId: 'catalog-1',
  title: 'Song',
  artist: 'Artist',
  album: 'Album',
  genre: 'Alternative',
  releaseYear: 2024,
  explicit: false,
  playCount: null,
  lastPlayedAt: null,
  dateAdded: 1_700_000_000_000,
  ...over,
})

describe('library sync contracts', () => {
  it('accepts a web run and an unavailable play count', () => {
    expect(beginLibrarySyncSchema.parse({
      source: 'web_musickit',
      storefront: 'ng',
      expectedSongs: 1,
      expectedRecentTracks: 2,
    })).toEqual({
      source: 'web_musickit', storefront: 'ng', expectedSongs: 1, expectedRecentTracks: 2,
    })
    expect(librarySongChunkSchema.parse({ songs: [song()] }).songs[0].playCount).toBeNull()
  })

  it('accepts a bounded ordered recent-track window', () => {
    expect(libraryRecentTrackChunkSchema.parse({
      catalogIds: ['catalog-2', 'catalog-1'],
    })).toEqual({ catalogIds: ['catalog-2', 'catalog-1'] })
    expect(libraryRecentTrackChunkSchema.safeParse({
      catalogIds: Array.from({ length: 31 }, (_, index) => `catalog-${index}`),
    }).success).toBe(false)
  })

  it('accepts native observed play counts', () => {
    expect(librarySongChunkSchema.parse({ songs: [song({ playCount: 42 })] }).songs[0].playCount)
      .toBe(42)
  })

  it.each([
    ['unknown source', { source: 'spotify', storefront: 'ng', expectedSongs: 1 }],
    ['uppercase storefront', { source: 'web_musickit', storefront: 'NG', expectedSongs: 1 }],
    ['too many songs', { source: 'web_musickit', storefront: 'ng', expectedSongs: 100_001 }],
  ])('rejects %s', (_case, input) => {
    expect(beginLibrarySyncSchema.safeParse(input).success).toBe(false)
  })

  it.each([
    ['unsafe catalog id', song({ appleCatalogId: '1,2' })],
    ['negative ordinal', song({ ordinal: -1 })],
    ['negative play count', song({ playCount: -1 })],
    ['invalid unicode', song({ title: '\ud800' })],
  ])('rejects %s', (_case, input) => {
    expect(librarySongChunkSchema.safeParse({ songs: [input] }).success).toBe(false)
  })

  it('bounds chunks and rejects unknown fields', () => {
    expect(librarySongChunkSchema.safeParse({ songs: [] }).success).toBe(false)
    expect(librarySongChunkSchema.safeParse({
      songs: Array.from({ length: 501 }, (_, ordinal) => song({ ordinal, appleCatalogId: String(ordinal + 1) })),
    }).success).toBe(false)
    expect(librarySongChunkSchema.safeParse({ songs: [song()], token: 'secret' }).success).toBe(false)
  })
})
