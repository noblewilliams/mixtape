import { describe, it, expect } from 'vitest'
import { createApp, type AuthLike } from '../src/app'
import { createTestDb } from './helpers/db'
import { testAuthEnv } from './helpers/auth'
import { createAuth } from '../src/auth/create-auth'

function stubAuth(session: { user: { id: string } } | null): AuthLike {
  return {
    handler: () => new Response('ok'),
    api: { getSession: async () => session },
  }
}

describe('session middleware', () => {
  it('rejects /me without a session', async () => {
    const app = createApp({ auth: stubAuth(null) })
    const res = await app.request('http://x/me')
    expect(res.status).toBe(401)
    expect(await res.json()).toEqual({ error: 'unauthorized' })
  })

  it('returns the user with a session', async () => {
    const app = createApp({ auth: stubAuth({ user: { id: 'user-1' } }) })
    const res = await app.request('http://x/me')
    expect(res.status).toBe(200)
    expect(await res.json()).toEqual({ user: { id: 'user-1' } })
  })

  it('authenticates a real bearer session end-to-end', async () => {
    const db = await createTestDb()
    const auth = createAuth(db, testAuthEnv)
    const ctx = await auth.$context
    const u = await ctx.internalAdapter.createUser(
      { email: 'b@b.com', name: 'B', emailVerified: true },
      { method: 'oauth' },
    )
    const { token } = await ctx.internalAdapter.createSession(u.id, undefined)
    const app = createApp({ auth })
    const ok = await app.request('http://x/me', { headers: { Authorization: `Bearer ${token}` } })
    expect(ok.status).toBe(200)
    expect(((await ok.json()) as { user: { id: string } }).user.id).toBe(u.id)
    const bad = await app.request('http://x/me', { headers: { Authorization: 'Bearer bogus' } })
    expect(bad.status).toBe(401)
  })
})
