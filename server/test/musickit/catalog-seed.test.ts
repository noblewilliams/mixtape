import { describe, expect, it, vi } from 'vitest'
import {
  AppleCatalogError,
  createAppleCatalogClient,
  type FetchLike,
} from '../../src/musickit/catalog'

// Recorded-style fixtures trimmed from Apple Music API responses.
const song = (id: string, name: string, isrc: string) => ({
  id,
  type: 'songs',
  href: `/v1/catalog/ng/songs/${id}`,
  attributes: {
    name,
    artistName: 'Ayra Starr',
    albumName: '19 & Dangerous',
    isrc,
    durationInMillis: 180_000,
    genreNames: ['Afrobeats', 'Music'],
    releaseDate: '2021-08-06',
    contentRating: 'clean',
    artwork: { url: 'https://is1-ssl.mzstatic.com/image/thumb/Music/{w}x{h}bb.{f}', width: 3000, height: 3000 },
  },
})

const CHART_PAGE = {
  results: {
    songs: [
      {
        chart: 'most-played',
        name: 'Top Songs',
        orderId: 'most-played:songs',
        next: '/v1/catalog/ng/charts?genre=14&limit=3&offset=3&types=songs',
        data: [
          song('1570000001', 'Bloody Samaritan', 'NGA3B2100001'),
          song('1570000002', 'Rush', 'NGA3B2200002'),
          { id: '1570000003', type: 'music-videos', attributes: { name: 'Rush (Video)', artistName: 'Ayra Starr' } },
          { id: '1570000004', type: 'songs', attributes: { artistName: 'Ayra Starr' } },
        ],
      },
    ],
  },
}

const PLAYLIST_SEARCH_HIT = {
  results: {
    playlists: {
      data: [
        { id: 'pl.dc349df19c6f410d874c197db63ecfed', type: 'playlists', attributes: { name: 'Afrobeats Essentials', curatorName: 'Apple Music' } },
        { id: 'pl.u-abc123', type: 'playlists', attributes: { name: 'my afrobeats' } },
        { id: 'pl.bad id', type: 'playlists', attributes: { name: 'Bad id' } },
        { id: 'pl.noname', type: 'playlists', attributes: { curatorName: 'Apple Music' } },
        { id: '1500000002', type: 'songs', attributes: { name: 'Not a playlist' } },
      ],
    },
  },
}

const PLAYLIST_TRACKS_PAGE = {
  next: '/v1/catalog/ng/playlists/pl.dc349df19c6f410d874c197db63ecfed/tracks?offset=100',
  data: [
    song('1570000001', 'Bloody Samaritan', 'NGA3B2100001'),
    song('1570000002', 'Rush', 'NGA3B2200002'),
  ],
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } })
}

function client(fetchLike: FetchLike) {
  return createAppleCatalogClient({
    fetchLike,
    issueServerToken: vi.fn(async () => ({ developerToken: 'server-token', expiresAt: 1_788_138_000 })),
    nowSeconds: () => 1_788_134_400,
  })
}

function oversizedClient(onCancel: () => void) {
  return createAppleCatalogClient({
    fetchLike: async () => new Response(
      new ReadableStream({
        start(controller) {
          controller.enqueue(new TextEncoder().encode('{"results":'))
          controller.enqueue(new TextEncoder().encode('{"SECRET OVERSIZED BODY":1}}'))
        },
        cancel: onCancel,
      }),
      { status: 200 },
    ),
    issueServerToken: async () => ({ developerToken: 'server-token', expiresAt: 1_788_138_000 }),
    nowSeconds: () => 1_788_134_400,
    maxResponseBytes: 10,
  })
}

async function expectOversizedRejected(call: (c: ReturnType<typeof client>) => Promise<unknown>) {
  let cancelled = false
  const thrown = await call(oversizedClient(() => { cancelled = true })).catch((error: unknown) => error)
  expect(thrown).toBeInstanceOf(AppleCatalogError)
  expect(thrown).toMatchObject({ category: 'response', status: 200 })
  expect(String(thrown)).not.toContain('SECRET OVERSIZED BODY')
  expect(cancelled).toBe(true)
}

async function expectRateLimit(call: (c: ReturnType<typeof client>) => Promise<unknown>) {
  const thrown = await call(client(async () => jsonResponse({ errors: [] }, 429))).catch((error: unknown) => error)
  expect(thrown).toBeInstanceOf(AppleCatalogError)
  expect(thrown).toMatchObject({ category: 'rate_limit', status: 429 })
}

describe('chartSongs', () => {
  it('parses a chart page through the song parser and reports the next offset', async () => {
    const fetchLike = vi.fn<FetchLike>(async () => jsonResponse(CHART_PAGE))

    const page = await client(fetchLike).chartSongs('ng', '14', 3)

    expect(fetchLike).toHaveBeenCalledOnce()
    expect(page.songs.map((s) => [s.appleId, s.isrc, s.releaseYear])).toEqual([
      ['1570000001', 'NGA3B2100001', 2021],
      ['1570000002', 'NGA3B2200002', 2021],
    ])
    expect(page.songs[0]).toMatchObject({ title: 'Bloody Samaritan', artist: 'Ayra Starr', genre: 'Afrobeats', explicit: false })
    expect(page.next).toBe(3)
    const [, init] = fetchLike.mock.calls[0]
    expect(new Headers(init?.headers).get('authorization')).toBe('Bearer server-token')
  })

  it('builds the exact chart URL with genre, a capped limit and an offset', async () => {
    const fetchLike = vi.fn<FetchLike>(async () => jsonResponse({ results: { songs: [{ data: [] }] } }))

    await client(fetchLike).chartSongs('ng', '14', 999, 200)
    await client(fetchLike).chartSongs('us', null, 50)

    expect(String(fetchLike.mock.calls[0][0])).toBe(
      'https://api.music.apple.com/v1/catalog/ng/charts?types=songs&genre=14&limit=200&offset=200',
    )
    expect(String(fetchLike.mock.calls[1][0])).toBe(
      'https://api.music.apple.com/v1/catalog/us/charts?types=songs&limit=50',
    )
  })

  it('returns an empty page with no next when Apple has no songs chart', async () => {
    expect(await client(async () => jsonResponse({ results: {} })).chartSongs('ng', '14', 10))
      .toEqual({ songs: [], next: null })
    expect(await client(async () => jsonResponse({ results: { songs: [] } })).chartSongs('ng', '14', 10))
      .toEqual({ songs: [], next: null })
    expect(await client(async () => jsonResponse({ results: { songs: [{ data: [] }] } })).chartSongs('ng', '14', 10))
      .toEqual({ songs: [], next: null })
  })

  it('returns an empty page for a 404, and for a 400 on a genre Apple does not chart there', async () => {
    expect(await client(async () => jsonResponse({ errors: [] }, 404)).chartSongs('ng', '100051', 10))
      .toEqual({ songs: [], next: null })
    expect(await client(async () => jsonResponse({ errors: [] }, 404)).chartSongs('ng', null, 10))
      .toEqual({ songs: [], next: null })
    expect(await client(async () => jsonResponse({ errors: [] }, 400)).chartSongs('ng', '100051', 10))
      .toEqual({ songs: [], next: null })
  })

  it('still throws a 400 on the overall chart, and other upstream errors', async () => {
    await expect(client(async () => jsonResponse({ errors: [] }, 400)).chartSongs('ng', null, 10))
      .rejects.toMatchObject({ category: 'upstream', status: 400 })
    await expect(client(async () => jsonResponse({}, 500)).chartSongs('ng', '14', 10))
      .rejects.toMatchObject({ category: 'upstream', status: 500 })
  })

  it('drops both copies of a song id that appears twice', async () => {
    const page = await client(async () => jsonResponse({ results: { songs: [{ data: [
      song('1570000001', 'A', 'NGA3B2100001'), song('1570000001', 'A dup', 'NGA3B2100001'), song('1570000002', 'B', 'NGA3B2200002'),
    ] }] } })).chartSongs('ng', null, 10)
    expect(page.songs.map((s) => s.appleId)).toEqual(['1570000002'])
  })

  it('rejects a malformed envelope', async () => {
    await expect(client(async () => jsonResponse({ results: { songs: [{ data: 'nope' }] } })).chartSongs('ng', '14', 10))
      .rejects.toMatchObject({ category: 'response', status: 200 })
  })

  it.each([
    ['NG', '14', 10, 0],
    ['ng', '14/..', 10, 0],
    ['ng', '', 10, 0],
    ['ng', '14', 0, 0],
    ['ng', '14', 1.5, 0],
    ['ng', '14', 10, -1],
    ['ng', '14', 10, 2.5],
  ] as const)('rejects invalid input (%s, %s, %s, %s) before token or network work', async (storefront, genre, limit, offset) => {
    const fetchLike = vi.fn<FetchLike>()
    const issueServerToken = vi.fn(async () => ({ developerToken: 'server-token', expiresAt: 1_788_138_000 }))
    const catalog = createAppleCatalogClient({ fetchLike, issueServerToken })
    await expect(catalog.chartSongs(storefront, genre, limit, offset)).rejects.toMatchObject({ category: 'response' })
    expect(fetchLike).not.toHaveBeenCalled()
    expect(issueServerToken).not.toHaveBeenCalled()
  })

  it('throws the rate-limit error with its status on 429', async () => {
    await expectRateLimit((c) => c.chartSongs('ng', '14', 10))
  })

  it('caps and cancels an oversized response', async () => {
    await expectOversizedRejected((c) => c.chartSongs('ng', '14', 10))
  })
})

describe('searchPlaylists', () => {
  it('returns id, name and curator for well-formed playlists', async () => {
    const fetchLike = vi.fn<FetchLike>(async () => jsonResponse(PLAYLIST_SEARCH_HIT))

    const result = await client(fetchLike).searchPlaylists('ng', 'Afrobeats Essentials', 5)

    expect(fetchLike).toHaveBeenCalledOnce()
    expect(result).toEqual([
      { id: 'pl.dc349df19c6f410d874c197db63ecfed', name: 'Afrobeats Essentials', curator: 'Apple Music' },
      { id: 'pl.u-abc123', name: 'my afrobeats', curator: null },
    ])
  })

  it('builds the exact search URL with types=playlists and a capped limit', async () => {
    const fetchLike = vi.fn<FetchLike>(async () => jsonResponse({ results: {} }))

    await client(fetchLike).searchPlaylists('gb', "  Today's Hits  ", 99)

    expect(String(fetchLike.mock.calls[0][0])).toBe(
      'https://api.music.apple.com/v1/catalog/gb/search?term=Today%27s+Hits&types=playlists&limit=25',
    )
  })

  it('returns an empty list when Apple omits the playlists key', async () => {
    expect(await client(async () => jsonResponse({ results: {} })).searchPlaylists('ng', 'zzqx', 5)).toEqual([])
  })

  it('rejects a malformed envelope', async () => {
    await expect(client(async () => jsonResponse({ results: { playlists: { data: 'nope' } } })).searchPlaylists('ng', 'x', 5))
      .rejects.toMatchObject({ category: 'response', status: 200 })
  })

  it.each([
    ['NG', 'hits', 5],
    ['ng', '   ', 5],
    ['ng', 'x'.repeat(121), 5],
    ['ng', 'hits', 0],
  ] as const)('rejects invalid input (%s, %s, %s) before network work', async (storefront, term, limit) => {
    const fetchLike = vi.fn<FetchLike>()
    await expect(client(fetchLike).searchPlaylists(storefront, term, limit)).rejects.toMatchObject({ category: 'response' })
    expect(fetchLike).not.toHaveBeenCalled()
  })

  it('throws the rate-limit error with its status on 429', async () => {
    await expectRateLimit((c) => c.searchPlaylists('ng', 'hits', 5))
  })

  it('caps and cancels an oversized response', async () => {
    await expectOversizedRejected((c) => c.searchPlaylists('ng', 'hits', 5))
  })
})

describe('playlistTracks', () => {
  it('parses a page of playlist songs and reports the next offset', async () => {
    const page = await client(async () => jsonResponse(PLAYLIST_TRACKS_PAGE))
      .playlistTracks('ng', 'pl.dc349df19c6f410d874c197db63ecfed', 100)
    expect(page.songs.map((s) => s.appleId)).toEqual(['1570000001', '1570000002'])
    expect(page.next).toBe(100)
  })

  it('builds the exact tracks URL with a capped limit and an offset', async () => {
    const fetchLike = vi.fn<FetchLike>(async () => jsonResponse({ data: [] }))

    await client(fetchLike).playlistTracks('ng', 'pl.dc349df19c6f410d874c197db63ecfed', 500, 100)
    await client(fetchLike).playlistTracks('ng', 'pl.dc349df19c6f410d874c197db63ecfed', 20)

    expect(String(fetchLike.mock.calls[0][0])).toBe(
      'https://api.music.apple.com/v1/catalog/ng/playlists/pl.dc349df19c6f410d874c197db63ecfed/tracks?limit=100&offset=100',
    )
    expect(String(fetchLike.mock.calls[1][0])).toBe(
      'https://api.music.apple.com/v1/catalog/ng/playlists/pl.dc349df19c6f410d874c197db63ecfed/tracks?limit=20',
    )
  })

  it('returns an empty page for an empty or unknown playlist (404)', async () => {
    expect(await client(async () => jsonResponse({ data: [] })).playlistTracks('ng', 'pl.x', 10))
      .toEqual({ songs: [], next: null })
    expect(await client(async () => jsonResponse({ errors: [] }, 404)).playlistTracks('ng', 'pl.x', 10))
      .toEqual({ songs: [], next: null })
  })

  it('rejects a malformed envelope', async () => {
    await expect(client(async () => jsonResponse({ results: {} })).playlistTracks('ng', 'pl.x', 10))
      .rejects.toMatchObject({ category: 'response', status: 200 })
  })

  it.each([
    ['NG', 'pl.x', 10, 0],
    ['ng', 'pl.bad id', 10, 0],
    ['ng', '..', 10, 0],
    ['ng', 'pl.x', 0, 0],
    ['ng', 'pl.x', 10, -5],
  ] as const)('rejects invalid input (%s, %s, %s, %s) before network work', async (storefront, id, limit, offset) => {
    const fetchLike = vi.fn<FetchLike>()
    await expect(client(fetchLike).playlistTracks(storefront, id, limit, offset)).rejects.toMatchObject({ category: 'response' })
    expect(fetchLike).not.toHaveBeenCalled()
  })

  it('throws the rate-limit error with its status on 429', async () => {
    await expectRateLimit((c) => c.playlistTracks('ng', 'pl.x', 10))
  })

  it('caps and cancels an oversized response', async () => {
    await expectOversizedRejected((c) => c.playlistTracks('ng', 'pl.x', 10))
  })

  it('shares the server token cache with the other calls', async () => {
    const issueServerToken = vi.fn(async () => ({ developerToken: 'server-token', expiresAt: 1_788_138_000 }))
    const fetchLike = vi.fn<FetchLike>(async (input) => jsonResponse(
      String(input).includes('/charts') ? { results: {} } : String(input).includes('/search') ? { results: {} } : { data: [] },
    ))
    const catalog = createAppleCatalogClient({ fetchLike, issueServerToken, nowSeconds: () => 1_788_134_400 })

    await catalog.chartSongs('ng', '14', 10)
    await catalog.searchPlaylists('ng', 'hits', 5)
    await catalog.playlistTracks('ng', 'pl.x', 10)

    expect(issueServerToken).toHaveBeenCalledOnce()
    expect(fetchLike).toHaveBeenCalledTimes(3)
  })
})
