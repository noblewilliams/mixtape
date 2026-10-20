import { describe, expect, it, vi } from 'vitest'
import {
  AppleCatalogError,
  createAppleCatalogClient,
  type FetchLike,
} from '../../src/musickit/catalog'

const artwork = {
  url: 'https://is1-ssl.mzstatic.com/image/thumb/Music116/v4/a/b/c/{w}x{h}bb.{f}',
  width: 3000,
  height: 3000,
  bgColor: 'A1B2C3',
}

const album = (id: string, attributes: Record<string, unknown> = {}, extra: Record<string, unknown> = {}) => ({
  id,
  type: 'albums',
  attributes: {
    name: `Album ${id}`,
    artistName: `Artist ${id}`,
    ...attributes,
  },
  ...extra,
})

const tracks = (durations: unknown[], next?: string) => ({
  relationships: {
    tracks: {
      href: '/v1/catalog/us/albums/1/tracks',
      data: durations.map((durationInMillis, index) => ({
        id: String(1000 + index),
        type: 'songs',
        attributes: { durationInMillis },
      })),
      ...(next === undefined ? {} : { next }),
    },
  },
})

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  })
}

function client(fetchLike: FetchLike) {
  return createAppleCatalogClient({
    fetchLike,
    issueServerToken: vi.fn(async () => ({ developerToken: 'server-token', expiresAt: 1_788_138_000 })),
    nowSeconds: () => 1_788_134_400,
  })
}

function requestedUrl(fetchLike: ReturnType<typeof vi.fn<FetchLike>>, call = 0): URL {
  return new URL(String(fetchLike.mock.calls[call]![0]))
}

describe('Apple catalog album client', () => {
  it('searches albums with a bounded encoded request and maps a full hit', async () => {
    const fetchLike = vi.fn<FetchLike>(async () => jsonResponse({
      results: {
        albums: {
          href: '/v1/catalog/us/search?term=massive+attack&types=albums',
          data: [album('1440857781', {
            name: 'Blue Lines',
            artistName: 'Massive Attack',
            upc: '00724384756458',
            releaseDate: '1991-04-08',
            trackCount: 9,
            isSingle: false,
            isCompilation: false,
            genreNames: ['Electronic', 'Music'],
            artwork,
          })],
        },
      },
    }))

    const albums = await client(fetchLike).searchAlbums('us', '  massive attack blue lines  ', 5)

    const url = requestedUrl(fetchLike)
    expect(url.origin).toBe('https://api.music.apple.com')
    expect(url.pathname).toBe('/v1/catalog/us/search')
    expect(url.searchParams.get('types')).toBe('albums')
    expect(url.searchParams.get('term')).toBe('massive attack blue lines')
    expect(url.searchParams.get('limit')).toBe('5')
    expect(fetchLike.mock.calls[0]![1]?.headers).toEqual({ Authorization: 'Bearer server-token' })
    expect(albums).toEqual([{
      appleId: '1440857781',
      upc: '00724384756458',
      title: 'Blue Lines',
      artist: 'Massive Attack',
      releaseYear: 1991,
      trackCount: 9,
      durationMs: null,
      isSingle: false,
      isCompilation: false,
      genre: 'Electronic',
      artwork: { ...artwork, bgColor: 'a1b2c3' },
    }])
  })

  it('maps a single and a compilation from Apple booleans', async () => {
    const fetchLike = vi.fn<FetchLike>(async () => jsonResponse({
      results: {
        albums: {
          data: [
            album('11', { isSingle: true, trackCount: 1 }),
            album('12', { isCompilation: true }),
          ],
        },
      },
    }))

    const [single, compilation] = await client(fetchLike).searchAlbums('gb', 'term', 10)

    expect(single).toMatchObject({ appleId: '11', isSingle: true, isCompilation: false, trackCount: 1 })
    expect(compilation).toMatchObject({ appleId: '12', isSingle: false, isCompilation: true })
  })

  it.each([
    ['a numeric upc', 123],
    ['an empty upc', ''],
    ['a non-digit upc', 'abc'],
  ])('defaults optional album fields when absent or malformed (%s)', async (_label, upc) => {
    const fetchLike = vi.fn<FetchLike>(async () => jsonResponse({
      results: {
        albums: {
          data: [album('13', {
            upc,
            releaseDate: 'soon',
            trackCount: 0,
            isSingle: 'yes',
            genreNames: [7],
            artwork: { url: 'https://example.com/a.jpg' },
          })],
        },
      },
    }))

    const [parsed] = await client(fetchLike).searchAlbums('us', 'term', 1)

    expect(parsed).toEqual({
      appleId: '13',
      upc: null,
      title: 'Album 13',
      artist: 'Artist 13',
      releaseYear: null,
      trackCount: null,
      durationMs: null,
      isSingle: false,
      isCompilation: false,
      genre: null,
      artwork: null,
    })
  })

  it('drops a malformed album while its neighbours survive', async () => {
    const malformed = { id: '22', type: 'albums', attributes: { name: 'No Artist' } }
    const fetchLike = vi.fn<FetchLike>(async () => jsonResponse({
      results: {
        albums: {
          data: [
            album('21'),
            malformed,
            { id: '23', type: 'songs', attributes: { name: 'Song', artistName: 'A' } },
            album('24'),
          ],
        },
      },
    }))

    const albums = await client(fetchLike).searchAlbums('us', 'term', 10)

    expect(albums.map(value => value.appleId)).toEqual(['21', '24'])
  })

  it('drops both copies of a duplicated search id', async () => {
    const fetchLike = vi.fn<FetchLike>(async () => jsonResponse({
      results: { albums: { data: [album('31'), album('32'), album('31')] } },
    }))

    const albums = await client(fetchLike).searchAlbums('us', 'term', 10)

    expect(albums.map(value => value.appleId)).toEqual(['32'])
  })

  it('returns an empty list when Apple omits results.albums', async () => {
    const fetchLike = vi.fn<FetchLike>(async () => jsonResponse({ results: {} }))

    await expect(client(fetchLike).searchAlbums('us', 'nothing matches', 5)).resolves.toEqual([])
  })

  it.each([
    ['an errors payload', { errors: [{ status: '400' }], results: {} }],
    ['a non-object payload', ['not', 'an', 'object']],
    ['a missing results object', { meta: {} }],
    ['a non-array albums data', { results: { albums: { data: {} } } }],
  ])('rejects %s as a response error', async (_label, body) => {
    const fetchLike = vi.fn<FetchLike>(async () => jsonResponse(body))

    await expect(client(fetchLike).searchAlbums('us', 'term', 5)).rejects.toMatchObject({
      category: 'response',
      status: 200,
    })
  })

  it('throws a typed rate limit error on an upstream 429', async () => {
    const fetchLike = vi.fn<FetchLike>(async () => jsonResponse({ errors: [] }, 429))

    const error = await client(fetchLike).searchAlbums('us', 'term', 5).catch((value: unknown) => value)

    expect(error).toBeInstanceOf(AppleCatalogError)
    expect(error).toMatchObject({ category: 'rate_limit', status: 429 })
  })

  it.each([
    ['an empty term', 'us', '   ', 5],
    ['a 121-character term', 'us', 'a'.repeat(121), 5],
    ['limit 0', 'us', 'term', 0],
    ['limit 11', 'us', 'term', 11],
    ['a fractional limit', 'us', 'term', 2.5],
    ['an uppercase storefront', 'US', 'term', 5],
    ['a path storefront', 'us/../x', 'term', 5],
  ])('rejects %s before fetching', async (_label, storefront, term, limit) => {
    const fetchLike = vi.fn<FetchLike>(async () => jsonResponse({ results: {} }))

    await expect(client(fetchLike).searchAlbums(storefront, term, limit)).rejects.toMatchObject({
      category: 'response',
    })
    expect(fetchLike).not.toHaveBeenCalled()
  })

  it('accepts a 120-character term and limit 10', async () => {
    const fetchLike = vi.fn<FetchLike>(async () => jsonResponse({ results: {} }))

    await client(fetchLike).searchAlbums('us', 'a'.repeat(120), 10)

    expect(fetchLike).toHaveBeenCalledTimes(1)
  })

  it('fetches albums by id with the expected URL shape', async () => {
    const fetchLike = vi.fn<FetchLike>(async () => jsonResponse({ data: [album('41'), album('42')] }))

    const albums = await client(fetchLike).getAlbums('us', ['41', '42', '41', 'bad id', 'a/b', 'x'.repeat(129)])

    expect(fetchLike).toHaveBeenCalledTimes(1)
    const url = requestedUrl(fetchLike)
    expect(url.origin).toBe('https://api.music.apple.com')
    expect(url.pathname).toBe('/v1/catalog/us/albums')
    expect(url.searchParams.get('ids')).toBe('41,42')
    expect([...albums.keys()]).toEqual(['41', '42'])
    expect(albums.get('41')).toMatchObject({ title: 'Album 41', artist: 'Artist 41' })
  })

  it('makes no request when no valid ids remain', async () => {
    const fetchLike = vi.fn<FetchLike>(async () => jsonResponse({ data: [] }))

    await expect(client(fetchLike).getAlbums('us', ['a,b', ''])).resolves.toEqual(new Map())
    expect(fetchLike).not.toHaveBeenCalled()
  })

  it('batches album fetches at 100 ids', async () => {
    const ids = Array.from({ length: 150 }, (_, index) => String(5000 + index))
    const fetchLike = vi.fn<FetchLike>(async (input) => {
      const requested = new URL(String(input)).searchParams.get('ids')!.split(',')
      return jsonResponse({ data: requested.map(id => album(id)) })
    })

    const albums = await client(fetchLike).getAlbums('us', ids)

    expect(fetchLike).toHaveBeenCalledTimes(2)
    expect(requestedUrl(fetchLike, 0).searchParams.get('ids')!.split(',')).toHaveLength(100)
    expect(requestedUrl(fetchLike, 1).searchParams.get('ids')!.split(',')).toHaveLength(50)
    expect(albums.size).toBe(150)
  })

  it('keeps only requested ids and drops an id duplicated in the response', async () => {
    const fetchLike = vi.fn<FetchLike>(async () => jsonResponse({
      data: [album('51'), album('52'), album('99'), album('52', { name: 'Other' })],
    }))

    const albums = await client(fetchLike).getAlbums('us', ['51', '52'])

    expect([...albums.keys()]).toEqual(['51'])
  })

  it('rejects a malformed getAlbums payload', async () => {
    const fetchLike = vi.fn<FetchLike>(async () => jsonResponse({ results: [] }))

    await expect(client(fetchLike).getAlbums('us', ['61'])).rejects.toMatchObject({
      category: 'response',
      status: 200,
    })
  })

  it('throws a typed rate limit error when getAlbums hits an upstream 429', async () => {
    const fetchLike = vi.fn<FetchLike>(async () => jsonResponse({ errors: [] }, 429))

    const error = await client(fetchLike).getAlbums('us', ['61']).catch((value: unknown) => value)

    expect(error).toBeInstanceOf(AppleCatalogError)
    expect(error).toMatchObject({ category: 'rate_limit', status: 429 })
  })

  it('sums durationMs from a complete tracks relationship', async () => {
    const fetchLike = vi.fn<FetchLike>(async () => jsonResponse({
      data: [album('71', {}, tracks([200_000, 180_500, 241_000]))],
    }))

    const albums = await client(fetchLike).getAlbums('us', ['71'])

    expect(albums.get('71')?.durationMs).toBe(621_500)
  })

  it.each([
    ['the relationship is missing', {}],
    ['the relationship has a next page', tracks([200_000, 180_000], '/v1/catalog/us/albums/72/tracks?offset=2')],
    ['an entry lacks a duration', tracks([200_000, undefined])],
    ['an entry has a zero duration', tracks([200_000, 0])],
    ['an entry has a fractional duration', tracks([200_000, 1.5])],
    ['the sum overflows a 32-bit integer', tracks([2_000_000_000, 2_000_000_000])],
    ['the tracks data is empty', tracks([])],
    ['an entry is null', { relationships: { tracks: { data: [null] } } }],
  ])('leaves durationMs null when %s', async (_label, extra) => {
    const fetchLike = vi.fn<FetchLike>(async () => jsonResponse({ data: [album('72', {}, extra)] }))

    const albums = await client(fetchLike).getAlbums('us', ['72'])

    expect(albums.get('72')).toBeDefined()
    expect(albums.get('72')?.durationMs).toBeNull()
  })
})
