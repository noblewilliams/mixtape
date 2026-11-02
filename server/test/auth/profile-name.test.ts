import { afterEach, describe, it, expect, vi } from 'vitest'
import { eq } from 'drizzle-orm'
import { SignJWT } from 'jose'
import { createTestDb } from '../helpers/db'
import { testAuthEnv } from '../helpers/auth'
import { createAuth } from '../../src/auth/create-auth'
import { firstName, isUsableName, normalizeProfileName, PROFILE_NAME_MAX } from '../../src/auth/profile-name'
import { user } from '../../src/db/auth-schema'

describe('normalizeProfileName', () => {
  it('trims and collapses inner whitespace, tabs and newlines included', () => {
    expect(normalizeProfileName('  Ada   Lovelace  ')).toBe('Ada Lovelace')
    expect(normalizeProfileName('Ada\tLove\nlace')).toBe('Ada Love lace')
    expect(normalizeProfileName('Ada  Lovelace')).toBe('Ada Lovelace')
  })

  it('drops control and format characters', () => {
    expect(normalizeProfileName('A\u0000d\u0007a')).toBe('Ada')
    expect(normalizeProfileName('​Ada‎﻿')).toBe('Ada')
    expect(normalizeProfileName('Ada‮ecalevoL')).toBe('AdaecalevoL')
  })

  it('drops a lone surrogate rather than storing broken text', () => {
    expect(normalizeProfileName('Ada\ud83d')).toBe('Ada')
  })

  it('caps at 40 code points without splitting a surrogate pair', () => {
    expect(PROFILE_NAME_MAX).toBe(40)
    expect(normalizeProfileName('a'.repeat(50))).toBe('a'.repeat(40))
    // 39 letters then emoji: the emoji is the 40th code point and survives whole.
    const atCap = `${'a'.repeat(39)}😀😀`
    expect(normalizeProfileName(atCap)).toBe(`${'a'.repeat(39)}😀`)
    const emoji = '😀'.repeat(45)
    const capped = normalizeProfileName(emoji)
    expect(Array.from(capped)).toHaveLength(40)
    expect(capped).toBe('😀'.repeat(40))
  })

  it('does not leave a trailing space where the cap lands after one', () => {
    expect(normalizeProfileName(`${'a'.repeat(39)} bcd`)).toBe('a'.repeat(39))
  })

  it('returns an empty string for blank input', () => {
    expect(normalizeProfileName('')).toBe('')
    expect(normalizeProfileName('   \n\t ')).toBe('')
    expect(normalizeProfileName('​\u0000')).toBe('')
  })
})

describe('isUsableName', () => {
  it('accepts a real name and rejects blank, missing and the anonymous default', () => {
    expect(isUsableName('Ada')).toBe(true)
    expect(isUsableName('  Ada  ')).toBe(true)
    expect(isUsableName('')).toBe(false)
    expect(isUsableName('   ')).toBe(false)
    expect(isUsableName(null)).toBe(false)
    expect(isUsableName(undefined)).toBe(false)
    expect(isUsableName('Listener')).toBe(false)
    expect(isUsableName(' Listener ')).toBe(false)
  })
})

describe('firstName', () => {
  it('is the first word of a usable name', () => {
    expect(firstName('Ada Lovelace')).toBe('Ada')
    expect(firstName('  Ada\tLovelace ')).toBe('Ada')
    expect(firstName('Ada')).toBe('Ada')
  })

  it('is null for blank, missing and Listener', () => {
    expect(firstName('')).toBeNull()
    expect(firstName(null)).toBeNull()
    expect(firstName(undefined)).toBeNull()
    expect(firstName('Listener')).toBeNull()
  })

  it('caps at 20 code points without splitting a surrogate pair', () => {
    expect(firstName(`${'b'.repeat(30)} Smith`)).toBe('b'.repeat(20))
    expect(firstName(`${'b'.repeat(19)}😀😀`)).toBe(`${'b'.repeat(19)}😀`)
  })

  it('carries no control characters into the prompt', () => {
    expect(firstName('Ada\u0000\u001b[31m Lovelace')).toBe('Ada[31m')
  })
})

describe('profile name hooks', () => {
  it('normalises the name when a user is created', async () => {
    const db = await createTestDb()
    const ctx = await (createAuth(db, testAuthEnv)).$context
    const created = await ctx.internalAdapter.createUser(
      { email: 'ada@example.com', name: `  Ada \n ${'x'.repeat(60)}`, emailVerified: true },
      { method: 'oauth' },
    )
    const [row] = await db.select().from(user).where(eq(user.id, created.id))
    expect(row?.name).toBe(`Ada ${'x'.repeat(36)}`)
    expect(row?.namePromptedAt).toBeNull()
  })

  it('stores an empty string when a provider name is blank', async () => {
    const db = await createTestDb()
    const ctx = await (createAuth(db, testAuthEnv)).$context
    const created = await ctx.internalAdapter.createUser(
      { email: 'blank@example.com', name: ' ​ ', emailVerified: true },
      { method: 'oauth' },
    )
    const [row] = await db.select().from(user).where(eq(user.id, created.id))
    expect(row?.name).toBe('')
  })

  it('normalises a name written on update and leaves other updates alone', async () => {
    const db = await createTestDb()
    const ctx = await (createAuth(db, testAuthEnv)).$context
    const created = await ctx.internalAdapter.createUser(
      { email: 'upd@example.com', name: 'Ada', emailVerified: true },
      { method: 'oauth' },
    )
    await ctx.internalAdapter.updateUser(created.id, { name: '\tGrace\u0000  Hopper ' })
    let [row] = await db.select().from(user).where(eq(user.id, created.id))
    expect(row?.name).toBe('Grace Hopper')

    await ctx.internalAdapter.updateUser(created.id, { image: 'https://example.com/a.png' })
    ;[row] = await db.select().from(user).where(eq(user.id, created.id))
    expect(row?.name).toBe('Grace Hopper')
  })
})

// Better Auth's default rate-limit storage is a module-level Map; give each
// request its own IP so buckets never bleed across tests.
let ipCounter = 0
function freshIp() {
  ipCounter += 1
  return `192.0.2.${ipCounter}`
}

function post(auth: ReturnType<typeof createAuth>, path: string, body: unknown, token?: string) {
  const headers: Record<string, string> = {
    'content-type': 'application/json',
    origin: 'http://localhost:4176',
    'cf-connecting-ip': freshIp(),
  }
  if (token) headers.authorization = `Bearer ${token}`
  return auth.handler(new Request(`http://localhost:8787/api/auth${path}`, {
    method: 'POST', headers, body: JSON.stringify(body),
  }))
}

describe('POST /api/auth/update-user', () => {
  async function signedIn() {
    const db = await createTestDb()
    const auth = createAuth(db, testAuthEnv)
    const ctx = await auth.$context
    const created = await ctx.internalAdapter.createUser(
      { email: 'owner@example.com', name: '', emailVerified: true },
      { method: 'oauth' },
    )
    const session = await ctx.internalAdapter.createSession(created.id)
    return { db, auth, userId: created.id, token: session.token }
  }

  it('lets the owner set namePromptedAt and normalises a name sent with it', async () => {
    const { db, auth, userId, token } = await signedIn()
    const at = '2026-11-02T10:00:00.000Z'

    const res = await post(auth, '/update-user', { name: '  Ada   Lovelace ', namePromptedAt: at }, token)

    expect(res.status).toBe(200)
    const [row] = await db.select().from(user).where(eq(user.id, userId))
    expect(row?.name).toBe('Ada Lovelace')
    expect(row?.namePromptedAt?.toISOString()).toBe(at)
  })

  it('a blank name clears it to an empty string', async () => {
    const { db, auth, userId, token } = await signedIn()
    await post(auth, '/update-user', { name: 'Ada' }, token)

    const res = await post(auth, '/update-user', { name: '   ' }, token)

    expect(res.status).toBe(200)
    const [row] = await db.select().from(user).where(eq(user.id, userId))
    expect(row?.name).toBe('')
  })
})

// The real /sign-in/social id-token path with Apple's real getUserInfo, which
// builds the name from idToken.user.name. Only the signature check is stubbed
// (Apple's JWKS is a network fetch); the token is still a well-formed JWT.
describe('Apple ID-token sign-in with a disclosed name', () => {
  afterEach(() => vi.restoreAllMocks())

  it('stores the provider name, normalised', async () => {
    const db = await createTestDb()
    const auth = createAuth(db, testAuthEnv)
    const ctx = await auth.$context
    const apple = ctx.socialProviders.find((p) => p.id === 'apple')!
    apple.options = { ...apple.options, verifyIdToken: async () => true }
    const idToken = await new SignJWT({ email: 'ada@privaterelay.appleid.com', email_verified: true })
      .setProtectedHeader({ alg: 'HS256' })
      .setIssuer('https://appleid.apple.com')
      .setAudience(testAuthEnv.APPLE_BUNDLE_ID)
      .setSubject('apple-sub-ada')
      .setIssuedAt()
      .setExpirationTime('10m')
      .sign(new TextEncoder().encode('not-apple'))

    const res = await post(auth, '/sign-in/social', {
      provider: 'apple',
      idToken: { token: idToken, user: { name: { firstName: '  Ada​ ', lastName: ' Lovelace\n' } } },
    })

    expect(res.status).toBe(200)
    const { user: signedIn } = await res.json() as { user: { id: string } }
    const [row] = await db.select().from(user).where(eq(user.id, signedIn.id))
    expect(row?.name).toBe('Ada Lovelace')
  })
})
