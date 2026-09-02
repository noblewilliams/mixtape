import { describe, it, expect } from 'vitest'
import { fetchTracksBySpotifyIds, RECCOBEATS_ID_BATCH } from '../../src/enrich/reccobeats-by-id'
import { EnrichSourceError, type FetchLike } from '../../src/enrich/types'

const A = '4uLU6hMCjMI75M1A2tKUQC'
const B = '7ouMYWpwJ422jRcDASZB7P'
const C = '1301WleyT98MSxVHPZCA6M'

// A 22-char base62 id derived from an index, so batching tests can mint
// dozens of distinct valid ids without a fixture list.
const idAt = (i: number) => `${String(i).padStart(4, '0')}abcdefghijklmnopqr`.slice(0, 22)

const item = (spotifyId: string, over: Record<string, unknown> = {}) => ({
  id: `rb-${spotifyId}`,
  trackTitle: `Title ${spotifyId}`,
  artists: [{ name: 'Wizkid' }, { name: 'Tems' }],
  isrc: 'NGA0A2000001',
  durationMs: 200_000,
  href: `https://open.spotify.com/track/${spotifyId}`,
  ...over,
})

// Answers every batch with the items whose href id is in that batch's ids.
function fetchScript(items: ReturnType<typeof item>[], calls: string[] = []): FetchLike {
  return async (url, init) => {
    const u = String(url)
    calls.push(u)
    expect(init?.signal).toBeInstanceOf(AbortSignal)
    const ids = new URL(u).searchParams.get('ids')?.split(',') ?? []
    const content = items.filter((it) => ids.some((id) => String(it.href).endsWith(`/${id}`)))
    return new Response(JSON.stringify({ content }), { status: 200 })
  }
}

describe('fetchTracksBySpotifyIds', () => {
  it('maps hits by the Spotify id in href and lists ids the API did not return as missing', async () => {
    const calls: string[] = []
    const result = await fetchTracksBySpotifyIds([A, B, C], fetchScript([item(A), item(B, { isrc: null, durationMs: null })], calls))
    expect(result).toEqual({
      hits: [
        { spotifyId: A, title: `Title ${A}`, artists: ['Wizkid', 'Tems'], isrc: 'NGA0A2000001', durationMs: 200_000 },
        { spotifyId: B, title: `Title ${B}`, artists: ['Wizkid', 'Tems'], isrc: null, durationMs: null },
      ],
      missing: [C],
    })
    expect(calls).toHaveLength(1)
    expect(calls[0]).toContain('https://api.reccobeats.com/v1/track?ids=')
    expect(calls[0]).toContain(`${A},${B},${C}`)
  })

  it('batches at RECCOBEATS_ID_BATCH ids per request: 41 ids take two requests', async () => {
    expect(RECCOBEATS_ID_BATCH).toBe(40)
    const ids = Array.from({ length: 41 }, (_, i) => idAt(i))
    const calls: string[] = []
    const result = await fetchTracksBySpotifyIds(ids, fetchScript(ids.map((id) => item(id)), calls))
    expect(calls).toHaveLength(2)
    expect(new URL(calls[0]).searchParams.get('ids')?.split(',')).toHaveLength(40)
    expect(new URL(calls[1]).searchParams.get('ids')?.split(',')).toEqual([idAt(40)])
    expect(result.hits.map((h) => h.spotifyId)).toEqual(ids)
    expect(result.missing).toEqual([])
  })

  it('dedupes the requested ids and never reports an unrequested id as a hit', async () => {
    const calls: string[] = []
    const result = await fetchTracksBySpotifyIds([A, A, B], fetchScript([item(A), item(C)], calls))
    expect(new URL(calls[0]).searchParams.get('ids')).toBe(`${A},${B}`)
    expect(result.hits.map((h) => h.spotifyId)).toEqual([A])
    expect(result.missing).toEqual([B])
  })

  it('treats an item without a parseable Spotify href, or without a title, as not returned', async () => {
    const result = await fetchTracksBySpotifyIds(
      [A, B, C],
      async () => new Response(JSON.stringify({ content: [
        item(A, { href: 'https://open.spotify.com/album/notatrack' }),
        item(B, { trackTitle: '' }),
        item(C, { artists: [{ name: '' }, { name: 'Asake' }, {}] }),
      ] }), { status: 200 }),
    )
    expect(result.hits).toEqual([
      { spotifyId: C, title: `Title ${C}`, artists: ['Asake'], isrc: 'NGA0A2000001', durationMs: 200_000 },
    ])
    expect(result.missing).toEqual([A, B])
  })

  it('accepts a bare array body as well as {content: [...]}', async () => {
    const result = await fetchTracksBySpotifyIds([A], async () => new Response(JSON.stringify([item(A)]), { status: 200 }))
    expect(result.hits.map((h) => h.spotifyId)).toEqual([A])
  })

  it('returns nothing and makes no request for an empty id list', async () => {
    let calls = 0
    const result = await fetchTracksBySpotifyIds([], async () => { calls += 1; return new Response('[]') })
    expect(result).toEqual({ hits: [], missing: [] })
    expect(calls).toBe(0)
  })

  it('throws EnrichSourceError with the status on a non-2xx response', async () => {
    const bad: FetchLike = async () => new Response('x', { status: 400 })
    await expect(fetchTracksBySpotifyIds([A], bad)).rejects.toThrow(EnrichSourceError)
    await expect(fetchTracksBySpotifyIds([A], bad)).rejects.toMatchObject({ source: 'reccobeats', status: 400 })
  })

  it('throws EnrichSourceError on malformed JSON', async () => {
    const bad: FetchLike = async () => new Response('nope', { status: 200 })
    await expect(fetchTracksBySpotifyIds([A], bad)).rejects.toThrow(EnrichSourceError)
  })
})
