import { describe, it, expect, vi } from 'vitest'
import { eq } from 'drizzle-orm'
import { createTestDb } from '../helpers/db'
import { createApp, type AuthLike } from '../../src/app'
import { trackFeatures, trackMeanings, tracks } from '../../src/db/schema'
import { OK_FEATURES } from '../helpers/enrich-fixtures'
import { MAX_CHART_PAGE } from '../../src/enrich/seed-limits'
import {
  AppleCatalogError,
  type AppleCatalogSeedClient,
  type CatalogSong,
  type CatalogSongPage,
} from '../../src/musickit/catalog'

const auth: AuthLike = { handler: () => new Response('ok'), api: { getSession: async () => null } }
const TOKEN = 'secret'

const song = (appleId: string, isrc: string | null, title = `Song ${appleId}`): CatalogSong => ({
  appleId, isrc, title, artist: 'Tems', album: 'Born in the Wild', artwork: null,
  durationMs: 200_000, genre: 'Afrobeats', releaseYear: 2024, explicit: false,
})

function fakeCatalog(page: CatalogSongPage | Error = { songs: [], next: null }) {
  const answer = async () => { if (page instanceof Error) throw page; return page }
  return {
    chartSongs: vi.fn<AppleCatalogSeedClient['chartSongs']>(answer),
    playlistTracks: vi.fn<AppleCatalogSeedClient['playlistTracks']>(answer),
    searchPlaylists: vi.fn<AppleCatalogSeedClient['searchPlaylists']>(async () => [
      { id: 'pl.essentials', name: 'Afrobeats Essentials', curator: 'Apple Music' },
    ]),
  }
}

async function setup(page?: CatalogSongPage | Error) {
  const db = await createTestDb()
  const catalog = fakeCatalog(page)
  const app = createApp({ auth, db, enrich: { adminToken: TOKEN, seed: { catalog } } })
  const post = (path: string, body: unknown, token: string | null = TOKEN) => app.request(`http://x${path}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...(token ? { 'X-Admin-Token': token } : {}) },
    body: typeof body === 'string' ? body : JSON.stringify(body),
  })
  return { db, catalog, app, post }
}

describe('POST /enrich/seed', () => {
  it('requires the admin token', async () => {
    const { post, catalog } = await setup()
    expect((await post('/enrich/seed', { storefront: 'ng', source: 'chart', limit: 10 }, null)).status).toBe(401)
    expect((await post('/enrich/seed', { storefront: 'ng', source: 'chart', limit: 10 }, 'wrong')).status).toBe(401)
    expect((await post('/enrich/seed/playlists', { storefront: 'ng', term: 'hits', limit: 5 }, null)).status).toBe(401)
    expect(catalog.chartSongs).not.toHaveBeenCalled()
  })

  it('inserts a chart page at normal priority as Apple catalogue rows and reports counts and next', async () => {
    const { db, post, catalog } = await setup({ songs: [song('a1', 'NGA1'), song('a2', null)], next: 200 })

    const res = await post('/enrich/seed', { storefront: 'ng', source: 'chart', genreId: '14', limit: 100, offset: 0 })

    expect(res.status).toBe(200)
    expect(await res.json()).toEqual({ fetched: 2, inserted: 2, duplicates: 0, twins: 0, next: 200 })
    expect(catalog.chartSongs).toHaveBeenCalledOnce()
    expect(catalog.chartSongs).toHaveBeenCalledWith('ng', '14', 100, 0)
    const rows = await db.select().from(tracks)
    expect(rows.map((r) => [r.appleId, r.enrichPriority, r.artistSource, r.appleCatalogStorefront, r.isrc]).sort())
      .toEqual([['a1', 0, 'apple_catalog', 'ng', 'NGA1'], ['a2', 0, 'apple_catalog', 'ng', null]])
  })

  it('takes the overall chart when no genre is given and reports no next at the end', async () => {
    const { post, catalog } = await setup({ songs: [song('a1', 'NGA1')], next: null })
    const res = await post('/enrich/seed', { storefront: 'us', source: 'chart', limit: 50 })
    expect(await res.json()).toEqual({ fetched: 1, inserted: 1, duplicates: 0, twins: 0, next: null })
    expect(catalog.chartSongs).toHaveBeenCalledWith('us', null, 50, 0)
  })

  it('dedupes by ISRC then Apple id, within the page and against held rows, leaving held priority alone', async () => {
    const { db, post } = await setup({
      songs: [
        song('held-id', 'NEW1'), // same Apple id as a held row
        song('other-id', 'HELDISRC'), // same ISRC as a held Apple row under another id
        song('twin-a', 'TWIN'),
        song('twin-b', 'twin'), // same ISRC within the page, case aside
        song('fresh', 'FRESH'),
      ],
      next: null,
    })
    await db.insert(tracks).values([
      { appleId: 'held-id', title: 'Held', artist: 'Tems', enrichPriority: 5 },
      { appleId: 'held-2', isrc: 'heldisrc', title: 'Held 2', artist: 'Tems', enrichPriority: 7 },
    ])

    const res = await post('/enrich/seed', { storefront: 'ng', source: 'chart', genreId: '1203', limit: 5 })

    expect(await res.json()).toEqual({ fetched: 5, inserted: 2, duplicates: 3, twins: 0, next: null })
    const rows = await db.select().from(tracks)
    expect(rows.map((r) => [r.appleId, r.enrichPriority]).sort()).toEqual([
      ['fresh', 0], ['held-2', 7], ['held-id', 5], ['twin-a', 0],
    ])
  })

  it('a second run of the same page inserts nothing', async () => {
    const { post } = await setup({ songs: [song('a1', 'NGA1'), song('a2', 'NGA2')], next: null })
    await post('/enrich/seed', { storefront: 'ng', source: 'chart', limit: 2 })
    const res = await post('/enrich/seed', { storefront: 'ng', source: 'chart', limit: 2 })
    expect(await res.json()).toEqual({ fetched: 2, inserted: 0, duplicates: 2, twins: 0, next: null })
  })

  it('pages a playlist with one Apple call and never enriches', async () => {
    const { db, post, catalog } = await setup({ songs: [song('p1', 'PL1')], next: 100 })

    const res = await post('/enrich/seed', { storefront: 'gb', source: 'playlist', playlistId: 'pl.essentials', limit: 100, offset: 0 })

    expect(await res.json()).toEqual({ fetched: 1, inserted: 1, duplicates: 0, twins: 0, next: 100 })
    expect(catalog.playlistTracks).toHaveBeenCalledOnce()
    expect(catalog.playlistTracks).toHaveBeenCalledWith('gb', 'pl.essentials', 100, 0)
    expect(catalog.chartSongs).not.toHaveBeenCalled()
    expect(await db.select().from(trackFeatures)).toEqual([])
    expect(await db.select().from(trackMeanings)).toEqual([])
    const [row] = await db.select().from(tracks).where(eq(tracks.appleId, 'p1'))
    expect(row.appleCatalogStorefront).toBe('gb')
  })

  it('reports an empty list as nothing fetched and no next', async () => {
    const { post } = await setup({ songs: [], next: null })
    const res = await post('/enrich/seed', { storefront: 'ng', source: 'playlist', playlistId: 'pl.gone', limit: 10 })
    expect(await res.json()).toEqual({ fetched: 0, inserted: 0, duplicates: 0, twins: 0, next: null })
  })

  it.each([
    ['a bad storefront', { storefront: 'NG', source: 'chart', limit: 10 }],
    ['an unknown source', { storefront: 'ng', source: 'radio', limit: 10 }],
    ['a playlist without an id', { storefront: 'ng', source: 'playlist', limit: 10 }],
    ['a bad playlist id', { storefront: 'ng', source: 'playlist', playlistId: 'pl.bad id', limit: 10 }],
    ['a chart with a playlist id', { storefront: 'ng', source: 'chart', playlistId: 'pl.x', limit: 10 }],
    ['a non-numeric genre', { storefront: 'ng', source: 'chart', genreId: 'pop', limit: 10 }],
    ['a zero limit', { storefront: 'ng', source: 'chart', limit: 0 }],
    ['a chart limit over 100', { storefront: 'ng', source: 'chart', limit: 101 }],
    ['a playlist limit over 100', { storefront: 'ng', source: 'playlist', playlistId: 'pl.x', limit: 101 }],
    ['a negative offset', { storefront: 'ng', source: 'chart', limit: 10, offset: -1 }],
    ['a fractional limit', { storefront: 'ng', source: 'chart', limit: 1.5 }],
    ['a missing limit', { storefront: 'ng', source: 'chart' }],
  ])('rejects %s with 400 before any Apple call', async (_name, body) => {
    const { post, catalog } = await setup()
    const res = await post('/enrich/seed', body)
    expect(res.status).toBe(400)
    expect(catalog.chartSongs).not.toHaveBeenCalled()
    expect(catalog.playlistTracks).not.toHaveBeenCalled()
  })

  it('rejects a body that is not JSON', async () => {
    const { post } = await setup()
    expect((await post('/enrich/seed', 'not json')).status).toBe(400)
  })

  it('answers 429 when Apple rate-limits and 503 on other Apple failures, inserting nothing', async () => {
    const limited = await setup(new AppleCatalogError('rate_limit', 429))
    const res = await limited.post('/enrich/seed', { storefront: 'ng', source: 'chart', limit: 10 })
    expect(res.status).toBe(429)
    expect(await res.json()).toEqual({ error: 'apple_rate_limited' })

    const down = await setup(new AppleCatalogError('upstream', 500))
    const res2 = await down.post('/enrich/seed', { storefront: 'ng', source: 'chart', limit: 10 })
    expect(res2.status).toBe(503)
    expect(await res2.json()).toEqual({ error: 'apple_unavailable', category: 'upstream' })
    expect(await down.db.select().from(tracks)).toEqual([])
  })

  it.each([
    ['authorization', 401, 502],
    ['response', 200, 502],
    ['upstream', 500, 503],
    ['timeout', undefined, 503],
    ['network', undefined, 503],
  ] as const)('maps an Apple %s failure to %s then HTTP %s', async (category, status, http) => {
    const { post } = await setup(new AppleCatalogError(category, status))
    const res = await post('/enrich/seed', { storefront: 'ng', source: 'chart', limit: 10 })
    expect(res.status).toBe(http)
    expect(await res.json()).toEqual({ error: 'apple_unavailable', category })
  })

  it('caps a chart page at 100, below the client cap', async () => {
    expect(MAX_CHART_PAGE).toBe(100)
    const { post } = await setup()
    expect((await post('/enrich/seed', { storefront: 'ng', source: 'chart', limit: 100 })).status).toBe(200)
  })

  it('fills a new row from an already-enriched ISRC twin before the drain', async () => {
    const { db, post } = await setup({ songs: [song('a1', 'USUG11904206'), song('a2', 'NOTWIN000001')], next: null })
    // A Spotify export's row: same recording, no Apple id, already enriched.
    const [donor] = await db.insert(tracks)
      .values({ spotifyId: '4uLU6hMCjMI75M1A2tKUQC', isrc: 'USUG11904206', title: 'T', artist: 'Tems' }).returning()
    const { isrc: _i, matchedDurationMs: _m, ...cols } = OK_FEATURES
    await db.insert(trackFeatures).values({ trackId: donor.id, ...cols, tempo: 97, source: 'reccobeats' })

    const res = await post('/enrich/seed', { storefront: 'ng', source: 'chart', limit: 10 })

    expect(await res.json()).toEqual({ fetched: 2, inserted: 2, duplicates: 0, twins: 1, next: null })
    const [seeded] = await db.select().from(tracks).where(eq(tracks.appleId, 'a1'))
    const [features] = await db.select().from(trackFeatures).where(eq(trackFeatures.trackId, seeded.id))
    expect(features).toMatchObject({ tempo: 97, source: 'twin' })
    const [other] = await db.select().from(tracks).where(eq(tracks.appleId, 'a2'))
    expect(await db.select().from(trackFeatures).where(eq(trackFeatures.trackId, other.id))).toEqual([])
  })

  it('leaves the enrichment routes absent when only the seed is wired', async () => {
    const { app } = await setup()
    const res = await app.request('http://x/enrich/run', { method: 'POST', headers: { 'X-Admin-Token': TOKEN } })
    expect(res.status).toBe(404)
  })
})

describe('POST /enrich/seed/playlists', () => {
  it('resolves a search term to playlists with one Apple call', async () => {
    const { post, catalog } = await setup()
    const res = await post('/enrich/seed/playlists', { storefront: 'ng', term: 'Afrobeats Essentials', limit: 5 })
    expect(res.status).toBe(200)
    expect(await res.json()).toEqual({
      playlists: [{ id: 'pl.essentials', name: 'Afrobeats Essentials', curator: 'Apple Music' }],
    })
    expect(catalog.searchPlaylists).toHaveBeenCalledOnce()
    expect(catalog.searchPlaylists).toHaveBeenCalledWith('ng', 'Afrobeats Essentials', 5)
  })

  it.each([
    [{ storefront: 'ng', term: '', limit: 5 }],
    [{ storefront: 'ng', term: 'hits', limit: 26 }],
    [{ storefront: 'xyz', term: 'hits', limit: 5 }],
  ])('rejects %j with 400', async (body) => {
    const { post, catalog } = await setup()
    expect((await post('/enrich/seed/playlists', body)).status).toBe(400)
    expect(catalog.searchPlaylists).not.toHaveBeenCalled()
  })

  it('answers 429 when Apple rate-limits the search', async () => {
    const { post, catalog } = await setup()
    catalog.searchPlaylists.mockRejectedValueOnce(new AppleCatalogError('rate_limit', 429))
    expect((await post('/enrich/seed/playlists', { storefront: 'ng', term: 'hits', limit: 5 })).status).toBe(429)
  })
})
