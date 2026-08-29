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
})
