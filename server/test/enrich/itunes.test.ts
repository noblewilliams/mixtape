import { describe, it, expect } from 'vitest'
import { lookupItunes, type FetchLike } from '../../src/enrich/itunes'
import { EnrichSourceError } from '../../src/enrich/types'

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
    await expect(lookupItunes('1', 'ng', bad)).rejects.toThrow(EnrichSourceError)
    await expect(lookupItunes('1', 'ng', bad)).rejects.toMatchObject({ status: 503 })
  })

  it('marks a 503 transient and a 403 permanent, and a rejected fetch transient', async () => {
    await expect(lookupItunes('1', 'ng', async () => new Response('', { status: 503 }))).rejects.toMatchObject({ transient: true })
    await expect(lookupItunes('1', 'ng', async () => new Response('', { status: 403 }))).rejects.toMatchObject({ transient: false })
    await expect(lookupItunes('1', 'ng', async () => { throw new TypeError('fetch failed') }))
      .rejects.toMatchObject({ source: 'itunes', detail: 'fetch failed (TypeError)', transient: true })
  })

  it('makes a body read that rejects transient, and keeps an unparseable body permanent', async () => {
    await expect(lookupItunes('1', 'ng', async () => ({ ok: true, status: 200, json: async () => { throw new DOMException('timed out', 'TimeoutError') } } as unknown as Response)))
      .rejects.toMatchObject({ source: 'itunes', detail: 'body read failed (TimeoutError)', transient: true })
    await expect(lookupItunes('1', 'ng', async () => new Response('not json', { status: 200 })))
      .rejects.toMatchObject({ detail: 'malformed JSON', transient: false })
  })

  it('sends the injected storefront and the encoded apple id', async () => {
    let seen = ''
    const spy: FetchLike = async (url) => {
      seen = String(url)
      return new Response(JSON.stringify({ resultCount: 0, results: [] }), { status: 200 })
    }
    await lookupItunes('12 34', 'us', spy)
    expect(seen).toBe('https://itunes.apple.com/lookup?id=12+34&country=us')
  })

  it('maps absent optional fields to null', async () => {
    const hit = await lookupItunes('1', 'ng', ok({ resultCount: 1, results: [{ trackName: 'X' }] }))
    expect(hit).toEqual({ trackName: 'X', artistName: null, previewUrl: null, durationMs: null, genre: null })
  })

  it('throws EnrichSourceError on malformed JSON', async () => {
    const bad: FetchLike = async () => new Response('not json', { status: 200 })
    await expect(lookupItunes('1', 'ng', bad)).rejects.toThrow(EnrichSourceError)
  })
})
