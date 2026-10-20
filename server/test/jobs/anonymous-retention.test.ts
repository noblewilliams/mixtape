import { describe, it, expect } from 'vitest'
import { eq } from 'drizzle-orm'
import { session, user } from '../../src/db/auth-schema'
import { djSessions, funnelEvents } from '../../src/db/schema'
import { expireAnonymousUsers } from '../../src/jobs/anonymous-retention'
import { createTestDb, type TestDb } from '../helpers/db'

const NOW = new Date('2026-10-20T12:00:00.000Z')
const daysAgo = (days: number) => new Date(NOW.getTime() - days * 24 * 60 * 60 * 1_000)
const now = () => NOW

async function seed(db: TestDb, id: string, opts: { anonymous: boolean, createdAt: Date, sessions?: Date[] }) {
  await db.insert(user).values({
    id,
    name: 'Listener',
    email: `${id}@anonymous.mixtape.invalid`,
    isAnonymous: opts.anonymous,
    createdAt: opts.createdAt,
    updatedAt: opts.createdAt,
  })
  for (const [i, updatedAt] of (opts.sessions ?? []).entries()) {
    await db.insert(session).values({
      id: `${id}-s${i}`,
      token: `${id}-t${i}`,
      userId: id,
      expiresAt: daysAgo(-30),
      createdAt: opts.createdAt,
      updatedAt,
    })
  }
}

async function ids(db: TestDb) {
  return (await db.select({ id: user.id }).from(user)).map((r) => r.id).sort()
}

describe('expireAnonymousUsers', () => {
  it('expires an anonymous user whose last session is 31 days old', async () => {
    const db = await createTestDb()
    await seed(db, 'a1', { anonymous: true, createdAt: daysAgo(60), sessions: [daysAgo(45), daysAgo(31)] })
    expect(await expireAnonymousUsers(db, { now })).toEqual({ expired: 1 })
    expect(await ids(db)).toEqual([])
  })

  it('keeps an anonymous user whose newest session is 29 days old', async () => {
    const db = await createTestDb()
    await seed(db, 'a1', { anonymous: true, createdAt: daysAgo(60), sessions: [daysAgo(50), daysAgo(29)] })
    expect(await expireAnonymousUsers(db, { now })).toEqual({ expired: 0 })
    expect(await ids(db)).toEqual(['a1'])
  })

  it('never expires an account, even with no sessions for a year', async () => {
    const db = await createTestDb()
    await seed(db, 'u1', { anonymous: false, createdAt: daysAgo(365) })
    await seed(db, 'u2', { anonymous: false, createdAt: daysAgo(365), sessions: [daysAgo(300)] })
    expect(await expireAnonymousUsers(db, { now })).toEqual({ expired: 0 })
    expect(await ids(db)).toEqual(['u1', 'u2'])
  })

  it('expires an anonymous user with no session created 31 days ago, and keeps one created 29 days ago', async () => {
    const db = await createTestDb()
    await seed(db, 'old', { anonymous: true, createdAt: daysAgo(31) })
    await seed(db, 'new', { anonymous: true, createdAt: daysAgo(29) })
    expect(await expireAnonymousUsers(db, { now })).toEqual({ expired: 1 })
    expect(await ids(db)).toEqual(['new'])
  })

  it('respects the limit', async () => {
    const db = await createTestDb()
    for (let i = 0; i < 5; i++) {
      await seed(db, `a${i}`, { anonymous: true, createdAt: daysAgo(40), sessions: [daysAgo(35)] })
    }
    expect(await expireAnonymousUsers(db, { now, limit: 3 })).toEqual({ expired: 3 })
    expect(await ids(db)).toHaveLength(2)
    expect(await expireAnonymousUsers(db, { now, limit: 3 })).toEqual({ expired: 2 })
    expect(await ids(db)).toEqual([])
  })

  it('honours a custom idle window', async () => {
    const db = await createTestDb()
    await seed(db, 'a1', { anonymous: true, createdAt: daysAgo(20), sessions: [daysAgo(8)] })
    expect(await expireAnonymousUsers(db, { now, idleDays: 7 })).toEqual({ expired: 1 })
  })

  it('cascades the expired user\'s sessions and dj_sessions rows', async () => {
    const db = await createTestDb()
    await seed(db, 'a1', { anonymous: true, createdAt: daysAgo(60), sessions: [daysAgo(31)] })
    await seed(db, 'keep', { anonymous: true, createdAt: daysAgo(10), sessions: [daysAgo(1)] })
    await db.insert(djSessions).values([{ userId: 'a1', title: 'Rainy commute' }, { userId: 'keep', title: 'Kept' }])
    expect(await expireAnonymousUsers(db, { now })).toEqual({ expired: 1 })
    expect(await db.select().from(djSessions).where(eq(djSessions.userId, 'a1'))).toHaveLength(0)
    expect(await db.select().from(session).where(eq(session.userId, 'a1'))).toHaveLength(0)
    expect(await db.select().from(djSessions)).toHaveLength(1)
  })

  it('keeps the expired user\'s funnel rows with a null user id', async () => {
    const db = await createTestDb()
    await seed(db, 'a1', { anonymous: true, createdAt: daysAgo(60), sessions: [daysAgo(31)] })
    await seed(db, 'keep', { anonymous: true, createdAt: daysAgo(10), sessions: [daysAgo(1)] })
    await db.insert(funnelEvents).values([
      { userId: 'a1', type: 'first_run_opened', surface: 'web' },
      { userId: 'a1', type: 'first_mix_refused', surface: 'web' },
      { userId: 'keep', type: 'first_run_opened', surface: 'ios' },
    ])
    expect(await expireAnonymousUsers(db, { now })).toEqual({ expired: 1 })
    const rows = await db.select({ userId: funnelEvents.userId, type: funnelEvents.type }).from(funnelEvents)
    expect(rows).toHaveLength(3)
    expect(rows.filter((r) => r.userId === null).map((r) => r.type).sort()).toEqual(['first_mix_refused', 'first_run_opened'])
    expect(rows.filter((r) => r.userId === 'keep')).toHaveLength(1)
  })
})
