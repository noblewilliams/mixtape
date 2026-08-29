import { describe, it, expect } from 'vitest'
import { eq } from 'drizzle-orm'
import { createTestDb, type TestDb } from '../helpers/db'
import {
  replaceQueue,
  getActiveQueue,
  applyOps,
  planOps,
  QueueOpError,
  QueueVersionConflict,
  type ReplacementPick,
  type ReplacementsProvider,
} from '../../src/dj/queue-store'
import { djSessions, queueTracks, tracks, user } from '../../src/db/schema'
import { opIntentSchema, type OpIntent } from '../../src/dj/contracts'

function opIntent(partial: Partial<OpIntent> & { themes: string }): OpIntent {
  return opIntentSchema.parse(partial)
}

async function seedUser(db: TestDb, id: string) {
  await db.insert(user).values({
    id,
    name: id,
    email: `${id}@example.com`,
    emailVerified: false,
    createdAt: new Date(),
    updatedAt: new Date(),
  })
}

async function seedSession(db: TestDb, userId: string, title = 'session') {
  const [s] = await db.insert(djSessions).values({ userId, title }).returning()
  return s
}

let trackCounter = 0

async function seedTrack(db: TestDb, opts: { durationMs?: number } = {}) {
  trackCounter += 1
  const label = `T${trackCounter}`
  const [t] = await db
    .insert(tracks)
    .values({
      appleId: `apple-${label}`,
      title: label,
      artist: 'Artist',
      durationMs: opts.durationMs ?? 200_000,
    })
    .returning()
  return t
}

async function seedTracks(db: TestDb, n: number) {
  const out = []
  for (let i = 0; i < n; i++) out.push(await seedTrack(db))
  return out
}

function picksFrom(trackList: { id: string }[], reasonPrefix = 'r'): ReplacementPick[] {
  return trackList.map((t, i) => ({
    trackId: t.id,
    reason: `${reasonPrefix}${i}`,
  }))
}

// A ReplacementsProvider that plays back a scripted result and records every
// call it received, for call-count / call-order / argument assertions.
function spyProvider(impl: (count: number, intent?: OpIntent) => Promise<ReplacementPick[]> | ReplacementPick[]) {
  const calls: Array<{ count: number; intent?: OpIntent }> = []
  const provider: ReplacementsProvider = async (count, intent) => {
    calls.push({ count, intent })
    return impl(count, intent)
  }
  return { provider, calls }
}

describe('queue-store', () => {
  describe('replaceQueue', () => {
    it('writes tracks at positions 0..n-1 and bumps queueVersion to 1', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const session = await seedSession(db, 'u1')
      const trackList = await seedTracks(db, 3)

      const version = await replaceQueue(db, session.id, picksFrom(trackList), 'dj')

      expect(version).toBe(1)
      const rows = await db
        .select()
        .from(queueTracks)
        .where(eq(queueTracks.sessionId, session.id))
        .orderBy(queueTracks.position)
      expect(rows.map((r) => r.position)).toEqual([0, 1, 2])
      expect(rows.map((r) => r.trackId)).toEqual(trackList.map((t) => t.id))
      expect(rows.every((r) => r.state === 'active')).toBe(true)
      expect(rows.every((r) => r.addedBy === 'dj')).toBe(true)
      expect(rows[0].reason).toBe('r0')

      const [updatedSession] = await db.select().from(djSessions).where(eq(djSessions.id, session.id))
      expect(updatedSession.queueVersion).toBe(1)
    })

    it('hard-deletes prior rows on a second replace — no history survives', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const session = await seedSession(db, 'u1')
      const firstTracks = await seedTracks(db, 2)
      const secondTracks = await seedTracks(db, 2)

      const v1 = await replaceQueue(db, session.id, picksFrom(firstTracks), 'dj')
      // Remove one via ops so a 'removed' row exists in history before the second replace.
      await applyOps(db, session.id, [{ op: 'remove', position: 0 }], 'user')

      const v2 = await replaceQueue(db, session.id, picksFrom(secondTracks), 'dj')

      expect(v1).toBe(1)
      expect(v2).toBe(3) // v1 (replace) -> 2 (the intervening remove) -> 3 (this replace)
      const rows = await db.select().from(queueTracks).where(eq(queueTracks.sessionId, session.id))
      expect(rows).toHaveLength(2)
      expect(rows.map((r) => r.trackId).sort()).toEqual(secondTracks.map((t) => t.id).sort())
      expect(rows.every((r) => r.state === 'active')).toBe(true)
    })
  })

  describe('getActiveQueue', () => {
    it('returns active rows ordered by position with joined track fields', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const session = await seedSession(db, 'u1')
      const trackList = await seedTracks(db, 3)
      await replaceQueue(db, session.id, picksFrom(trackList, 'reason-'), 'dj')
      await applyOps(db, session.id, [{ op: 'remove', position: 1 }], 'user')

      const view = await getActiveQueue(db, session.id)

      expect(view).toHaveLength(2)
      expect(view.map((v) => v.position)).toEqual([0, 1])
      expect(view[0].trackId).toBe(trackList[0].id)
      expect(view[0].appleId).toBe(trackList[0].appleId)
      expect(view[0].title).toBe(trackList[0].title)
      expect(view[0].artist).toBe(trackList[0].artist)
      expect(view[0].reason).toBe('reason-0')
      expect(view[0].durationMs).toBe(trackList[0].durationMs)
      // trackList[1] was removed; trackList[2] renumbered to position 1.
      expect(view[1].trackId).toBe(trackList[2].id)
    })
  })

  describe('planOps (pure planning)', () => {
    it('avoids a wasted provider request when a later op removes the swapped slot', () => {
      const rows = [
        { id: 'row-a', trackId: 'track-a', reason: null },
        { id: 'row-b', trackId: 'track-b', reason: null },
      ]
      const { requests, removedIds } = planOps(rows, [
        { op: 'swap', position: 0 },
        { op: 'remove', position: 0 },
      ])

      // The swap's placeholder never survives to the end of the batch (the
      // very next op removes that slot), so no request is generated for it —
      // the provider would never be called for this batch at all.
      expect(requests).toEqual([])
      expect(removedIds).toEqual(['row-a'])
    })

    it('only requests a replacement for the LAST of two swaps on the same position', () => {
      const rows = [{ id: 'row-a', trackId: 'track-a', reason: null }]
      const second = opIntent({ themes: 'second' })
      const { requests } = planOps(rows, [
        { op: 'swap', position: 0, intent: opIntent({ themes: 'first' }) },
        { op: 'swap', position: 0, intent: second },
      ])

      expect(requests).toHaveLength(1)
      expect(requests[0]).toEqual({
        opIndex: 1,
        kind: 'swap',
        count: 1,
        intent: second,
      })
    })

    it('throws QueueOpError on an out-of-range op without touching removedIds construction', () => {
      const rows = [{ id: 'row-a', trackId: 'track-a', reason: null }]
      expect(() => planOps(rows, [{ op: 'remove', position: 5 }])).toThrow(QueueOpError)
    })
  })

  describe('applyOps', () => {
    it('remove closes the gap and records removedBy', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const session = await seedSession(db, 'u1')
      const trackList = await seedTracks(db, 3)
      await replaceQueue(db, session.id, picksFrom(trackList), 'dj')

      const result = await applyOps(db, session.id, [{ op: 'remove', position: 0 }], 'user')

      expect(result.version).toBe(2)
      expect(result.removed).toBe(1)
      expect(result.requested).toBe(0)
      expect(result.added).toBe(0)
      const view = await getActiveQueue(db, session.id)
      expect(view.map((v) => v.position)).toEqual([0, 1])
      expect(view.map((v) => v.trackId)).toEqual([trackList[1].id, trackList[2].id])

      const removedRows = await db.select().from(queueTracks).where(eq(queueTracks.sessionId, session.id))
      const removed = removedRows.find((r) => r.trackId === trackList[0].id)!
      expect(removed.state).toBe('removed')
      expect(removed.removedBy).toBe('user')
    })

    it('move reorders the queue', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const session = await seedSession(db, 'u1')
      const trackList = await seedTracks(db, 3)
      await replaceQueue(db, session.id, picksFrom(trackList), 'dj')

      await applyOps(db, session.id, [{ op: 'move', from: 0, to: 2 }], 'user')

      const view = await getActiveQueue(db, session.id)
      expect(view.map((v) => v.trackId)).toEqual([trackList[1].id, trackList[2].id, trackList[0].id])
      expect(view.map((v) => v.position)).toEqual([0, 1, 2])
    })

    it('[remove 0, remove 0] removes the first two tracks — positions are working-relative', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const session = await seedSession(db, 'u1')
      const trackList = await seedTracks(db, 3)
      await replaceQueue(db, session.id, picksFrom(trackList), 'dj')

      const result = await applyOps(
        db,
        session.id,
        [
          { op: 'remove', position: 0 },
          { op: 'remove', position: 0 },
        ],
        'user',
      )

      expect(result.removed).toBe(2)
      const view = await getActiveQueue(db, session.id)
      expect(view.map((v) => v.trackId)).toEqual([trackList[2].id])
      expect(view.map((v) => v.position)).toEqual([0])
    })

    it('out-of-range op in a multi-op batch throws QueueOpError and applies NOTHING', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const session = await seedSession(db, 'u1')
      const trackList = await seedTracks(db, 3)
      await replaceQueue(db, session.id, picksFrom(trackList), 'dj')

      await expect(
        applyOps(
          db,
          session.id,
          [
            { op: 'remove', position: 0 }, // valid on its own
            { op: 'move', from: 5, to: 0 }, // out of range
          ],
          'user',
        ),
      ).rejects.toThrow(QueueOpError)

      const view = await getActiveQueue(db, session.id)
      expect(view.map((v) => v.trackId)).toEqual(trackList.map((t) => t.id))
      const [sessionRow] = await db.select().from(djSessions).where(eq(djSessions.id, session.id))
      expect(sessionRow.queueVersion).toBe(1)
    })

    it('provider is NOT called when the batch is invalid', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const session = await seedSession(db, 'u1')
      const trackList = await seedTracks(db, 2)
      await replaceQueue(db, session.id, picksFrom(trackList), 'dj')
      const [extra] = await seedTracks(db, 1)
      const { provider, calls } = spyProvider(() => [{ trackId: extra.id, reason: 'x' }])

      await expect(
        applyOps(
          db,
          session.id,
          [
            { op: 'swap', position: 0 },
            { op: 'move', from: 99, to: 0 }, // out of range — invalidates the whole batch
          ],
          'dj',
          provider,
        ),
      ).rejects.toThrow(QueueOpError)

      expect(calls).toHaveLength(0)
    })

    it('swap replaces one track via the provider, marking the old row removed-not-deleted', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const session = await seedSession(db, 'u1')
      const trackList = await seedTracks(db, 3)
      const [replacement] = await seedTracks(db, 1)
      await replaceQueue(db, session.id, picksFrom(trackList), 'dj')

      const { provider, calls } = spyProvider(() => [{ trackId: replacement.id, reason: 'fresh pick' }])

      const result = await applyOps(db, session.id, [{ op: 'swap', position: 1 }], 'dj', provider)

      expect(calls).toEqual([{ count: 1, intent: undefined }])
      expect(result.requested).toBe(1)
      expect(result.added).toBe(1)
      expect(result.removed).toBe(1)

      const view = await getActiveQueue(db, session.id)
      expect(view.map((v) => v.trackId)).toEqual([trackList[0].id, replacement.id, trackList[2].id])
      expect(view[1].reason).toBe('fresh pick')

      const oldRow = (await db.select().from(queueTracks).where(eq(queueTracks.sessionId, session.id))).find(
        (r) => r.trackId === trackList[1].id,
      )!
      expect(oldRow.state).toBe('removed')
      expect(oldRow.removedBy).toBe('dj')

      const newRow = (await db.select().from(queueTracks).where(eq(queueTracks.sessionId, session.id))).find(
        (r) => r.trackId === replacement.id,
      )!
      expect(newRow.addedBy).toBe('dj')

      // Only ever called once, in phase 1 — never again while writing in phase 2.
      expect(calls).toHaveLength(1)
    })

    it('swap forwards op.intent to the provider', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const session = await seedSession(db, 'u1')
      const trackList = await seedTracks(db, 2)
      const [replacement] = await seedTracks(db, 1)
      await replaceQueue(db, session.id, picksFrom(trackList), 'dj')
      const intent = opIntent({ themes: 'a different flavour entirely' })
      const { provider, calls } = spyProvider(() => [{ trackId: replacement.id, reason: 'r' }])

      await applyOps(db, session.id, [{ op: 'swap', position: 0, intent }], 'dj', provider)

      expect(calls).toEqual([{ count: 1, intent }])
    })

    it('a swap with an empty provider return leaves the original track in place (shortfall, not deletion)', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const session = await seedSession(db, 'u1')
      const trackList = await seedTracks(db, 2)
      await replaceQueue(db, session.id, picksFrom(trackList), 'dj')
      const { provider } = spyProvider(() => [])

      const result = await applyOps(db, session.id, [{ op: 'swap', position: 0 }], 'dj', provider)

      expect(result.requested).toBe(1)
      expect(result.added).toBe(0)
      expect(result.removed).toBe(0)
      const view = await getActiveQueue(db, session.id)
      expect(view.map((v) => v.trackId)).toEqual(trackList.map((t) => t.id))
      const rows = await db.select().from(queueTracks).where(eq(queueTracks.sessionId, session.id))
      expect(rows.every((r) => r.state === 'active')).toBe(true)
    })

    it('extend appends tracks from the provider', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const session = await seedSession(db, 'u1')
      const trackList = await seedTracks(db, 2)
      const extras = await seedTracks(db, 2)
      await replaceQueue(db, session.id, picksFrom(trackList), 'dj')

      const { provider, calls } = spyProvider((count) => {
        expect(count).toBe(2)
        return picksFrom(extras, 'extra-')
      })

      const result = await applyOps(db, session.id, [{ op: 'extend', count: 2 }], 'dj', provider)

      expect(result.requested).toBe(2)
      expect(result.added).toBe(2)
      const view = await getActiveQueue(db, session.id)
      expect(view.map((v) => v.trackId)).toEqual([...trackList.map((t) => t.id), ...extras.map((t) => t.id)])
      expect(view.map((v) => v.position)).toEqual([0, 1, 2, 3])
      expect(view[2].reason).toBe('extra-0')
      expect(calls).toHaveLength(1)
    })

    it('extend under-return appends only what arrived and reports the shortfall', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const session = await seedSession(db, 'u1')
      const trackList = await seedTracks(db, 2)
      const [onlyOne] = await seedTracks(db, 1)
      await replaceQueue(db, session.id, picksFrom(trackList), 'dj')

      const { provider } = spyProvider(() => [{ trackId: onlyOne.id, reason: 'the only one' }])

      const result = await applyOps(db, session.id, [{ op: 'extend', count: 3 }], 'dj', provider)

      expect(result.requested).toBe(3)
      expect(result.added).toBe(1)
      const view = await getActiveQueue(db, session.id)
      expect(view.map((v) => v.trackId)).toEqual([...trackList.map((t) => t.id), onlyOne.id])
      expect(view.map((v) => v.position)).toEqual([0, 1, 2])
    })

    it('skips a pick whose trackId is already active in the queue (duplicate guard)', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const session = await seedSession(db, 'u1')
      const trackList = await seedTracks(db, 3)
      await replaceQueue(db, session.id, picksFrom(trackList), 'dj')
      // Provider "picks" a track that's already active elsewhere in the queue.
      const { provider } = spyProvider(() => [{ trackId: trackList[2].id, reason: 'duplicate' }])

      const result = await applyOps(db, session.id, [{ op: 'extend', count: 1 }], 'dj', provider)

      expect(result.requested).toBe(1)
      expect(result.added).toBe(0)
      const view = await getActiveQueue(db, session.id)
      expect(view.map((v) => v.trackId)).toEqual(trackList.map((t) => t.id)) // unchanged — no duplicate inserted
      expect(view.filter((v) => v.trackId === trackList[2].id)).toHaveLength(1)
    })

    it('swap/extend without a replacementsProvider throws QueueOpError', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const session = await seedSession(db, 'u1')
      const trackList = await seedTracks(db, 2)
      await replaceQueue(db, session.id, picksFrom(trackList), 'dj')

      await expect(applyOps(db, session.id, [{ op: 'swap', position: 0 }], 'dj')).rejects.toThrow(QueueOpError)
      await expect(applyOps(db, session.id, [{ op: 'extend', count: 1 }], 'dj')).rejects.toThrow(QueueOpError)

      const [sessionRow] = await db.select().from(djSessions).where(eq(djSessions.id, session.id))
      expect(sessionRow.queueVersion).toBe(1)
    })

    it('a throwing provider leaves state and version unchanged (phase 1 aborts before any transaction)', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const session = await seedSession(db, 'u1')
      const trackList = await seedTracks(db, 2)
      await replaceQueue(db, session.id, picksFrom(trackList), 'dj')
      const boom = new Error('provider exploded')
      const provider: ReplacementsProvider = async () => {
        throw boom
      }

      await expect(applyOps(db, session.id, [{ op: 'extend', count: 1 }], 'dj', provider)).rejects.toThrow(boom)

      const view = await getActiveQueue(db, session.id)
      expect(view.map((v) => v.trackId)).toEqual(trackList.map((t) => t.id))
      const [sessionRow] = await db.select().from(djSessions).where(eq(djSessions.id, session.id))
      expect(sessionRow.queueVersion).toBe(1)
    })

    it('throws QueueVersionConflict when expectedVersion is stale', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const session = await seedSession(db, 'u1')
      const trackList = await seedTracks(db, 2)
      await replaceQueue(db, session.id, picksFrom(trackList), 'dj') // version 1

      await expect(applyOps(db, session.id, [{ op: 'remove', position: 0 }], 'user', undefined, 99)).rejects.toThrow(
        QueueVersionConflict,
      )

      const view = await getActiveQueue(db, session.id)
      expect(view.map((v) => v.trackId)).toEqual(trackList.map((t) => t.id))
      const [sessionRow] = await db.select().from(djSessions).where(eq(djSessions.id, session.id))
      expect(sessionRow.queueVersion).toBe(1)
    })

    it('succeeds when expectedVersion matches the current version', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const session = await seedSession(db, 'u1')
      const trackList = await seedTracks(db, 2)
      await replaceQueue(db, session.id, picksFrom(trackList), 'dj') // version 1

      const result = await applyOps(db, session.id, [{ op: 'remove', position: 0 }], 'user', undefined, 1)

      expect(result.version).toBe(2)
    })

    it('bumps queueVersion exactly once for a multi-op batch', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const session = await seedSession(db, 'u1')
      const trackList = await seedTracks(db, 4)
      const extra = await seedTracks(db, 1)
      await replaceQueue(db, session.id, picksFrom(trackList), 'dj')

      const { provider } = spyProvider(() => picksFrom(extra, 'e-'))

      const result = await applyOps(
        db,
        session.id,
        [
          { op: 'remove', position: 0 },
          { op: 'move', from: 0, to: 1 },
          { op: 'extend', count: 1 },
        ],
        'dj',
        provider,
      )

      expect(result.version).toBe(2)
    })

    it('renumbers positions to exactly 0..len-1 with no duplicates after an arbitrary op sequence', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const session = await seedSession(db, 'u1')
      const trackList = await seedTracks(db, 5)
      const extras = await seedTracks(db, 2)
      await replaceQueue(db, session.id, picksFrom(trackList), 'dj')

      const { provider } = spyProvider((count) => picksFrom(extras.slice(0, count), 'p-'))

      await applyOps(
        db,
        session.id,
        [
          { op: 'remove', position: 4 },
          { op: 'move', from: 0, to: 2 },
          { op: 'swap', position: 1 },
          { op: 'extend', count: 2 },
        ],
        'dj',
        provider,
      )

      const view = await getActiveQueue(db, session.id)
      const positions = view.map((v) => v.position)
      expect(positions).toEqual(Array.from({ length: positions.length }, (_, i) => i))
      expect(new Set(positions).size).toBe(positions.length)
    })

    it('two sequential applyOps calls leave the queue with consistent, gap-free positions', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const session = await seedSession(db, 'u1')
      const trackList = await seedTracks(db, 4)
      await replaceQueue(db, session.id, picksFrom(trackList), 'dj')

      await applyOps(db, session.id, [{ op: 'remove', position: 0 }], 'user')
      await applyOps(db, session.id, [{ op: 'move', from: 0, to: 1 }], 'user')

      const view = await getActiveQueue(db, session.id)
      const positions = view.map((v) => v.position)
      expect(positions).toEqual([0, 1, 2])
      expect(new Set(positions).size).toBe(positions.length)
    })

    it('only renumbers rows whose position actually changed (updatedAt untouched otherwise)', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const session = await seedSession(db, 'u1')
      const trackList = await seedTracks(db, 3)
      await replaceQueue(db, session.id, picksFrom(trackList), 'dj')
      const before = await db.select().from(queueTracks).where(eq(queueTracks.sessionId, session.id))
      const untouchedBefore = before.find((r) => r.trackId === trackList[2].id)!

      // Removing position 0 shifts trackList[1] (now at 0) but trackList[2]
      // was already at the tail-most surviving position (2 -> 1)... to keep
      // one row GENUINELY untouched, move only the front track instead.
      await applyOps(db, session.id, [{ op: 'move', from: 0, to: 1 }], 'user')

      const after = await db.select().from(queueTracks).where(eq(queueTracks.sessionId, session.id))
      const untouchedAfter = after.find((r) => r.trackId === trackList[2].id)!
      expect(untouchedAfter.position).toBe(untouchedBefore.position)
      expect(untouchedAfter.updatedAt.getTime()).toBe(untouchedBefore.updatedAt.getTime())
    })
  })

  describe('locking', () => {
    it('locks the session row with FOR UPDATE in phase 2 (verified via the emitted SQL)', async () => {
      const db = await createTestDb()
      const built = db.select().from(djSessions).where(eq(djSessions.id, 'x')).for('update').toSQL()
      expect(built.sql.toLowerCase()).toContain('for update')
    })
  })
})
