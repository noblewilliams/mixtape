import { describe, expect, it, vi } from 'vitest'
import {
  AppleCatalogError,
  createAppleCatalogClient,
  createAppleCatalogTokenCache,
  parseArtworkMetadata,
  type FetchLike,
} from '../../src/musickit/catalog'

const song = (id: string, artwork: unknown = undefined) => ({
  id,
  type: 'songs',
  attributes: {
    name: `Song ${id}`,
    artistName: `Artist ${id}`,
    albumName: `Album ${id}`,
    isrc: `ISRC${id}`,
    ...(artwork === undefined ? {} : { artwork }),
  },
})

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  })
}

function client(fetchLike: FetchLike, nowSeconds = () => 1_788_134_400) {
  return createAppleCatalogClient({
    fetchLike,
    issueServerToken: vi.fn(async () => ({ developerToken: 'server-token', expiresAt: 1_788_138_000 })),
    nowSeconds,
  })
}

describe('parseArtworkMetadata', () => {
  it('maps Apple CDN templates, positive dimensions, and a lowercase background colour', () => {
    expect(
      parseArtworkMetadata({
        url: 'https://is1-ssl.mzstatic.com/image/thumb/Music116/v4/a/b/c/{w}x{h}bb.{f}',
        width: 3000,
        height: 3000,
        bgColor: 'A1B2C3',
      }),
    ).toEqual({
      url: 'https://is1-ssl.mzstatic.com/image/thumb/Music116/v4/a/b/c/{w}x{h}bb.{f}',
      width: 3000,
      height: 3000,
      bgColor: 'a1b2c3',
    })
  })

  it.each([
    ['non-Apple URL', { url: 'https://example.com/cover.jpg', width: 10, height: 10, bgColor: 'abcdef' }],
    ['HTTP URL', { url: 'http://is1-ssl.mzstatic.com/cover.jpg', width: 10, height: 10, bgColor: 'abcdef' }],
    ['script URL', { url: 'javascript:alert(1)', width: 10, height: 10, bgColor: 'abcdef' }],
    ['hash colour', { url: 'https://is1-ssl.mzstatic.com/cover.jpg', width: 10, height: 10, bgColor: '#abcdef' }],
    ['spaced colour', { url: 'https://is1-ssl.mzstatic.com/cover.jpg', width: 10, height: 10, bgColor: ' abcdef' }],
    ['long colour', { url: 'https://is1-ssl.mzstatic.com/cover.jpg', width: 10, height: 10, bgColor: 'abcdef0' }],
    ['zero width', { url: 'https://is1-ssl.mzstatic.com/cover.jpg', width: 0, height: 10, bgColor: 'abcdef' }],
    ['fractional height', { url: 'https://is1-ssl.mzstatic.com/cover.jpg', width: 10, height: 1.5, bgColor: 'abcdef' }],
  ])('rejects the complete artwork payload for a malformed %s', (_label, artwork) => {
    expect(parseArtworkMetadata(artwork)).toBeNull()
  })

  it('allows missing optional dimensions and colour', () => {
    expect(parseArtworkMetadata({ url: 'https://a1.mzstatic.com/cover.jpg' })).toEqual({
      url: 'https://a1.mzstatic.com/cover.jpg',
      width: null,
      height: null,
      bgColor: null,
    })
  })
})

describe('Apple catalog client', () => {
  it('carries duration, genre, release year and an honest nullable content rating', async () => {
    const item = song('1')
    const result = await client(async () => jsonResponse({ data: [{ ...item, attributes: {
      ...item.attributes, durationInMillis: 180000, genreNames: ['R&B/Soul'],
      releaseDate: '2024-03-15', contentRating: 'clean',
    } }, song('2')] })).getSongs('ng', ['1', '2'])
    expect(result.get('1')).toMatchObject({ durationMs: 180000, genre: 'R&B/Soul', releaseYear: 2024, explicit: false })
    expect(result.get('2')).toMatchObject({ durationMs: null, genre: null, releaseYear: null, explicit: null })
  })

  it('rejects ambiguous duplicate IDs and non-song resources instead of choosing a winner', async () => {
    const result = await client(async () => jsonResponse({ data: [
      song('1'), song('1'), { ...song('2'), type: 'albums' }, song('3'),
    ] })).getSongs('ng', ['1', '2', '3'])
    expect([...result.keys()]).toEqual(['3'])
  })

  it('batches at 300, URL-encodes the storefront, and authenticates each request', async () => {
    const ids = Array.from({ length: 302 }, (_, index) => String(1_000_000_000 + index))
    const fetchLike = vi.fn<FetchLike>(async () => jsonResponse({ data: [] }))

    await client(fetchLike).getSongs('ng / west', ids)

    expect(fetchLike).toHaveBeenCalledTimes(2)
    const calls = fetchLike.mock.calls.map(([input, init]) => ({ url: new URL(input), init }))
    expect(calls[0].url.pathname).toBe('/v1/catalog/ng%20%2F%20west/songs')
    expect(calls[0].url.searchParams.get('ids')?.split(',')).toHaveLength(300)
    expect(calls[0].url.searchParams.get('ids')?.split(',')[0]).toBe('1000000000')
    expect(calls[1].url.searchParams.get('ids')?.split(',')).toHaveLength(2)
    expect(calls.every(({ init }) => new Headers(init?.headers).get('authorization') === 'Bearer server-token')).toBe(true)
  })

  it('drops malformed and oversized Apple song IDs before token or network work', async () => {
    const fetchLike = vi.fn<FetchLike>(async () => jsonResponse({ data: [] }))
    const issueServerToken = vi.fn(async () => ({ developerToken: 'server-token', expiresAt: 1_788_138_000 }))
    const catalog = createAppleCatalogClient({
      fetchLike,
      issueServerToken,
      nowSeconds: () => 1_788_134_400,
    })

    await catalog.getSongs('ng', ['1', 'opaque.ID_2~', 'bad id', 'x'.repeat(129), '1'])
    await catalog.getSongs('ng', ['bad,id', 'has/slash', 'x'.repeat(129)])

    expect(fetchLike).toHaveBeenCalledOnce()
    const [input] = fetchLike.mock.calls[0]
    expect(new URL(input).searchParams.get('ids')).toBe('1,opaque.ID_2~')
    expect(issueServerToken).toHaveBeenCalledOnce()
  })

  it('reconciles by Apple ID, ignores missing and extra songs, and preserves valid songs with invalid artwork', async () => {
    const fetchLike = vi.fn<FetchLike>(async () =>
      jsonResponse({
        data: [
          song('2', {
            url: 'https://is2-ssl.mzstatic.com/image/thumb/two/{w}x{h}.{f}',
            width: 1200,
            height: 1200,
            bgColor: 'FFEEDD',
          }),
          song('999'),
          song('1', { url: 'https://example.com/not-apple.jpg', width: 100, height: 100, bgColor: 'abcdef' }),
        ],
      }),
    )

    const result = await client(fetchLike).getSongs('ng', ['1', '3', '2'])

    expect([...result.keys()]).toEqual(['2', '1'])
    expect(result.get('2')).toMatchObject({
      appleId: '2',
      isrc: 'ISRC2',
      title: 'Song 2',
      artist: 'Artist 2',
      album: 'Album 2',
      artwork: { bgColor: 'ffeedd' },
    })
    expect(result.get('1')?.artwork).toBeNull()
    expect(result.has('999')).toBe(false)
    expect(result.has('3')).toBe(false)
  })

  it('keeps songs whose artwork is absent as null', async () => {
    const result = await client(async () => jsonResponse({ data: [song('1')] })).getSongs('ng', ['1'])
    expect(result.get('1')?.artwork).toBeNull()
  })

  it('reuses a still-valid internal server token', async () => {
    const issueServerToken = vi.fn(async () => ({ developerToken: 'server-token', expiresAt: 1_788_138_000 }))
    const catalog = createAppleCatalogClient({
      fetchLike: async () => jsonResponse({ data: [] }),
      issueServerToken,
      nowSeconds: () => 1_788_134_400,
    })

    await catalog.getSongs('ng', ['1'])
    await catalog.getSongs('ng', ['2'])

    expect(issueServerToken).toHaveBeenCalledTimes(1)
  })

  it('reuses a still-valid server token across separately constructed clients', async () => {
    const issueServerToken = vi.fn(async () => ({ developerToken: 'server-token', expiresAt: 1_788_138_000 }))
    const tokenCache = createAppleCatalogTokenCache()
    const common = {
      fetchLike: async () => jsonResponse({ data: [] }),
      issueServerToken,
      nowSeconds: () => 1_788_134_400,
      tokenCache,
      tokenCacheKey: 'TEAM123456:MUSIC12345',
    }

    await createAppleCatalogClient(common).getSongs('ng', ['1'])
    await createAppleCatalogClient(common).getSongs('ng', ['2'])

    expect(issueServerToken).toHaveBeenCalledTimes(1)
  })

  it('classifies token issuer failures as authorization without attempting a request', async () => {
    const fetchLike = vi.fn<FetchLike>()
    const catalog = createAppleCatalogClient({
      fetchLike,
      issueServerToken: async () => { throw new Error('SECRET SIGNING FAILURE') },
      nowSeconds: () => 1_788_134_400,
    })

    const thrown = await catalog.getSongs('ng', ['1']).catch((error: unknown) => error)

    expect(thrown).toBeInstanceOf(AppleCatalogError)
    expect(thrown).toMatchObject({ category: 'authorization' })
    expect(String(thrown)).not.toContain('SECRET SIGNING FAILURE')
    expect(fetchLike).not.toHaveBeenCalled()
  })

  it.each([
    [401, 'authorization'],
    [403, 'authorization'],
    [429, 'rate_limit'],
    [500, 'upstream'],
    [503, 'upstream'],
  ] as const)('turns HTTP %i into a fixed typed %s error without upstream text', async (status, category) => {
    const catalog = client(async () => new Response('SECRET APPLE RESPONSE', { status }))

    const thrown = await catalog.getSongs('ng', ['1']).catch((error: unknown) => error)

    expect(thrown).toBeInstanceOf(AppleCatalogError)
    expect(thrown).toMatchObject({ category, status })
    expect(String(thrown)).not.toContain('SECRET APPLE RESPONSE')
  })

  it('cancels an unread non-success response body', async () => {
    let cancelled = false
    const catalog = client(async () =>
      new Response(
        new ReadableStream({
          start(controller) {
            controller.enqueue(new TextEncoder().encode('SECRET APPLE RESPONSE'))
          },
          cancel() {
            cancelled = true
          },
        }),
        { status: 503 },
      ),
    )

    await expect(catalog.getSongs('ng', ['1'])).rejects.toMatchObject({
      category: 'upstream',
      status: 503,
    })
    expect(cancelled).toBe(true)
  })

  it('turns malformed JSON into a fixed response error', async () => {
    const catalog = client(async () => new Response('{bad json', { status: 200 }))

    await expect(catalog.getSongs('ng', ['1'])).rejects.toMatchObject({
      name: 'AppleCatalogError',
      category: 'response',
      status: 200,
    })
  })

  it('turns a timed-out request into a fixed timeout error', async () => {
    const catalog = createAppleCatalogClient({
      fetchLike: async (_input, init) => {
        await new Promise((resolve, reject) => {
          init?.signal?.addEventListener('abort', () => reject(init.signal?.reason), { once: true })
          setTimeout(resolve, 100)
        })
        return jsonResponse({ data: [] })
      },
      issueServerToken: async () => ({ developerToken: 'server-token', expiresAt: 1_788_138_000 }),
      nowSeconds: () => 1_788_134_400,
      timeoutMs: 5,
    })

    await expect(catalog.getSongs('ng', ['1'])).rejects.toMatchObject({
      name: 'AppleCatalogError',
      category: 'timeout',
    })
  })

  it('keeps the timeout active while the response body is being read', async () => {
    const catalog = createAppleCatalogClient({
      fetchLike: async (_input, init) =>
        new Response(
          new ReadableStream({
            start(controller) {
              const delayedBody = setTimeout(() => {
                controller.enqueue(new TextEncoder().encode('{"data":[]}'))
                controller.close()
              }, 100)
              init?.signal?.addEventListener('abort', () => {
                clearTimeout(delayedBody)
                controller.error(new DOMException('aborted', 'AbortError'))
              }, { once: true })
            },
          }),
        ),
      issueServerToken: async () => ({ developerToken: 'server-token', expiresAt: 1_788_138_000 }),
      nowSeconds: () => 1_788_134_400,
      timeoutMs: 5,
    })

    await expect(catalog.getSongs('ng', ['1'])).rejects.toMatchObject({
      name: 'AppleCatalogError',
      category: 'timeout',
    })
  })

  it('caps and cancels an oversized successful response body', async () => {
    let cancelled = false
    const catalog = createAppleCatalogClient({
      fetchLike: async () =>
        new Response(
          new ReadableStream({
            start(controller) {
              controller.enqueue(new TextEncoder().encode('{"data":'))
              controller.enqueue(new TextEncoder().encode('["SECRET OVERSIZED BODY"]}'))
            },
            cancel() {
              cancelled = true
            },
          }),
          { status: 200 },
        ),
      issueServerToken: async () => ({ developerToken: 'server-token', expiresAt: 1_788_138_000 }),
      nowSeconds: () => 1_788_134_400,
      maxResponseBytes: 10,
    })

    const thrown = await catalog.getSongs('ng', ['1']).catch((error: unknown) => error)

    expect(thrown).toBeInstanceOf(AppleCatalogError)
    expect(thrown).toMatchObject({ category: 'response', status: 200 })
    expect(String(thrown)).not.toContain('SECRET OVERSIZED BODY')
    expect(cancelled).toBe(true)
  })
})
