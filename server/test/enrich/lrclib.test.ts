import { describe, it, expect } from 'vitest'
import { fetchLyrics } from '../../src/enrich/lrclib'
import { EnrichSourceError, type FetchLike } from '../../src/enrich/types'

describe('fetchLyrics', () => {
  it('gets exact-match lyrics with duration in seconds', async () => {
    const fetchLike: FetchLike = async (url, init) => {
      const u = String(url)
      expect(u).toContain('lrclib.net/api/get')
      expect(u).toContain('duration=255')
      expect(u).toContain('album_name=In+Rainbows')
      expect((init?.headers as Record<string, string>)['User-Agent']).toContain('mixtape')
      return new Response(
        JSON.stringify({ plainLyrics: 'Some words', instrumental: false }),
        { status: 200 },
      )
    }
    const r = await fetchLyrics(
      { title: 'Nude', artist: 'Radiohead', album: 'In Rainbows', durationMs: 255386 },
      fetchLike,
    )
    expect(r).toEqual({ lyrics: 'Some words', instrumental: false })
  })

  it('falls back to search when exact get 404s', async () => {
    const fetchLike: FetchLike = async (url) => {
      const u = String(url)
      if (u.includes('/api/get')) return new Response('', { status: 404 })
      expect(u).toContain('/api/search')
      return new Response(
        JSON.stringify([{ plainLyrics: 'Found via search', instrumental: false }]),
        { status: 200 },
      )
    }
    const r = await fetchLyrics({ title: 'Nude', artist: 'Radiohead', album: null, durationMs: null }, fetchLike)
    expect(r?.lyrics).toBe('Found via search')
  })

  it('flags instrumentals', async () => {
    const fetchLike: FetchLike = async () =>
      new Response(JSON.stringify({ plainLyrics: null, instrumental: true }), { status: 200 })
    const r = await fetchLyrics({ title: 'X', artist: 'Y', album: null, durationMs: 1000 }, fetchLike)
    expect(r).toEqual({ lyrics: null, instrumental: true })
  })

  it('returns null when nothing is found anywhere', async () => {
    const fetchLike: FetchLike = async (url) =>
      String(url).includes('/api/get')
        ? new Response('', { status: 404 })
        : new Response(JSON.stringify([]), { status: 200 })
    expect(await fetchLyrics({ title: 'X', artist: 'Y', album: null, durationMs: null }, fetchLike)).toBeNull()
  })

  it('throws EnrichSourceError with status on server errors', async () => {
    const bad: FetchLike = async () => new Response('x', { status: 503 })
    await expect(
      fetchLyrics({ title: 'X', artist: 'Y', album: null, durationMs: null }, bad),
    ).rejects.toThrow(EnrichSourceError)
    await expect(
      fetchLyrics({ title: 'X', artist: 'Y', album: null, durationMs: null }, bad),
    ).rejects.toMatchObject({ status: 503 })
  })

  it('throws EnrichSourceError on malformed JSON', async () => {
    const bad: FetchLike = async () => new Response('<html>', { status: 200 })
    await expect(
      fetchLyrics({ title: 'X', artist: 'Y', album: null, durationMs: null }, bad),
    ).rejects.toThrow(EnrichSourceError)
  })

  it('skips the get call entirely when there is no duration (search only)', async () => {
    const urls: string[] = []
    const fetchLike: FetchLike = async (url) => {
      urls.push(String(url))
      return new Response(JSON.stringify([]), { status: 200 })
    }
    await fetchLyrics({ title: 'X', artist: 'Y', album: null, durationMs: null }, fetchLike)
    expect(urls).toHaveLength(1)
    expect(urls[0]).toContain('/api/search')
  })
})
