import { describe, expect, it, vi } from 'vitest'
import {
  AppleCatalogError,
  createAppleCatalogClient,
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
  it('batches at 300, URL-encodes the storefront and IDs, and authenticates each request', async () => {
    const ids = Array.from({ length: 302 }, (_, index) => (index === 0 ? 'id/with spaces' : `id-${index}`))
    const fetchLike = vi.fn<FetchLike>(async () => jsonResponse({ data: [] }))

    await client(fetchLike).getSongs('ng / west', ids)

    expect(fetchLike).toHaveBeenCalledTimes(2)
    const calls = fetchLike.mock.calls.map(([input, init]) => ({ url: new URL(input), init }))
    expect(calls[0].url.pathname).toBe('/v1/catalog/ng%20%2F%20west/songs')
    expect(calls[0].url.searchParams.get('ids')?.split(',')).toHaveLength(300)
    expect(calls[0].url.searchParams.get('ids')?.split(',')[0]).toBe('id/with spaces')
    expect(calls[1].url.searchParams.get('ids')?.split(',')).toHaveLength(2)
    expect(calls.every(({ init }) => new Headers(init?.headers).get('authorization') === 'Bearer server-token')).toBe(true)
  })

  it('reconciles by Apple ID, ignores missing and extra songs, and preserves valid songs with invalid artwork', async () => {
    const fetchLike = vi.fn<FetchLike>(async () =>
      jsonResponse({
        data: [
          song('two', {
            url: 'https://is2-ssl.mzstatic.com/image/thumb/two/{w}x{h}.{f}',
            width: 1200,
            height: 1200,
            bgColor: 'FFEEDD',
          }),
          song('extra'),
          song('one', { url: 'https://example.com/not-apple.jpg', width: 100, height: 100, bgColor: 'abcdef' }),
        ],
      }),
    )

    const result = await client(fetchLike).getSongs('ng', ['one', 'missing', 'two'])

    expect([...result.keys()]).toEqual(['two', 'one'])
    expect(result.get('two')).toMatchObject({
      appleId: 'two',
      isrc: 'ISRCtwo',
      title: 'Song two',
      artist: 'Artist two',
      album: 'Album two',
      artwork: { bgColor: 'ffeedd' },
    })
    expect(result.get('one')?.artwork).toBeNull()
    expect(result.has('extra')).toBe(false)
    expect(result.has('missing')).toBe(false)
  })

  it('keeps songs whose artwork is absent as null', async () => {
    const result = await client(async () => jsonResponse({ data: [song('one')] })).getSongs('ng', ['one'])
    expect(result.get('one')?.artwork).toBeNull()
  })

  it('reuses a still-valid internal server token', async () => {
    const issueServerToken = vi.fn(async () => ({ developerToken: 'server-token', expiresAt: 1_788_138_000 }))
    const catalog = createAppleCatalogClient({
      fetchLike: async () => jsonResponse({ data: [] }),
      issueServerToken,
      nowSeconds: () => 1_788_134_400,
    })

    await catalog.getSongs('ng', ['one'])
    await catalog.getSongs('ng', ['two'])

    expect(issueServerToken).toHaveBeenCalledTimes(1)
  })

  it.each([
    [401, 'authorization'],
    [403, 'authorization'],
    [429, 'rate_limit'],
    [500, 'upstream'],
    [503, 'upstream'],
  ] as const)('turns HTTP %i into a fixed typed %s error without upstream text', async (status, category) => {
    const catalog = client(async () => new Response('SECRET APPLE RESPONSE', { status }))

    const thrown = await catalog.getSongs('ng', ['one']).catch((error: unknown) => error)

    expect(thrown).toBeInstanceOf(AppleCatalogError)
    expect(thrown).toMatchObject({ category, status })
    expect(String(thrown)).not.toContain('SECRET APPLE RESPONSE')
  })

  it('turns malformed JSON into a fixed response error', async () => {
    const catalog = client(async () => new Response('{bad json', { status: 200 }))

    await expect(catalog.getSongs('ng', ['one'])).rejects.toMatchObject({
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

    await expect(catalog.getSongs('ng', ['one'])).rejects.toMatchObject({
      name: 'AppleCatalogError',
      category: 'timeout',
    })
  })
})
