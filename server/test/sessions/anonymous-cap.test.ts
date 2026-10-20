import { describe, it, expect } from 'vitest'
import { eq } from 'drizzle-orm'
import { createTestDb, type TestDb } from '../helpers/db'
import { createApp, type AuthLike } from '../../src/app'
import type { DjDeps } from '../../src/dj/loop'
import type { LlmClient } from '../../src/dj/llm'
import type { Embedder } from '../../src/enrich/embedder'
import { djMessages, djSessions, user } from '../../src/db/schema'
import { ANONYMOUS_MIX_CAP } from '../../src/playlists/seed'

const fakeEmbed: Embedder = async () => new Array(1024).fill(0)

// A text-only DJ that counts every model call, so a capped request can be
// shown to have made none.
function countingLlm() {
  const state = { calls: 0 }
  const llm: LlmClient = async () => {
    state.calls += 1
    return {
      text: 'ready.',
      toolCalls: [],
      raw: [{ type: 'text', text: 'ready.' }],
      stopReason: 'end_turn',
      usage: { inputTokens: 1, outputTokens: 1, cacheReadInputTokens: null },
    }
  }
  return { llm, state }
}

async function seedUser(db: TestDb, id: string, isAnonymous: boolean) {
  await db.insert(user).values({ id, name: id, email: `${id}@example.com`, emailVerified: false, isAnonymous,
    createdAt: new Date(), updatedAt: new Date() })
}

function authedAs(id: string, isAnonymous: boolean): AuthLike {
  return { handler: () => new Response('ok'), api: { getSession: async () => ({ user: { id, isAnonymous } }) } }
}

function buildApp(db: TestDb, deps: DjDeps, auth: AuthLike) {
  return createApp({ auth, db, dj: { deps } })
}

function send(app: ReturnType<typeof buildApp>, method: string, path: string, body: unknown) {
  return app.request(`http://x${path}`, { method, headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) })
}

async function sessionCount(db: TestDb, userId: string) {
  return (await db.select({ id: djSessions.id }).from(djSessions).where(eq(djSessions.userId, userId))).length
}

describe('anonymous mix cap', () => {
  it('is three', () => {
    expect(ANONYMOUS_MIX_CAP).toBe(3)
  })

  it('lets an anonymous listener make three mixes and refuses the fourth before any model call or insert', async () => {
    const db = await createTestDb()
    await seedUser(db, 'anon', true)
    const { llm, state } = countingLlm()
    const app = buildApp(db, { embed: fakeEmbed, llm }, authedAs('anon', true))

    for (let i = 0; i < 3; i++) {
      const res = await send(app, 'POST', '/sessions', { prompt: `mix ${i}` })
      expect(res.status).toBe(200)
    }
    expect(await sessionCount(db, 'anon')).toBe(3)
    const callsBefore = state.calls
    const messagesBefore = (await db.select({ id: djMessages.id }).from(djMessages)).length

    const res = await send(app, 'POST', '/sessions', { prompt: 'mix 4' })
    expect(res.status).toBe(403)
    expect(await res.json()).toEqual({ error: 'anonymous_cap', limit: 3 })
    expect(await sessionCount(db, 'anon')).toBe(3)
    expect(state.calls).toBe(callsBefore)
    expect((await db.select({ id: djMessages.id }).from(djMessages)).length).toBe(messagesBefore)
  })

  it('counts archived sessions toward the cap', async () => {
    const db = await createTestDb()
    await seedUser(db, 'anon', true)
    await db.insert(djSessions).values([
      { userId: 'anon', title: 'a', status: 'archived' },
      { userId: 'anon', title: 'b', status: 'archived' },
      { userId: 'anon', title: 'c', status: 'archived' },
    ])
    const { llm, state } = countingLlm()
    const app = buildApp(db, { embed: fakeEmbed, llm }, authedAs('anon', true))

    const res = await send(app, 'POST', '/sessions', { prompt: 'one more' })
    expect(res.status).toBe(403)
    expect(await res.json()).toEqual({ error: 'anonymous_cap', limit: 3 })
    expect(state.calls).toBe(0)
    expect(await sessionCount(db, 'anon')).toBe(3)
  })

  it('only counts the anonymous listener\'s own sessions', async () => {
    const db = await createTestDb()
    await seedUser(db, 'anon', true)
    await seedUser(db, 'other', true)
    await db.insert(djSessions).values([1, 2, 3].map(i => ({ userId: 'other', title: `o${i}` })))
    const { llm } = countingLlm()
    const app = buildApp(db, { embed: fakeEmbed, llm }, authedAs('anon', true))

    const res = await send(app, 'POST', '/sessions', { prompt: 'first' })
    expect(res.status).toBe(200)
  })

  it('never caps an account, however many sessions it has', async () => {
    const db = await createTestDb()
    await seedUser(db, 'acct', false)
    await db.insert(djSessions).values(Array.from({ length: 30 }, (_, i) => ({ userId: 'acct', title: `s${i}` })))
    const { llm } = countingLlm()
    const app = buildApp(db, { embed: fakeEmbed, llm }, authedAs('acct', false))

    const res = await send(app, 'POST', '/sessions', { prompt: 'thirty-first' })
    expect(res.status).toBe(200)
    expect(await sessionCount(db, 'acct')).toBe(31)
  })

  it('keeps follow-ups, renames and archiving working on an anonymous session past the cap', async () => {
    const db = await createTestDb()
    await seedUser(db, 'anon', true)
    const { llm } = countingLlm()
    const app = buildApp(db, { embed: fakeEmbed, llm }, authedAs('anon', true))
    const ids: string[] = []
    for (let i = 0; i < 3; i++) {
      const res = await send(app, 'POST', '/sessions', { prompt: `mix ${i}` })
      ids.push(((await res.json()) as { session: { id: string } }).session.id)
    }
    expect((await send(app, 'POST', '/sessions', { prompt: 'capped' })).status).toBe(403)

    const followUp = await send(app, 'POST', `/sessions/${ids[0]}/messages`, { text: 'keep going' })
    expect(followUp.status).toBe(200)
    expect(((await followUp.json()) as { djMessage: { content: string } }).djMessage.content).toBe('ready.')

    const rename = await send(app, 'PATCH', `/sessions/${ids[2]}`, { title: 'Renamed' })
    expect(rename.status).toBe(200)
    const patch = await send(app, 'PATCH', `/sessions/${ids[1]}`, { status: 'archived' })
    expect(patch.status).toBe(200)
    // Archiving frees nothing: the cap counts every session ever made.
    expect((await send(app, 'POST', '/sessions', { prompt: 'still capped' })).status).toBe(403)
  })
})
