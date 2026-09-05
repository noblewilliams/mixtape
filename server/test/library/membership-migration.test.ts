import { readFileSync } from 'node:fs'
import { eq, sql } from 'drizzle-orm'
import { describe, expect, it } from 'vitest'
import { userTracks, userTrackLibrarySources, tracks, user } from '../../src/db/schema'
import { createTestDb } from '../helpers/db'
import { seedUser, SPOTIFY_A, APPLE_A } from '../helpers/listening-fixtures'

describe('library membership migration', () => {
  it('preserves historical saved rows without inventing source or seed membership', async () => {
    const db = await createTestDb()
    // Restore the pre-0022 boundary, then apply the actual upgrade to saved data.
    await db.execute(sql`DROP TABLE user_track_library_sources`)
    await seedUser(db, 'u1')
    await seedUser(db, 'u2')
    const [dual] = await db.insert(tracks).values({
      appleId: APPLE_A, spotifyId: SPOTIFY_A, title: 'Song', artist: 'Artist',
    }).returning()
    const [seed] = await db.insert(tracks).values({ title: 'Seed', artist: 'Artist' }).returning()
    await db.insert(userTracks).values([
      { userId: 'u1', trackId: dual.id, inLibrary: true, playCount: 17 },
      { userId: 'u2', trackId: dual.id, inLibrary: true, playCountObserved: false },
      { userId: 'u1', trackId: seed.id, inLibrary: false, seeded: true },
    ])
    const before = await db.select().from(userTracks)
    const migration = readFileSync(new URL('../../drizzle/0022_library_source_ownership.sql', import.meta.url), 'utf8')
    for (const statement of migration.split('--> statement-breakpoint')) {
      if (statement.trim()) await db.execute(sql.raw(statement))
    }
    expect(await db.select().from(userTracks)).toEqual(before)
    expect(await db.select().from(userTrackLibrarySources).orderBy(userTrackLibrarySources.userId)).toEqual([
      { userId: 'u1', trackId: dual.id, source: 'legacy' },
      { userId: 'u2', trackId: dual.id, source: 'legacy' },
    ])
  })

  it('enforces listener-track ownership, valid sources, uniqueness, and deletion cascades', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedUser(db, 'u2')
    const [row] = await db.insert(tracks).values({ title: 'Song', artist: 'Artist' }).returning()
    await db.insert(userTracks).values({ userId: 'u1', trackId: row.id })
    await expect(db.execute(sql`
      INSERT INTO user_track_library_sources VALUES ('u2', ${row.id}, 'apple_live')
    `)).rejects.toThrow()
    await expect(db.execute(sql`
      INSERT INTO user_track_library_sources VALUES ('u1', ${row.id}, 'guessed')
    `)).rejects.toThrow()
    const membership = { userId: 'u1', trackId: row.id, source: 'apple_live' as const }
    await db.insert(userTrackLibrarySources).values(membership)
    await expect(db.insert(userTrackLibrarySources).values(membership)).rejects.toThrow()
    await db.delete(userTracks).where(eq(userTracks.userId, 'u1'))
    expect(await db.select().from(userTrackLibrarySources)).toEqual([])
    await db.insert(userTracks).values({ userId: 'u1', trackId: row.id })
    await db.insert(userTrackLibrarySources).values(membership)
    await db.delete(user).where(eq(user.id, 'u1'))
    expect(await db.select().from(userTrackLibrarySources)).toEqual([])
  })
})
