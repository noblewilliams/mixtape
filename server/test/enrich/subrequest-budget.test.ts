import { describe, it, expect } from 'vitest'
import { createTestDb, type TestDb } from '../helpers/db'
import { runEnrichmentBatch } from '../../src/enrich/runner'
import type { EnrichDeps } from '../../src/enrich/pipeline'
import { resolveAndFetchFeatures } from '../../src/enrich/reccobeats'
import { fetchTracksBySpotifyIds, fetchAudioFeaturesBySpotifyIds, RECCOBEATS_ID_BATCH } from '../../src/enrich/reccobeats-by-id'
import { fetchLyrics } from '../../src/enrich/lrclib'
import { workersAiEmbedder } from '../../src/enrich/embedder'
import { createAppleCatalogClient } from '../../src/musickit/catalog'
import { APPLE_ISRC_BATCH } from '../../src/enrich/apple-isrc'
import { runSpotifyArtworkBatch, FALLBACK_ARTWORK_BATCH } from '../../src/artwork/spotify-fallback'
import { createSpotifyOEmbedArtworkClient } from '../../src/artwork/spotify-oembed'
import { createDeezerArtworkClient } from '../../src/artwork/deezer'
import { seedUser, now } from '../helpers/listening-fixtures'
import { userTracks, userMusicSources } from '../../src/db/schema'
import {
  APPLE_ISRC_SUBREQUESTS,
  CRON_BATCH,
  ENRICH_CRON_OVERHEAD_SUBREQUESTS,
  FALLBACK_ARTWORK_CALLS_PER_ROW,
  ENRICH_BATCH_CAP,
  ENRICH_BATCH_STEP,
  ENRICH_FIXED_SUBREQUESTS,
  ENRICH_SUBREQUESTS_PER_TRACK,
  ENRICH_SUBREQUEST_BUDGET,
  largestEnrichBatch,
} from '../../src/enrich/scheduled'
import { MAX_BATCH } from '../../src/routes/enrich'
import { tracks } from '../../src/db/schema'

const DURATION_MS = 200_000
const spotifyId = (i: number) => `S${String(i).padStart(21, '0')}`

// Every source answers in the way that costs the most requests: the by-id
// features lookup misses (so the title search runs), the search matches (so
// the features fetch runs), the exact lyrics lookup 404s (so the lyrics
// search runs), and the lyrics carry text (so the embedder runs). Every
// request goes through the real source functions' fetch seam and is counted
// there, so one dep call that makes two requests counts as two.
function worstCase() {
  const calls: string[] = []
  const fetchLike = async (input: string | URL) => {
    const url = new URL(input)
    if (url.host === 'api.reccobeats.com') {
      if (url.pathname === '/v1/track') {
        calls.push('reccobeats by-id tracks')
        const ids = (url.searchParams.get('ids') ?? '').split(',')
        return Response.json({ content: ids.map((id) => ({
          href: `https://open.spotify.com/track/${id}`, trackTitle: 'Song', artists: [{ name: 'Artist' }],
          isrc: null, durationMs: DURATION_MS,
        })) })
      }
      if (url.pathname === '/v1/audio-features') {
        calls.push('reccobeats by-id features')
        return Response.json({ content: [] })
      }
      if (url.pathname === '/v1/track/search') {
        calls.push('reccobeats search')
        return Response.json({ content: [{
          id: 'rb1', trackTitle: url.searchParams.get('searchText'), artists: [{ name: 'Artist' }],
          durationMs: DURATION_MS, isrc: null,
        }] })
      }
      if (url.pathname === '/v1/track/rb1/audio-features') {
        calls.push('reccobeats features')
        return Response.json({ tempo: 120, energy: 0.5 })
      }
    }
    if (url.host === 'lrclib.net') {
      if (url.pathname === '/api/get') {
        calls.push('lrclib get')
        return new Response(null, { status: 404 })
      }
      if (url.pathname === '/api/search') {
        calls.push('lrclib search')
        return Response.json([{ plainLyrics: 'words', instrumental: false, artistName: 'Artist' }])
      }
    }
    throw new Error(`unexpected request ${url.host}${url.pathname}`)
  }
  const ai = {
    run: async () => {
      calls.push('workers ai embed')
      return { data: [Array.from({ length: 1024 }, () => 0)] }
    },
  }
  const deps: EnrichDeps = {
    storefront: 'ng',
    // Production wires iTunes as a no-op (Apple 403s Cloudflare IPs, see
    // buildDeps in src/index.ts), so it makes no request and is not counted.
    itunes: async () => null,
    features: (key) => resolveAndFetchFeatures(key, fetchLike),
    spotify: {
      tracks: (ids) => fetchTracksBySpotifyIds(ids, fetchLike),
      features: (ids) => fetchAudioFeaturesBySpotifyIds(ids, fetchLike),
    },
    lyrics: (key) => fetchLyrics(key, fetchLike),
    embed: workersAiEmbedder(ai),
  }
  return { calls, deps }
}

async function seed(db: TestDb, kind: 'spotify' | 'apple', n: number, offset = 0) {
  for (let i = offset; i < offset + n; i++) {
    await db.insert(tracks).values(kind === 'spotify'
      ? { spotifyId: spotifyId(i), title: `Song ${i}`, artist: 'Artist', durationMs: DURATION_MS, artistSource: 'export' }
      : { appleId: `a${i}`, title: `Song ${i}`, artist: 'Artist', durationMs: DURATION_MS })
  }
}

describe('enrichment subrequest budget', () => {
  it('a Spotify-id row costs the per-track worst case on top of the two shared by-id lookups', async () => {
    for (const n of [1, 3, 8]) {
      const db = await createTestDb()
      await seed(db, 'spotify', n)
      const { calls, deps } = worstCase()
      expect(await runEnrichmentBatch(db, deps, n)).toMatchObject({ processed: n, features: n, meaning: n })
      expect(calls).toHaveLength(ENRICH_FIXED_SUBREQUESTS + ENRICH_SUBREQUESTS_PER_TRACK * n)
      expect(calls.filter((c) => c.startsWith('reccobeats by-id'))).toEqual([
        'reccobeats by-id tracks', 'reccobeats by-id features',
      ])
    }
  })

  it('an Apple-only row costs the same per-track worst case with no shared lookups', async () => {
    for (const n of [1, 3, 8]) {
      const db = await createTestDb()
      await seed(db, 'apple', n)
      const { calls, deps } = worstCase()
      expect(await runEnrichmentBatch(db, deps, n)).toMatchObject({ processed: n, features: n, meaning: n })
      expect(calls).toHaveLength(ENRICH_SUBREQUESTS_PER_TRACK * n)
    }
  })

  it('names each per-track request', async () => {
    const db = await createTestDb()
    await seed(db, 'apple', 1)
    const { calls, deps } = worstCase()
    await runEnrichmentBatch(db, deps, 1)
    expect(calls).toEqual([
      'reccobeats search', 'reccobeats features', 'lrclib get', 'lrclib search', 'workers ai embed',
    ])
  })

  it('a mixed batch stays within fixed + perTrack * n', async () => {
    const db = await createTestDb()
    await seed(db, 'spotify', 4)
    await seed(db, 'apple', 4, 100)
    const { calls, deps } = worstCase()
    expect(await runEnrichmentBatch(db, deps, 8)).toMatchObject({ processed: 8 })
    expect(calls).toHaveLength(ENRICH_FIXED_SUBREQUESTS + ENRICH_SUBREQUESTS_PER_TRACK * 8)
  })

  it('the shared by-id lookups stay one request each for any batch the cap allows', () => {
    expect(ENRICH_BATCH_CAP).toBeLessThanOrEqual(RECCOBEATS_ID_BATCH)
  })

  it('Apple ISRC linking, which shares the enrichment invocation, makes one catalogue request per run', async () => {
    let requests = 0
    const catalog = createAppleCatalogClient({
      fetchLike: async () => { requests++; return Response.json({ data: [] }) },
      issueServerToken: async () => ({ developerToken: 'server-token', expiresAt: 9999999999 }),
    })
    const isrcs = Array.from({ length: APPLE_ISRC_BATCH }, (_, i) => `USUG1190${String(i).padStart(4, '0')}`)
    await catalog.getSongsByIsrc('gb', isrcs)
    expect(requests).toBe(APPLE_ISRC_SUBREQUESTS)
  })

  it('the Spotify artwork fallback, which shares the enrichment invocation, costs at most oEmbed + Deezer per row', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await db.insert(userMusicSources).values({ userId: 'u1', source: 'spotify_export', lastImportedAt: now })
    for (let i = 0; i < FALLBACK_ARTWORK_BATCH + 2; i++) {
      const [row] = await db.insert(tracks).values({
        spotifyId: spotifyId(i), isrc: `USUG1190${String(i).padStart(4, '0')}`, title: 'Song', artist: 'Artist',
      }).returning()
      await db.insert(userTracks).values({ userId: 'u1', trackId: row.id, inLibrary: true })
    }
    const hosts: string[] = []
    // Both providers miss, so every row pays for both requests.
    const fetchLike = async (input: string | URL) => {
      hosts.push(new URL(input).host)
      return new Response(null, { status: 404 })
    }
    const result = await runSpotifyArtworkBatch(db, {
      spotify: createSpotifyOEmbedArtworkClient({ fetchLike }),
      deezer: createDeezerArtworkClient({ fetchLike }),
      now: () => now,
    })
    expect(result).toMatchObject({ processed: FALLBACK_ARTWORK_BATCH, missing: FALLBACK_ARTWORK_BATCH })
    expect(hosts).toHaveLength(FALLBACK_ARTWORK_BATCH * FALLBACK_ARTWORK_CALLS_PER_ROW)
    expect(new Set(hosts)).toEqual(new Set(['open.spotify.com', 'api.deezer.com']))
  })

  it('derives the batch from the measurement, then ships at the first step', () => {
    expect(ENRICH_SUBREQUEST_BUDGET).toBe(40)
    expect(ENRICH_CRON_OVERHEAD_SUBREQUESTS)
      .toBe(APPLE_ISRC_SUBREQUESTS + FALLBACK_ARTWORK_BATCH * FALLBACK_ARTWORK_CALLS_PER_ROW)
    expect(ENRICH_CRON_OVERHEAD_SUBREQUESTS).toBe(7)
    expect(largestEnrichBatch(0)).toBe(7)
    expect(largestEnrichBatch(ENRICH_CRON_OVERHEAD_SUBREQUESTS)).toBe(6)
    expect(ENRICH_FIXED_SUBREQUESTS + ENRICH_SUBREQUESTS_PER_TRACK * MAX_BATCH)
      .toBeLessThanOrEqual(ENRICH_SUBREQUEST_BUDGET)
    expect(ENRICH_CRON_OVERHEAD_SUBREQUESTS + ENRICH_FIXED_SUBREQUESTS + ENRICH_SUBREQUESTS_PER_TRACK * CRON_BATCH)
      .toBeLessThanOrEqual(ENRICH_SUBREQUEST_BUDGET)
    expect(ENRICH_BATCH_STEP).toBe(5)
    expect(CRON_BATCH).toBe(Math.min(largestEnrichBatch(ENRICH_CRON_OVERHEAD_SUBREQUESTS), ENRICH_BATCH_STEP))
    expect(CRON_BATCH).toBe(5)
    expect(MAX_BATCH).toBe(Math.min(largestEnrichBatch(0), ENRICH_BATCH_STEP))
  })
})
