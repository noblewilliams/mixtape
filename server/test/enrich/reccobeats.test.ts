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
    expect(result).toMatchObject({ tempo: 128.378, energy: 0.342, key: 4, mode: 1, isrc: 'GBSTK0700003' })
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
})
