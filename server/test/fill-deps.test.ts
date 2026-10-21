import { describe, it, expect } from 'vitest'
import { buildFillDeps } from '../src/index'
import { STAGE_SUBREQUESTS, type FillDeps } from '../src/dj/catalogue-fill'

const catalog: FillDeps['catalog'] = {
  searchArtists: async () => [],
  artistTopSongs: async () => [],
  searchSongs: async () => [],
}
const ai = { run: async () => ({ data: [[1]] }) }

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } })
}

// Stands in for ReccoBeats and LRCLIB: a search hit then its features; an
// LRCLIB exact get that misses (404), then a search hit. Counts every call.
function stubFetch() {
  const urls: string[] = []
  const fetchLike = async (url: string | URL) => {
    const u = String(url)
    urls.push(u)
    if (u.includes('/track/search')) {
      return json({ content: [{ id: 'rb1', trackTitle: 'Ye', artists: [{ name: 'Burna Boy' }], durationMs: 200_000, isrc: null }] })
    }
    if (u.includes('/audio-features')) return json({ tempo: 100, energy: 0.6 })
    if (u.includes('lrclib.net/api/get')) return new Response('', { status: 404 })
    if (u.includes('lrclib.net/api/search')) return json([{ plainLyrics: 'la', instrumental: false, artistName: 'Burna Boy' }])
    return new Response('', { status: 500 })
  }
  return { fetchLike, urls }
}

describe('buildFillDeps', () => {
  it('is absent without the AI binding or MusicKit', () => {
    expect(buildFillDeps({ AI: undefined }, { catalog })).toBeUndefined()
    expect(buildFillDeps({ AI: ai }, undefined)).toBeUndefined()
  })

  it('counts every real ReccoBeats and LRCLIB fetch, within the STAGE_SUBREQUESTS worst case', async () => {
    const { fetchLike, urls } = stubFetch()
    const deps = buildFillDeps({ AI: ai, ITUNES_STOREFRONT: 'gb' }, { catalog }, fetchLike)!
    expect(deps.defaultStorefront).toBe('gb')
    expect(deps.enrichFetches!()).toBe(0)

    const features = await deps.enrich.features({ title: 'Ye', artist: 'Burna Boy', durationMs: 200_000 })
    expect(features?.tempo).toBe(100)
    const afterFeatures = deps.enrichFetches!()
    expect(afterFeatures).toBe(2)
    expect(afterFeatures).toBeLessThanOrEqual(STAGE_SUBREQUESTS.features)

    const lyrics = await deps.enrich.lyrics({ title: 'Ye', artist: 'Burna Boy', album: null, durationMs: 200_000 })
    expect(lyrics?.lyrics).toBe('la')
    expect(deps.enrichFetches!() - afterFeatures).toBe(2)
    expect(deps.enrichFetches!() - afterFeatures).toBeLessThanOrEqual(STAGE_SUBREQUESTS.lyrics)

    expect(deps.enrichFetches!()).toBe(urls.length)
    // iTunes is never fetched from Workers (Apple 403s Cloudflare).
    expect(await deps.enrich.itunes('1', 'gb')).toBeNull()
    expect(deps.enrichFetches!()).toBe(urls.length)
  })
})
