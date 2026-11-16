import { describe, it, expect } from 'vitest'
import { sql } from 'drizzle-orm'
import { createTestDb, type TestDb } from '../helpers/db'
import { okDeps } from '../helpers/enrich-fixtures'
import {
  djSessions, enrichmentFailures, queueTracks, trackFeatures, trackMeanings, tracks, user, userTracks,
} from '../../src/db/schema'
import { dueTracks, FRONT_OF_QUEUE_PRIORITY, runEnrichmentBatch } from '../../src/enrich/runner'

const UNIT = Array.from({ length: 1024 }, (_, i) => (i === 0 ? 1 : 0))

describe('dueTracks', () => {
  it('returns due rows highest priority first, FRONT_OF_QUEUE_PRIORITY ahead of an import, with skip flags', async () => {
    const db = await createTestDb()
    const [backlog] = await db.insert(tracks).values({ appleId: 'a0', title: 'Backlog', artist: 'A' }).returning()
    const [imported] = await db.insert(tracks).values({ appleId: 'a1', title: 'Import', artist: 'A', enrichPriority: 5 }).returning()
    const [front] = await db.insert(tracks).values({ appleId: 'a2', title: 'Fill', artist: 'A', enrichPriority: FRONT_OF_QUEUE_PRIORITY }).returning()
    const [done] = await db.insert(tracks).values({ appleId: 'a3', title: 'Done', artist: 'A', enrichPriority: FRONT_OF_QUEUE_PRIORITY + 1 }).returning()
    await db.insert(trackFeatures).values({ trackId: done.id, tempo: 100, source: 'reccobeats' })
    await db.insert(trackMeanings).values({ trackId: done.id, embedding: UNIT, lyricsSource: 'lrclib' })
    await db.insert(trackFeatures).values({ trackId: imported.id, tempo: 100, source: 'reccobeats' })

    const due = await dueTracks(db, 10)

    expect(due.map((d) => d.track.id)).toEqual([front.id, imported.id, backlog.id])
    expect(due[1].skip).toEqual({ features: true, meaning: false })
    expect(due[0].skip).toEqual({ features: false, meaning: false })
    expect(due[0].track.artistKeys).toEqual(['a'])
  })

  it('narrows to the given filter and honours the limit', async () => {
    const db = await createTestDb()
    const rows = await db.insert(tracks).values([
      { appleId: 'b0', title: 'One', artist: 'Tems', enrichPriority: 3 },
      { appleId: 'b1', title: 'Two', artist: 'Tems', enrichPriority: 2 },
      { appleId: 'b2', title: 'Three', artist: 'Other', enrichPriority: 9 },
    ]).returning()

    const due = await dueTracks(db, 1, sql`t.artist_keys && ARRAY['tems']::text[]`)

    expect(due.map((d) => d.track.id)).toEqual([rows[0].id])
  })
})

// Proposed songs (dj/propose.ts verifyProposals) are inserted with
// meaning_deferred: no lyrics embedding until the song enters a library or
// recurs in MEANING_RECUR_SESSIONS sessions' queues. Features still run.
describe('dueTracks: deferred meaning', () => {
  async function seedUser(db: TestDb, id: string) {
    await db.insert(user).values({ id, name: id, email: `${id}@example.com`, emailVerified: false, createdAt: new Date(), updatedAt: new Date() })
      .onConflictDoNothing()
  }

  async function queueIn(db: TestDb, trackId: string, sessions: number) {
    await seedUser(db, 'q-user')
    for (let i = 0; i < sessions; i++) {
      const [s] = await db.insert(djSessions).values({ userId: 'q-user', title: `S${i}` }).returning()
      // Twice in one session counts once.
      await db.insert(queueTracks).values([
        { sessionId: s.id, position: 0, trackId, addedBy: 'dj' },
        { sessionId: s.id, position: 1, trackId, addedBy: 'dj' },
      ])
    }
  }

  async function deferred(db: TestDb, appleId = 'd0') {
    const [t] = await db.insert(tracks).values({ appleId, title: 'Proposed', artist: 'A', meaningDeferred: true }).returning()
    return t
  }

  it('a deferred catalogue song is due for features but not for meaning', async () => {
    const db = await createTestDb()
    const t = await deferred(db)
    const due = await dueTracks(db, 10)
    expect(due.map((d) => d.track.id)).toEqual([t.id])
    expect(due[0].skip).toEqual({ features: false, meaning: true })
    expect(due[0].track.meaningDeferred).toBe(true)
  })

  it('a deferred song with features is not due at all', async () => {
    const db = await createTestDb()
    const t = await deferred(db)
    await db.insert(trackFeatures).values({ trackId: t.id, tempo: 100, source: 'reccobeats' })
    expect(await dueTracks(db, 10)).toEqual([])
  })

  it('a deferred song in some listener\'s library is due for meaning', async () => {
    const db = await createTestDb()
    const t = await deferred(db)
    await db.insert(trackFeatures).values({ trackId: t.id, tempo: 100, source: 'reccobeats' })
    await seedUser(db, 'u1')
    await db.insert(userTracks).values({ userId: 'u1', trackId: t.id })
    const due = await dueTracks(db, 10)
    expect(due.map((d) => d.track.id)).toEqual([t.id])
    expect(due[0].skip).toEqual({ features: true, meaning: false })
  })

  it('a user_tracks row out of the library does not lift the deferral', async () => {
    const db = await createTestDb()
    const t = await deferred(db)
    await db.insert(trackFeatures).values({ trackId: t.id, tempo: 100, source: 'reccobeats' })
    await seedUser(db, 'u1')
    await db.insert(userTracks).values({ userId: 'u1', trackId: t.id, inLibrary: false })
    expect(await dueTracks(db, 10)).toEqual([])
  })

  it('queued in 3 different sessions it is due for meaning; in 2 it is not', async () => {
    const db = await createTestDb()
    const two = await deferred(db, 'd2')
    const three = await deferred(db, 'd3')
    for (const t of [two, three]) await db.insert(trackFeatures).values({ trackId: t.id, tempo: 100, source: 'reccobeats' })
    await queueIn(db, two.id, 2)
    await queueIn(db, three.id, 3)
    const due = await dueTracks(db, 10)
    expect(due.map((d) => d.track.id)).toEqual([three.id])
    expect(due[0].skip).toEqual({ features: true, meaning: false })
  })

  it('remaining and cooling agree with dueTracks for deferred songs', async () => {
    const db = await createTestDb()
    const waiting = await deferred(db, 'w')
    const lifted = await deferred(db, 'l')
    const cooling = await deferred(db, 'c')
    for (const t of [waiting, lifted, cooling]) await db.insert(trackFeatures).values({ trackId: t.id, tempo: 100, source: 'reccobeats' })
    await seedUser(db, 'u1')
    await db.insert(userTracks).values({ userId: 'u1', trackId: lifted.id })
    // A transient meaning failure from before the song was deferred again
    // (say it left the library): still deferred, so not cooling either.
    await db.insert(enrichmentFailures).values({ trackId: cooling.id, stage: 'meaning', attempts: 1, error: 'transient: boom' })

    expect((await dueTracks(db, 10)).map((d) => d.track.id)).toEqual([lifted.id])
    // limit 0 processes nothing, so the counts describe the seeded state.
    expect(await runEnrichmentBatch(db, okDeps, 0)).toEqual({ processed: 0, features: 0, meaning: 0, remaining: 1, cooling: 0 })
  })

  it('an undeferred song is unaffected', async () => {
    const db = await createTestDb()
    const [t] = await db.insert(tracks).values({ appleId: 'u0', title: 'Plain', artist: 'A' }).returning()
    await db.insert(trackFeatures).values({ trackId: t.id, tempo: 100, source: 'reccobeats' })
    const due = await dueTracks(db, 10)
    expect(due.map((d) => d.track.id)).toEqual([t.id])
    expect(due[0].skip).toEqual({ features: true, meaning: false })
  })
})
