import { describe, expect, it } from 'vitest'
import {
  beginPlaylistSyncSchema,
  playlistChunkSchema,
  playlistEntryChunkSchema,
} from '../../src/playlists/contracts'

const playlist = (over: Record<string, unknown> = {}) => ({
  ordinal: 0,
  appleLibraryId: 'library-playlist-1',
  appleCatalogId: null,
  name: 'Evening',
  description: null,
  curatorName: null,
  artworkUrlTemplate: null,
  artworkWidth: null,
  artworkHeight: null,
  artworkBgColor: 'a1b2c3',
  kind: 'user_shared',
  canEdit: false,
  appleDateAdded: null,
  appleLastModifiedAt: 1788200000000,
  sourceFingerprint: 'a'.repeat(64),
  entryCount: 1,
  ...over,
})

const entry = (over: Record<string, unknown> = {}) => ({
  position: 0,
  appleLibraryEntryId: 'entry-1',
  appleLibraryTrackId: 'library-track-1',
  appleCatalogId: null,
  isrcSnapshot: null,
  titleSnapshot: 'Song',
  artistSnapshot: 'Artist',
  albumSnapshot: null,
  durationMsSnapshot: 123000,
  artworkUrlTemplateSnapshot: null,
  artworkWidthSnapshot: null,
  artworkHeightSnapshot: null,
  artworkBgColorSnapshot: '010203',
  ...over,
})

describe('playlist ingest contracts', () => {
  it('accepts zero-count syncs and normalized playlist shapes', () => {
    expect(beginPlaylistSyncSchema.parse({
      storefront: 'ng',
      expectedPlaylists: 0,
      expectedEntries: 0,
    })).toEqual({ storefront: 'ng', expectedPlaylists: 0, expectedEntries: 0 })
    expect(playlistChunkSchema.parse({ playlists: [playlist()] }).playlists).toHaveLength(1)
    expect(playlistEntryChunkSchema.parse({
      playlistAppleId: 'library-playlist-1',
      entries: [entry()],
    }).entries).toHaveLength(1)
  })

  it.each(['NG', 'n', 'nga'])('rejects invalid storefront %j', (storefront) => {
    expect(() => beginPlaylistSyncSchema.parse({
      storefront,
      expectedPlaylists: 0,
      expectedEntries: 0,
    })).toThrow()
  })

  it.each([
    playlist({ artworkBgColor: '#a1b2c3' }),
    playlist({ artworkWidth: 0 }),
    playlist({ sourceFingerprint: 'short' }),
    playlist({ appleLibraryId: 'nul\u0000id' }),
    playlist({ name: '' }),
    playlist({ kind: 'guessed_user' }),
  ])('rejects malformed playlist metadata', (value) => {
    expect(() => playlistChunkSchema.parse({ playlists: [value] })).toThrow()
  })

  it.each([
    entry({ position: -1 }),
    entry({ durationMsSnapshot: -1 }),
    entry({ durationMsSnapshot: 2_147_483_648 }),
    entry({ position: 100_000 }),
    entry({ artworkBgColorSnapshot: 'ABCDEF' }),
    entry({ appleLibraryEntryId: '' }),
    entry({ titleSnapshot: 'nul\u0000title' }),
    entry({ appleCatalogId: 'unsafe/id' }),
  ])('rejects malformed entry metadata', (value) => {
    expect(() => playlistEntryChunkSchema.parse({
      playlistAppleId: 'library-playlist-1',
      entries: [value],
    })).toThrow()
  })

  it('enforces chunk ceilings and accepts an explicit empty entry page', () => {
    expect(() => playlistChunkSchema.parse({
      playlists: Array.from({ length: 51 }, (_, ordinal) => playlist({
        ordinal,
        appleLibraryId: `playlist-${ordinal}`,
      })),
    })).toThrow()
    expect(() => playlistEntryChunkSchema.parse({
      playlistAppleId: 'library-playlist-1',
      entries: Array.from({ length: 201 }, (_, position) => entry({
        position,
        appleLibraryEntryId: `entry-${position}`,
      })),
    })).toThrow()
    expect(playlistEntryChunkSchema.parse({
      playlistAppleId: 'library-playlist-1',
      entries: [],
    }).entries).toEqual([])
  })
})
