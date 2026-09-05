import { describe, expect, it, vi } from 'vitest'
import type { MixtapeApi } from '../api/client'
import type { MusicKitClient } from '../musickit/client'
import type { MusicSnapshot } from '../musickit/library'
import { createMusicSyncService } from './music-sync-service'

const snapshot: MusicSnapshot = {
  storefront: 'ng',
  songs: Array.from({ length: 501 }, (_, ordinal) => ({
    ordinal,
    appleLibraryId: `i.song-${ordinal}`,
    appleCatalogId: `catalog-${ordinal}`,
    title: `Song ${ordinal}`,
    artist: 'Artist',
    album: null,
    genre: null,
    releaseYear: null,
    explicit: null,
    playCount: null,
    lastPlayedAt: null,
    dateAdded: null,
  })),
  playlists: [
    {
      ordinal: 0,
      appleLibraryId: 'p-1',
      appleCatalogId: null,
      name: 'Playlist',
      description: null,
      curatorName: null,
      artworkUrlTemplate: null,
      artworkWidth: null,
      artworkHeight: null,
      artworkBgColor: null,
      kind: 'user',
      canEdit: true,
      appleDateAdded: null,
      appleLastModifiedAt: null,
      sourceFingerprint: 'a'.repeat(64),
      entryCount: 2,
    },
  ],
  playlistEntries: [0, 1].map((position) => ({
    playlistAppleId: 'p-1',
    position,
    appleLibraryEntryId: `entry-${position}`,
    appleLibraryTrackId: `i.song-${position}`,
    appleCatalogId: `catalog-${position}`,
    isrcSnapshot: null,
    titleSnapshot: `Song ${position}`,
    artistSnapshot: 'Artist',
    albumSnapshot: null,
    durationMsSnapshot: null,
    artworkUrlTemplateSnapshot: null,
    artworkWidthSnapshot: null,
    artworkHeightSnapshot: null,
    artworkBgColorSnapshot: null,
  })),
  recentCatalogIds: ['catalog-2'],
  excludedLibrarySongs: 1,
}

function setup() {
  const calls: string[] = []
  const musicKit = {
    connect: vi.fn(async () => {
      calls.push('connect')
    }),
    snapshot: vi.fn(async () => {
      calls.push('snapshot')
      return snapshot
    }),
  } as unknown as MusicKitClient
  const api = {
    beginLibrarySync: vi.fn(async () => {
      calls.push('begin-library')
      return { syncId: 'library-sync', expiresAt: 1 }
    }),
    putLibrarySongs: vi.fn(async () => {
      calls.push('put-songs')
    }),
    completeLibrarySync: vi.fn(async () => {
      calls.push('complete-library')
      return { songs: 501, catalogResolved: 501, playCountsObserved: 0, recentTracks: 1 }
    }),
    putLibraryRecentTracks: vi.fn(async () => {
      calls.push('put-recent')
    }),
    beginPlaylistSync: vi.fn(async () => {
      calls.push('begin-playlists')
      return { syncId: 'playlist-sync', expiresAt: 1 }
    }),
    putPlaylists: vi.fn(async () => {
      calls.push('put-playlists')
    }),
    putPlaylistEntries: vi.fn(async () => {
      calls.push('put-entries')
    }),
    completePlaylistSync: vi.fn(async () => {
      calls.push('complete-playlists')
      return { playlists: 1, entries: 2, resolvedEntries: 2, unresolvedEntries: 0 }
    }),
  } as unknown as MixtapeApi
  return { service: createMusicSyncService({ musicKit, api }), musicKit, api, calls }
}

describe('MusicSyncService', () => {
  it('reconciles a lost playlist response without uploading either snapshot twice', async () => {
    const { service, api } = setup()
    vi.mocked(api.completePlaylistSync).mockRejectedValueOnce(new TypeError('lost response'))
    const options = { signal: new AbortController().signal, onProgress: vi.fn() }
    const pending = await service.sync(options)
    expect(pending).toMatchObject({ kind: 'unconfirmed', stage: 'playlists', library: { songs: 501 } })
    if (pending.kind !== 'unconfirmed') throw new Error('Expected an unconfirmed result')
    expect(await pending.check(options)).toMatchObject({ kind: 'complete', songs: 501, playlists: 1 })
    expect(api.beginPlaylistSync).toHaveBeenCalledOnce()
    expect(api.putPlaylistEntries).toHaveBeenCalledOnce()
    expect(api.completeLibrarySync).toHaveBeenCalledOnce()
    expect(vi.mocked(api.completePlaylistSync).mock.calls.map(([id]) => id)).toEqual([
      'playlist-sync',
      'playlist-sync',
    ])
  })

  it('keeps published songs when cancellation lands between publications', async () => {
    const { service, api } = setup()
    const controller = new AbortController()
    vi.mocked(api.completeLibrarySync).mockImplementationOnce(async () => {
      controller.abort()
      return { songs: 501, catalogResolved: 501, playCountsObserved: 0, recentTracks: 1 }
    })
    expect(await service.sync({ signal: controller.signal, onProgress: vi.fn() })).toMatchObject({
      kind: 'partial',
      reason: 'cancelled',
      library: { songs: 501 },
    })
    expect(api.beginPlaylistSync).not.toHaveBeenCalled()
  })

  it('reports published library evidence before starting the playlist stage', async () => {
    const { service, api } = setup()
    const onProgress = vi.fn()
    vi.mocked(api.beginPlaylistSync).mockImplementationOnce(async () => {
      expect(onProgress).toHaveBeenLastCalledWith(
        expect.objectContaining({
          stage: 'uploading_playlists',
          completed: 0,
          library: { songs: 501, catalogResolved: 501, playCountsObserved: 0, recentTracks: 1 },
        }),
      )
      return { syncId: 'playlist-sync', expiresAt: 1 }
    })
    expect(await service.sync({ signal: new AbortController().signal, onProgress })).toMatchObject({
      kind: 'complete',
    })
  })

  it('keeps a lost library confirmation unconfirmed and resumes the same publication', async () => {
    const { service, api, musicKit } = setup()
    vi.mocked(api.completeLibrarySync).mockRejectedValueOnce(new TypeError('lost response'))
    const options = { signal: new AbortController().signal, onProgress: vi.fn() }

    const pending = await service.sync(options)
    expect(pending.kind).toBe('unconfirmed')
    expect(api.beginPlaylistSync).not.toHaveBeenCalled()
    if (pending.kind !== 'unconfirmed') throw new Error('Expected an unconfirmed result')
    expect(pending.library).toBeNull()
    const result = await pending.check({ ...options, signal: new AbortController().signal })

    expect(result).toMatchObject({ kind: 'complete', songs: 501, playlists: 1 })
    expect(api.beginLibrarySync).toHaveBeenCalledOnce()
    expect(musicKit.snapshot).toHaveBeenCalledOnce()
    expect(vi.mocked(api.completeLibrarySync).mock.calls.map(([id]) => id)).toEqual([
      'library-sync',
      'library-sync',
    ])
  })

  it('reports saved songs and unchanged playlists when playlist upload fails', async () => {
    const { service, api } = setup()
    vi.mocked(api.putPlaylistEntries).mockRejectedValueOnce(new TypeError('offline'))

    const result = await service.sync({ signal: new AbortController().signal, onProgress: vi.fn() })

    expect(result).toMatchObject({
      kind: 'partial',
      library: { songs: 501, recentTracks: 1 },
      reason: 'failed',
      excludedLibrarySongs: 1,
    })
    expect(api.completePlaylistSync).not.toHaveBeenCalled()
  })

  it('authorizes, snapshots, then publishes songs before playlists in bounded chunks', async () => {
    const { service, api, calls } = setup()
    const progress = vi.fn()

    const result = await service.sync({
      signal: new AbortController().signal,
      onProgress: progress,
    })

    expect(calls).toEqual([
      'connect',
      'snapshot',
      'begin-library',
      'put-songs',
      'put-songs',
      'put-recent',
      'complete-library',
      'begin-playlists',
      'put-playlists',
      'put-entries',
      'complete-playlists',
    ])
    expect(vi.mocked(api.putLibrarySongs).mock.calls.map(([, songs]) => songs.length)).toEqual([500, 1])
    expect(api.beginPlaylistSync).toHaveBeenCalledWith(
      expect.objectContaining({
        source: 'web_musickit',
      }),
      expect.any(AbortSignal),
    )
    expect(result).toMatchObject({
      songs: 501,
      playlists: 1,
      entries: 2,
      excludedLibrarySongs: 1,
      recentCatalogIds: ['catalog-2'],
    })
    expect(progress).toHaveBeenLastCalledWith({
      stage: 'complete',
      completed: 1,
      total: 1,
    })
  })

  it('does not begin server publication when browser snapshotting fails', async () => {
    const { service, musicKit, api } = setup()
    vi.mocked(musicKit.snapshot).mockRejectedValue(new Error('offline'))

    await expect(service.sync({ signal: new AbortController().signal, onProgress: vi.fn() })).rejects.toThrow(
      'offline',
    )
    expect(api.beginLibrarySync).not.toHaveBeenCalled()
    expect(api.beginPlaylistSync).not.toHaveBeenCalled()
  })

  it('stops between chunks when cancelled', async () => {
    const { service, api } = setup()
    const controller = new AbortController()
    vi.mocked(api.putLibrarySongs).mockImplementationOnce(async (_syncId, songs) => {
      controller.abort()
      return { accepted: songs.length }
    })

    await expect(service.sync({ signal: controller.signal, onProgress: vi.fn() })).rejects.toMatchObject({
      name: 'AbortError',
    })
    expect(api.putLibrarySongs).toHaveBeenCalledOnce()
    expect(api.completeLibrarySync).not.toHaveBeenCalled()
    expect(api.beginPlaylistSync).not.toHaveBeenCalled()
  })
})
