import { exportPKCS8, generateKeyPair, jwtVerify } from 'jose'
import { describe, expect, it, vi } from 'vitest'
import { createApp, type AuthLike } from '../src/app'
import { buildMusicKit } from '../src/index'
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

  it('signs a server token without exposing a browser origin claim', async () => {
    const { privateKey, publicKey } = await generateKeyPair('ES256', { extractable: true })
    const privateKeyPem = await exportPKCS8(privateKey)
    const result = await generateMusicKitDeveloperToken({
      teamId: 'TEAM123456',
      keyId: 'MUSIC12345',
      privateKey: privateKeyPem,
      nowSeconds: 1_788_134_400,
      ttlSeconds: 3_600,
    })

    const verified = await jwtVerify(result.developerToken, publicKey, {
      issuer: 'TEAM123456',
      currentDate: new Date(1_788_134_400 * 1_000),
    })
    expect(verified.payload).toMatchObject({
      iss: 'TEAM123456',
      iat: 1_788_134_400,
      exp: 1_788_138_000,
    })
    expect(verified.payload).not.toHaveProperty('origin')
  })

  it('fails fast when MusicKit key configuration is partial', () => {
    expect(() =>
      buildMusicKit(
        {
          APPLE_TEAM_ID: 'TEAM123456',
          MUSICKIT_KEY_ID: 'MUSIC12345',
        },
        ['https://mixtape.example.com'],
      ),
    ).toThrow('MUSICKIT_KEY_ID and MUSICKIT_PRIVATE_KEY must be configured together')
  })

  it('leaves MusicKit and artwork catalog wiring disabled when both key values are absent', () => {
    expect(
      buildMusicKit(
        { APPLE_TEAM_ID: 'TEAM123456' },
        ['https://mixtape.example.com'],
      ),
    ).toBeUndefined()
  })

  it('shares the server catalog token across separately built Worker wiring', async () => {
    const { privateKey } = await generateKeyPair('ES256', { extractable: true })
    const privateKeyPem = await exportPKCS8(privateKey)
    const authorizationHeaders: string[] = []
    const fetchLike = vi.fn(async (_input: string | URL, init?: RequestInit) => {
      authorizationHeaders.push(new Headers(init?.headers).get('authorization') ?? '')
      return new Response('{"data":[]}', { status: 200 })
    })
    const env = {
      APPLE_TEAM_ID: 'CACHE_TEAM',
      MUSICKIT_KEY_ID: 'CACHE_KEY',
      MUSICKIT_PRIVATE_KEY: privateKeyPem,
    }

    await buildMusicKit(env, [], fetchLike)?.catalog.getSongs('ng', ['1'])
    await buildMusicKit(env, [], fetchLike)?.catalog.getSongs('ng', ['2'])

    expect(authorizationHeaders).toHaveLength(2)
    expect(authorizationHeaders[1]).toBe(authorizationHeaders[0])
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

  it('never exposes the internal server token issuer as a route', async () => {
    const app = createApp({
      auth: stubAuth({ user: { id: 'user-1' } }),
      musicKit: {
        allowedOrigins: [origin],
        issueDeveloperToken: vi.fn(async () => ({ developerToken: 'browser-token', expiresAt: 1_788_138_000 })),
      },
    })

    const response = await app.request('http://x/musickit/server-token', { headers: { Origin: origin } })

    expect(response.status).toBe(404)
  })
})
