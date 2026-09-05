import { describe, it, expect } from 'vitest'
import { fetchTracksBySpotifyIds, fetchAudioFeaturesBySpotifyIds, RECCOBEATS_ID_BATCH } from '../../src/enrich/reccobeats-by-id'
import { EnrichSourceError, type FetchLike } from '../../src/enrich/types'

const A = '4uLU6hMCjMI75M1A2tKUQC'
const B = '7ouMYWpwJ422jRcDASZB7P'
const C = '1301WleyT98MSxVHPZCA6M'

// Synthetic base62 IDs for batching without a long fixture list.
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

const featureItem = (spotifyId: string, over: Record<string, unknown> = {}) => ({
  id: `rb-${spotifyId}`, href: `https://open.spotify.com/track/${spotifyId}`,
  tempo: 120, key: 4, mode: 1, energy: 0.6, danceability: 0.7, valence: 0.5,
  acousticness: 0.2, instrumentalness: 0, liveness: 0.1, speechiness: 0.04,
  loudness: -8, isrc: 'NGA0A2000001', ...over,
})

describe('fetchAudioFeaturesBySpotifyIds', () => {
  it('maps out-of-order features by requested Spotify href and reports missing IDs', async () => {
    const calls: string[] = []
    const result = await fetchAudioFeaturesBySpotifyIds([A, B, C], async (url, init) => {
      calls.push(String(url))
      expect(init?.signal).toBeInstanceOf(AbortSignal)
      return Response.json({ content: [featureItem(B), featureItem(A)] })
    })
    expect(calls).toEqual([`https://api.reccobeats.com/v1/audio-features?ids=${A},${B},${C}`])
    expect(result).toEqual({
      hits: [A, B].map((spotifyId) => ({ spotifyId, features: {
        tempo: 120, key: 4, mode: 1, energy: 0.6, danceability: 0.7, valence: 0.5,
        acousticness: 0.2, instrumentalness: 0, liveness: 0.1, speechiness: 0.04,
        loudness: -8, isrc: 'NGA0A2000001', matchedDurationMs: null,
      } })),
      missing: [C],
    })
  })

  it('keeps unknown/out-of-range values null and never caches an empty feature record', async () => {
    const result = await fetchAudioFeaturesBySpotifyIds([A, B], async () => Response.json({ content: [
      featureItem(A, { key: -1, mode: 2, tempo: 0, energy: 3, valence: '0.5', loudness: 8 }),
      { href: `https://open.spotify.com/track/${B}`, id: 'empty' },
    ] }))
    expect(result.hits).toHaveLength(1)
    expect(result.hits[0].features).toMatchObject({
      key: null, mode: null, tempo: null, energy: null, valence: null, loudness: null,
      danceability: 0.7,
    })
    expect(result.missing).toEqual([B])
  })

  it('batches 41 distinct IDs into requests of 40 and 1, omitting invalid and duplicate IDs', async () => {
    const ids = Array.from({ length: 41 }, (_, i) => idAt(i))
    const sizes: number[] = []
    const result = await fetchAudioFeaturesBySpotifyIds([...ids, ids[0], 'invalid'], async (url) => {
      const requested = new URL(url).searchParams.get('ids')!.split(',')
      sizes.push(requested.length)
      return Response.json(requested.map((id) => featureItem(id)).reverse())
    })
    expect(sizes).toEqual([40, 1])
    expect(result.hits.map((hit) => hit.spotifyId)).toEqual(ids)
    expect(result.missing).toEqual(['invalid'])
  })
})

describe.each([
  { label: 'track', lookup: fetchTracksBySpotifyIds, make: item },
  { label: 'features', lookup: fetchAudioFeaturesBySpotifyIds, make: featureItem },
])('$label ID lookup safeguards', ({ label, lookup, make }) => {
  it('rejects lookalike hosts, embedded URLs, and ambiguous duplicate identities', async () => {
    const result = await lookup([A, B, C], async () => Response.json({ content: [
      make(A, { href: `https://example.com/open.spotify.com/track/${A}` }),
      make(B, { href: `https://open.spotify.com.evil.test/track/${B}` }),
      make(C), make(C, { tempo: 180, trackTitle: 'Different recording' }),
    ] }))
    expect(result).toEqual({ hits: [], missing: [A, B, C] })
  })

  it.each([null, {}, { content: {} }, { error: 'private data' }])('rejects malformed success envelopes', async (body) => {
    await expect(lookup([A], async () => Response.json(body)))
      .rejects.toMatchObject({ source: 'reccobeats', detail: `malformed ${label} response` })
  })

  it('returns a miss for a not-found batch without parsing its error body', async () => {
    expect(await lookup([A], async () => new Response('not JSON or music data', { status: 404 })))
      .toEqual({ hits: [], missing: [A] })
  })

  it.each([429, 500])('reports HTTP %s once without exposing the response body', async (status) => {
    let requests = 0
    const result = await lookup([A], async () => {
      requests++
      return new Response(`private response for ${A}`, { status })
    }).catch((error: unknown) => error)
    expect(result).toMatchObject({ source: 'reccobeats', detail: `${label} HTTP ${status}`, status })
    expect(String(result)).not.toContain(A)
    expect(requests).toBe(1)
  })

  it('does not expose request details after a transport failure or malformed JSON', async () => {
    for (const fetchLike of [
      async () => { throw new TypeError(`private URL/${A}`) },
      async () => new Response(`private body ${A}`),
    ]) {
      const error = await lookup([A], fetchLike).catch((value: unknown) => value)
      expect(error).toBeInstanceOf(EnrichSourceError)
      expect(String(error)).not.toContain(A)
    }
  })

  it('normalizes valid recording codes and leaves malformed codes unknown', async () => {
    const result = await lookup([A, B], async () => Response.json({ content: [
      make(A, { isrc: ' nga0a2000001 ' }), make(B, { isrc: 'not-an-isrc' }),
    ] }))
    const codes = result.hits.map((hit) => 'features' in hit ? hit.features.isrc : hit.isrc)
    expect(codes).toEqual(['NGA0A2000001', null])
  })
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
  it('does not pass sub-millisecond or overflowing durations to the database', async () => {
    const result = await fetchTracksBySpotifyIds([A, B, C], async () => Response.json({ content: [
      item(A, { durationMs: 0.1 }), item(B, { durationMs: 2147483648 }), item(C, { durationMs: 201000.4 }),
    ] }))
    expect(result.hits.map((hit) => hit.durationMs)).toEqual([null, null, 201000])
  })

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

  // A rejected fetch's own message carries the request URL, ids included,
  // so it must never become the error detail.
  it('throws EnrichSourceError with a fixed detail when the fetch times out', async () => {
    const timedOut: FetchLike = async () => {
      throw new DOMException(`https://api.reccobeats.com/v1/track?ids=${A} timed out`, 'TimeoutError')
    }
    const error = await fetchTracksBySpotifyIds([A], timedOut).catch((e: unknown) => e)
    expect(error).toBeInstanceOf(EnrichSourceError)
    expect(error).toMatchObject({ source: 'reccobeats', detail: 'track fetch failed', status: undefined })
    expect((error as Error).message).not.toContain(A)
  })

  it('throws EnrichSourceError with a fixed detail when the fetch cannot connect', async () => {
    const unreachable: FetchLike = async () => {
      throw new TypeError(`fetch failed: https://api.reccobeats.com/v1/track?ids=${A}`)
    }
    const error = await fetchTracksBySpotifyIds([A], unreachable).catch((e: unknown) => e)
    expect(error).toBeInstanceOf(EnrichSourceError)
    expect(error).toMatchObject({ source: 'reccobeats', detail: 'track fetch failed', status: undefined })
    expect((error as Error).message).not.toContain(A)
  })
})
