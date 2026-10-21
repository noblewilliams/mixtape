import { describe, expect, it, vi } from 'vitest'
import {
  AppleCatalogError,
  createAppleCatalogClient,
  type FetchLike,
} from '../../src/musickit/catalog'

// Recorded-style fixtures trimmed from Apple Music API responses.
const ARTIST_SEARCH_HIT = {
  results: {
    artists: {
      href: '/v1/catalog/ng/search?limit=3&term=burna&types=artists',
      data: [
        {
          id: '1015380298',
          type: 'artists',
          href: '/v1/catalog/ng/artists/1015380298',
          attributes: { name: 'Burna Boy', genreNames: ['Afrobeats', 'African'], url: 'https://music.apple.com/ng/artist/burna-boy/1015380298' },
        },
        {
          id: '1446365464',
          type: 'artists',
          href: '/v1/catalog/ng/artists/1446365464',
          attributes: { name: 'Burna Boy & Friends', genreNames: ['Afro-Pop'] },
        },
        {
          id: '1500000001',
          type: 'artists',
          href: '/v1/catalog/ng/artists/1500000001',
          attributes: { name: 'Burnaby Choir' },
        },
        { id: '1500000002', type: 'songs', attributes: { name: 'Not an artist', genreNames: [] } },
        { id: '1500000003', type: 'artists', attributes: { genreNames: ['Pop'] } },
        { id: 'bad id/../', type: 'artists', attributes: { name: 'Bad Id' } },
      ],
    },
  },
  meta: { results: { order: ['artists'], rawOrder: ['artists'] } },
}

const ARTIST_SEARCH_MISS = {
  results: {},
  meta: { results: { order: [], rawOrder: [] } },
}

const topSong = (id: string, name: string, isrc: string, releaseDate: string) => ({
  id,
  type: 'songs',
  href: `/v1/catalog/ng/songs/${id}`,
  attributes: {
    name,
    artistName: 'Burna Boy',
    albumName: 'African Giant',
    isrc,
    durationInMillis: 201_000,
    genreNames: ['Afrobeats', 'Music'],
    releaseDate,
    contentRating: 'explicit',
    artwork: { url: 'https://is1-ssl.mzstatic.com/image/thumb/Music/{w}x{h}bb.{f}', width: 3000, height: 3000, bgColor: '1a1a1a' },
  },
})

const TOP_SONGS_PAGE = {
  next: '/v1/catalog/ng/artists/1015380298/view/top-songs?offset=3',
  data: [
    topSong('1476035700', 'On the Low', 'GBUM71806282', '2018-11-30'),
    topSong('1476035701', 'Ye', 'QMFME1800026', '2018'),
    topSong('1476035702', 'Last Last', 'USAT22205003', '2022-05-13'),
    { id: '1476035703', type: 'songs', attributes: { artistName: 'Burna Boy' } },
  ],
}

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

function oversized(onCancel: () => void): FetchLike {
  return async () => new Response(
    new ReadableStream({
      start(controller) {
        controller.enqueue(new TextEncoder().encode('{"results":'))
        controller.enqueue(new TextEncoder().encode('{"SECRET OVERSIZED BODY":1}}'))
      },
      cancel: onCancel,
    }),
    { status: 200 },
  )
}

describe('searchArtists', () => {
  it('returns the well-formed artists of a hit and skips malformed entries', async () => {
    const fetchLike = vi.fn<FetchLike>(async () => jsonResponse(ARTIST_SEARCH_HIT))

    const result = await client(fetchLike).searchArtists('ng', 'burna', 3)

    expect(result).toEqual([
      { id: '1015380298', name: 'Burna Boy', genres: ['Afrobeats', 'African'] },
      { id: '1446365464', name: 'Burna Boy & Friends', genres: ['Afro-Pop'] },
      { id: '1500000001', name: 'Burnaby Choir', genres: [] },
    ])
    expect(fetchLike).toHaveBeenCalledOnce()
    const [, init] = fetchLike.mock.calls[0]
    expect(new Headers(init?.headers).get('authorization')).toBe('Bearer server-token')
  })

  it('drops both copies of an artist id that appears twice', async () => {
    const artist = (name: string) => ({ id: '1015380298', type: 'artists', attributes: { name, genreNames: [] } })
    const result = await client(async () => jsonResponse({ results: { artists: { data: [
      artist('Burna Boy'), artist('Burna Boy (dup)'),
      { id: '1500000001', type: 'artists', attributes: { name: 'Burnaby Choir' } },
    ] } } })).searchArtists('ng', 'burna', 5)
    expect(result.map((item) => item.id)).toEqual(['1500000001'])
  })

  it('keeps a valid artist when a malformed entry shares its id', async () => {
    const result = await client(async () => jsonResponse({ results: { artists: { data: [
      { id: '1015380298', type: 'artists', attributes: { genreNames: ['Pop'] } },
      { id: '1015380298', type: 'artists', attributes: { name: 'Burna Boy', genreNames: ['Afrobeats'] } },
    ] } } })).searchArtists('ng', 'burna', 5)
    expect(result).toEqual([{ id: '1015380298', name: 'Burna Boy', genres: ['Afrobeats'] }])
  })

  it('returns an empty list when Apple omits the artists key', async () => {
    expect(await client(async () => jsonResponse(ARTIST_SEARCH_MISS)).searchArtists('ng', 'zzqx', 5))
      .toEqual([])
  })

  it('builds the exact search URL with an encoded term, types=artists and a capped limit', async () => {
    const fetchLike = vi.fn<FetchLike>(async () => jsonResponse(ARTIST_SEARCH_MISS))

    await client(fetchLike).searchArtists('ng', '  Beyoncé & Jay-Z / x?  ', 99)

    expect(String(fetchLike.mock.calls[0][0])).toBe(
      'https://api.music.apple.com/v1/catalog/ng/search?term=Beyonc%C3%A9+%26+Jay-Z+%2F+x%3F&types=artists&limit=25',
    )
  })

  it.each([
    ['NG', 'burna', 5],
    ['n/g', 'burna', 5],
    ['ng', '   ', 5],
    ['ng', 'x'.repeat(121), 5],
    ['ng', 'burna', 0],
    ['ng', 'burna', 1.5],
  ] as const)('rejects invalid input (%s, %s, %s) before token or network work', async (storefront, term, limit) => {
    const fetchLike = vi.fn<FetchLike>()
    const issueServerToken = vi.fn(async () => ({ developerToken: 'server-token', expiresAt: 1_788_138_000 }))
    const catalog = createAppleCatalogClient({ fetchLike, issueServerToken })

    await expect(catalog.searchArtists(storefront, term, limit)).rejects.toMatchObject({
      name: 'AppleCatalogError', category: 'response',
    })
    expect(fetchLike).not.toHaveBeenCalled()
    expect(issueServerToken).not.toHaveBeenCalled()
  })

  it('rejects a malformed envelope', async () => {
    await expect(client(async () => jsonResponse({ results: { artists: { data: 'nope' } } }))
      .searchArtists('ng', 'burna', 5)).rejects.toMatchObject({ category: 'response', status: 200 })
  })

  it('throws the rate-limit error with its status on 429', async () => {
    const thrown = await client(async () => jsonResponse({ errors: [] }, 429))
      .searchArtists('ng', 'burna', 5).catch((error: unknown) => error)
    expect(thrown).toBeInstanceOf(AppleCatalogError)
    expect(thrown).toMatchObject({ category: 'rate_limit', status: 429 })
  })

  it('caps and cancels an oversized response', async () => {
    let cancelled = false
    const catalog = createAppleCatalogClient({
      fetchLike: oversized(() => { cancelled = true }),
      issueServerToken: async () => ({ developerToken: 'server-token', expiresAt: 1_788_138_000 }),
      nowSeconds: () => 1_788_134_400,
      maxResponseBytes: 10,
    })

    const thrown = await catalog.searchArtists('ng', 'burna', 5).catch((error: unknown) => error)

    expect(thrown).toBeInstanceOf(AppleCatalogError)
    expect(thrown).toMatchObject({ category: 'response', status: 200 })
    expect(String(thrown)).not.toContain('SECRET OVERSIZED BODY')
    expect(cancelled).toBe(true)
  })
})

describe('artistTopSongs', () => {
  it('parses a top-songs page with ISRC, duration, genre and release year', async () => {
    const fetchLike = vi.fn<FetchLike>(async () => jsonResponse(TOP_SONGS_PAGE))

    const result = await client(fetchLike).artistTopSongs('ng', '1015380298', 10)

    expect(fetchLike).toHaveBeenCalledOnce()
    expect(result.map((song) => [song.appleId, song.isrc, song.releaseYear])).toEqual([
      ['1476035700', 'GBUM71806282', 2018],
      ['1476035701', 'QMFME1800026', 2018],
      ['1476035702', 'USAT22205003', 2022],
    ])
    expect(result[0]).toMatchObject({
      title: 'On the Low', artist: 'Burna Boy', album: 'African Giant',
      durationMs: 201_000, genre: 'Afrobeats', explicit: true,
    })
  })

  it('builds the exact top-songs URL with an encoded storefront and artist id and a capped limit', async () => {
    const fetchLike = vi.fn<FetchLike>(async () => jsonResponse({ data: [] }))

    await client(fetchLike).artistTopSongs('ng', '1015380298', 99)

    expect(String(fetchLike.mock.calls[0][0])).toBe(
      'https://api.music.apple.com/v1/catalog/ng/artists/1015380298/view/top-songs?limit=30',
    )
  })

  it('drops both copies of a song id that appears twice', async () => {
    const result = await client(async () => jsonResponse({ data: [
      topSong('1476035700', 'On the Low', 'GBUM71806282', '2018-11-30'),
      topSong('1476035700', 'On the Low (dup)', 'GBUM71806282', '2018-11-30'),
      topSong('1476035702', 'Last Last', 'USAT22205003', '2022-05-13'),
    ] })).artistTopSongs('ng', '1015380298', 10)
    expect(result.map((song) => song.appleId)).toEqual(['1476035702'])
  })

  it('keeps a valid song when a malformed entry shares its id', async () => {
    const result = await client(async () => jsonResponse({ data: [
      { id: '1476035700', type: 'songs', attributes: { artistName: 'Burna Boy' } },
      topSong('1476035700', 'On the Low', 'GBUM71806282', '2018-11-30'),
    ] })).artistTopSongs('ng', '1015380298', 10)
    expect(result.map((song) => [song.appleId, song.title])).toEqual([['1476035700', 'On the Low']])
  })

  it('returns an empty list for an unknown artist (404)', async () => {
    expect(await client(async () => jsonResponse({ errors: [{ status: '404' }] }, 404))
      .artistTopSongs('ng', '999999999999', 10)).toEqual([])
  })

  it('throws the rate-limit error with its status on 429', async () => {
    const thrown = await client(async () => jsonResponse({ errors: [] }, 429))
      .artistTopSongs('ng', '1015380298', 10).catch((error: unknown) => error)
    expect(thrown).toBeInstanceOf(AppleCatalogError)
    expect(thrown).toMatchObject({ category: 'rate_limit', status: 429 })
  })

  it('throws upstream errors other than 404', async () => {
    await expect(client(async () => jsonResponse({}, 500)).artistTopSongs('ng', '1015380298', 10))
      .rejects.toMatchObject({ category: 'upstream', status: 500 })
  })

  it('rejects a malformed envelope', async () => {
    await expect(client(async () => jsonResponse({ results: {} })).artistTopSongs('ng', '1015380298', 10))
      .rejects.toMatchObject({ category: 'response', status: 200 })
  })

  it.each([
    ['NG', '1015380298', 10],
    ['ng', 'bad id/..', 10],
    ['ng', '', 10],
    ['ng', '..', 10],
    ['ng', '.', 10],
    ['ng', '1015380298', 0],
    ['ng', '1015380298', 2.5],
  ] as const)('rejects invalid input (%s, %s, %s) before token or network work', async (storefront, artistId, limit) => {
    const fetchLike = vi.fn<FetchLike>()
    const issueServerToken = vi.fn(async () => ({ developerToken: 'server-token', expiresAt: 1_788_138_000 }))
    const catalog = createAppleCatalogClient({ fetchLike, issueServerToken })

    await expect(catalog.artistTopSongs(storefront, artistId, limit)).rejects.toMatchObject({
      name: 'AppleCatalogError', category: 'response',
    })
    expect(fetchLike).not.toHaveBeenCalled()
    expect(issueServerToken).not.toHaveBeenCalled()
  })

  it('caps and cancels an oversized response', async () => {
    let cancelled = false
    const catalog = createAppleCatalogClient({
      fetchLike: oversized(() => { cancelled = true }),
      issueServerToken: async () => ({ developerToken: 'server-token', expiresAt: 1_788_138_000 }),
      nowSeconds: () => 1_788_134_400,
      maxResponseBytes: 10,
    })

    const thrown = await catalog.artistTopSongs('ng', '1015380298', 10).catch((error: unknown) => error)

    expect(thrown).toBeInstanceOf(AppleCatalogError)
    expect(thrown).toMatchObject({ category: 'response', status: 200 })
    expect(String(thrown)).not.toContain('SECRET OVERSIZED BODY')
    expect(cancelled).toBe(true)
  })

  it('shares the server token cache with the other calls', async () => {
    const issueServerToken = vi.fn(async () => ({ developerToken: 'server-token', expiresAt: 1_788_138_000 }))
    const fetchLike = vi.fn<FetchLike>(async (input) => jsonResponse(
      String(input).includes('/search') ? ARTIST_SEARCH_MISS : { data: [] },
    ))
    const catalog = createAppleCatalogClient({ fetchLike, issueServerToken, nowSeconds: () => 1_788_134_400 })

    await catalog.searchArtists('ng', 'burna', 3)
    await catalog.artistTopSongs('ng', '1015380298', 10)

    expect(issueServerToken).toHaveBeenCalledOnce()
    expect(fetchLike).toHaveBeenCalledTimes(2)
  })
})
