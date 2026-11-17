import { describe, it, expect } from 'vitest'
import { eq, inArray } from 'drizzle-orm'
import { createTestDb, type TestDb } from '../helpers/db'
import { createApp, type AuthLike } from '../../src/app'
import type { DjDeps } from '../../src/dj/loop'
import type { LlmClient } from '../../src/dj/llm'
import type { Embedder } from '../../src/enrich/embedder'
import { djMessages, djSessions, user } from '../../src/db/schema'

const fakeEmbed: Embedder = async () => new Array(1024).fill(0)
const llm: LlmClient = async () => ({
  text: 'ready.',
  toolCalls: [],
  raw: [{ type: 'text', text: 'ready.' }],
  stopReason: 'end_turn',
  usage: { inputTokens: 1, outputTokens: 1, cacheReadInputTokens: null },
})
const deps: DjDeps = { embed: fakeEmbed, llm }

async function seedUser(db: TestDb, id: string, isAnonymous = false) {
  await db.insert(user).values({ id, name: id, email: `${id}@example.com`, emailVerified: false, isAnonymous,
    createdAt: new Date(), updatedAt: new Date() })
}

async function seedSession(db: TestDb, userId: string, title: string) {
  const [row] = await db.insert(djSessions).values({ userId, title }).returning({ id: djSessions.id })
  await db.insert(djMessages).values({ sessionId: row.id, role: 'user', content: title, seq: 1 })
  return row.id
}

function appAs(db: TestDb, id: string, isAnonymous = false) {
  const auth: AuthLike = { handler: () => new Response('ok'), api: { getSession: async () => ({ user: { id, isAnonymous } }) } }
  return createApp({ auth, db, dj: { deps } })
}

function del(app: ReturnType<typeof appAs>, body: unknown) {
  return app.request('http://x/sessions/delete', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  })
}

async function remaining(db: TestDb, ids: string[]) {
  return (await db.select({ id: djSessions.id }).from(djSessions).where(inArray(djSessions.id, ids))).map(r => r.id).sort()
}

describe('POST /sessions/delete', () => {
  it('permanently deletes the listener\'s chosen mixes and their messages', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const a = await seedSession(db, 'u1', 'a')
    const b = await seedSession(db, 'u1', 'b')
    const keep = await seedSession(db, 'u1', 'keep')

    const res = await del(appAs(db, 'u1'), { ids: [a, b] })
    expect(res.status).toBe(200)
    expect(((await res.json()) as { deleted: string[] }).deleted.sort()).toEqual([a, b].sort())
    expect(await remaining(db, [a, b, keep])).toEqual([keep])
    expect(await db.select().from(djMessages).where(inArray(djMessages.sessionId, [a, b]))).toEqual([])
  })

  it('never deletes another listener\'s mix, and does not say it exists', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedUser(db, 'u2')
    const mine = await seedSession(db, 'u1', 'mine')
    const theirs = await seedSession(db, 'u2', 'theirs')

    const res = await del(appAs(db, 'u1'), { ids: [mine, theirs] })
    expect(res.status).toBe(200)
    expect(((await res.json()) as { deleted: string[] }).deleted).toEqual([mine])
    expect(await remaining(db, [mine, theirs])).toEqual([theirs])
  })

  it('refuses an anonymous listener, so the free-mix cap cannot be reset', async () => {
    const db = await createTestDb()
    await seedUser(db, 'anon', true)
    const a = await seedSession(db, 'anon', 'a')

    const res = await del(appAs(db, 'anon', true), { ids: [a] })
    expect(res.status).toBe(403)
    expect(await res.json()).toEqual({ error: 'sign_in_required' })
    expect(await remaining(db, [a])).toEqual([a])
  })

  it('rejects an empty list, a malformed id and an oversized list', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const app = appAs(db, 'u1')
    expect((await del(app, { ids: [] })).status).toBe(400)
    expect((await del(app, { ids: ['not-a-uuid'] })).status).toBe(400)
    const many = Array.from({ length: 101 }, () => crypto.randomUUID())
    expect((await del(app, { ids: many })).status).toBe(400)
  })

  it('deletes a mix whose turn is still running, after asking the turn to stop', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const a = await seedSession(db, 'u1', 'a')
    // A live claim with nothing behind it: the stop request sees no turn let
    // go, so the route must not wait on it forever before deleting.
    await db.update(djSessions)
      .set({ activeTurnId: crypto.randomUUID(), activeTurnAt: new Date() })
      .where(eq(djSessions.id, a))

    const res = await del(appAs(db, 'u1'), { ids: [a] })
    expect(res.status).toBe(200)
    expect(await remaining(db, [a])).toEqual([])
  }, 10_000)

  it('does not shadow GET /sessions/:id', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const a = await seedSession(db, 'u1', 'a')
    const res = await appAs(db, 'u1').request(`http://x/sessions/${a}`)
    expect(res.status).toBe(200)
  })
})
