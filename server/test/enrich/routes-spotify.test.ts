import { describe, expect, it } from 'vitest'
import { createApp, type AuthLike } from '../../src/app'
import { tracks, trackFeatures } from '../../src/db/schema'
import { fetchTracksBySpotifyIds, fetchAudioFeaturesBySpotifyIds } from '../../src/enrich/reccobeats-by-id'
import type { FetchLike } from '../../src/enrich/types'
import { createTestDb } from '../helpers/db'
import { okDeps } from '../helpers/enrich-fixtures'

const auth: AuthLike = { handler: () => new Response('ok'), api: { getSession: async () => null } }

describe('Spotify enrichment through the admin route', () => {
  it('requires the admin token, then resolves exact IDs and returns counts only', async () => {
    const db = await createTestDb()
    const spotifyId = '4uLU6hMCjMI75M1A2tKUQC'
    await db.insert(tracks).values({
      spotifyId, title: 'Imported song', artist: 'Various Artists', artistSource: 'export',
    })
    const calls: string[] = []
    const fetchLike: FetchLike = async (url) => {
      const path = new URL(url).pathname
      calls.push(path)
      const identity = { href: `https://open.spotify.com/track/${spotifyId}`, isrc: 'NGA0A2000001' }
      return Response.json({ content: [path === '/v1/track'
        ? { ...identity, trackTitle: 'Imported song', artists: [{ name: 'Credited artist' }], durationMs: 180000 }
        : { ...identity, tempo: 120, energy: 0.7, danceability: 0.5 }] })
    }
    const app = createApp({ auth, db, enrich: { adminToken: 'test-secret', deps: {
      ...okDeps,
      features: async () => { throw new Error('Unexpected text lookup') },
      spotify: {
        tracks: (ids) => fetchTracksBySpotifyIds(ids, fetchLike),
        features: (ids) => fetchAudioFeaturesBySpotifyIds(ids, fetchLike),
      },
    } } })
    expect((await app.request('http://x/enrich/run', { method: 'POST' })).status).toBe(401)
    expect(calls).toEqual([])
    const result = await app.request('http://x/enrich/run', {
      method: 'POST', headers: { 'X-Admin-Token': 'test-secret' },
    })
    expect(result.status).toBe(200)
    expect(await result.json()).toEqual({ processed: 1, features: 1, meaning: 1, remaining: 0 })
    expect(calls).toEqual(['/v1/track', '/v1/audio-features'])
    expect(await db.select().from(tracks)).toEqual([expect.objectContaining({
      artist: 'Credited artist', artistSource: 'reccobeats', isrc: 'NGA0A2000001', durationMs: 180000,
    })])
    expect(await db.select().from(trackFeatures)).toEqual([expect.objectContaining({ tempo: 120, energy: 0.7 })])
  })
})
