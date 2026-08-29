import { describe, it, expect } from 'vitest'
import { createTestDb } from './helpers/db'
import { createAuth } from '../src/auth/create-auth'
import { createApp } from '../src/app'

const testEnv = {
  BETTER_AUTH_SECRET: 'test-secret-test-secret-test-secret',
  BETTER_AUTH_URL: 'http://localhost:8787',
  APPLE_BUNDLE_ID: 'com.mixtape.mixtape',
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
})
