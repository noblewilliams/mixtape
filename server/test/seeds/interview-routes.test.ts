import { describe, it, expect } from 'vitest'
import { asc, eq } from 'drizzle-orm'
import { createApp, type AuthLike } from '../../src/app'
import { djMemories, funnelEvents, userArtistSeeds } from '../../src/db/schema'
import { MAX_MEMORY_NOTES, MAX_MEMORY_NOTE_LENGTH } from '../../src/dj/memory-notes'
import { createTestDb, type TestDb } from '../helpers/db'
import { now, seedUser } from '../helpers/listening-fixtures'

const authFor = (id: string | null): AuthLike => ({
  handler: () => new Response('ok'),
  api: { getSession: async () => id ? { user: { id } } : null },
})

const answers = (over: Record<string, unknown> = {}) => ({
  surface: 'ios',
  neverSkip: ['Wizkid', 'Tems'],
  playsMost: 'amapiano and alte',
  listensWhen: 'late drives, mostly',
  neverWants: 'gospel',
  era: '2010s',
  ...over,
})

function post(db: TestDb, auth: AuthLike, body: unknown) {
  return createApp({ auth, db }).request('http://x/me/interview', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  })
}

async function notes(db: TestDb, userId: string) {
  return (await db.select({ note: djMemories.note }).from(djMemories)
    .where(eq(djMemories.userId, userId))
    .orderBy(asc(djMemories.note))).map((r) => r.note)
}

async function seeds(db: TestDb, userId: string) {
  return db.select({ name: userArtistSeeds.name, source: userArtistSeeds.source })
    .from(userArtistSeeds)
    .where(eq(userArtistSeeds.userId, userId))
    .orderBy(asc(userArtistSeeds.name))
}

describe('POST /me/interview', () => {
  it('401s without a session', async () => {
    const db = await createTestDb()
    expect((await post(db, authFor(null), answers())).status).toBe(401)
  })

  it('400s on an unknown key, a bad surface, too many artists, a blank artist, an over-long answer, or a missing field', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    for (const body of [
      answers({ extra: 1 }),
      answers({ surface: 'android' }),
      answers({ neverSkip: Array.from({ length: 21 }, (_, i) => `Artist ${i}`) }),
      answers({ neverSkip: ['  '] }),
      answers({ neverSkip: ['x'.repeat(201)] }),
      answers({ era: 'x'.repeat(301) }),
      (() => { const { era: _era, ...rest } = answers(); return rest })(),
    ]) {
      expect((await post(db, authFor('u1'), body)).status, JSON.stringify(body).slice(0, 60)).toBe(400)
    }
    expect(await notes(db, 'u1')).toEqual([])
    expect(await db.select().from(funnelEvents)).toHaveLength(0)
  })

  it('replaces the interview seeds, saves one prefixed note per answer, and records interview_completed', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await db.insert(userArtistSeeds).values([
      { userId: 'u1', name: 'Old', source: 'interview', createdAt: now },
      { userId: 'u1', name: 'Pasted', source: 'pasted', createdAt: now },
    ])

    const response = await post(db, authFor('u1'), answers())
    expect(response.status).toBe(200)
    expect(await response.json()).toEqual({ seeds: 2, notes: { saved: 5, duplicate: 0, capped: 0 } })

    expect(await seeds(db, 'u1')).toEqual([
      { name: 'Pasted', source: 'pasted' },
      { name: 'Tems', source: 'interview' },
      { name: 'Wizkid', source: 'interview' },
    ])
    expect(await notes(db, 'u1')).toEqual([
      'Era: 2010s',
      'Listens when: late drives, mostly',
      'Never skips: Wizkid, Tems',
      'Never wants: gospel',
      'Plays most: amapiano and alte',
    ])
    const events = await db.select().from(funnelEvents).where(eq(funnelEvents.userId, 'u1'))
    expect(events).toHaveLength(1)
    expect(events[0]).toMatchObject({ type: 'interview_completed', surface: 'ios' })
  })

  it('skips empty answers, clears the interview seeds on an empty artist list, and still records the event', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await db.insert(userArtistSeeds).values({ userId: 'u1', name: 'Old', source: 'interview', createdAt: now })

    const response = await post(db, authFor('u1'), answers({ neverSkip: [], playsMost: '   ', listensWhen: '', neverWants: 'gospel', era: '', surface: 'web' }))
    expect(response.status).toBe(200)
    expect(await response.json()).toEqual({ seeds: 0, notes: { saved: 1, duplicate: 0, capped: 0 } })
    expect(await seeds(db, 'u1')).toEqual([])
    expect(await notes(db, 'u1')).toEqual(['Never wants: gospel'])
    expect(await db.select().from(funnelEvents).where(eq(funnelEvents.userId, 'u1'))).toMatchObject([{ type: 'interview_completed', surface: 'web' }])
  })

  it('reports duplicate and capped outcomes without failing the interview', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await db.insert(djMemories).values([
      { userId: 'u1', note: 'Plays most: amapiano and alte' },
      ...Array.from({ length: MAX_MEMORY_NOTES - 3 }, (_, i) => ({ userId: 'u1', note: `note ${i}` })),
    ])

    const response = await post(db, authFor('u1'), answers())
    expect(response.status).toBe(200)
    // 2 free slots: "Never skips" and "Listens when" land, "Plays most" is
    // the duplicate, "Never wants" and "Era" hit the cap.
    expect(await response.json()).toEqual({ seeds: 2, notes: { saved: 2, duplicate: 1, capped: 2 } })
    const stored = await notes(db, 'u1')
    expect(stored).toHaveLength(MAX_MEMORY_NOTES)
    expect(stored).toContain('Never skips: Wizkid, Tems')
    expect(stored).toContain('Listens when: late drives, mostly')
    expect(stored).not.toContain('Era: 2010s')
    expect(await db.select().from(funnelEvents).where(eq(funnelEvents.userId, 'u1'))).toHaveLength(1)
  })

  it('truncates a long answer so the prefixed note fits the note cap', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const long = 'a'.repeat(300)
    const response = await post(db, authFor('u1'), answers({ neverSkip: [], playsMost: long, listensWhen: '', neverWants: '', era: '' }))
    expect(response.status).toBe(200)
    const [note] = await notes(db, 'u1')
    expect(note.startsWith('Plays most: ')).toBe(true)
    expect(note).toHaveLength(MAX_MEMORY_NOTE_LENGTH)
  })

  it('trims and dedupes the artists case-insensitively before seeding and noting', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const response = await post(db, authFor('u1'), answers({ neverSkip: [' Wizkid ', 'wizkid', 'Tems'], playsMost: '', listensWhen: '', neverWants: '', era: '' }))
    expect(response.status).toBe(200)
    expect(await response.json()).toMatchObject({ seeds: 2 })
    expect((await seeds(db, 'u1')).map((s) => s.name)).toEqual(['Tems', 'Wizkid'])
    expect(await notes(db, 'u1')).toEqual(['Never skips: Wizkid, Tems'])
  })
})
