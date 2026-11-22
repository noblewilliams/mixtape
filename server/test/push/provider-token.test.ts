import { eq } from 'drizzle-orm'
import { decodeJwt, decodeProtectedHeader, importSPKI, jwtVerify } from 'jose'
import { beforeAll, describe, expect, it } from 'vitest'
import { apnsProviderTokens } from '../../src/db/schema'
import { getApnsProviderToken, signApnsProviderToken } from '../../src/push/provider-token'
import { createTestDb } from '../helpers/db'

let privateKey: string
let publicKeyPem: string

function pem(label: string, der: ArrayBuffer): string {
  const b64 = Buffer.from(der).toString('base64').replace(/(.{64})/g, '$1\n')
  return `-----BEGIN ${label}-----\n${b64}\n-----END ${label}-----\n`
}

beforeAll(async () => {
  const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify'])
  privateKey = pem('PRIVATE KEY', await crypto.subtle.exportKey('pkcs8', pair.privateKey))
  publicKeyPem = pem('PUBLIC KEY', await crypto.subtle.exportKey('spki', pair.publicKey))
})

const key = () => ({ teamId: 'TEAM123456', keyId: 'KEY1234567', privateKey })
const T0 = new Date('2026-11-22T10:00:00.000Z')
const minutes = (n: number) => new Date(T0.getTime() + n * 60_000)

async function stored(db: Awaited<ReturnType<typeof createTestDb>>) {
  return db.select().from(apnsProviderTokens).where(eq(apnsProviderTokens.keyId, 'KEY1234567'))
}

describe('signApnsProviderToken', () => {
  it('signs an ES256 JWT with kid, iss = team id and iat = seconds', async () => {
    const token = await signApnsProviderToken(key(), T0)
    expect(decodeProtectedHeader(token)).toEqual({ alg: 'ES256', kid: 'KEY1234567' })
    expect(decodeJwt(token)).toEqual({ iss: 'TEAM123456', iat: T0.getTime() / 1000 })
    await expect(jwtVerify(token, await importSPKI(publicKeyPem, 'ES256'), { currentDate: T0 })).resolves.toBeTruthy()
  })

  it('accepts a key whose newlines arrived escaped', async () => {
    const token = await signApnsProviderToken({ ...key(), privateKey: privateKey.replace(/\n/g, '\\n') }, T0)
    expect(decodeJwt(token).iss).toBe('TEAM123456')
  })
})

describe('getApnsProviderToken', () => {
  it('signs and stores the first token', async () => {
    const db = await createTestDb()
    const token = await getApnsProviderToken(db, key(), { now: T0 })
    const rows = await stored(db)
    expect(rows).toHaveLength(1)
    expect(rows[0]!.token).toBe(token)
    expect(rows[0]!.issuedAt.toISOString()).toBe(T0.toISOString())
  })

  it('reuses the stored token while it is under 40 minutes old', async () => {
    const db = await createTestDb()
    const first = await getApnsProviderToken(db, key(), { now: T0 })
    expect(await getApnsProviderToken(db, key(), { now: minutes(39.9) })).toBe(first)
    expect((await stored(db))[0]!.issuedAt.toISOString()).toBe(T0.toISOString())
  })

  it('refreshes once the stored token is 40 minutes old', async () => {
    const db = await createTestDb()
    const first = await getApnsProviderToken(db, key(), { now: T0 })
    const second = await getApnsProviderToken(db, key(), { now: minutes(40) })
    expect(second).not.toBe(first)
    expect(decodeJwt(second).iat).toBe(minutes(40).getTime() / 1000)
    const rows = await stored(db)
    expect(rows[0]!.token).toBe(second)
    expect(rows[0]!.issuedAt.toISOString()).toBe(minutes(40).toISOString())
  })

  it('lets one of two concurrent refreshes win, and both use the winner', async () => {
    const db = await createTestDb()
    await getApnsProviderToken(db, key(), { now: T0 })
    let signs = 0
    let release!: () => void
    const gate = new Promise<void>((resolve) => (release = resolve))
    const sign = async () => {
      signs += 1
      const n = signs
      if (n === 2) release()
      await gate
      return `signed-${n}`
    }
    const [a, b] = await Promise.all([
      getApnsProviderToken(db, key(), { now: minutes(45), sign }),
      getApnsProviderToken(db, key(), { now: minutes(45), sign }),
    ])
    expect(signs).toBe(2)
    expect(a).toBe(b)
    expect((await stored(db))[0]!.token).toBe(a)
  })

  it('lets one of two concurrent first inserts win, and both use the winner', async () => {
    const db = await createTestDb()
    let signs = 0
    let release!: () => void
    const gate = new Promise<void>((resolve) => (release = resolve))
    const sign = async () => {
      signs += 1
      const n = signs
      if (n === 2) release()
      await gate
      return `signed-${n}`
    }
    const [a, b] = await Promise.all([
      getApnsProviderToken(db, key(), { now: T0, sign }),
      getApnsProviderToken(db, key(), { now: T0, sign }),
    ])
    expect(signs).toBe(2)
    expect(a).toBe(b)
    const rows = await stored(db)
    expect(rows).toHaveLength(1)
    expect(rows[0]!.token).toBe(a)
  })

  it('forceRefresh re-signs a young token', async () => {
    const db = await createTestDb()
    const first = await getApnsProviderToken(db, key(), { now: T0 })
    const second = await getApnsProviderToken(db, key(), { now: minutes(5), forceRefresh: true })
    expect(second).not.toBe(first)
    expect((await stored(db))[0]!.token).toBe(second)
  })

  it('forceRefresh with a rejected token reuses a newer token another sender already stored', async () => {
    const db = await createTestDb()
    const rejected = await getApnsProviderToken(db, key(), { now: T0 })
    const newer = await getApnsProviderToken(db, key(), { now: minutes(2), forceRefresh: true })
    let signs = 0
    const sign = async () => {
      signs += 1
      return 'unused'
    }
    const got = await getApnsProviderToken(db, key(), { now: minutes(3), forceRefresh: true, rejectedToken: rejected, sign })
    expect(got).toBe(newer)
    expect(signs).toBe(0)
  })

  it('forceRefresh with the stored token as the rejected one re-signs', async () => {
    const db = await createTestDb()
    const rejected = await getApnsProviderToken(db, key(), { now: T0 })
    const got = await getApnsProviderToken(db, key(), { now: minutes(3), forceRefresh: true, rejectedToken: rejected })
    expect(got).not.toBe(rejected)
  })

  it('fails fast on missing key material', async () => {
    const db = await createTestDb()
    await expect(getApnsProviderToken(db, { ...key(), privateKey: '' }, { now: T0 })).rejects.toThrow(/private key/)
    await expect(getApnsProviderToken(db, { ...key(), keyId: '' }, { now: T0 })).rejects.toThrow(/key id/i)
  })
})
