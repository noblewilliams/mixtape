import { afterEach, describe, expect, it, vi } from 'vitest'
import { createMusicKitClient, MusicKitClientError, type MusicKitGlobal, type MusicKitInstance } from './client'

function setup() {
  const instance: MusicKitInstance = {
    isAuthorized: false,
    authorize: vi.fn(async () => 'music-user-token'),
    setQueue: vi.fn(async () => undefined),
    play: vi.fn(),
    pause: vi.fn(),
  }
  const musicKit: MusicKitGlobal = {
    configure: vi.fn(async () => instance),
    getInstance: vi.fn(() => instance),
  }
  const getDeveloperToken = vi.fn(async () => ({
    developerToken: 'developer-token',
    expiresAt: Math.floor(Date.now() / 1000) + 3600,
  }))
  const fetchImpl = vi.fn<typeof fetch>()
  const client = createMusicKitClient({
    getDeveloperToken,
    loadMusicKit: async () => musicKit,
    fetchImpl,
  })

  return { client, instance, musicKit, getDeveloperToken, fetchImpl }
}

describe('MusicKit browser client', () => {
  it.each([{}, { data: [] }, { data: [{ id: 'p.1', type: 'songs' }] },
    { data: [{ id: 'bad/id', type: 'library-playlists' }] }])(
    'keeps successful creation successful when its receipt is unusable', async (payload) => {
      const { client, fetchImpl } = setup()
      fetchImpl.mockResolvedValue(new Response(JSON.stringify(payload), { status: 201 }))
      await client.connect()
      const onCreated = vi.fn()
      await expect(client.createPlaylist('Mix', ['123'], onCreated)).resolves.toBeUndefined()
      expect(onCreated).not.toHaveBeenCalled()
    },
  )
  it('does not fail successful creation if recording its ID throws', async () => {
    const { client, fetchImpl } = setup()
    fetchImpl.mockResolvedValue(new Response(JSON.stringify({ data: [{ id: 'p.1', type: 'library-playlists' }] }), { status: 201 }))
    await client.connect()
    await expect(client.createPlaylist('Mix', ['123'], () => { throw new Error('offline') })).resolves.toBeUndefined()
  })
  afterEach(() => vi.restoreAllMocks())

  it('configures Apple Music and authorizes the listener without persisting the user token', async () => {
    const { client, instance, musicKit, getDeveloperToken } = setup()

    await client.connect()

    expect(getDeveloperToken).toHaveBeenCalledOnce()
    expect(musicKit.configure).toHaveBeenCalledWith({
      developerToken: 'developer-token',
      app: { name: 'Mixtape', build: '0.1.0' },
    })
    expect(instance.authorize).toHaveBeenCalledOnce()
    expect(localStorage).toHaveLength(0)
    expect(sessionStorage).toHaveLength(0)
  })

  it('sets the ordered catalog-song queue before starting playback', async () => {
    const { client, instance } = setup()
    await client.connect()

    await client.play(['song-1', 'song-2'])

    expect(instance.setQueue).toHaveBeenCalledWith({ songs: ['song-1', 'song-2'] })
    expect(instance.play).toHaveBeenCalledOnce()
    expect(vi.mocked(instance.setQueue).mock.invocationCallOrder[0]).toBeLessThan(
      vi.mocked(instance.play).mock.invocationCallOrder[0],
    )
  })

  it('creates an Apple Music playlist with developer and in-memory user authorization', async () => {
    const { client, fetchImpl } = setup()
    fetchImpl.mockResolvedValue(new Response(JSON.stringify({ data: [{ id: 'p.123', type: 'library-playlists' }] }), { status: 201 }))
    await client.connect()

    const onCreated = vi.fn()
    await client.createPlaylist('Blue hour', ['song-1', 'song-2'], onCreated)
    expect(onCreated).toHaveBeenCalledExactlyOnceWith('p.123')

    expect(fetchImpl).toHaveBeenCalledWith(
      'https://api.music.apple.com/v1/me/library/playlists',
      expect.objectContaining({
        method: 'POST',
        headers: {
          Authorization: 'Bearer developer-token',
          'Content-Type': 'application/json',
          'Music-User-Token': 'music-user-token',
        },
        body: JSON.stringify({
          attributes: { name: 'Blue hour', description: 'Created with Mixtape' },
          relationships: {
            tracks: {
              data: [
                { id: 'song-1', type: 'songs' },
                { id: 'song-2', type: 'songs' },
              ],
            },
          },
        }),
      }),
    )
  })

  it('treats a dismissed Apple authorization sheet as a recoverable connection error', async () => {
    const { client, instance } = setup()
    vi.mocked(instance.authorize).mockResolvedValue(undefined)

    await expect(client.connect()).rejects.toBeInstanceOf(MusicKitClientError)
    await expect(client.connect()).rejects.toMatchObject({ code: 'authorization_cancelled' })
  })

  it('materializes a paged library, ordered duplicate playlist entries, and recent tracks', async () => {
    const { client, fetchImpl } = setup()
    fetchImpl
      .mockResolvedValueOnce(json({ data: [{ id: 'ng', type: 'storefronts' }] }))
      .mockResolvedValueOnce(json({
        data: [{
          id: 'i.song-1',
          type: 'library-songs',
          attributes: {
            name: 'First', artistName: 'Artist', albumName: 'Album',
            genreNames: ['Alternative'], releaseDate: '2024-03-01',
            contentRating: 'explicit', dateAdded: '2026-08-01T12:00:00.000Z',
            playParams: { catalogId: 'catalog-1' },
          },
        }],
        next: '/v1/me/library/songs?offset=1',
      }))
      .mockResolvedValueOnce(json({
        data: [
          {
            id: 'i.local-only', type: 'library-songs',
            attributes: { name: 'Local', artistName: 'Artist' },
          },
          {
            id: 'i.song-2', type: 'library-songs',
            attributes: { name: 'Second', artistName: 'Artist', playParams: { catalogId: 'catalog-2' } },
          },
        ],
      }))
      .mockResolvedValueOnce(json({
        data: [{
          id: 'p.library-1',
          type: 'library-playlists',
          attributes: {
            name: 'Repeat one', canEdit: true,
            artwork: { url: 'https://img/{w}x{h}.jpg', width: 800, height: 800, bgColor: 'A1B2C3' },
          },
        }],
      }))
      .mockResolvedValueOnce(json({
        data: [
          {
            id: 'i.song-1', type: 'library-songs',
            attributes: { name: 'First', artistName: 'Artist', playParams: { catalogId: 'catalog-1' } },
          },
          {
            id: 'i.song-1', type: 'library-songs',
            attributes: { name: 'First', artistName: 'Artist', playParams: { catalogId: 'catalog-1' } },
          },
          {
            id: 'i.local-only', type: 'library-songs',
            attributes: { name: 'Local', artistName: 'Artist' },
          },
        ],
      }))
      .mockResolvedValueOnce(json({
        data: [{ id: 'catalog-2', type: 'songs', attributes: { name: 'Second', artistName: 'Artist' } }],
      }))
    await client.connect()
    const progress = vi.fn()

    const snapshot = await client.snapshot({ signal: new AbortController().signal, onProgress: progress })

    expect(snapshot.storefront).toBe('ng')
    expect(snapshot.songs.map((song) => song.appleCatalogId)).toEqual(['catalog-1', 'catalog-2'])
    expect(snapshot.songs.every((song) => song.playCount === null)).toBe(true)
    expect(snapshot.excludedLibrarySongs).toBe(1)
    expect(snapshot.playlists).toMatchObject([{ name: 'Repeat one', entryCount: 3, artworkBgColor: 'a1b2c3' }])
    expect(snapshot.playlistEntries.map((entry) => entry.appleCatalogId)).toEqual([
      'catalog-1', 'catalog-1', null,
    ])
    expect(new Set(snapshot.playlistEntries.map((entry) => entry.appleLibraryEntryId)).size).toBe(3)
    expect(snapshot.recentCatalogIds).toEqual(['catalog-2'])
    expect(progress).toHaveBeenLastCalledWith(expect.objectContaining({ stage: 'complete' }))
    expect(localStorage).toHaveLength(0)
    expect(sessionStorage).toHaveLength(0)
  })

  it('rejects pagination that tries to leave the Apple Music API origin', async () => {
    const { client, fetchImpl } = setup()
    fetchImpl
      .mockResolvedValueOnce(json({ data: [{ id: 'ng', type: 'storefronts' }] }))
      .mockResolvedValueOnce(json({ data: [], next: 'https://evil.example/collect' }))
    await client.connect()

    await expect(client.snapshot({ signal: new AbortController().signal, onProgress: vi.fn() }))
      .rejects.toMatchObject({ code: 'library_failed' })
    expect(fetchImpl).toHaveBeenCalledTimes(2)
  })

  it('clears in-memory Apple authorization after an authorization response', async () => {
    const { client, fetchImpl } = setup()
    fetchImpl.mockResolvedValueOnce(json({ error: 'forbidden' }, 403))
    await client.connect()

    await expect(client.snapshot({ signal: new AbortController().signal, onProgress: vi.fn() }))
      .rejects.toMatchObject({ code: 'authorization_failed' })
    await expect(client.snapshot({ signal: new AbortController().signal, onProgress: vi.fn() }))
      .rejects.toMatchObject({ code: 'not_connected' })
  })
})

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  })
}
