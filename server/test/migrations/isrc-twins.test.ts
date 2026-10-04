import { sql } from 'drizzle-orm'
import { describe, expect, it } from 'vitest'
import { appleIsrcLookups, listeningImportRuns, listeningImportTracks, tracks } from '../../src/db/schema'
import { createTestDb } from '../helpers/db'
import { seedUser } from '../helpers/listening-fixtures'

describe('ISRC twins migration', () => {
  it('stages a nullable, well-formed ISRC per import track', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const [run] = await db.insert(listeningImportRuns).values({
      userId: 'u1', source: 'spotify_export', package: 'spotify_extended', status: 'open',
      timeZone: 'UTC', expectedTracks: 3, expectedDays: 0, expectedLibraryTracks: 0, expectedArtists: 0, expiresAt: new Date('2099-01-01T00:00:00Z'),
    }).returning()
    const row = { importId: run.id, title: 'Song', artist: 'Artist' }
    await db.insert(listeningImportTracks).values([
      { ...row, ordinal: 0, platformId: 'a', isrc: 'USUG11904206' },
      { ...row, ordinal: 1, platformId: 'b' },
    ])
    expect((await db.select().from(listeningImportTracks)).map((r) => r.isrc).sort())
      .toEqual(['USUG11904206', null])
    await expect(db.insert(listeningImportTracks).values({ ...row, ordinal: 2, platformId: 'c', isrc: 'usug11904206' }))
      .rejects.toThrow()
    await expect(db.insert(listeningImportTracks).values({ ...row, ordinal: 2, platformId: 'c', isrc: 'bad' }))
      .rejects.toThrow()
  })

  it('adds a nullable ISRC check marker to tracks', async () => {
    const db = await createTestDb()
    const checkedAt = new Date('2026-10-03T12:00:00Z')
    await db.insert(tracks).values([
      { appleId: '1', title: 'Song', artist: 'Artist' },
      { appleId: '2', title: 'Song', artist: 'Artist', isrcCheckedAt: checkedAt },
    ])
    expect((await db.select().from(tracks)).map((r) => r.isrcCheckedAt))
      .toEqual(expect.arrayContaining([null, checkedAt]))
  })

  it('accepts twin as a lookup category and still rejects unknown ones', async () => {
    const db = await createTestDb()
    const [track] = await db.insert(tracks).values({ title: 'Song', artist: 'Artist' }).returning()
    const value = { trackId: track.id, storefront: 'ng', isrc: 'USUG11904206', leaseToken: crypto.randomUUID() }
    await db.insert(appleIsrcLookups).values({ ...value, lastCategory: 'twin' })
    await expect(db.execute(sql`UPDATE apple_isrc_lookups SET last_category = 'sibling'`)).rejects.toThrow()
  })
})
