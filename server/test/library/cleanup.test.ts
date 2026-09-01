import { eq } from 'drizzle-orm'
import { describe, expect, it } from 'vitest'
import { cleanupLibrarySyncStaging } from '../../src/library/cleanup'
import {
  librarySyncRecentTracks,
  librarySyncRuns,
  librarySyncSongs,
  user,
} from '../../src/db/schema'
import { createTestDb, type TestDb } from '../helpers/db'

const now = new Date('2026-09-10T12:00:00.000Z')

async function seedRun(
  db: TestDb,
  id: string,
  status: 'open' | 'completed' | 'expired',
  ageDays: number,
) {
  await db.insert(user).values({
    id: `user-${id}`,
    name: id,
    email: `${id}@example.com`,
    emailVerified: false,
    createdAt: now,
    updatedAt: now,
  })
  const at = new Date(now.getTime() - ageDays * 24 * 60 * 60 * 1_000)
  const [run] = await db.insert(librarySyncRuns).values({
    userId: `user-${id}`,
    source: 'web_musickit',
    status,
    appleStorefront: 'ng',
    expectedSongs: 1,
    receivedSongs: 1,
    expectedRecentTracks: 1,
    receivedRecentTracks: 1,
    resultSongs: status === 'completed' ? 1 : null,
    resultCatalogResolved: status === 'completed' ? 1 : null,
    resultPlayCountsObserved: status === 'completed' ? 0 : null,
    resultRecentTracks: status === 'completed' ? 1 : null,
    startedAt: at,
    expiresAt: at,
    completedAt: status === 'completed' ? at : null,
  }).returning()
  await db.insert(librarySyncSongs).values({
    syncId: run.id,
    ordinal: 0,
    appleLibraryId: `i.${id}`,
    appleCatalogId: `catalog-${id}`,
    title: id,
    artist: 'Artist',
  })
  await db.insert(librarySyncRecentTracks).values({
    syncId: run.id,
    rank: 0,
    appleCatalogId: `catalog-${id}`,
  })
  return run
}

describe('cleanupLibrarySyncStaging', () => {
  it('expires open runs older than 24 hours without deleting their retry evidence', async () => {
    const db = await createTestDb()
    const old = await seedRun(db, 'old', 'open', 2)
    const fresh = await seedRun(db, 'fresh', 'open', 0)

    expect(await cleanupLibrarySyncStaging(db, { now: () => now })).toMatchObject({
      touchedRuns: 1,
      expiredRuns: 1,
      deletedSongs: 0,
      deletedRecentTracks: 0,
    })
    expect((await db.select().from(librarySyncRuns)
      .where(eq(librarySyncRuns.id, old.id)))[0].status).toBe('expired')
    expect((await db.select().from(librarySyncRuns)
      .where(eq(librarySyncRuns.id, fresh.id)))[0].status).toBe('open')
  })

  it('purges bounded old staging while retaining completed summaries', async () => {
    const db = await createTestDb()
    const completed = await seedRun(db, 'completed', 'completed', 8)
    await seedRun(db, 'recent', 'completed', 2)

    expect(await cleanupLibrarySyncStaging(db, {
      now: () => now,
      songBatchSize: 1,
      recentBatchSize: 1,
    })).toEqual({
      touchedRuns: 1,
      expiredRuns: 0,
      deletedSongs: 1,
      deletedRecentTracks: 1,
      purgedRuns: 1,
    })
    expect(await db.select().from(librarySyncSongs)).toHaveLength(1)
    expect(await db.select().from(librarySyncRecentTracks)).toHaveLength(1)
    expect((await db.select().from(librarySyncRuns)
      .where(eq(librarySyncRuns.id, completed.id)))[0]).toMatchObject({
      status: 'completed',
      resultSongs: 1,
      resultRecentTracks: 1,
    })
  })
})
