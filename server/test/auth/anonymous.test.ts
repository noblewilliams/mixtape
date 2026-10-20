import { afterEach, describe, it, expect, vi } from 'vitest'
import { eq } from 'drizzle-orm'
import { createTestDb } from '../helpers/db'
import { testAuthEnv } from '../helpers/auth'
import { createAuth } from '../../src/auth/create-auth'
import { createApp } from '../../src/app'
import { user } from '../../src/db/auth-schema'

// Better Auth's default rate-limit storage is a module-level Map, shared by
// every auth instance in this file. Each test signs in from its own IP so the
// per-IP buckets never bleed across tests.
let ipCounter = 0
function freshIp() {
  ipCounter += 1
  return `203.0.113.${ipCounter}`
}

function signInAnonymous(
  auth: ReturnType<typeof createAuth>,
  { ip, token }: { ip: string; token?: string },
) {
  const headers: Record<string, string> = {
    'content-type': 'application/json',
    origin: 'http://localhost:4176',
    'cf-connecting-ip': ip,
  }
  if (token) headers.authorization = `Bearer ${token}`
  return auth.handler(new Request('http://localhost:8787/api/auth/sign-in/anonymous', {
    method: 'POST',
    headers,
    body: '{}',
  }))
}

type AnonymousBody = {
  token: string
  user: { id: string; email: string; name: string; isAnonymous: boolean }
}

afterEach(() => {
  vi.useRealTimers()
})

describe('anonymous sign-in', () => {
  it('returns a bearer token and a user flagged anonymous under the placeholder domain', async () => {
    const db = await createTestDb()
    const auth = createAuth(db, testAuthEnv)

    const res = await signInAnonymous(auth, { ip: freshIp() })

    expect(res.status).toBe(200)
    const bearer = res.headers.get('set-auth-token')
    expect(bearer).toBeTruthy()
    const body = await res.json() as AnonymousBody
    // The header is the signed cookie value (token.signature); the body
    // carries the raw session token it was signed from.
    expect(bearer!.split('.')[0]).toBe(body.token)
    expect(body.user.isAnonymous).toBe(true)
    expect(body.user.name).toBe('Listener')
    expect(body.user.email).toMatch(/@anonymous\.mixtape\.invalid$/)

    const [row] = await db.select().from(user).where(eq(user.id, body.user.id))
    expect(row?.isAnonymous).toBe(true)
  })

  it('leaves ordinary users not anonymous by default', async () => {
    const db = await createTestDb()
    const auth = createAuth(db, testAuthEnv)
    const ctx = await auth.$context
    const created = await ctx.internalAdapter.createUser(
      { email: 'real@example.com', name: 'Real', emailVerified: true },
      { method: 'oauth' },
    )

    const [row] = await db.select().from(user).where(eq(user.id, created.id))
    expect(row?.isAnonymous).toBe(false)
  })

  it('lets a protected route accept the anonymous bearer token and see isAnonymous', async () => {
    const db = await createTestDb()
    const auth = createAuth(db, testAuthEnv)
    const app = createApp({ auth })
    const signIn = await signInAnonymous(auth, { ip: freshIp() })
    const bearer = signIn.headers.get('set-auth-token')!
    const { user: anon } = await signIn.json() as AnonymousBody

    const res = await app.request('http://localhost:8787/me', {
      headers: { authorization: `Bearer ${bearer}` },
    })

    expect(res.status).toBe(200)
    const body = await res.json() as { user: { id: string; isAnonymous: boolean } }
    expect(body.user.id).toBe(anon.id)
    expect(body.user.isAnonymous).toBe(true)
  })

  it('lets a protected route see a social session as not anonymous', async () => {
    const db = await createTestDb()
    const auth = createAuth(db, testAuthEnv)
    const app = createApp({ auth })
    const ctx = await auth.$context
    const account = await ctx.internalAdapter.createUser(
      { email: 'social@example.com', name: 'Social', emailVerified: true },
      { method: 'oauth' },
    )
    const session = await ctx.internalAdapter.createSession(account.id)

    const res = await app.request('http://localhost:8787/me', {
      headers: { authorization: `Bearer ${session.token}` },
    })

    expect(res.status).toBe(200)
    const body = await res.json() as { user: { id: string; isAnonymous: boolean } }
    expect(body.user.id).toBe(account.id)
    expect(body.user.isAnonymous).toBe(false)
  })

  it('refuses a second anonymous sign-in carrying the anonymous token', async () => {
    const db = await createTestDb()
    const auth = createAuth(db, testAuthEnv)
    const ip = freshIp()
    const first = await signInAnonymous(auth, { ip })
    const bearer = first.headers.get('set-auth-token')!

    const second = await signInAnonymous(auth, { ip, token: bearer })

    expect(second.status).toBe(400)
    expect(await second.json()).toMatchObject({
      code: 'ANONYMOUS_USERS_CANNOT_SIGN_IN_AGAIN_ANONYMOUSLY',
    })
    expect(await db.select().from(user)).toHaveLength(1)
  })

  it('allows five anonymous sign-ins per IP per hour and refuses the sixth', async () => {
    const db = await createTestDb()
    const auth = createAuth(db, testAuthEnv)
    const ip = freshIp()
    vi.useFakeTimers({ toFake: ['Date'] })
    const start = Date.now()

    for (let attempt = 1; attempt <= 5; attempt++) {
      const res = await signInAnonymous(auth, { ip })
      expect(res.status, `attempt ${attempt}`).toBe(200)
    }
    const sixth = await signInAnonymous(auth, { ip })
    expect(sixth.status).toBe(429)

    // Past Better Auth's default /sign-in rule (3 per 10s): still refused, so
    // the one-hour custom rule is the one in force.
    vi.setSystemTime(start + 11_000)
    expect((await signInAnonymous(auth, { ip })).status).toBe(429)

    // The bucket is per IP: another address is unaffected.
    expect((await signInAnonymous(auth, { ip: freshIp() })).status).toBe(200)

    // Once the hour has passed, the same IP may sign in again.
    vi.setSystemTime(start + 3_601_000)
    expect((await signInAnonymous(auth, { ip })).status).toBe(200)
  })
})
