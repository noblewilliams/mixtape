import { describe, expect, it } from 'vitest'
import { and, eq } from 'drizzle-orm'
import { cleanupPlaylistSyncStaging } from '../../src/playlists/cleanup'
import {
  playlistSyncEntries,
  playlistSyncPlaylists,
  playlistSyncRuns,
  user,
} from '../../src/db/schema'
import { createTestDb, type TestDb } from '../helpers/db'

const now = new Date('2026-09-10T12:00:00Z')

async function seedRun(
  db: TestDb,
  id: string,
  status: 'open' | 'completed' | 'expired',
  ageDays: number,
  entryCount = 1,
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
  const [run] = await db.insert(playlistSyncRuns).values({
    userId: `user-${id}`,
    status,
    appleStorefront: 'ng',
    expectedPlaylists: 1,
    expectedEntries: entryCount,
    receivedPlaylists: 1,
    receivedEntries: entryCount,
    resultPlaylists: status === 'completed' ? 1 : null,
    resultEntries: status === 'completed' ? entryCount : null,
    resultResolvedEntries: status === 'completed' ? 0 : null,
    resultUnresolvedEntries: status === 'completed' ? entryCount : null,
    startedAt: at,
    expiresAt: at,
    completedAt: status === 'completed' ? at : null,
  }).returning()
  await db.insert(playlistSyncPlaylists).values({
    syncId: run.id,
    ordinal: 0,
    appleLibraryId: `playlist-${id}`,
    name: id,
    kind: 'user',
    sourceFingerprint: 'a'.repeat(64),
    entryCount,
  })
  if (entryCount > 0) {
    await db.insert(playlistSyncEntries).values(Array.from({ length: entryCount }, (_, position) => ({
      syncId: run.id,
      applePlaylistId: `playlist-${id}`,
      position,
      appleLibraryEntryId: `entry-${position}`,
      titleSnapshot: `Song ${position}`,
      artistSnapshot: 'Artist',
    })))
  }
  return run
}

describe('cleanupPlaylistSyncStaging', () => {
  it('expires open runs older than 24 hours without touching fresh runs', async () => {
    const db = await createTestDb()
    const old = await seedRun(db, 'old-open', 'open', 2)
    const fresh = await seedRun(db, 'fresh-open', 'open', 0)

    const result = await cleanupPlaylistSyncStaging(db, { now: () => now })

    expect(result).toMatchObject({ touchedRuns: 1, expiredRuns: 1 })
    const runs = await db.select().from(playlistSyncRuns)
    expect(runs.find((run) => run.id === old.id)?.status).toBe('expired')
    expect(runs.find((run) => run.id === fresh.id)?.status).toBe('open')
    expect(await db.select().from(playlistSyncPlaylists)).toHaveLength(2)
  })

  it('purges old expired and completed staging while retaining run summaries', async () => {
    const db = await createTestDb()
    const expired = await seedRun(db, 'old-expired', 'expired', 8)
    const completed = await seedRun(db, 'old-completed', 'completed', 8)
    const recent = await seedRun(db, 'recent-expired', 'expired', 2)

    const result = await cleanupPlaylistSyncStaging(db, { now: () => now })

    expect(result).toEqual({
      touchedRuns: 2,
      expiredRuns: 0,
      deletedEntries: 2,
      deletedPlaylists: 2,
      purgedRuns: 2,
    })
    expect(await db.select().from(playlistSyncRuns)).toHaveLength(3)
    const [completedRow] = await db.select().from(playlistSyncRuns)
      .where(eq(playlistSyncRuns.id, completed.id))
    expect(completedRow).toMatchObject({
      status: 'completed',
      resultPlaylists: 1,
      resultEntries: 1,
    })
    expect(await db.select().from(playlistSyncPlaylists)
      .where(eq(playlistSyncPlaylists.syncId, recent.id))).toHaveLength(1)
    expect(await db.select().from(playlistSyncPlaylists)
      .where(eq(playlistSyncPlaylists.syncId, expired.id))).toHaveLength(0)
  })

  it('touches at most 25 runs and processes the oldest first', async () => {
    const db = await createTestDb()
    const runs = []
    for (var index = 0; index < 26; index++) {
      runs.push(await seedRun(db, `run-${index}`, 'expired', 40 - index))
    }

    const result = await cleanupPlaylistSyncStaging(db, { now: () => now })

    expect(result.touchedRuns).toBe(25)
    expect(await db.select().from(playlistSyncPlaylists)).toHaveLength(1)
    const remaining = await db.select().from(playlistSyncPlaylists)
      .where(eq(playlistSyncPlaylists.syncId, runs.at(-1)!.id))
    expect(remaining).toHaveLength(1)
  })

  it('bounds row deletion and removes a playlist header only after its entries', async () => {
    const db = await createTestDb()
    const run = await seedRun(db, 'large', 'expired', 8, 7)
    const options = {
      now: () => now,
      entryBatchSize: 3,
      playlistBatchSize: 1,
    }

    expect(await cleanupPlaylistSyncStaging(db, options)).toMatchObject({
      deletedEntries: 3,
      deletedPlaylists: 0,
      purgedRuns: 0,
    })
    expect(await db.select().from(playlistSyncEntries)
      .where(eq(playlistSyncEntries.syncId, run.id))).toHaveLength(4)
    expect(await cleanupPlaylistSyncStaging(db, options)).toMatchObject({
      deletedEntries: 3,
      deletedPlaylists: 0,
      purgedRuns: 0,
    })
    expect(await cleanupPlaylistSyncStaging(db, options)).toMatchObject({
      deletedEntries: 1,
      deletedPlaylists: 1,
      purgedRuns: 1,
    })
    expect(await db.select().from(playlistSyncEntries)
      .where(and(eq(playlistSyncEntries.syncId, run.id)))).toHaveLength(0)
  })
})
