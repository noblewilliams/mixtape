import { describe, it, expect, vi } from 'vitest'
import { createTestDb, type TestDb } from '../helpers/db'
import {
  AlbumVerifyError,
  CatalogBudget,
  fold,
  resolveMarket,
  verifyCandidates,
  type VerifyCandidate,
} from '../../src/albums/verify'
import { AppleCatalogError, type AppleCatalogAlbumClient, type CatalogAlbum } from '../../src/musickit/catalog'
import { user, userMusicProfiles } from '../../src/db/schema'

let idCounter = 1000

function album(over: Partial<CatalogAlbum> = {}): CatalogAlbum {
  idCounter += 1
  return {
    appleId: String(idCounter),
    upc: null,
    title: 'Blue',
    artist: 'Joni Mitchell',
    releaseYear: 1971,
    trackCount: 10,
    durationMs: null,
    isSingle: false,
    isCompilation: false,
    genre: 'Folk',
    artwork: null,
    ...over,
  }
}

function fakeCatalog(byTerm: Record<string, CatalogAlbum[]>, details: Map<string, CatalogAlbum> | Error = new Map()) {
  const searchAlbums = vi.fn(async (_market: string, term: string, _limit: number) => byTerm[term] ?? [])
  const getAlbums = vi.fn(async (_market: string, _ids: readonly string[]) => {
    if (details instanceof Error) throw details
    return details
  })
  const client: AppleCatalogAlbumClient = { searchAlbums, getAlbums }
  return { client, searchAlbums, getAlbums }
}

function cand(over: Partial<VerifyCandidate> = {}): VerifyCandidate {
  return { artist: 'Joni Mitchell', title: 'Blue', type: 'album', why: 'quiet', ...over }
}

describe('fold', () => {
  it('folds case, brackets, tolerated words, a leading "the" and punctuation', () => {
    expect(fold('Love Deluxe')).toBe('love')
    expect(fold('Blue (Deluxe Edition)')).toBe('blue')
    expect(fold('Blue [2021 Remaster]')).toBe('blue')
    expect(fold('The Velvet Underground & Nico')).toBe('velvet underground and nico')
    expect(fold('  OK   Computer! ')).toBe('ok computer')
    expect(fold('Ｂｌｕｅ')).toBe('blue')
  })
})

describe('resolveMarket', () => {
  async function seed(db: TestDb, storefront: string | null) {
    await db.insert(user).values({ id: 'u1', name: 'u1', email: 'u1@example.com', emailVerified: false, createdAt: new Date(), updatedAt: new Date() })
    if (storefront !== undefined) await db.insert(userMusicProfiles).values({ userId: 'u1', appleStorefront: storefront })
  }

  it('prefers the listener storefront', async () => {
    const db = await createTestDb()
    await seed(db, 'gb')
    expect(await resolveMarket(db, 'u1', 'us')).toBe('gb')
  })

  it('falls back to a valid default, else null', async () => {
    const db = await createTestDb()
    await seed(db, null)
    expect(await resolveMarket(db, 'u1', ' US ')).toBe('us')
    expect(await resolveMarket(db, 'u1', 'usa')).toBeNull()
    expect(await resolveMarket(db, 'u1', undefined)).toBeNull()
  })
})

describe('verifyCandidates', () => {
  it('verifies a matching album and carries the candidate fields', async () => {
    const hit = album()
    const { client } = fakeCatalog({ 'Joni Mitchell Blue': [hit] })
    const out = await verifyCandidates(client, 'us', [cand({ year: 1971 })], new CatalogBudget())
    expect(out.dropped).toBe(0)
    expect(out.verified).toHaveLength(1)
    expect(out.verified[0]).toMatchObject({
      appleId: hit.appleId, title: 'Blue', artist: 'Joni Mitchell', type: 'album', why: 'quiet',
      fromShelf: false, modelOrder: 0, storefront: 'us', releaseYear: 1971,
    })
  })

  it('matches a "(Deluxe Edition)" title to the plain title', async () => {
    const hit = album({ title: 'Blue (Deluxe Edition)' })
    const { client } = fakeCatalog({ 'Joni Mitchell Blue': [hit] })
    const out = await verifyCandidates(client, 'us', [cand()], new CatalogBudget())
    expect(out.verified.map((v) => v.appleId)).toEqual([hit.appleId])
  })

  it('drops a single unless the candidate asked for a single', async () => {
    const hit = album({ isSingle: true })
    const { client } = fakeCatalog({ 'Joni Mitchell Blue': [hit] })
    expect((await verifyCandidates(client, 'us', [cand()], new CatalogBudget())).verified).toHaveLength(0)
    const asSingle = await verifyCandidates(client, 'us', [cand({ type: 'single' })], new CatalogBudget())
    expect(asSingle.verified[0].type).toBe('single')
  })

  it("overrides the model's type with Apple's flags", async () => {
    const single = album({ isSingle: true })
    const comp = album({ title: 'Hits', isCompilation: true })
    const { client } = fakeCatalog({ 'Joni Mitchell Blue': [single], 'Joni Mitchell Hits': [comp] })
    // A single is kept only for a single candidate; the compilation flag overrides 'live'.
    const out = await verifyCandidates(client, 'us', [cand({ type: 'single' }), cand({ title: 'Hits', type: 'live' })], new CatalogBudget())
    expect(out.verified.map((v) => v.type)).toEqual(['single', 'compilation'])
  })

  it('drops an artist mismatch and counts it', async () => {
    const { client } = fakeCatalog({ 'Joni Mitchell Blue': [album({ artist: 'Blue Man Group' })] })
    const out = await verifyCandidates(client, 'us', [cand()], new CatalogBudget())
    expect(out).toEqual({ verified: [], dropped: 1 })
  })

  it('tolerates a featured-artist suffix on the Apple artist', async () => {
    const { client } = fakeCatalog({ 'Joni Mitchell Blue': [album({ artist: 'Joni Mitchell feat. Someone' })] })
    expect((await verifyCandidates(client, 'us', [cand()], new CatalogBudget())).verified).toHaveLength(1)
  })

  it('tolerates "&", "and", "with" and "x" credits but not a different artist sharing the prefix', async () => {
    for (const artist of ['Joni Mitchell & Friends', 'Joni Mitchell and Friends', 'Joni Mitchell with Someone', 'Joni Mitchell x Someone', 'Joni Mitchell featuring Someone']) {
      const { client } = fakeCatalog({ 'Joni Mitchell Blue': [album({ artist })] })
      expect((await verifyCandidates(client, 'us', [cand()], new CatalogBudget())).verified, artist).toHaveLength(1)
    }
    const { client } = fakeCatalog({ 'Joni Mitchell Blue': [album({ artist: 'Joni Mitchell Tribute Band' })] })
    expect(await verifyCandidates(client, 'us', [cand()], new CatalogBudget())).toEqual({ verified: [], dropped: 1 })
  })

  it('matches nothing when a name folds to an empty string', async () => {
    const { client } = fakeCatalog({ '!!! ...': [album({ artist: '!!!', title: '...' })] })
    const out = await verifyCandidates(client, 'us', [cand({ artist: '!!!', title: '...' })], new CatalogBudget())
    expect(out).toEqual({ verified: [], dropped: 1 })
  })

  it('counts an unverifiable candidate while the others survive', async () => {
    const { client } = fakeCatalog({ 'Joni Mitchell Blue': [album()] })
    const out = await verifyCandidates(client, 'us', [cand({ title: 'Imaginary Record' }), cand()], new CatalogBudget())
    expect(out.dropped).toBe(1)
    expect(out.verified).toHaveLength(1)
    expect(out.verified[0].modelOrder).toBe(1)
  })

  it('searches a shelf candidate by the shelf group display names', async () => {
    const { client, searchAlbums } = fakeCatalog({ 'Sade Love Deluxe': [album({ artist: 'Sade', title: 'Love Deluxe' })] })
    const shelf = { artist: 'Sade', album: 'Love Deluxe', songCount: 9, plays: 30, similarity: 0.8, sampleAppleIds: [] }
    const out = await verifyCandidates(client, 'us', [cand({ artist: 'sade', title: 'love deluxe', shelf })], new CatalogBudget())
    expect(searchAlbums).toHaveBeenCalledWith('us', 'Sade Love Deluxe', 5)
    expect(out.verified[0].fromShelf).toBe(true)
  })

  it('fills durationMs and refreshes details from the one fetch', async () => {
    const hit = album()
    const detail = { ...hit, durationMs: 2_200_000, trackCount: 12, upc: '012345678905', artwork: { url: 'https://a/{w}x{h}.jpg', width: 1000, height: 1000, bgColor: '112233' } }
    const { client, getAlbums } = fakeCatalog({ 'Joni Mitchell Blue': [hit] }, new Map([[hit.appleId, detail]]))
    const out = await verifyCandidates(client, 'us', [cand()], new CatalogBudget())
    expect(getAlbums).toHaveBeenCalledTimes(1)
    expect(getAlbums).toHaveBeenCalledWith('us', [hit.appleId])
    expect(out.verified[0]).toMatchObject({ durationMs: 2_200_000, trackCount: 12, upc: '012345678905' })
    expect(out.verified[0].artwork?.url).toBe('https://a/{w}x{h}.jpg')
  })

  it('leaves durationMs null when the fetch fails, without failing', async () => {
    const { client } = fakeCatalog({ 'Joni Mitchell Blue': [album()] }, new AppleCatalogError('upstream', 503))
    const out = await verifyCandidates(client, 'us', [cand()], new CatalogBudget())
    expect(out.verified).toHaveLength(1)
    expect(out.verified[0].durationMs).toBeNull()
  })

  it('skips the fetch when nothing verified', async () => {
    const { client, getAlbums } = fakeCatalog({})
    await verifyCandidates(client, 'us', [cand()], new CatalogBudget())
    expect(getAlbums).not.toHaveBeenCalled()
  })

  it('throws catalogue_search when a search fails', async () => {
    const client: AppleCatalogAlbumClient = {
      searchAlbums: vi.fn(async () => { throw new AppleCatalogError('timeout') }),
      getAlbums: vi.fn(async () => new Map()),
    }
    const err = await verifyCandidates(client, 'us', [cand()], new CatalogBudget()).catch((e) => e)
    expect(err).toBeInstanceOf(AlbumVerifyError)
    expect(err.kind).toBe('catalogue_search')
  })

  it('caps a turn at five searches and one fetch', async () => {
    const budget = new CatalogBudget()
    const { client, searchAlbums, getAlbums } = fakeCatalog({ 'Joni Mitchell Blue': [album()] })
    await verifyCandidates(client, 'us', Array.from({ length: 5 }, () => cand()), budget)
    expect(searchAlbums).toHaveBeenCalledTimes(5)
    expect(getAlbums).toHaveBeenCalledTimes(1)
    expect(budget.searches).toBe(5)
    expect(budget.fetches).toBe(1)
    const err = await verifyCandidates(client, 'us', [cand()], budget).catch((e) => e)
    expect(err).toBeInstanceOf(AlbumVerifyError)
    expect(err.kind).toBe('budget')
    expect(searchAlbums).toHaveBeenCalledTimes(5)
  })

  it('dedupes verified albums by appleId, keeping the first', async () => {
    const hit = album()
    const { client, getAlbums } = fakeCatalog({ 'Joni Mitchell Blue': [hit] })
    const out = await verifyCandidates(client, 'us', [cand({ why: 'first' }), cand({ why: 'second' })], new CatalogBudget())
    expect(out.verified).toHaveLength(1)
    expect(out.verified[0].why).toBe('first')
    expect(getAlbums).toHaveBeenCalledWith('us', [hit.appleId])
  })

  it('keeps the search term inside the catalogue bound', async () => {
    const { client, searchAlbums } = fakeCatalog({})
    await verifyCandidates(client, 'us', [cand({ artist: 'a'.repeat(200), title: 'b'.repeat(200) })], new CatalogBudget())
    expect((searchAlbums.mock.calls[0][1] as string).length).toBeLessThanOrEqual(120)
  })
})
