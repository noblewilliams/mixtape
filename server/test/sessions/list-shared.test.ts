import { describe, it, expect } from 'vitest'
import { createTestDb, type TestDb } from '../helpers/db'
import { createApp, type AuthLike } from '../../src/app'
import type { DjDeps } from '../../src/dj/loop'
import { djSessions, mixShares, user } from '../../src/db/schema'

const deps = { embed: async () => new Array(1024).fill(0), llm: async () => { throw new Error('no model') } } as unknown as DjDeps

async function seed(db: TestDb) {
  await db.insert(user).values({ id: 'u1', name: 'u1', email: 'u1@example.com', emailVerified: false, isAnonymous: false,
    createdAt: new Date(), updatedAt: new Date() })
  const ids: Record<string, string> = {}
  for (const title of ['plain', 'shared', 'revoked']) {
    const [row] = await db.insert(djSessions).values({ userId: 'u1', title }).returning({ id: djSessions.id })
    ids[title] = row.id
  }
  const share = (sessionId: string, token: string, revokedAt: Date | null) => ({
    token, sessionId, sharerId: 'u1', queueVersion: 0, title: 't', caseColor: '#bc5734', entries: [], revokedAt,
  })
  await db.insert(mixShares).values([share(ids.shared, 'a'.repeat(22), null), share(ids.revoked, 'b'.repeat(22), new Date())])
  return ids
}

describe('GET /sessions shared flag', () => {
  // Select mode's delete confirm warns that share links stop working, so the
  // list has to say which mixes have a live link without opening each one.
  it('marks mixes with a live share link, not revoked or unshared ones', async () => {
    const db = await createTestDb()
    const ids = await seed(db)
    const auth: AuthLike = { handler: () => new Response('ok'), api: { getSession: async () => ({ user: { id: 'u1', isAnonymous: false } }) } }
    const res = await createApp({ auth, db, dj: { deps } }).request('http://x/sessions')
    expect(res.status).toBe(200)
    const { sessions } = (await res.json()) as { sessions: { id: string; shared: boolean }[] }
    const byId = Object.fromEntries(sessions.map((s) => [s.id, s.shared]))
    expect(byId).toEqual({ [ids.plain]: false, [ids.shared]: true, [ids.revoked]: false })
  }, 60_000)
})
