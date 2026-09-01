import { eq } from 'drizzle-orm'
import { describe, expect, it } from 'vitest'
import {
  cleanupListeningImportStaging,
  LISTENING_IMPORT_CLEANUP_ARTIST_BATCH,
  LISTENING_IMPORT_CLEANUP_DAY_BATCH,
  LISTENING_IMPORT_CLEANUP_LIBRARY_BATCH,
  LISTENING_IMPORT_CLEANUP_TRACK_BATCH,
} from '../../src/listening/cleanup'
import {
  listeningImportArtists,
  listeningImportDays,
  listeningImportLibrary,
  listeningImportRuns,
  listeningImportTracks,
  user,
} from '../../src/db/schema'
import { createTestDb, type TestDb } from '../helpers/db'

const now = new Date('2026-09-10T12:00:00.000Z')

type Rows = { tracks?: number; days?: number; library?: number; artists?: number }

// Cleanup is indifferent to which package a run carried, so every seeded run
// gets rows in all four staging tables unless told otherwise.
async function seedRun(
  db: TestDb,
  id: string,
  status: 'open' | 'completed' | 'expired',
  ageDays: number,
  rows: Rows = { tracks: 1, days: 1, library: 1, artists: 1 },
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
  const [run] = await db.insert(listeningImportRuns).values({
    userId: `user-${id}`,
    source: 'apple_export',
    package: 'apple_media',
    status,
    timeZone: 'Africa/Lagos',
    expectedTracks: rows.tracks ?? 0,
    receivedTracks: rows.tracks ?? 0,
    expectedDays: rows.days ?? 0,
    receivedDays: rows.days ?? 0,
    expectedLibraryTracks: rows.library ?? 0,
    receivedLibraryTracks: rows.library ?? 0,
    expectedArtists: 0,
    receivedArtists: 0,
    resultTracks: status === 'completed' ? rows.tracks ?? 0 : null,
    resultDays: status === 'completed' ? rows.days ?? 0 : null,
    resultLibraryTracks: status === 'completed' ? rows.library ?? 0 : null,
    resultArtists: status === 'completed' ? 0 : null,
    startedAt: at,
    expiresAt: at,
    completedAt: status === 'completed' ? at : null,
  }).returning()
  const count = (n: number | undefined) => Array.from({ length: n ?? 0 }, (_, ordinal) => ordinal)
  if (rows.tracks) {
    await db.insert(listeningImportTracks).values(count(rows.tracks).map((ordinal) => ({
      importId: run.id,
      ordinal,
      platformId: `${id}-${ordinal}`,
      title: id,
      artist: 'Artist',
    })))
  }
  if (rows.days) {
    await db.insert(listeningImportDays).values(count(rows.days).map((ordinal) => ({
      importId: run.id,
      ordinal,
      platformId: `${id}-0`,
      day: `2026-08-${String(ordinal + 1).padStart(2, '0')}`,
      plays: 1,
      msPlayed: 1_000,
    })))
  }
  if (rows.library) {
    await db.insert(listeningImportLibrary).values(count(rows.library).map((ordinal) => ({
      importId: run.id,
      ordinal,
      platformId: `${id}-${ordinal}`,
    })))
  }
  if (rows.artists) {
    await db.insert(listeningImportArtists).values(count(rows.artists).map((ordinal) => ({
      importId: run.id,
      ordinal,
      name: `${id} artist ${ordinal}`,
    })))
  }
  return run
}

async function status(db: TestDb, id: string) {
  return (await db.select().from(listeningImportRuns).where(eq(listeningImportRuns.id, id)))[0].status
}

describe('cleanupListeningImportStaging', () => {
  it('exports bounded batch sizes per staging table', () => {
    expect(LISTENING_IMPORT_CLEANUP_TRACK_BATCH).toBe(5_000)
    expect(LISTENING_IMPORT_CLEANUP_DAY_BATCH).toBe(10_000)
    expect(LISTENING_IMPORT_CLEANUP_LIBRARY_BATCH).toBe(5_000)
    expect(LISTENING_IMPORT_CLEANUP_ARTIST_BATCH).toBe(1_000)
  })

  it('expires open runs older than 24 hours without deleting their staging', async () => {
    const db = await createTestDb()
    const old = await seedRun(db, 'old', 'open', 2)
    const fresh = await seedRun(db, 'fresh', 'open', 0)

    expect(await cleanupListeningImportStaging(db, { now: () => now })).toEqual({
      touchedRuns: 1,
      expiredRuns: 1,
      deletedTracks: 0,
      deletedDays: 0,
      deletedLibraryTracks: 0,
      deletedArtists: 0,
      purgedRuns: 0,
    })
    expect(await status(db, old.id)).toBe('expired')
    expect(await status(db, fresh.id)).toBe('open')
    expect(await db.select().from(listeningImportTracks)).toHaveLength(2)
    expect(await db.select().from(listeningImportDays)).toHaveLength(2)
  })

  it('purges old staging in bounded batches across the four tables', async () => {
    const db = await createTestDb()
    const completed = await seedRun(db, 'done', 'completed', 8, {
      tracks: 2, days: 3, library: 2, artists: 2,
    })
    await seedRun(db, 'recent', 'completed', 2)
    await seedRun(db, 'fresh-open', 'open', 0)
    const options = {
      now: () => now,
      trackBatchSize: 1,
      dayBatchSize: 2,
      libraryBatchSize: 1,
      artistBatchSize: 1,
    }

    expect(await cleanupListeningImportStaging(db, options)).toEqual({
      touchedRuns: 1,
      expiredRuns: 0,
      deletedTracks: 1,
      deletedDays: 2,
      deletedLibraryTracks: 1,
      deletedArtists: 1,
      purgedRuns: 0,
    })
    expect(await cleanupListeningImportStaging(db, options)).toEqual({
      touchedRuns: 1,
      expiredRuns: 0,
      deletedTracks: 1,
      deletedDays: 1,
      deletedLibraryTracks: 1,
      deletedArtists: 1,
      purgedRuns: 1,
    })
    expect(await cleanupListeningImportStaging(db, options)).toMatchObject({
      touchedRuns: 0,
      purgedRuns: 0,
    })

    expect(await db.select().from(listeningImportTracks)).toHaveLength(2)
    expect(await db.select().from(listeningImportDays)).toHaveLength(2)
    expect(await db.select().from(listeningImportLibrary)).toHaveLength(2)
    expect(await db.select().from(listeningImportArtists)).toHaveLength(2)
    expect((await db.select().from(listeningImportRuns)
      .where(eq(listeningImportRuns.id, completed.id)))[0]).toMatchObject({
      status: 'completed',
      resultTracks: 2,
      resultDays: 3,
      resultLibraryTracks: 2,
    })
  })

  it('counts a run as purged only once every staging table is empty', async () => {
    const db = await createTestDb()
    const expired = await seedRun(db, 'expired', 'expired', 8, { artists: 2 })
    await seedRun(db, 'old-tracks', 'expired', 9, { tracks: 1 })
    const options = { now: () => now, artistBatchSize: 1 }

    expect(await cleanupListeningImportStaging(db, options)).toEqual({
      touchedRuns: 2,
      expiredRuns: 0,
      deletedTracks: 1,
      deletedDays: 0,
      deletedLibraryTracks: 0,
      deletedArtists: 1,
      purgedRuns: 1,
    })
    expect(await cleanupListeningImportStaging(db, options)).toEqual({
      touchedRuns: 1,
      expiredRuns: 0,
      deletedTracks: 0,
      deletedDays: 0,
      deletedLibraryTracks: 0,
      deletedArtists: 1,
      purgedRuns: 1,
    })
    expect(await status(db, expired.id)).toBe('expired')
    expect(await cleanupListeningImportStaging(db, options)).toMatchObject({ touchedRuns: 0 })
  })

  it('bounds the number of runs touched per call', async () => {
    const db = await createTestDb()
    for (let index = 0; index < 27; index += 1) {
      await seedRun(db, `stale-${index}`, 'open', 2 + index, {})
    }

    expect(await cleanupListeningImportStaging(db, { now: () => now, runLimit: 2 }))
      .toMatchObject({ touchedRuns: 2, expiredRuns: 2 })
    expect(await cleanupListeningImportStaging(db, { now: () => now, runLimit: 0 }))
      .toMatchObject({ touchedRuns: 1, expiredRuns: 1 })
    expect(await cleanupListeningImportStaging(db, { now: () => now, runLimit: 99 }))
      .toMatchObject({ touchedRuns: 24, expiredRuns: 24 })
    expect(await db.select().from(listeningImportRuns)
      .where(eq(listeningImportRuns.status, 'open'))).toHaveLength(0)
  })
})
