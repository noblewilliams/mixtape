import { describe, it, expect } from 'vitest'
import { eq } from 'drizzle-orm'
import { createApp, type AuthLike } from '../src/app'
import { createTestDb, type TestDb } from './helpers/db'
import { djMemories, user } from '../src/db/schema'

async function seedUser(db: TestDb, id: string) {
  await db.insert(user).values({ id, name: id, email: `${id}@example.com`, emailVerified: false, createdAt: new Date(), updatedAt: new Date() })
}

function authedAs(userId: string): AuthLike {
  return {
    handler: () => new Response('ok'),
    api: { getSession: async () => ({ user: { id: userId } }) },
  }
}

const unauthed: AuthLike = {
  handler: () => new Response('ok'),
  api: { getSession: async () => null },
}

describe('GET /me/memories', () => {
  it("lists the caller's own notes newest-first, in the {id, note, createdAt} shape", async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await db.insert(djMemories).values({ userId: 'u1', note: 'older', createdAt: new Date(Date.now() - 60_000) })
    const [newer] = await db.insert(djMemories).values({ userId: 'u1', note: 'newer' }).returning()
    const app = createApp({ auth: authedAs('u1'), db })

    const res = await app.request('http://x/me/memories')
    expect(res.status).toBe(200)
    const body = (await res.json()) as { memories: Array<{ id: string; note: string; createdAt: string }> }
    expect(body.memories.map((m) => m.note)).toEqual(['newer', 'older'])
    expect(body.memories[0].id).toBe(newer.id)
    expect(body.memories[0]).toHaveProperty('createdAt')
  })

  it("scopes to the authenticated user — never returns another user's notes", async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedUser(db, 'u2')
    await db.insert(djMemories).values({ userId: 'u2', note: 'not yours' })
    const app = createApp({ auth: authedAs('u1'), db })

    const res = await app.request('http://x/me/memories')
    expect(res.status).toBe(200)
    const body = (await res.json()) as { memories: unknown[] }
    expect(body.memories).toHaveLength(0)
  })

  it('401s without a session', async () => {
    const db = await createTestDb()
    const app = createApp({ auth: unauthed, db })
    const res = await app.request('http://x/me/memories')
    expect(res.status).toBe(401)
  })
})

describe('DELETE /me/memories/:id', () => {
  it("deletes the caller's own note and returns {ok:true}", async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const [note] = await db.insert(djMemories).values({ userId: 'u1', note: 'forget this' }).returning()
    const app = createApp({ auth: authedAs('u1'), db })

    const res = await app.request(`http://x/me/memories/${note.id}`, { method: 'DELETE' })
    expect(res.status).toBe(200)
    expect(await res.json()).toEqual({ ok: true })

    const rows = await db.select().from(djMemories).where(eq(djMemories.id, note.id))
    expect(rows).toHaveLength(0)
  })

  it('404s for a well-formed but missing id', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const app = createApp({ auth: authedAs('u1'), db })
    const res = await app.request('http://x/me/memories/00000000-0000-0000-0000-000000000000', { method: 'DELETE' })
    expect(res.status).toBe(404)
    expect(await res.json()).toEqual({ error: 'not_found' })
  })

  it("404s for another user's note — no existence leak, the note survives untouched", async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedUser(db, 'u2')
    const [note] = await db.insert(djMemories).values({ userId: 'u2', note: 'not yours' }).returning()
    const app = createApp({ auth: authedAs('u1'), db })

    const res = await app.request(`http://x/me/memories/${note.id}`, { method: 'DELETE' })
    expect(res.status).toBe(404)
    expect(await res.json()).toEqual({ error: 'not_found' })

    const rows = await db.select().from(djMemories).where(eq(djMemories.id, note.id))
    expect(rows).toHaveLength(1)
  })

  it('404s for a malformed id rather than throwing a Postgres uuid-syntax 500', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const app = createApp({ auth: authedAs('u1'), db })
    const res = await app.request('http://x/me/memories/not-a-uuid', { method: 'DELETE' })
    expect(res.status).toBe(404)
    expect(await res.json()).toEqual({ error: 'not_found' })
  })

  it('401s without a session', async () => {
    const db = await createTestDb()
    const app = createApp({ auth: unauthed, db })
    const res = await app.request('http://x/me/memories/00000000-0000-0000-0000-000000000000', { method: 'DELETE' })
    expect(res.status).toBe(401)
  })
})
