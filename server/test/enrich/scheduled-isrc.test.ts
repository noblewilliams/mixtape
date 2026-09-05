import { describe, expect, it, vi } from 'vitest'
import { handleScheduled } from '../../src/enrich/scheduled'
import { createTestDb } from '../helpers/db'
import { okDeps } from '../helpers/enrich-fixtures'
import { tracks, userTracks, userMusicProfiles, userMusicSources } from '../../src/db/schema'
import { seedUser, SPOTIFY_A, now } from '../helpers/listening-fixtures'
import { fetchTracksBySpotifyIds, fetchAudioFeaturesBySpotifyIds } from '../../src/enrich/reccobeats-by-id'
import { createAppleCatalogClient } from '../../src/musickit/catalog'
import { createSpotifyOEmbedArtworkClient } from '../../src/artwork/spotify-oembed'
import { createDeezerArtworkClient } from '../../src/artwork/deezer'

const empty = { processed: 0, linked: 0, missing: 0, ambiguous: 0, conflicts: 0, failed: 0, skipped: 0 }

describe('scheduled Apple ISRC linking', () => {
  it('carries a freshly observed Spotify ISRC through the real adapters in one maintenance pass', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await db.insert(userMusicProfiles).values({ userId: 'u1', country: 'GB' })
    await db.insert(userMusicSources).values({ userId: 'u1', source: 'spotify_export', lastImportedAt: now })
    const [row] = await db.insert(tracks).values({ spotifyId: SPOTIFY_A, title: 'Song', artist: 'Various Artists', artistSource: 'export' }).returning()
    await db.insert(userTracks).values({ userId: 'u1', trackId: row.id, inLibrary: false, playCount: 5 })
    const calls: string[] = []
    const isrc = 'USUG11904206'
    const fetchLike = async (input: string | URL) => {
      const url = new URL(input)
      calls.push(url.pathname)
      if (url.host === 'api.reccobeats.com') return Response.json({ content: [{
        href: `https://open.spotify.com/track/${SPOTIFY_A}`, isrc,
        trackTitle: 'Song', artists: [{ name: 'Credited artist' }], durationMs: 180000,
        tempo: 120, energy: 0.7,
      }] })
      expect(url.pathname).toBe('/v1/catalog/gb/songs')
      expect(url.searchParams.get('filter[isrc]')).toBe(isrc)
      return Response.json({ data: [{ id: '123', type: 'songs', attributes: {
        isrc, name: 'Song', artistName: 'Credited artist', genreNames: ['Pop'],
        artwork: { url: 'https://is1-ssl.mzstatic.com/image/{w}x{h}.jpg', bgColor: 'aabbcc' },
      } }] })
    }
    const catalog = createAppleCatalogClient({ fetchLike, issueServerToken: async () => ({ developerToken: 'server-token', expiresAt: 9999999999 }) })
    const result = await handleScheduled(db, {
      enrichment: { ...okDeps, spotify: {
        tracks: ids => fetchTracksBySpotifyIds(ids, fetchLike),
        features: ids => fetchAudioFeaturesBySpotifyIds(ids, fetchLike),
      } }, appleIsrc: { catalog },
      spotifyArtwork: {
        spotify: createSpotifyOEmbedArtworkClient({ fetchLike }),
        deezer: createDeezerArtworkClient({ fetchLike }),
      },
      artwork: { storefront: 'ng', catalog },
    })
    expect(result.enrichment).toMatchObject({ features: 1, meaning: 1 })
    expect(result.appleIsrc).toMatchObject({ linked: 1, failed: 0 })
    expect(calls).toEqual(['/v1/track', '/v1/audio-features', '/v1/catalog/gb/songs'])
    expect(await db.select().from(tracks)).toMatchObject([{
      spotifyId: SPOTIFY_A, appleId: '123', appleCatalogStorefront: 'gb', isrc,
      artist: 'Credited artist', artworkBgColor: 'aabbcc',
    }])
    expect(await db.select().from(userTracks)).toMatchObject([{ playCount: 5, inLibrary: false }])
  })

  it('runs after metadata enrichment, before artwork, even without the AI binding', async () => {
    const db = await createTestDb()
    const order: string[] = []
    const appleIsrc = vi.fn(async () => { order.push('isrc'); return empty })
    const enrichment = vi.fn(async () => { order.push('metadata'); return { processed: 0, features: 0, meaning: 0, remaining: 0 } })
    const spotifyArtwork = vi.fn(async () => { order.push('spotify-artwork'); return {
      processed: 0, matched: 0, spotify: 0, deezer: 0, missing: 0, failed: 0, skipped: 0, remaining: 0,
    } })
    const artwork = vi.fn(async () => { order.push('artwork'); return { processed: 0, matched: 0, missing: 0, failed: 0, remaining: 0 } })
    const catalog = { getSongs: async () => new Map(), getSongsByIsrc: async () => new Map() }
    const deps = {
      enrichment: okDeps,
      appleIsrc: { catalog },
      spotifyArtwork: { spotify: { getArtwork: async () => null } },
      artwork: { storefront: 'ng', catalog },
    }
    const result = await handleScheduled(db, deps, { appleIsrc, enrichment, spotifyArtwork, artwork })
    expect(order).toEqual(['metadata', 'isrc', 'spotify-artwork', 'artwork'])
    expect(result.appleIsrc).toEqual(empty)
    expect(appleIsrc).toHaveBeenCalledWith(db, deps.appleIsrc)
    await handleScheduled(db, { appleIsrc: { catalog } }, { appleIsrc })
    expect(appleIsrc).toHaveBeenCalledTimes(2)
  })

  it('keeps artwork running after an ISRC failure without exposing the exception', async () => {
    const db = await createTestDb()
    const artwork = vi.fn(async () => ({ processed: 0, matched: 0, missing: 0, failed: 0, remaining: 0 }))
    const catalog = { getSongs: async () => new Map(), getSongsByIsrc: async () => new Map() }
    const result = await handleScheduled(db, { appleIsrc: { catalog }, artwork: { storefront: 'ng', catalog } }, {
      appleIsrc: async () => { throw new Error('private provider response') }, artwork,
    })
    expect(result.appleIsrc).toEqual({ error: 'failed' })
    expect(artwork).toHaveBeenCalledOnce()
    expect(JSON.stringify(result)).not.toContain('private provider response')
  })

  it('stores oEmbed artwork in the same pass when Apple has no exact match', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await db.insert(userMusicProfiles).values({ userId: 'u1', country: 'GB' })
    await db.insert(userMusicSources).values({ userId: 'u1', source: 'spotify_export', lastImportedAt: now })
    const [row] = await db.insert(tracks).values({
      spotifyId: SPOTIFY_A, isrc: 'USUG11904206', title: 'Song', artist: 'Artist',
    }).returning()
    await db.insert(userTracks).values({ userId: 'u1', trackId: row.id, inLibrary: true })
    const spotifyImage = 'https://i.scdn.co/image/ab67616d00001e02ff9ca10b55ce82ae553c8228'
    const fetchLike = vi.fn(async (input: string | URL) => {
      const url = new URL(input)
      if (url.host === 'api.music.apple.com') return Response.json({ data: [] })
      expect(url.origin + url.pathname).toBe('https://open.spotify.com/oembed')
      return Response.json({
        html: '<iframe></iframe>', width: 456, height: 152, version: '1.0',
        provider_name: 'Spotify', provider_url: 'https://spotify.com', type: 'rich', title: 'Song',
        thumbnail_url: spotifyImage, thumbnail_width: 300, thumbnail_height: 300,
      })
    })
    const catalog = createAppleCatalogClient({
      fetchLike,
      issueServerToken: async () => ({ developerToken: 'server-token', expiresAt: 9999999999 }),
    })

    const result = await handleScheduled(db, {
      appleIsrc: { catalog, now: () => now },
      spotifyArtwork: {
        spotify: createSpotifyOEmbedArtworkClient({ fetchLike }),
        deezer: createDeezerArtworkClient({ fetchLike }),
        now: () => now,
      },
    })

    expect(result.appleIsrc).toMatchObject({ processed: 1, missing: 1 })
    expect(result.spotifyArtwork).toMatchObject({ processed: 1, matched: 1, spotify: 1 })
    expect((await db.select().from(tracks))[0].artworkUrlTemplate).toBe(spotifyImage)
    expect(fetchLike).toHaveBeenCalledTimes(2)
  })

  it('isolates fallback failure from Apple artwork and hides provider details', async () => {
    const db = await createTestDb()
    const artwork = vi.fn(async () => ({ processed: 0, matched: 0, missing: 0, failed: 0, remaining: 0 }))
    const catalog = { getSongs: async () => new Map(), getSongsByIsrc: async () => new Map() }
    const result = await handleScheduled(db, {
      spotifyArtwork: { spotify: { getArtwork: async () => null } },
      artwork: { storefront: 'ng', catalog },
    }, {
      spotifyArtwork: async () => { throw new Error('private provider response') },
      artwork,
    })
    expect(result.spotifyArtwork).toEqual({ error: 'failed' })
    expect(artwork).toHaveBeenCalledOnce()
    expect(JSON.stringify(result)).not.toContain('private provider response')
  })
})
