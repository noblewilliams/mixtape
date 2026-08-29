import { describe, it, expect } from 'vitest'
import { createApp, type AuthLike } from '../src/app'

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
  })

  it('returns the user with a session', async () => {
    const app = createApp({ auth: stubAuth({ user: { id: 'user-1' } }) })
    const res = await app.request('http://x/me', {
      headers: { Authorization: 'Bearer whatever' },
    })
    expect(res.status).toBe(200)
    expect(await res.json()).toEqual({ user: { id: 'user-1' } })
  })
})
