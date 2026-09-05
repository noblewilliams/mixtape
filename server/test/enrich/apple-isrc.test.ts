import { and, eq, sql } from 'drizzle-orm'
import { describe, expect, it, vi } from 'vitest'
import {
  tracks,
  userTracks,
  userMusicProfiles,
  userMusicSources,
  appleIsrcLookups,
  trackArtworkStatus,
} from '../../src/db/schema'
import { runAppleIsrcBatch, APPLE_ISRC_BATCH, APPLE_ISRC_LEASE_MS } from '../../src/enrich/apple-isrc'
import { AppleCatalogError, type CatalogSong } from '../../src/musickit/catalog'
import { createTestDb, type TestDb } from '../helpers/db'
import { seedUser, now, SPOTIFY_A, APPLE_A, tenantRows } from '../helpers/listening-fixtures'

const ISRC = 'USUG11904206'
const catalogSong = (over: Partial<CatalogSong> = {}): CatalogSong => ({
  appleId: APPLE_A, isrc: ISRC, title: 'Catalog title', artist: 'Catalog artist',
  album: 'Album', durationMs: 200000, genre: 'Pop', releaseYear: 2020, explicit: false,
  artwork: { url: 'https://is1-ssl.mzstatic.com/image/{w}x{h}.jpg', width: 600, height: 600, bgColor: 'aabbcc' },
  ...over,
})

async function listener(db: TestDb, country: string | null = 'NG', storefront: string | null = null, id = 'u1') {
  await seedUser(db, id)
  await db.insert(userMusicProfiles).values({ userId: id, country, appleStorefront: storefront })
  await db.insert(userMusicSources).values({ userId: id, source: 'spotify_export', lastImportedAt: now })
}

async function spotifyTrack(db: TestDb, over: Partial<typeof tracks.$inferInsert> = {}, userId = 'u1') {
  const [row] = await db.insert(tracks).values({
    spotifyId: SPOTIFY_A, isrc: ISRC, title: 'Export title', artist: 'Credited artist',
    artistSource: 'reccobeats', enrichPriority: 4, ...over,
  }).returning()
  await db.insert(userTracks).values({ userId, trackId: row.id, inLibrary: true, playCount: 12 })
  return row
}

describe('Apple ISRC linking', () => {
  it('links one exact catalog result and fills missing metadata without changing listener data', async () => {
    const db = await createTestDb()
    await listener(db)
    const row = await spotifyTrack(db)
    await db.insert(trackArtworkStatus).values({
      trackId: row.id,
      attempts: 1,
      lastCategory: 'no_match',
      nextAttemptAt: new Date('2026-10-01T00:00:00Z'),
      updatedAt: now,
    })
    const before = await tenantRows(db, 'u1')
    const lookup = vi.fn(async () => new Map([[ISRC, [catalogSong()]]]))
    expect(await runAppleIsrcBatch(db, { catalog: { getSongsByIsrc: lookup }, now: () => now }))
      .toMatchObject({ processed: 1, linked: 1, failed: 0 })
    expect(lookup).toHaveBeenCalledWith('ng', [ISRC])
    expect(await db.select().from(tracks).where(eq(tracks.id, row.id))).toMatchObject([{
      appleId: APPLE_A, appleCatalogStorefront: 'ng', spotifyId: SPOTIFY_A, isrc: ISRC,
      title: 'Export title', artist: 'Credited artist', artistSource: 'reccobeats',
      genre: 'Pop', releaseYear: 2020, explicit: false, artworkBgColor: 'aabbcc',
    }])
    expect(await tenantRows(db, 'u1')).toEqual(before)
    expect(await db.select().from(trackArtworkStatus)).toEqual([])
  })

  it.each([
    ['GB', null, 'gb'], ['NG', 'us', 'us'], [null, 'ca', 'ca'], [null, null, null],
  ])('selects the confirmed storefront before country (%s / %s)', async (country, storefront, expected) => {
    const db = await createTestDb()
    await listener(db, country, storefront)
    await spotifyTrack(db)
    const lookup = vi.fn(async () => new Map())
    await runAppleIsrcBatch(db, { catalog: { getSongsByIsrc: lookup }, now: () => now })
    if (expected) expect(lookup).toHaveBeenCalledWith(expected, [ISRC])
    else expect(lookup).not.toHaveBeenCalled()
  })

  it.each([
    ['missing', [], 'no_match', { missing: 1 }],
    ['ambiguous', [catalogSong(), catalogSong({ appleId: '999' })], 'ambiguous', { ambiguous: 1 }],
    ['wrong ISRC', [catalogSong({ isrc: 'GBUM71029604' })], 'malformed', { failed: 1 }],
    ['invalid Apple ID', [catalogSong({ appleId: 'bad/id' })], 'malformed', { failed: 1 }],
  ] as const)('leaves %s results unlinked and backs off instead of retrying immediately', async (_label, matches, category, counts) => {
    const db = await createTestDb()
    await listener(db)
    await spotifyTrack(db)
    const lookup = vi.fn(async () => new Map([[ISRC, [...matches]]]))
    const deps = { catalog: { getSongsByIsrc: lookup }, now: () => now }
    expect(await runAppleIsrcBatch(db, deps)).toMatchObject({ linked: 0, ...counts })
    expect((await db.select().from(tracks))[0].appleId).toBeNull()
    expect(await db.select().from(appleIsrcLookups)).toMatchObject([{ attempts: 1, lastCategory: category }])
    expect((await runAppleIsrcBatch(db, deps)).processed).toBe(0)
    expect(lookup).toHaveBeenCalledOnce()
  })

  it('preserves an existing Apple owner and unrelated matches in the same batch', async () => {
    const db = await createTestDb()
    await listener(db)
    const target = await spotifyTrack(db)
    const otherIsrc = 'GBUM71029604'
    const other = await spotifyTrack(db, { spotifyId: '7ouMYWpwJ422jRcDASZB7P', isrc: otherIsrc })
    const [owner] = await db.insert(tracks).values({ appleId: APPLE_A, isrc: ISRC, title: 'Existing', artist: 'Owner' }).returning()
    const result = await runAppleIsrcBatch(db, { now: () => now, catalog: {
      getSongsByIsrc: async () => new Map([
        [ISRC, [catalogSong()]], [otherIsrc, [catalogSong({ appleId: '999', isrc: otherIsrc })]],
      ]),
    } })
    expect(result).toMatchObject({ linked: 1, conflicts: 1, failed: 0 })
    expect((await db.select().from(tracks).where(eq(tracks.id, target.id)))[0].appleId).toBeNull()
    expect((await db.select().from(tracks).where(eq(tracks.id, other.id)))[0].appleId).toBe('999')
    expect((await db.select().from(tracks).where(eq(tracks.id, owner.id)))[0]).toEqual(owner)
  })

  it('does not overwrite existing metadata or mix artwork fields from different covers', async () => {
    const db = await createTestDb()
    await listener(db)
    const prior = await spotifyTrack(db, {
      album: 'Known', genre: 'R&B', durationMs: 123000, releaseYear: 2019, explicit: true,
      artworkUrlTemplate: 'https://is1-ssl.mzstatic.com/prior/{w}x{h}.jpg', artworkBgColor: '123456',
    })
    await runAppleIsrcBatch(db, { now: () => now, catalog: { getSongsByIsrc: async () => new Map([[ISRC, [catalogSong()]]]) } })
    const [saved] = await db.select().from(tracks)
    expect(saved).toEqual({ ...prior, appleId: APPLE_A, appleCatalogStorefront: 'ng' })
  })

  it('recovers from an Apple-ID unique-constraint race without rolling back another match', async () => {
    const db = await createTestDb()
    await listener(db)
    await spotifyTrack(db)
    const otherIsrc = 'GBUM71029604'
    await spotifyTrack(db, { spotifyId: '7ouMYWpwJ422jRcDASZB7P', isrc: otherIsrc })
    // Raise the actual PostgreSQL uniqueness condition inside the write. Unlike
    // an existing-owner fixture this exercises recovery from an aborted statement.
    await db.execute(sql`
      CREATE FUNCTION simulate_apple_id_race() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.apple_id = '1440935467' THEN
          RAISE EXCEPTION 'simulated conflict' USING ERRCODE = '23505', CONSTRAINT = 'tracks_apple_id_idx';
        END IF;
        RETURN NEW;
      END $$
    `)
    await db.execute(sql`CREATE TRIGGER simulated_apple_race BEFORE UPDATE ON tracks
      FOR EACH ROW EXECUTE FUNCTION simulate_apple_id_race()`)
    expect(await runAppleIsrcBatch(db, { now: () => now, catalog: {
      getSongsByIsrc: async () => new Map([
        [ISRC, [catalogSong()]], [otherIsrc, [catalogSong({ appleId: '999', isrc: otherIsrc })]],
      ]),
    } })).toMatchObject({ linked: 1, conflicts: 1, failed: 0 })
    expect(await db.select().from(appleIsrcLookups)).toMatchObject([{ lastCategory: 'conflict' }])
    expect((await db.select().from(tracks).where(eq(tracks.isrc, otherIsrc)))[0].appleId).toBe('999')
  })

  it('deduplicates ISRC requests but assigns an Apple ID to at most one Spotify row', async () => {
    const db = await createTestDb()
    await listener(db)
    await spotifyTrack(db)
    await spotifyTrack(db, { spotifyId: '7ouMYWpwJ422jRcDASZB7P' })
    const lookup = vi.fn(async () => new Map([[ISRC, [catalogSong()]]]))
    expect(await runAppleIsrcBatch(db, { now: () => now, catalog: { getSongsByIsrc: lookup } }))
      .toMatchObject({ processed: 2, linked: 1, conflicts: 1 })
    expect(lookup).toHaveBeenCalledWith('ng', [ISRC])
    expect(await db.select().from(tracks)).toHaveLength(2)
    expect(await db.select().from(userTracks)).toHaveLength(2)
  })

  it.each(['delete-source', 'change-country', 'change-isrc', 'assign-id'] as const)
  ('rechecks eligibility after the network request: %s', async (change) => {
    const db = await createTestDb()
    await listener(db)
    const target = await spotifyTrack(db)
    const result = await runAppleIsrcBatch(db, { now: () => now, catalog: { getSongsByIsrc: async () => {
      if (change === 'delete-source') await db.delete(userMusicSources).where(eq(userMusicSources.userId, 'u1'))
      if (change === 'change-country') await db.update(userMusicProfiles).set({ country: 'GB' })
      if (change === 'change-isrc') await db.update(tracks).set({ isrc: 'GBUM71029604' })
      if (change === 'assign-id') await db.update(tracks).set({ appleId: '777' })
      return new Map([[ISRC, [catalogSong()]]])
    } } })
    expect(result).toMatchObject({ linked: 0, skipped: 1 })
    expect((await db.select().from(tracks).where(eq(tracks.id, target.id)))[0].appleId)
      .toBe(change === 'assign-id' ? '777' : null)
  })

  it('isolates a country miss so a different storefront can still resolve the same track', async () => {
    const db = await createTestDb()
    await listener(db)
    await listener(db, 'GB', null, 'u2')
    const target = await spotifyTrack(db)
    await db.insert(userTracks).values({ userId: 'u2', trackId: target.id, inLibrary: false })
    const markets: string[] = []
    const deps = { now: () => now, catalog: { getSongsByIsrc: async (market: string) => {
      markets.push(market)
      return markets.length === 1 ? new Map() : new Map([[ISRC, [catalogSong()]]])
    } } }
    expect((await runAppleIsrcBatch(db, deps)).missing).toBe(1)
    expect((await runAppleIsrcBatch(db, deps)).linked).toBe(1)
    expect(new Set(markets).size).toBe(2)
  })

  it('backs off sanitized provider failures and retries when due', async () => {
    const db = await createTestDb()
    await listener(db)
    await spotifyTrack(db)
    let clock = now
    const lookup = vi.fn(async (): Promise<Map<string, CatalogSong[]>> => { throw new AppleCatalogError('rate_limit', 429) })
    const deps = { now: () => clock, catalog: { getSongsByIsrc: lookup } }
    expect(await runAppleIsrcBatch(db, deps)).toMatchObject({ failed: 1, linked: 0 })
    const [retry] = await db.select().from(appleIsrcLookups)
    expect(retry).toMatchObject({ lastCategory: 'rate_limit', attempts: 1 })
    clock = new Date(retry.nextAttemptAt.getTime() - 1)
    expect((await runAppleIsrcBatch(db, deps)).processed).toBe(0)
    clock = retry.nextAttemptAt
    lookup.mockResolvedValueOnce(new Map([[ISRC, [catalogSong()]]]))
    expect((await runAppleIsrcBatch(db, deps)).linked).toBe(1)
  })

  it('does not send a second request for a held lease and discards a superseded result', async () => {
    const db = await createTestDb()
    await listener(db)
    await spotifyTrack(db)
    let clock = now
    const lookup = vi.fn(async () => new Map([[ISRC, [catalogSong()]]]))
    const replacement = { now: () => clock, catalog: { getSongsByIsrc: lookup } }
    const result = await runAppleIsrcBatch(db, { now: () => clock, catalog: { getSongsByIsrc: async () => {
      expect((await runAppleIsrcBatch(db, replacement)).processed).toBe(0)
      expect(lookup).not.toHaveBeenCalled()
      clock = new Date(now.getTime() + APPLE_ISRC_LEASE_MS + 1)
      expect((await runAppleIsrcBatch(db, replacement)).linked).toBe(1)
      return new Map([[ISRC, [catalogSong({ appleId: 'stale-id' })]]])
    } } })
    expect(result.processed).toBe(0)
    expect((await db.select().from(tracks))[0].appleId).toBe(APPLE_A)
  })

  it('does not publish an expired lease even when no newer invocation claimed it', async () => {
    const db = await createTestDb()
    await listener(db)
    await spotifyTrack(db)
    let clock = now
    const result = await runAppleIsrcBatch(db, { now: () => clock, catalog: { getSongsByIsrc: async () => {
      clock = new Date(now.getTime() + APPLE_ISRC_LEASE_MS)
      return new Map([[ISRC, [catalogSong()]]])
    } } })
    expect(result.linked).toBe(0)
    expect((await db.select().from(tracks))[0].appleId).toBeNull()
  })

  it('caps a pass at 25 tracks and prioritizes the songs most relevant to the pool', async () => {
    const db = await createTestDb()
    await listener(db)
    for (let i = 0; i < APPLE_ISRC_BATCH + 1; i++) {
      await spotifyTrack(db, { spotifyId: String(i).padStart(22, '0'), isrc: `USUG1${String(i).padStart(7, '0')}`, enrichPriority: i })
    }
    const lookup = vi.fn(async () => new Map())
    expect((await runAppleIsrcBatch(db, { now: () => now, catalog: { getSongsByIsrc: lookup } })).processed).toBe(25)
    const requested = (lookup.mock.calls[0] as unknown as [string, string[]])[1]
    expect(requested).toHaveLength(25)
    expect(requested).not.toContain('USUG10000000')
    expect(requested).toContain('USUG10000025')
  })

  it('skips invalid identities, already linked tracks, abandoned imports, and unowned catalog rows', async () => {
    const db = await createTestDb()
    await listener(db)
    await spotifyTrack(db, { isrc: 'invalid' })
    await spotifyTrack(db, { spotifyId: '7ouMYWpwJ422jRcDASZB7P', appleId: APPLE_A })
    await db.insert(tracks).values({ spotifyId: '1301WleyT98MSxVHPZCA6M', isrc: ISRC, title: 'Orphan', artist: 'A' })
    await listener(db, 'GB', null, 'u2')
    await spotifyTrack(db, { spotifyId: 'aaaaaaaaaaaaaaaaaaaaaa' }, 'u2')
    await db.update(userMusicSources).set({ lastImportedAt: null }).where(and(
      eq(userMusicSources.userId, 'u2'), eq(userMusicSources.source, 'spotify_export'),
    ))
    const lookup = vi.fn(async () => new Map())
    expect((await runAppleIsrcBatch(db, { catalog: { getSongsByIsrc: lookup } })).processed).toBe(0)
    expect(lookup).not.toHaveBeenCalled()
  })
})
