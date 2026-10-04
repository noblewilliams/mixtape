import { asc, eq } from 'drizzle-orm'
import { describe, expect, it, vi } from 'vitest'
import {
  ARTWORK_MALFORMED_RETRY_MS,
  ISRC_BACKFILL_BATCH,
  ISRC_RECHECK_MS,
  runAppleIsrcBackfill,
  type ArtworkDeps,
} from '../../src/artwork/runner'
import { AppleCatalogError, createAppleCatalogClient, type CatalogSong } from '../../src/musickit/catalog'
import { tracks } from '../../src/db/schema'
import { createTestDb, type TestDb } from '../helpers/db'

const NOW = new Date('2026-10-03T12:00:00.000Z')
const ARTWORK = 'https://is1-ssl.mzstatic.com/image/thumb/known/{w}x{h}.{f}'

function song(appleId: string, isrc: string | null): CatalogSong {
  return { appleId, isrc, title: 'Song', artist: 'Artist', album: null, artwork: null }
}

type GetSongs = ArtworkDeps['catalog']['getSongs']

function deps(getSongs: GetSongs, now = NOW): ArtworkDeps {
  return { storefront: 'ng', catalog: { getSongs: vi.fn(getSongs) }, now: () => now }
}

async function seed(db: TestDb, appleId: string | null, over: Partial<typeof tracks.$inferInsert> = {}) {
  const [row] = await db.insert(tracks).values({
    appleId, title: 'Track', artist: 'Artist', artworkUrlTemplate: ARTWORK, ...over,
  }).returning()
  return row
}

const byIsrc = (isrcs: Record<string, string | null>): GetSongs =>
  async (_storefront, ids) => new Map(ids.filter((id) => id in isrcs).map((id) => [id, song(id, isrcs[id])]))

describe('runAppleIsrcBackfill', () => {
  it('fills a well-formed ISRC for Apple rows with artwork and none, in one catalogue request', async () => {
    const db = await createTestDb()
    const a = await seed(db, 'a')
    const b = await seed(db, 'b')
    const getSongs = vi.fn(byIsrc({ a: 'usug11904206', b: 'bad' }))

    expect(await runAppleIsrcBackfill(db, deps(getSongs)))
      .toEqual({ processed: 2, filled: 1, failed: 0, remaining: 0 })

    expect(getSongs).toHaveBeenCalledOnce()
    expect(getSongs.mock.calls[0][0]).toBe('ng')
    expect([...getSongs.mock.calls[0][1]].sort()).toEqual(['a', 'b'])
    const rows = await db.select().from(tracks).orderBy(asc(tracks.appleId))
    expect(rows).toMatchObject([
      { id: a.id, isrc: 'USUG11904206', isrcCheckedAt: NOW },
      { id: b.id, isrc: null, isrcCheckedAt: NOW },
    ])
  })

  it('skips rows without an Apple id, without artwork, with an ISRC, or checked recently', async () => {
    const db = await createTestDb()
    await seed(db, null, { spotifyId: '4uLU6hMCjMI75M1A2tKUQC' })
    await seed(db, 'no-art', { artworkUrlTemplate: null })
    await seed(db, 'has-isrc', { isrc: 'GBUM71029604' })
    await seed(db, 'recent', { isrcCheckedAt: new Date(NOW.getTime() - ISRC_RECHECK_MS + 1) })
    const getSongs = vi.fn(byIsrc({}))

    expect(await runAppleIsrcBackfill(db, deps(getSongs)))
      .toEqual({ processed: 0, filled: 0, failed: 0, remaining: 0 })
    expect(getSongs).not.toHaveBeenCalled()
  })

  it('never overwrites an ISRC written while the request was in flight', async () => {
    const db = await createTestDb()
    const row = await seed(db, 'a')
    const getSongs: GetSongs = async (_storefront, ids) => {
      await db.update(tracks).set({ isrc: 'GBUM71029604' }).where(eq(tracks.id, row.id))
      return new Map(ids.map((id) => [id, song(id, 'USUG11904206')]))
    }

    expect(await runAppleIsrcBackfill(db, deps(getSongs))).toMatchObject({ processed: 1, filled: 0 })
    expect((await db.select().from(tracks))[0].isrc).toBe('GBUM71029604')
  })

  it('does not write to a row whose Apple id changed while the request was in flight', async () => {
    const db = await createTestDb()
    const row = await seed(db, 'a')
    const getSongs: GetSongs = async (_storefront, ids) => {
      await db.update(tracks).set({ appleId: 'z' }).where(eq(tracks.id, row.id))
      return new Map(ids.map((id) => [id, song(id, 'USUG11904206')]))
    }

    expect(await runAppleIsrcBackfill(db, deps(getSongs))).toMatchObject({ processed: 1, filled: 0 })
    expect((await db.select().from(tracks))[0]).toMatchObject({ isrc: null, isrcCheckedAt: null })
  })

  it('takes at most 300 rows per pass, in id order, with exactly one request', async () => {
    const db = await createTestDb()
    for (let i = 0; i < ISRC_BACKFILL_BATCH + 5; i++) await seed(db, `song-${String(i).padStart(3, '0')}`)
    const getSongs = vi.fn(byIsrc({}))

    expect(await runAppleIsrcBackfill(db, deps(getSongs)))
      .toEqual({ processed: 300, filled: 0, failed: 0, remaining: 5 })
    expect(ISRC_BACKFILL_BATCH).toBe(300)
    expect(getSongs).toHaveBeenCalledOnce()
    const requested = getSongs.mock.calls[0][1]
    expect(requested).toHaveLength(300)
    const ordered = await db.select({ appleId: tracks.appleId }).from(tracks).orderBy(asc(tracks.id))
    expect(requested).toEqual(ordered.slice(0, 300).map((row) => row.appleId))
  })

  it('spends exactly one subrequest through the real catalogue client for a full pass', async () => {
    const db = await createTestDb()
    for (let i = 0; i < ISRC_BACKFILL_BATCH + 5; i++) await seed(db, String(1_000_000 + i))
    const fetchLike = vi.fn(async (input: string | URL) => {
      const ids = new URL(input).searchParams.get('ids')?.split(',') ?? []
      return Response.json({ data: ids.map((id) => ({
        id, type: 'songs', attributes: { name: 'Song', artistName: 'Artist', isrc: 'USUG11904206' },
      })) })
    })
    const catalog = createAppleCatalogClient({
      fetchLike, issueServerToken: async () => ({ developerToken: 'server-token', expiresAt: 9999999999 }),
    })

    expect(await runAppleIsrcBackfill(db, { storefront: 'ng', catalog, now: () => NOW }))
      .toMatchObject({ processed: 300, filled: 300, remaining: 5 })
    expect(fetchLike).toHaveBeenCalledOnce()
  })

  it('asks one recorded market per pass', async () => {
    const db = await createTestDb()
    await seed(db, 'gb-song', { appleCatalogStorefront: 'gb' })
    await seed(db, 'ng-song')
    const getSongs = vi.fn(byIsrc({}))

    expect((await runAppleIsrcBackfill(db, deps(getSongs))).processed).toBe(1)
    expect((await runAppleIsrcBackfill(db, deps(getSongs))).processed).toBe(1)
    expect(getSongs.mock.calls.map(([market, ids]) => [market, [...ids]]).sort())
      .toEqual([['gb', ['gb-song']], ['ng', ['ng-song']]])
  })

  it('does not refetch a song Apple returned no ISRC for until the recheck window passes', async () => {
    const db = await createTestDb()
    await seed(db, 'silent')
    await seed(db, 'gone')
    const getSongs = vi.fn(byIsrc({ silent: null }))

    expect(await runAppleIsrcBackfill(db, deps(getSongs))).toMatchObject({ processed: 2, filled: 0 })
    expect(await runAppleIsrcBackfill(db, deps(getSongs, new Date(NOW.getTime() + 60 * 60 * 1000))))
      .toEqual({ processed: 0, filled: 0, failed: 0, remaining: 0 })
    expect(getSongs).toHaveBeenCalledOnce()

    expect((await runAppleIsrcBackfill(db, deps(getSongs, new Date(NOW.getTime() + ISRC_RECHECK_MS))))
      .processed).toBe(2)
    expect(getSongs).toHaveBeenCalledTimes(2)
  })

  it.each([
    ['rate_limit', 429], ['timeout', undefined], ['network', undefined], ['upstream', 503],
  ] as const)('leaves rows unmarked after a transient %s failure so the next run retries them', async (category, status) => {
    const db = await createTestDb()
    await seed(db, 'a')
    const failing = vi.fn(async () => { throw new AppleCatalogError(category, status) })

    expect(await runAppleIsrcBackfill(db, deps(failing)))
      .toEqual({ processed: 1, filled: 0, failed: 1, remaining: 1 })
    expect((await db.select().from(tracks))[0]).toMatchObject({ isrc: null, isrcCheckedAt: null })
    expect((await runAppleIsrcBackfill(db, deps(byIsrc({ a: 'USUG11904206' })))).filled).toBe(1)
  })

  it.each([
    ['a malformed response', () => new AppleCatalogError('response', 200)],
    ['an authorization failure', () => new AppleCatalogError('authorization', 401)],
    ['a client-side 4xx', () => new AppleCatalogError('upstream', 400)],
    ['an unexpected error', () => new Error('unexpected')],
  ])('defers rows for the malformed retry window after %s, so later rows are reached', async (_label, error) => {
    const db = await createTestDb()
    await seed(db, 'a')
    const failing = vi.fn(async () => { throw error() })

    expect(await runAppleIsrcBackfill(db, deps(failing)))
      .toEqual({ processed: 1, filled: 0, failed: 1, remaining: 0 })
    const [row] = await db.select().from(tracks)
    expect(row.isrc).toBeNull()
    expect(row.isrcCheckedAt).toEqual(new Date(NOW.getTime() - ISRC_RECHECK_MS + ARTWORK_MALFORMED_RETRY_MS))

    const getSongs = vi.fn(byIsrc({ a: 'USUG11904206' }))
    const justBefore = new Date(NOW.getTime() + ARTWORK_MALFORMED_RETRY_MS - 1)
    expect((await runAppleIsrcBackfill(db, deps(getSongs, justBefore))).processed).toBe(0)
    expect(getSongs).not.toHaveBeenCalled()
    const due = new Date(NOW.getTime() + ARTWORK_MALFORMED_RETRY_MS)
    expect((await runAppleIsrcBackfill(db, deps(getSongs, due))).filled).toBe(1)
  })
})
