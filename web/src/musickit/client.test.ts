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
    fetchImpl.mockResolvedValue(new Response(JSON.stringify({ data: [{ id: 'p.123' }] }), { status: 201 }))
    await client.connect()

    await client.createPlaylist('Blue hour', ['song-1', 'song-2'])

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
})
