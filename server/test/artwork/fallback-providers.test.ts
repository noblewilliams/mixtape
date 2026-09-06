import { describe, expect, it, vi } from 'vitest'
import { createDeezerArtworkClient } from '../../src/artwork/deezer'
import { ArtworkProviderError } from '../../src/artwork/provider'
import { createSpotifyOEmbedArtworkClient } from '../../src/artwork/spotify-oembed'
import { SPOTIFY_A } from '../helpers/listening-fixtures'

const ISRC = 'USUG11904206'
const SPOTIFY_IMAGE = 'https://i.scdn.co/image/ab67616d00001e02ff9ca10b55ce82ae553c8228'
const SPOTIFY_IMAGE_CDN = 'https://image-cdn-ak.spotifycdn.com/image/ab67616d00001e02ff9ca10b55ce82ae553c8228'
const SPOTIFY_REGIONAL_IMAGE_CDN = 'https://image-cdn-fa.spotifycdn.com/image/ab67616d00001e02ff9ca10b55ce82ae553c8228'
const DEEZER_IMAGE = 'https://e-cdns-images.dzcdn.net/images/cover/abc123/1000x1000-000000-80-0-0.jpg'
const DEEZER_CURRENT_IMAGE = 'https://cdn-images.dzcdn.net/images/cover/abc123/1000x1000-000000-80-0-0.jpg'

function spotifyPayload(over: Record<string, unknown> = {}) {
  return {
    html: '<iframe></iframe>',
    width: 456,
    height: 152,
    version: '1.0',
    provider_name: 'Spotify',
    provider_url: 'https://spotify.com',
    type: 'rich',
    title: 'Song',
    thumbnail_url: SPOTIFY_IMAGE,
    thumbnail_width: 300,
    thumbnail_height: 300,
    ...over,
  }
}

function deezerPayload(over: Record<string, unknown> = {}) {
  return {
    id: 3135556,
    readable: true,
    title: 'Song',
    duration: 200,
    isrc: ISRC,
    artist: { id: 1, name: 'Artist' },
    album: { id: 2, title: 'Album', cover_xl: DEEZER_IMAGE },
    ...over,
  }
}

describe('Spotify oEmbed artwork', () => {
  it('requests one exact public track URL and accepts a fixed Spotify CDN thumbnail', async () => {
    const fetchLike = vi.fn(async (_input: string | URL, _init?: RequestInit) => Response.json(spotifyPayload()))
    const client = createSpotifyOEmbedArtworkClient({ fetchLike })

    await expect(client.getArtwork(SPOTIFY_A)).resolves.toEqual({
      url: SPOTIFY_IMAGE,
      width: 300,
      height: 300,
      bgColor: null,
    })
    const requested = new URL(String(fetchLike.mock.calls[0][0]))
    expect(requested.origin + requested.pathname).toBe('https://open.spotify.com/oembed')
    expect(requested.searchParams.get('url')).toBe(`https://open.spotify.com/track/${SPOTIFY_A}`)
    expect(fetchLike.mock.calls[0][1]).toMatchObject({ signal: expect.any(AbortSignal) })
  })

  it('returns no match for a 404 or a valid response without a thumbnail', async () => {
    const missing = createSpotifyOEmbedArtworkClient({
      fetchLike: async () => new Response(null, { status: 404 }),
    })
    const noThumbnail = createSpotifyOEmbedArtworkClient({
      fetchLike: async () => Response.json(spotifyPayload({ thumbnail_url: null })),
    })
    await expect(missing.getArtwork(SPOTIFY_A)).resolves.toBeNull()
    await expect(noThumbnail.getArtwork(SPOTIFY_A)).resolves.toBeNull()
  })

  it.each([SPOTIFY_IMAGE_CDN, SPOTIFY_REGIONAL_IMAGE_CDN])(
    'accepts Spotify regional image CDN host %s',
    async (thumbnailUrl) => {
      const client = createSpotifyOEmbedArtworkClient({
        fetchLike: async () => Response.json(spotifyPayload({ thumbnail_url: thumbnailUrl })),
      })

      await expect(client.getArtwork(SPOTIFY_A)).resolves.toMatchObject({ url: thumbnailUrl })
    },
  )

  it.each([
    ['wrong host', 'https://example.com/cover.jpg'],
    ['Spotify lookalike host', `https://image-cdn-ak.spotifycdn.com.example.com/image/abc`],
    ['credentials', 'https://user:secret@i.scdn.co/image/abc'],
    ['query string', `${SPOTIFY_IMAGE}?token=private`],
  ])('rejects a %s thumbnail without exposing its URL', async (_label, thumbnailUrl) => {
    const client = createSpotifyOEmbedArtworkClient({
      fetchLike: async () => Response.json(spotifyPayload({ thumbnail_url: thumbnailUrl })),
    })
    const error = await client.getArtwork(SPOTIFY_A).catch((value) => value)
    expect(error).toBeInstanceOf(ArtworkProviderError)
    expect(error).toMatchObject({ category: 'response' })
    expect(String(error)).not.toContain(thumbnailUrl)
  })

  it('maps rate limits and rejects oversized response bodies with fixed errors', async () => {
    const limited = createSpotifyOEmbedArtworkClient({
      fetchLike: async () => new Response(null, { status: 429 }),
    })
    await expect(limited.getArtwork(SPOTIFY_A)).rejects.toMatchObject({ category: 'rate_limit' })

    const oversized = createSpotifyOEmbedArtworkClient({
      fetchLike: async () => new Response('x'.repeat(129)), maxResponseBytes: 128,
    })
    await expect(oversized.getArtwork(SPOTIFY_A)).rejects.toMatchObject({ category: 'response' })
  })

  it('times out a stalled request with a fixed category', async () => {
    const stalled = createSpotifyOEmbedArtworkClient({
      timeoutMs: 1,
      fetchLike: async (_input, init) => new Promise((_resolve, reject) => {
        init?.signal?.addEventListener('abort', () => reject(new Error('request URL was private')))
      }),
    })
    const error = await stalled.getArtwork(SPOTIFY_A).catch((value) => value)
    expect(error).toMatchObject({ category: 'timeout' })
    expect(String(error)).not.toContain('request URL was private')
  })

  it('rejects invalid Spotify ids before making a request', async () => {
    const fetchLike = vi.fn()
    const client = createSpotifyOEmbedArtworkClient({ fetchLike })
    await expect(client.getArtwork('bad/id')).rejects.toMatchObject({ category: 'response' })
    expect(fetchLike).not.toHaveBeenCalled()
  })
})

describe('Deezer exact-ISRC artwork fallback', () => {
  it('uses only the public ISRC identity and accepts an exact response', async () => {
    const fetchLike = vi.fn(async (_input: string | URL, _init?: RequestInit) => Response.json(deezerPayload()))
    const client = createDeezerArtworkClient({ fetchLike })

    await expect(client.getArtwork(ISRC)).resolves.toEqual({
      url: DEEZER_IMAGE,
      width: 1000,
      height: 1000,
      bgColor: null,
    })
    const requested = new URL(String(fetchLike.mock.calls[0][0]))
    expect(requested.origin).toBe('https://api.deezer.com')
    expect(requested.pathname).toBe(`/track/isrc:${ISRC}`)
    expect(requested.search).toBe('')
  })

  it('treats Deezer no-data as a miss but rejects a mismatched ISRC', async () => {
    const missing = createDeezerArtworkClient({
      fetchLike: async () => Response.json({ error: { type: 'DataException', code: 800 } }),
    })
    await expect(missing.getArtwork(ISRC)).resolves.toBeNull()

    const mismatch = createDeezerArtworkClient({
      fetchLike: async () => Response.json(deezerPayload({ isrc: 'GBUM71029604' })),
    })
    await expect(mismatch.getArtwork(ISRC)).rejects.toMatchObject({ category: 'response' })
  })

  it('accepts the current Deezer image CDN host', async () => {
    const client = createDeezerArtworkClient({
      fetchLike: async () => Response.json(deezerPayload({
        album: { id: 2, title: 'Album', cover_xl: DEEZER_CURRENT_IMAGE },
      })),
    })

    await expect(client.getArtwork(ISRC)).resolves.toMatchObject({ url: DEEZER_CURRENT_IMAGE })
  })

  it('rejects untrusted cover hosts and maps authorization failures', async () => {
    const badCover = createDeezerArtworkClient({
      fetchLike: async () => Response.json(deezerPayload({
        album: { id: 2, title: 'Album', cover_xl: 'https://example.com/cover.jpg' },
      })),
    })
    await expect(badCover.getArtwork(ISRC)).rejects.toMatchObject({ category: 'response' })

    const lookalikeCover = createDeezerArtworkClient({
      fetchLike: async () => Response.json(deezerPayload({
        album: {
          id: 2,
          title: 'Album',
          cover_xl: 'https://cdn-images.dzcdn.net.example.com/images/cover/abc123/1000x1000-000000-80-0-0.jpg',
        },
      })),
    })
    await expect(lookalikeCover.getArtwork(ISRC)).rejects.toMatchObject({ category: 'response' })

    const unauthorized = createDeezerArtworkClient({
      fetchLike: async () => new Response(null, { status: 403 }),
    })
    await expect(unauthorized.getArtwork(ISRC)).rejects.toMatchObject({ category: 'authorization' })
  })
})
