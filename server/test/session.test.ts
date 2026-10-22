import { describe, it, expect } from 'vitest'
import { createApp, type AuthLike } from '../src/app'
import { createTestDb } from './helpers/db'
import { testAuthEnv } from './helpers/auth'
import { createAuth } from '../src/auth/create-auth'
import type { DjDeps } from '../src/dj/loop'

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
    expect(await res.json()).toEqual({ user: { id: 'user-1', isAnonymous: false }, merged: null, albumPicks: false, neverRefuse: false })
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

// The DJ deps carry NEVER_REFUSE (src/index.ts buildDjDeps); the clients read
// it to route "Skip for now" to the prompt page.
function djWith(neverRefuse: boolean | undefined, { fill = true }: { fill?: boolean } = {}) {
  const fake = fill ? ({} as NonNullable<DjDeps['fill']>) : undefined
  return { deps: { llm: {} as DjDeps['llm'], embed: {} as DjDeps['embed'], neverRefuse, fill: fake } }
}

function sessionFreeAuth(): AuthLike & { calls: number } {
  const auth = {
    calls: 0,
    handler: () => new Response('ok'),
    api: {
      getSession: async () => {
        auth.calls += 1
        return null
      },
    },
  }
  return auth
}

describe('neverRefuse flag', () => {
  it('GET /me reports neverRefuse on and off', async () => {
    const user = stubAuth({ user: { id: 'user-1' } })
    const on = (await (await createApp({ auth: user, dj: djWith(true) }).request('http://x/me')).json()) as { neverRefuse: boolean }
    expect(on.neverRefuse).toBe(true)
    const off = (await (await createApp({ auth: user, dj: djWith(false) }).request('http://x/me')).json()) as { neverRefuse: boolean }
    expect(off.neverRefuse).toBe(false)
    const unset = (await (await createApp({ auth: user, dj: djWith(undefined) }).request('http://x/me')).json()) as { neverRefuse: boolean }
    expect(unset.neverRefuse).toBe(false)
  })

  it('flag on, no fill → false on /me and /health: the DJ cannot act on it', async () => {
    const app = createApp({ auth: stubAuth({ user: { id: 'user-1' } }), dj: djWith(true, { fill: false }) })
    expect(((await (await app.request('http://x/me')).json()) as { neverRefuse: boolean }).neverRefuse).toBe(false)
    expect(((await (await app.request('http://x/health')).json()) as { neverRefuse: boolean }).neverRefuse).toBe(false)
  })

  it('GET /health reports neverRefuse with no session and no database', async () => {
    // No db passed: the route cannot touch one. The auth seam counts lookups.
    const auth = sessionFreeAuth()
    const on = await createApp({ auth, dj: djWith(true) }).request('http://x/health')
    expect(on.status).toBe(200)
    expect(await on.json()).toEqual({ ok: true, service: 'mixtape-api', neverRefuse: true })
    const off = await createApp({ auth, dj: djWith(false) }).request('http://x/health')
    expect(await off.json()).toEqual({ ok: true, service: 'mixtape-api', neverRefuse: false })
    const noDj = await createApp({ auth }).request('http://x/health')
    expect(await noDj.json()).toEqual({ ok: true, service: 'mixtape-api', neverRefuse: false })
    expect(auth.calls).toBe(0)
  })
})
