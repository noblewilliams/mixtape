import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { eq } from 'drizzle-orm'
import { createTestDb } from '../helpers/db'
import { messages, mixSession, queueMessageTurn, seedUser, turnRow } from '../helpers/turn-job'
import { djMessages, djSessions, djTurns } from '../../src/db/schema'
import { sweepLostTurns, type EndedTurn } from '../../src/dj/turn-sweep'
import { handleScheduled } from '../../src/enrich/scheduled'
import { insertUserMessage } from '../../src/dj/loop'

// The maintenance sweep of lost durable turns (spec 2026-11-21
// durable-mix-turns, "Status rules"): queued or running with no heartbeat
// (or created_at, while queued) for over 90 s.

beforeEach(() => {
  vi.spyOn(console, 'log').mockImplementation(() => {})
})
afterEach(() => {
  vi.restoreAllMocks()
})

const ago = (ms: number) => new Date(Date.now() - ms)

describe('sweepLostTurns', () => {
  it('fails lost turns, rolls back what a dead attempt wrote (keeping the listener\'s words), and notifies each once', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const sessionId = await mixSession(db)

    // Queued 91 s ago and never claimed.
    const queued = await queueMessageTurn(db, sessionId, 'never ran')
    await db.update(djTurns).set({ createdAt: ago(91_000) }).where(eq(djTurns.id, queued.turnId))
    // Running, heartbeat 91 s old, its attempt had renamed the mix and
    // written a DJ message before it died.
    const running = await queueMessageTurn(db, sessionId, 'died mid turn')
    const djSeq = (await db.insert(djMessages).values({ sessionId, role: 'dj', content: 'half a reply' }).returning())[0].seq
    await db.update(djSessions).set({ title: 'Renamed Mid Turn' }).where(eq(djSessions.id, sessionId))
    await db.update(djTurns).set({
      status: 'running',
      attempt: 1,
      heartbeatAt: ago(91_000),
      writes: { messageSeqs: [running.userMessageSeq, djSeq], renamed: true, historyOffered: false, startingVersion: 0, claimTitle: 'start', claimNotPersonal: false, claimTurnId: null },
    }).where(eq(djTurns.id, running.turnId))
    // Fresh: queued just now, and running with a heartbeat 80 s old.
    const fresh = await queueMessageTurn(db, sessionId, 'just asked')
    const alive = await queueMessageTurn(db, sessionId, 'still going')
    await db.update(djTurns).set({ status: 'running', attempt: 1, heartbeatAt: ago(80_000) }).where(eq(djTurns.id, alive.turnId))
    // Finished long ago: not live, not touched.
    const done = await queueMessageTurn(db, sessionId, 'long done')
    await db.update(djTurns).set({ status: 'done', createdAt: ago(3_600_000) }).where(eq(djTurns.id, done.turnId))

    const told: EndedTurn[] = []
    const lost = await sweepLostTurns(db, { notify: async (_db, turn) => void told.push(turn) })

    expect(lost).toBe(2)
    expect(await turnRow(db, queued.turnId)).toMatchObject({ status: 'failed', errorKind: 'lost' })
    expect(await turnRow(db, running.turnId)).toMatchObject({ status: 'failed', errorKind: 'lost' })
    expect((await turnRow(db, running.turnId)).finishedAt).toBeInstanceOf(Date)
    expect((await turnRow(db, fresh.turnId)).status).toBe('queued')
    expect((await turnRow(db, alive.turnId)).status).toBe('running')
    expect((await turnRow(db, done.turnId)).status).toBe('done')
    expect(told.map((t) => t.turnId).sort()).toEqual([queued.turnId, running.turnId].sort())
    expect(told.every((t) => t.status === 'failed' && t.errorKind === 'lost' && t.userId === 'u1')).toBe(true)

    // Rolled back in re-run mode: the rename and the DJ's half reply go,
    // every listener message stays.
    const [row] = await db.select().from(djSessions).where(eq(djSessions.id, sessionId))
    expect(row.title).toBe('start')
    const contents = (await messages(db, sessionId)).map((m) => m.content)
    expect(contents).not.toContain('half a reply')
    expect(contents).toEqual(expect.arrayContaining(['never ran', 'died mid turn', 'just asked', 'still going']))

    // A second run finds nothing.
    expect(await sweepLostTurns(db, { notify: async (_db, turn) => void told.push(turn) })).toBe(0)
    expect(told).toHaveLength(2)
  })

  it('a rollback that fails still fails the turn, and a notify that throws does not stop the sweep', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const sessionId = await mixSession(db)
    vi.spyOn(console, 'error').mockImplementation(() => {})
    const broken = await queueMessageTurn(db, sessionId, 'one')
    await db.update(djTurns).set({ createdAt: ago(200_000), writes: { nonsense: true } }).where(eq(djTurns.id, broken.turnId))
    const other = await queueMessageTurn(db, sessionId, 'two')
    await db.update(djTurns).set({ createdAt: ago(100_000) }).where(eq(djTurns.id, other.turnId))

    const lost = await sweepLostTurns(db, { notify: async () => { throw new Error('push down') } })

    expect(lost).toBe(2)
    expect((await turnRow(db, broken.turnId)).status).toBe('failed')
    expect((await turnRow(db, other.turnId)).status).toBe('failed')
  })

  it('runs in the maintenance cron only when its deps are wired, as a bare count', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const sessionId = await mixSession(db)
    await insertUserMessage(db, sessionId, 'x')
    const turn = await queueMessageTurn(db, sessionId, 'lost')
    await db.update(djTurns).set({ createdAt: ago(100_000) }).where(eq(djTurns.id, turn.turnId))
    const quiet = { libraryCleanup: async () => ({}), listeningCleanup: async () => ({}), playlistCleanup: async () => ({}), anonymousRetention: async () => ({ expired: 0 }) } as never

    expect('lostTurns' in (await handleScheduled(db, 'maintenance', {}, quiet))).toBe(false)
    expect((await turnRow(db, turn.turnId)).status).toBe('queued')
    expect((await handleScheduled(db, 'maintenance', { turns: {} }, quiet)).lostTurns).toBe(1)
    expect((await turnRow(db, turn.turnId)).status).toBe('failed')
    expect((await handleScheduled(db, 'enrichment', { turns: {} }, {})).lostTurns).toBeUndefined()
  })
})
