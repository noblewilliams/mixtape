import { exportPKCS8, generateKeyPair, jwtVerify } from 'jose'
import { describe, expect, it, vi } from 'vitest'
import { createApp, type AuthLike } from '../src/app'
import { generateMusicKitDeveloperToken } from '../src/musickit/token'

function stubAuth(session: { user: { id: string } } | null): AuthLike {
  return {
    handler: () => new Response('ok'),
    api: { getSession: async () => session },
  }
}

describe('MusicKit developer token', () => {
  it('signs a short-lived ES256 token restricted to the requesting web origin', async () => {
    const { privateKey, publicKey } = await generateKeyPair('ES256', { extractable: true })
    const privateKeyPem = await exportPKCS8(privateKey)
    const result = await generateMusicKitDeveloperToken({
      teamId: 'TEAM123456',
      keyId: 'MUSIC12345',
      privateKey: privateKeyPem,
      origin: 'https://mixtape.example.com',
      nowSeconds: 1_788_134_400,
      ttlSeconds: 3_600,
    })

    const verified = await jwtVerify(result.developerToken, publicKey, {
      issuer: 'TEAM123456',
      currentDate: new Date(1_788_134_400 * 1_000),
    })
    expect(verified.protectedHeader).toMatchObject({ alg: 'ES256', kid: 'MUSIC12345' })
    expect(verified.payload).toMatchObject({
      iss: 'TEAM123456',
      iat: 1_788_134_400,
      exp: 1_788_138_000,
      origin: ['https://mixtape.example.com'],
    })
    expect(result.expiresAt).toBe(1_788_138_000)
  })
})

describe('GET /musickit/token', () => {
  const origin = 'https://mixtape.example.com'

  it('requires the existing Mixtape session', async () => {
    const app = createApp({
      auth: stubAuth(null),
      musicKit: {
        allowedOrigins: [origin],
        issueDeveloperToken: vi.fn(async () => ({ developerToken: 'signed-token', expiresAt: 1_788_138_000 })),
      },
    })

    const response = await app.request('http://x/musickit/token', { headers: { Origin: origin } })

    expect(response.status).toBe(401)
  })

  it('rejects an origin outside the web allowlist without minting a token', async () => {
    const issueDeveloperToken = vi.fn(async () => ({ developerToken: 'signed-token', expiresAt: 1_788_138_000 }))
    const app = createApp({
      auth: stubAuth({ user: { id: 'user-1' } }),
      musicKit: { allowedOrigins: [origin], issueDeveloperToken },
    })

    const response = await app.request('http://x/musickit/token', {
      headers: { Origin: 'https://not-mixtape.example.com' },
    })

    expect(response.status).toBe(403)
    expect(await response.json()).toEqual({ error: 'origin_not_allowed' })
    expect(issueDeveloperToken).not.toHaveBeenCalled()
  })

  it('returns an uncached token bound to the allowed origin', async () => {
    const issueDeveloperToken = vi.fn(async () => ({ developerToken: 'signed-token', expiresAt: 1_788_138_000 }))
    const app = createApp({
      auth: stubAuth({ user: { id: 'user-1' } }),
      musicKit: { allowedOrigins: [origin], issueDeveloperToken },
    })

    const response = await app.request('http://x/musickit/token', { headers: { Origin: origin } })

    expect(response.status).toBe(200)
    expect(response.headers.get('cache-control')).toBe('private, no-store')
    expect(await response.json()).toEqual({ developerToken: 'signed-token', expiresAt: 1_788_138_000 })
    expect(issueDeveloperToken).toHaveBeenCalledWith(origin)
  })
})
