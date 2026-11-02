import { describe, it, expect } from 'vitest'
import { sql } from 'drizzle-orm'
import { createTestDb, type TestDb } from './helpers/db'
import { createApp, type AuthLike } from '../src/app'
import { account, session, user } from '../src/db/auth-schema'
import { djMemories, funnelEvents } from '../src/db/schema'
import type { AppleRevokeDeps } from '../src/auth/apple-revoke'

function authedAs(id: string): AuthLike {
  return { handler: () => new Response('ok'), api: { getSession: async () => ({ user: { id } }) } }
}

async function seedUser(db: TestDb, id: string) {
  const now = new Date()
  await db.insert(user).values({ id, name: id, email: `${id}@example.com`, emailVerified: false, createdAt: now, updatedAt: now })
  await db.insert(session).values({ id: `${id}-s`, token: `${id}-t`, userId: id, expiresAt: new Date(now.getTime() + 86_400_000), createdAt: now, updatedAt: now })
}

async function seedApple(db: TestDb, userId: string, tokens: { refreshToken?: string, accessToken?: string } = {}) {
  const now = new Date()
  await db.insert(account).values({ id: `${userId}-apple`, accountId: `apple-sub-${userId}`, providerId: 'apple', issuer: 'https://appleid.apple.com', userId, createdAt: now, updatedAt: now, ...tokens })
}

type Call = { url: string, body: URLSearchParams }

// Unsigned is fine: the server reads sub from a token Apple just handed it.
function idToken(sub: string) {
  const part = (v: object) => Buffer.from(JSON.stringify(v)).toString('base64url')
  return `${part({ alg: 'none' })}.${part({ sub })}.sig`
}

function fakeApple(responses: { token?: Response, revoke?: Response } = {}) {
  const calls: Call[] = []
  const deps: AppleRevokeDeps = {
    bundleId: 'com.example.app',
    webClientId: 'com.example.web',
    clientSecret: async (clientId) => `secret-for-${clientId}`,
    fetchLike: async (url, init) => {
      const body = new URLSearchParams(String(init?.body))
      calls.push({ url: String(url), body })
      if (String(url).endsWith('/auth/token')) {
        return responses.token ?? Response.json({ refresh_token: 'fresh-refresh', access_token: 'fresh-access', id_token: idToken('apple-sub-u1') })
      }
      return responses.revoke ?? new Response(null, { status: 200 })
    },
  }
  return { deps, calls }
}

function build(db: TestDb, apple?: AppleRevokeDeps, userId = 'u1') {
  return createApp({ auth: authedAs(userId), db, accountDeletion: { apple } })
}

function del(app: ReturnType<typeof createApp>, body?: unknown, raw?: string) {
  return app.request('http://x/me', {
    method: 'DELETE',
    headers: { 'content-type': 'application/json' },
    ...(raw !== undefined ? { body: raw } : body === undefined ? {} : { body: JSON.stringify(body) }),
  })
}

async function userIds(db: TestDb) {
  return (await db.select({ id: user.id }).from(user)).map((r) => r.id).sort()
}

describe('DELETE /me', () => {
  it('deletes the user, their sessions and their rows, and leaves other users alone', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedUser(db, 'u2')
    await db.insert(djMemories).values([{ userId: 'u1', note: 'no jazz' }, { userId: 'u2', note: 'more jazz' }])
    await db.insert(funnelEvents).values({ userId: 'u1', type: 'first_run_opened', surface: 'ios' })

    const res = await del(build(db))
    expect(res.status).toBe(200)
    expect(await res.json()).toEqual({ deleted: true, apple: 'not_linked' })

    expect(await userIds(db)).toEqual(['u2'])
    expect((await db.select().from(session)).map((s) => s.userId)).toEqual(['u2'])
    expect((await db.select().from(djMemories)).map((m) => m.userId)).toEqual(['u2'])
    // Funnel counts survive, unlinked.
    const funnel = await db.select().from(funnelEvents)
    expect(funnel).toHaveLength(1)
    expect(funnel[0].userId).toBeNull()
  })

  it('exchanges an iOS authorization code with the bundle id and revokes the refresh token', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedApple(db, 'u1')
    const { deps, calls } = fakeApple()

    const res = await del(build(db, deps), { appleAuthorizationCode: 'native-code' })
    expect(await res.json()).toEqual({ deleted: true, apple: 'revoked' })
    expect(calls.map((c) => c.url)).toEqual(['https://appleid.apple.com/auth/token', 'https://appleid.apple.com/auth/revoke'])
    expect(Object.fromEntries(calls[0].body)).toEqual({
      client_id: 'com.example.app',
      client_secret: 'secret-for-com.example.app',
      code: 'native-code',
      grant_type: 'authorization_code',
    })
    expect(Object.fromEntries(calls[1].body)).toEqual({
      client_id: 'com.example.app',
      client_secret: 'secret-for-com.example.app',
      token: 'fresh-refresh',
      token_type_hint: 'refresh_token',
    })
    expect(await userIds(db)).toEqual([])
  })

  it('does not count a code from another Apple ID, and falls back to the stored token', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedApple(db, 'u1', { refreshToken: 'stored-refresh' })
    const { deps, calls } = fakeApple({ token: Response.json({ refresh_token: 'other-refresh', id_token: idToken('someone-else') }) })

    expect(await (await del(build(db, deps), { appleAuthorizationCode: 'other-device' })).json()).toEqual({ deleted: true, apple: 'revoked' })
    expect(calls.map((c) => c.body.get('token'))).toEqual([null, 'other-refresh', 'stored-refresh'])
    expect(calls[2].body.get('client_id')).toBe('com.example.web')
  })

  it('reports failed for a code from another Apple ID with nothing stored', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedApple(db, 'u1')
    const { deps } = fakeApple({ token: Response.json({ refresh_token: 'other-refresh', id_token: idToken('someone-else') }) })

    expect(await (await del(build(db, deps), { appleAuthorizationCode: 'other-device' })).json()).toEqual({ deleted: true, apple: 'failed' })
    expect(await userIds(db)).toEqual([])
  })

  it('gives every Apple call a timeout', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedApple(db, 'u1')
    const signals: unknown[] = []
    const base = fakeApple().deps
    const deps: AppleRevokeDeps = { ...base, fetchLike: async (url, init) => { signals.push(init?.signal); return base.fetchLike!(url, init) } }

    await del(build(db, deps), { appleAuthorizationCode: 'native-code' })
    expect(signals).toHaveLength(2)
    for (const s of signals) expect(s).toBeInstanceOf(AbortSignal)
  })

  it('revokes a stored web refresh token with the web client id when no code is sent', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedApple(db, 'u1', { refreshToken: 'stored-refresh', accessToken: 'stored-access' })
    const { deps, calls } = fakeApple()

    expect(await (await del(build(db, deps))).json()).toEqual({ deleted: true, apple: 'revoked' })
    expect(calls).toHaveLength(1)
    expect(Object.fromEntries(calls[0].body)).toEqual({
      client_id: 'com.example.web',
      client_secret: 'secret-for-com.example.web',
      token: 'stored-refresh',
      token_type_hint: 'refresh_token',
    })
  })

  it('falls back to a stored access token', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedApple(db, 'u1', { accessToken: 'stored-access' })
    const { deps, calls } = fakeApple()

    expect(await (await del(build(db, deps))).json()).toEqual({ deleted: true, apple: 'revoked' })
    expect(Object.fromEntries(calls[0].body)).toMatchObject({ token: 'stored-access', token_type_hint: 'access_token' })
  })

  it('reports no_token for an Apple login with nothing to revoke, and still deletes', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedApple(db, 'u1')
    const { deps, calls } = fakeApple()

    expect(await (await del(build(db, deps))).json()).toEqual({ deleted: true, apple: 'no_token' })
    expect(calls).toEqual([])
    expect(await userIds(db)).toEqual([])
  })

  it('still deletes when Apple refuses the exchange', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedApple(db, 'u1')
    const { deps } = fakeApple({ token: Response.json({ error: 'invalid_grant' }, { status: 400 }) })

    expect(await (await del(build(db, deps), { appleAuthorizationCode: 'stale' })).json()).toEqual({ deleted: true, apple: 'failed' })
    expect(await userIds(db)).toEqual([])
  })

  it('still deletes when the revoke call throws', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedApple(db, 'u1', { refreshToken: 'stored-refresh' })
    const deps: AppleRevokeDeps = { ...fakeApple().deps, fetchLike: async () => { throw new Error('network') } }

    expect(await (await del(build(db, deps))).json()).toEqual({ deleted: true, apple: 'failed' })
    expect(await userIds(db)).toEqual([])
  })

  it('reports failed for a linked Apple login when revocation is not configured', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedApple(db, 'u1', { refreshToken: 'stored-refresh' })

    expect(await (await del(build(db))).json()).toEqual({ deleted: true, apple: 'failed' })
    expect(await userIds(db)).toEqual([])
  })

  it('rejects a malformed body without deleting', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    for (const res of [
      await del(build(db), { appleAuthorizationCode: '' }),
      await del(build(db), { appleAuthorizationCode: 7 }),
      await del(build(db), { appleAuthorizationCode: 'x'.repeat(2049) }),
      await del(build(db), undefined, '{not json'),
    ]) {
      expect(res.status).toBe(400)
    }
    expect(await userIds(db)).toEqual(['u1'])
  })

  it('needs a session', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const app = createApp({ auth: { handler: () => new Response('ok'), api: { getSession: async () => null } }, db })
    expect((await del(app)).status).toBe(401)
    expect(await userIds(db)).toEqual(['u1'])
  })
})

// Deletion is one DELETE on "user": every table that keys a listener must
// follow it. funnel_events alone keeps its rows, unlinked.
describe('user foreign keys', () => {
  it('cascade everywhere except funnel_events', async () => {
    const db = await createTestDb()
    const result = await db.execute(sql`
      SELECT tc.table_name, rc.delete_rule
      FROM information_schema.referential_constraints rc
      JOIN information_schema.table_constraints tc ON tc.constraint_name = rc.constraint_name
      JOIN information_schema.constraint_column_usage ccu ON ccu.constraint_name = rc.unique_constraint_name
      WHERE ccu.table_name = 'user' AND ccu.column_name = 'id'
    `)
    const rows = (result as unknown as { rows: { table_name: string, delete_rule: string }[] }).rows
    expect(rows.length).toBeGreaterThan(10)
    const notCascade = rows.filter((r) => r.delete_rule !== 'CASCADE').map((r) => `${r.table_name}:${r.delete_rule}`)
    expect(notCascade).toEqual(['funnel_events:SET NULL'])
  })

  it('every user_id column is covered by a foreign key that reaches user', async () => {
    const db = await createTestDb()
    const result = await db.execute(sql`
      SELECT c.table_name FROM information_schema.columns c
      WHERE c.table_schema = 'public' AND c.column_name = 'user_id'
        AND NOT EXISTS (
          SELECT 1 FROM information_schema.key_column_usage k
          JOIN information_schema.table_constraints tc
            ON tc.constraint_name = k.constraint_name AND tc.constraint_type = 'FOREIGN KEY'
          WHERE k.table_name = c.table_name AND k.column_name = 'user_id'
        )
    `)
    const rows = (result as unknown as { rows: { table_name: string }[] }).rows
    expect(rows.map((r) => r.table_name)).toEqual([])
  })
})

