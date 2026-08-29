import { describe, it, expect } from 'vitest'
import { createTestDb } from './helpers/db'
import { createAuth } from '../src/auth/create-auth'
import { createApp } from '../src/app'

const testEnv = {
  BETTER_AUTH_SECRET: 'test-secret-test-secret-test-secret',
  BETTER_AUTH_URL: 'http://localhost:8787',
  APPLE_BUNDLE_ID: 'com.noble.mixtape',
}

describe('auth mounting', () => {
  it('serves better-auth endpoints', async () => {
    const db = await createTestDb()
    const auth = createAuth(db, testEnv)
    const app = createApp({ auth })
    const res = await app.request('http://localhost:8787/api/auth/ok')
    expect(res.status).toBe(200)
  })

  it('health still works', async () => {
    const db = await createTestDb()
    const auth = createAuth(db, testEnv)
    const app = createApp({ auth })
    const res = await app.request('http://localhost:8787/health')
    expect(res.status).toBe(200)
  })

  it('throws on missing or short secret', async () => {
    const db = await createTestDb()
    expect(() => createAuth(db, { ...testEnv, BETTER_AUTH_SECRET: '' })).toThrow()
    expect(() => createAuth(db, { ...testEnv, BETTER_AUTH_SECRET: 'short' })).toThrow()
  })

  it('drizzle adapter round-trips the user table', async () => {
    const auth = createAuth(await createTestDb(), testEnv)
    const ctx = await auth.$context
    await ctx.internalAdapter.createUser(
      { email: 'a@b.com', name: 'A', emailVerified: true },
      { method: 'oauth' },
    )
    expect(await ctx.internalAdapter.findUserByEmail('a@b.com')).toBeTruthy()
  })

  it('bearer path rejects a bogus token without erroring', async () => {
    const auth = createAuth(await createTestDb(), testEnv)
    const res = await auth.handler(new Request('http://localhost:8787/api/auth/get-session', {
      headers: { authorization: 'Bearer not-a-real-token' },
    }))
    expect(res.status).toBeLessThan(500)
  })
})
