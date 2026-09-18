import { decodeJwt, decodeProtectedHeader } from 'jose'
import { afterEach, describe, it, expect, vi } from 'vitest'
import { createTestDb } from './helpers/db'
import { testApplePrivateKey, testAuthEnv } from './helpers/auth'
import { createAuth, generateAppleClientSecret, parseWebOrigins } from '../src/auth/create-auth'
import { createApp } from '../src/app'

const testEnv = testAuthEnv

afterEach(() => {
  vi.restoreAllMocks()
})

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

  it('logs only a fixed marker when a request handler throws', async () => {
    const sensitiveSentinel = 'private-upstream-body-sentinel'
    const error = new Error(sensitiveSentinel)
    const logged = vi.spyOn(console, 'error').mockImplementation(() => undefined)
    const app = createApp({
      auth: {
        handler: () => {
          throw error
        },
        api: { getSession: async () => null },
      },
    })

    const res = await app.request('http://localhost:8787/api/auth/fail')

    expect(res.status).toBe(500)
    expect(await res.json()).toEqual({ error: 'internal' })
    expect(logged).toHaveBeenCalledOnce()
    expect(logged).toHaveBeenCalledWith('app request failed')
    expect(JSON.stringify(logged.mock.calls)).not.toContain(sensitiveSentinel)
  })

  it('throws on missing or short secret', async () => {
    const db = await createTestDb()
    expect(() => createAuth(db, { ...testEnv, BETTER_AUTH_SECRET: '' })).toThrow()
    expect(() => createAuth(db, { ...testEnv, BETTER_AUTH_SECRET: 'short' })).toThrow()
  })

  it.each([
    'APPLE_WEB_CLIENT_ID',
    'APPLE_TEAM_ID',
    'APPLE_KEY_ID',
    'APPLE_PRIVATE_KEY',
    'GOOGLE_CLIENT_ID',
    'GOOGLE_CLIENT_SECRET',
    'WEB_ORIGINS',
  ] as const)(
    'throws when %s is missing',
    async (key) => {
      const db = await createTestDb()
      expect(() => createAuth(db, { ...testEnv, [key]: '' })).toThrow(`${key} is required`)
    },
  )

  it('parses an exact allowlist of web origins', () => {
    expect(parseWebOrigins(testEnv.WEB_ORIGINS)).toEqual([
      'http://localhost:4176',
      'https://mixtape.example.com',
    ])
    expect(() => parseWebOrigins('https://mixtape.example.com/path')).toThrow('WEB_ORIGINS must contain origins only')
  })

  it('generates an Apple client-secret JWT with the web service audience', async () => {
    const token = await generateAppleClientSecret({
      clientId: testEnv.APPLE_WEB_CLIENT_ID,
      teamId: testEnv.APPLE_TEAM_ID,
      keyId: testEnv.APPLE_KEY_ID,
      privateKey: testApplePrivateKey,
      nowSeconds: 1_800_000_000,
    })

    expect(decodeProtectedHeader(token)).toMatchObject({ alg: 'ES256', kid: testEnv.APPLE_KEY_ID })
    expect(decodeJwt(token)).toMatchObject({
      iss: testEnv.APPLE_TEAM_ID,
      sub: testEnv.APPLE_WEB_CLIENT_ID,
      aud: 'https://appleid.apple.com',
      iat: 1_800_000_000,
      exp: 1_815_552_000,
    })
  })

  it('allows credentialed API requests only from configured web origins', async () => {
    const auth = createAuth(await createTestDb(), testEnv)
    const app = createApp({ auth, allowedOrigins: parseWebOrigins(testEnv.WEB_ORIGINS) })
    const allowed = await app.request('http://localhost:8787/me', {
      method: 'OPTIONS',
      headers: {
        origin: 'http://localhost:4176',
        'access-control-request-method': 'GET',
      },
    })
    const rejected = await app.request('http://localhost:8787/me', {
      method: 'OPTIONS',
      headers: {
        origin: 'https://not-mixtape.example.com',
        'access-control-request-method': 'GET',
      },
    })

    expect(allowed.headers.get('access-control-allow-origin')).toBe('http://localhost:4176')
    expect(allowed.headers.get('access-control-allow-credentials')).toBe('true')
    expect(rejected.headers.get('access-control-allow-origin')).toBeNull()
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

  it('drizzle adapter can write an account row (social sign-in link path)', async () => {
    const auth = createAuth(await createTestDb(), testEnv)
    const ctx = await auth.$context
    const u = await ctx.internalAdapter.createUser(
      { email: 'c@d.com', name: 'C', emailVerified: true },
      { method: 'oauth' },
    )
    // Regression: @better-auth/core 1.7.x requires account.issuer; a schema
    // missing it makes every real social sign-in 302 to internal_server_error
    // while user/session tests stay green.
    const linked = await ctx.internalAdapter.createAccount({
      userId: u.id,
      providerId: 'apple',
      issuer: 'https://appleid.apple.com',
      accountId: 'apple-sub-123',
    })
    expect(linked.userId).toBe(u.id)
  })

  it('offers Google as a social sign-in provider', async () => {
    const auth = createAuth(await createTestDb(), testEnv)
    const response = await auth.handler(new Request('http://localhost:8787/api/auth/sign-in/social', {
      method: 'POST',
      headers: { 'content-type': 'application/json', origin: 'http://localhost:4176' },
      body: JSON.stringify({ provider: 'google', callbackURL: 'http://localhost:4176' }),
    }))

    expect(response.status).toBe(200)
    const body = await response.json() as { redirect: boolean; url: string }
    expect(body).toMatchObject({ redirect: true })
    expect(body.url).toContain('accounts.google.com')
  })

  it('requires explicit account linking while allowing verified provider emails to differ', async () => {
    const auth = createAuth(await createTestDb(), testEnv)

    expect(auth.options.account?.accountLinking).toMatchObject({
      disableImplicitLinking: true,
      allowDifferentEmails: true,
    })
  })

  // The iOS google_sign_in SDK stamps the *iOS* client id as the ID token's
  // `aud` (the server client id only rides along in `azp` / the server auth
  // code), so a server that knows the web client id alone rejects every native
  // token as an audience mismatch. Better Auth's Google provider takes
  // `clientId: string | string[]`; index 0 stays the primary that pairs with
  // the client secret for the web authorization-code flow, later entries are
  // accepted as additional ID token audiences only.
  it('accepts both the web and the iOS client id as Google token audiences', async () => {
    const auth = createAuth(await createTestDb(), {
      ...testEnv,
      GOOGLE_IOS_CLIENT_ID: 'google-ios-client-id.apps.googleusercontent.com',
    })

    expect(auth.options.socialProviders?.google?.clientId).toEqual([
      testEnv.GOOGLE_CLIENT_ID,
      'google-ios-client-id.apps.googleusercontent.com',
    ])

    // The built provider is what verification actually reads; assert the
    // audience there too, so a Better Auth change that stops threading the
    // array through fails here rather than in production.
    const ctx = await auth.$context
    const googleIdToken = ctx.socialProviders.find((p) => p.id === 'google')?.idToken
    expect(googleIdToken && 'audience' in googleIdToken ? googleIdToken.audience : undefined).toEqual([
      testEnv.GOOGLE_CLIENT_ID,
      'google-ios-client-id.apps.googleusercontent.com',
    ])
  })

  it('keeps the single web client id when no iOS client id is configured', async () => {
    const auth = createAuth(await createTestDb(), testEnv)
    expect(auth.options.socialProviders?.google?.clientId).toBe(testEnv.GOOGLE_CLIENT_ID)
  })

  it('treats an empty GOOGLE_IOS_CLIENT_ID as absent', async () => {
    const auth = createAuth(await createTestDb(), { ...testEnv, GOOGLE_IOS_CLIENT_ID: '' })
    expect(auth.options.socialProviders?.google?.clientId).toBe(testEnv.GOOGLE_CLIENT_ID)
  })

  it('still starts the Google web redirect flow with the iOS id configured', async () => {
    const auth = createAuth(await createTestDb(), {
      ...testEnv,
      GOOGLE_IOS_CLIENT_ID: 'google-ios-client-id.apps.googleusercontent.com',
    })
    const response = await auth.handler(new Request('http://localhost:8787/api/auth/sign-in/social', {
      method: 'POST',
      headers: { 'content-type': 'application/json', origin: 'http://localhost:4176' },
      body: JSON.stringify({ provider: 'google', callbackURL: 'http://localhost:4176' }),
    }))

    expect(response.status).toBe(200)
    const body = await response.json() as { redirect: boolean; url: string }
    // The web flow must keep using the web client id as its primary.
    expect(new URL(body.url).searchParams.get('client_id')).toBe(testEnv.GOOGLE_CLIENT_ID)
  })

  it('bearer path rejects a bogus token without erroring', async () => {
    const auth = createAuth(await createTestDb(), testEnv)
    const res = await auth.handler(new Request('http://localhost:8787/api/auth/get-session', {
      headers: { authorization: 'Bearer not-a-real-token' },
    }))
    expect(res.status).toBeLessThan(500)
  })
})
