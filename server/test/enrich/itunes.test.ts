import { describe, it, expect } from 'vitest'
import { lookupItunes, type FetchLike } from '../../src/enrich/itunes'

const ok = (body: unknown): FetchLike => async (url) => {
  expect(String(url)).toContain('itunes.apple.com/lookup')
  expect(String(url)).toContain('country=ng')
  return new Response(JSON.stringify(body), { status: 200 })
}

describe('lookupItunes', () => {
  it('maps a hit to duration, genre, preview', async () => {
    const fetchLike = ok({
      resultCount: 1,
      results: [{
        trackName: 'Space Song',
        artistName: 'Beach House',
        previewUrl: 'https://audio-ssl.itunes.apple.com/x.m4a',
        trackTimeMillis: 320000,
        primaryGenreName: 'Alternative',
      }],
    })
    const hit = await lookupItunes('12345', 'ng', fetchLike)
    expect(hit).toEqual({
      trackName: 'Space Song',
      artistName: 'Beach House',
      previewUrl: 'https://audio-ssl.itunes.apple.com/x.m4a',
      durationMs: 320000,
      genre: 'Alternative',
    })
  })

  it('returns null on zero results', async () => {
    expect(await lookupItunes('999', 'ng', ok({ resultCount: 0, results: [] }))).toBeNull()
  })

  it('throws EnrichSourceError on non-200', async () => {
    const bad: FetchLike = async () => new Response('nope', { status: 503 })
    await expect(lookupItunes('1', 'ng', bad)).rejects.toThrow('itunes')
  })
})
