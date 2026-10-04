import { describe, it, expect } from 'vitest'
import { resolveAndFetchFeatures } from '../../src/enrich/reccobeats'
import { EnrichSourceError, type FetchLike } from '../../src/enrich/types'

const candidate = (over: Record<string, unknown> = {}) => ({
  id: 'rb-1',
  trackTitle: 'Nude',
  artists: [{ name: 'Radiohead' }],
  durationMs: 255386,
  isrc: 'GBSTK0700003',
  ...over,
})

const features = {
  acousticness: 0.832, danceability: 0.516, energy: 0.342, instrumentalness: 0.579,
  key: 4, liveness: 0.0857, loudness: -9.785, mode: 1, speechiness: 0.0342,
  tempo: 128.378, valence: 0.167, isrc: 'GBSTK0700003',
}

function fetchScript(searchBody: unknown, featuresBody: unknown = features): FetchLike {
  return async (url) => {
    const u = String(url)
    if (u.includes('/track/search')) {
      // Title only — artist terms break ReccoBeats matching (probed live).
      expect(u).toContain('searchText=Nude')
      expect(u).not.toContain('Radiohead')
      return new Response(JSON.stringify(searchBody), { status: 200 })
    }
    expect(u).toContain('/track/rb-1/audio-features')
    return new Response(JSON.stringify(featuresBody), { status: 200 })
  }
}

describe('resolveAndFetchFeatures', () => {
  it('finds the right candidate and returns mapped features + isrc', async () => {
    const result = await resolveAndFetchFeatures(
      { title: 'Nude', artist: 'Radiohead', durationMs: 255000 },
      fetchScript({ content: [candidate({ id: 'rb-0', artists: [{ name: 'Someone Else' }] }), candidate()] }),
    )
    expect(result).toEqual({
      tempo: 128.378,
      key: 4,
      mode: 1,
      energy: 0.342,
      danceability: 0.516,
      valence: 0.167,
      acousticness: 0.832,
      instrumentalness: 0.579,
      liveness: 0.0857,
      speechiness: 0.0342,
      loudness: -9.785,
      isrc: 'GBSTK0700003',
      matchedDurationMs: 255386,
    })
  })

  it('rejects candidates whose duration differs by more than 5s', async () => {
    const result = await resolveAndFetchFeatures(
      { title: 'Nude', artist: 'Radiohead', durationMs: 300000 },
      fetchScript({ content: [candidate()] }),
    )
    expect(result).toBeNull()
  })

  it('matches without duration when the track has none (artist match only)', async () => {
    const result = await resolveAndFetchFeatures(
      { title: 'Nude', artist: 'Radiohead', durationMs: null },
      fetchScript({ content: [candidate()] }),
    )
    expect(result).not.toBeNull()
  })

  it('matches artists case/diacritic-insensitively', async () => {
    const result = await resolveAndFetchFeatures(
      { title: 'Nude', artist: 'RADIOHÉAD', durationMs: null },
      fetchScript({ content: [candidate({ artists: [{ name: 'radiohead' }] })] }),
    )
    expect(result).not.toBeNull()
  })

  it('returns null on empty search results', async () => {
    expect(
      await resolveAndFetchFeatures({ title: 'Nude', artist: 'Radiohead', durationMs: null }, fetchScript({ content: [] })),
    ).toBeNull()
  })

  it('returns null when features 404 (track known, features absent)', async () => {
    const fetchLike: FetchLike = async (url) =>
      String(url).includes('/track/search')
        ? new Response(JSON.stringify({ content: [candidate()] }), { status: 200 })
        : new Response('', { status: 404 })
    expect(await resolveAndFetchFeatures({ title: 'Nude', artist: 'Radiohead', durationMs: null }, fetchLike)).toBeNull()
  })

  it('throws EnrichSourceError with status on server errors', async () => {
    const bad: FetchLike = async () => new Response('x', { status: 500 })
    await expect(
      resolveAndFetchFeatures({ title: 'Nude', artist: 'Radiohead', durationMs: null }, bad),
    ).rejects.toThrow(EnrichSourceError)
    await expect(
      resolveAndFetchFeatures({ title: 'Nude', artist: 'Radiohead', durationMs: null }, bad),
    ).rejects.toMatchObject({ status: 500 })
  })

  it('marks 429 and server errors transient and other 4xx permanent', async () => {
    const key = { title: 'Nude', artist: 'Radiohead', durationMs: null }
    for (const [status, transient] of [[429, true], [502, true], [400, false]] as const) {
      const bad: FetchLike = async () => new Response('x', { status })
      await expect(resolveAndFetchFeatures(key, bad)).rejects.toMatchObject({ status, transient })
    }
  })

  it('makes a search or features body read that rejects transient, and keeps unparseable bodies permanent', async () => {
    const key = { title: 'Nude', artist: 'Radiohead', durationMs: null }
    const searchTimesOut: FetchLike = async () => ({ ok: true, status: 200, json: async () => { throw new DOMException('timed out', 'TimeoutError') } } as unknown as Response)
    await expect(resolveAndFetchFeatures(key, searchTimesOut))
      .rejects.toMatchObject({ detail: 'search body read failed (TimeoutError)', transient: true })
    const featuresAborted: FetchLike = async (url) => String(url).includes('/track/search')
      ? new Response(JSON.stringify({ content: [candidate()] }), { status: 200 })
      : ({ ok: true, status: 200, json: async () => { throw new DOMException('aborted', 'AbortError') } } as unknown as Response)
    await expect(resolveAndFetchFeatures(key, featuresAborted))
      .rejects.toMatchObject({ detail: 'features body read failed (AbortError)', transient: true })
    await expect(resolveAndFetchFeatures(key, async () => new Response('nope', { status: 200 })))
      .rejects.toMatchObject({ detail: 'malformed search JSON', transient: false })
    const featuresGarbled: FetchLike = async (url) => String(url).includes('/track/search')
      ? new Response(JSON.stringify({ content: [candidate()] }), { status: 200 })
      : new Response('nope', { status: 200 })
    await expect(resolveAndFetchFeatures(key, featuresGarbled))
      .rejects.toMatchObject({ detail: 'malformed features JSON', transient: false })
  })

  it('turns a rejected search or features fetch into a transient EnrichSourceError', async () => {
    const key = { title: 'Nude', artist: 'Radiohead', durationMs: null }
    const searchDown: FetchLike = async () => { throw new TypeError('fetch failed: https://api.reccobeats.com/secret') }
    const searchError = await resolveAndFetchFeatures(key, searchDown).catch((e: unknown) => e)
    expect(searchError).toMatchObject({ source: 'reccobeats', detail: 'search fetch failed (TypeError)', transient: true })
    expect((searchError as Error).message).not.toContain('secret')
    const featuresTimeout: FetchLike = async (url) => {
      if (String(url).includes('/track/search')) return new Response(JSON.stringify({ content: [candidate()] }), { status: 200 })
      throw new DOMException('timed out', 'TimeoutError')
    }
    await expect(resolveAndFetchFeatures(key, featuresTimeout))
      .rejects.toMatchObject({ source: 'reccobeats', detail: 'features fetch failed (TimeoutError)', transient: true })
  })

  it('falls back to the candidate isrc when features omit it', async () => {
    const { isrc, ...featuresNoIsrc } = features
    const result = await resolveAndFetchFeatures(
      { title: 'Nude', artist: 'Radiohead', durationMs: null },
      fetchScript({ content: [candidate()] }, featuresNoIsrc),
    )
    expect(result?.isrc).toBe('GBSTK0700003')
  })

  it('throws EnrichSourceError on malformed search JSON', async () => {
    const bad: FetchLike = async () => new Response('nope', { status: 200 })
    await expect(
      resolveAndFetchFeatures({ title: 'Nude', artist: 'Radiohead', durationMs: null }, bad),
    ).rejects.toThrow(EnrichSourceError)
  })

  it('throws EnrichSourceError on malformed features JSON', async () => {
    const fetchLike: FetchLike = async (url) =>
      String(url).includes('/track/search')
        ? new Response(JSON.stringify({ content: [candidate()] }), { status: 200 })
        : new Response('nope', { status: 200 })
    await expect(
      resolveAndFetchFeatures({ title: 'Nude', artist: 'Radiohead', durationMs: null }, fetchLike),
    ).rejects.toThrow(EnrichSourceError)
  })

  it('rejects a non-exact title when there is no duration to gate on', async () => {
    const result = await resolveAndFetchFeatures(
      { title: 'Nude', artist: 'Radiohead', durationMs: null },
      fetchScript({ content: [candidate({ trackTitle: 'Nude (Live at the BBC)' })] }),
    )
    expect(result).toBeNull()
  })

  it('accepts a non-exact title when duration + artist both gate the match', async () => {
    const result = await resolveAndFetchFeatures(
      { title: 'Nude', artist: 'Radiohead', durationMs: 255000 },
      fetchScript({ content: [candidate({ trackTitle: 'Nude - Remaster', durationMs: 255386 })] }),
    )
    expect(result).not.toBeNull()
  })

  it('maps a missing numeric feature field to null', async () => {
    const { tempo, ...featuresNoTempo } = features
    const result = await resolveAndFetchFeatures(
      { title: 'Nude', artist: 'Radiohead', durationMs: null },
      fetchScript({ content: [candidate()] }, featuresNoTempo),
    )
    expect(result?.tempo).toBeNull()
  })

  it('falls back to a non-exact-title candidate when the exact-title match is a different-artist cover', async () => {
    const fetchLike: FetchLike = async (url) => {
      const u = String(url)
      if (u.includes('/track/search')) {
        return new Response(
          JSON.stringify({
            content: [
              candidate({ id: 'rb-cover', artists: [{ name: 'Some Cover Band' }] }),
              candidate({ id: 'rb-album', trackTitle: 'Nude (Album Version)', durationMs: 255386 }),
            ],
          }),
          { status: 200 },
        )
      }
      expect(u).toContain('/track/rb-album/audio-features')
      return new Response(JSON.stringify(features), { status: 200 })
    }
    const result = await resolveAndFetchFeatures(
      { title: 'Nude', artist: 'Radiohead', durationMs: 255000 },
      fetchLike,
    )
    expect(result?.isrc).toBe('GBSTK0700003')
  })

  it('accepts a plain candidate title when the query title carries a suffix (bidirectional containment)', async () => {
    const result = await resolveAndFetchFeatures(
      { title: 'Nude - Remastered 2011', artist: 'Radiohead', durationMs: 255000 },
      fetchScript({ content: [candidate({ trackTitle: 'Nude', durationMs: 255386 })] }),
    )
    expect(result).not.toBeNull()
  })

  it('makes zero fetch calls when the title is blank', async () => {
    let calls = 0
    const spy: FetchLike = async () => {
      calls++
      return new Response(JSON.stringify({ content: [] }), { status: 200 })
    }
    const result = await resolveAndFetchFeatures({ title: '', artist: 'X', durationMs: null }, spy)
    expect(result).toBeNull()
    expect(calls).toBe(0)
  })
})
