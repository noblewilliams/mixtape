import { betterAuth } from 'better-auth'
import { drizzleAdapter } from 'better-auth/adapters/drizzle'
import { bearer } from 'better-auth/plugins'
import { importPKCS8, SignJWT } from 'jose'
import * as schema from '../db/schema'
import type { AuthLike } from '../app'

export type AuthEnv = {
  BETTER_AUTH_SECRET: string
  BETTER_AUTH_URL: string
  APPLE_BUNDLE_ID: string
  APPLE_WEB_CLIENT_ID: string
  APPLE_TEAM_ID: string
  APPLE_KEY_ID: string
  APPLE_PRIVATE_KEY: string
  WEB_ORIGINS: string
}

const APPLE_ORIGIN = 'https://appleid.apple.com'
const APPLE_CLIENT_SECRET_TTL_SECONDS = 180 * 24 * 60 * 60

export function parseWebOrigins(value: string): string[] {
  if (!value) throw new Error('WEB_ORIGINS is required')

  const origins = value
    .split(',')
    .map((origin) => origin.trim())
    .filter(Boolean)

  if (origins.length === 0) throw new Error('WEB_ORIGINS is required')

  return [...new Set(origins.map((origin) => {
    const url = new URL(origin)
    if (!['http:', 'https:'].includes(url.protocol) || url.origin !== origin) {
      throw new Error('WEB_ORIGINS must contain origins only')
    }
    return url.origin
  }))]
}

export async function generateAppleClientSecret({
  clientId,
  teamId,
  keyId,
  privateKey,
  nowSeconds = Math.floor(Date.now() / 1000),
}: {
  clientId: string
  teamId: string
  keyId: string
  privateKey: string
  nowSeconds?: number
}): Promise<string> {
  const signingKey = await importPKCS8(privateKey.replace(/\\n/g, '\n'), 'ES256')
  return new SignJWT({})
    .setProtectedHeader({ alg: 'ES256', kid: keyId })
    .setIssuer(teamId)
    .setSubject(clientId)
    .setAudience(APPLE_ORIGIN)
    .setIssuedAt(nowSeconds)
    .setExpirationTime(nowSeconds + APPLE_CLIENT_SECRET_TTL_SECONDS)
    .sign(signingKey)
}

// db is any drizzle pg database (neon-http in prod, pglite in tests)
export function createAuth(db: object, env: AuthEnv) {
  if (!env.BETTER_AUTH_SECRET || env.BETTER_AUTH_SECRET.length < 32) {
    throw new Error('BETTER_AUTH_SECRET is missing or too short (min 32 chars)')
  }
  if (!env.BETTER_AUTH_URL) throw new Error('BETTER_AUTH_URL is required')
  if (!env.APPLE_BUNDLE_ID) throw new Error('APPLE_BUNDLE_ID is required')
  if (!env.APPLE_WEB_CLIENT_ID) throw new Error('APPLE_WEB_CLIENT_ID is required')
  if (!env.APPLE_TEAM_ID) throw new Error('APPLE_TEAM_ID is required')
  if (!env.APPLE_KEY_ID) throw new Error('APPLE_KEY_ID is required')
  if (!env.APPLE_PRIVATE_KEY) throw new Error('APPLE_PRIVATE_KEY is required')

  const webOrigins = parseWebOrigins(env.WEB_ORIGINS)

  return betterAuth({
    baseURL: env.BETTER_AUTH_URL,
    secret: env.BETTER_AUTH_SECRET,
    database: drizzleAdapter(db as never, { provider: 'pg', schema }),
    socialProviders: {
      apple: async () => ({
        clientId: env.APPLE_WEB_CLIENT_ID,
        clientSecret: await generateAppleClientSecret({
          clientId: env.APPLE_WEB_CLIENT_ID,
          teamId: env.APPLE_TEAM_ID,
          keyId: env.APPLE_KEY_ID,
          privateKey: env.APPLE_PRIVATE_KEY,
        }),
        // Native Apple tokens use the bundle ID as their audience while the
        // web redirect flow above uses the Services ID.
        appBundleIdentifier: env.APPLE_BUNDLE_ID,
      }),
    },
    trustedOrigins: [...webOrigins, APPLE_ORIGIN],
    // memory storage is per-isolate on Workers — real KV/DO storage is a P2 item
    rateLimit: { enabled: true, window: 10, max: 100 },
    // Without this, Better Auth can't resolve a client IP on Workers and rate
    // limiting collapses into one shared per-path bucket for ALL users.
    advanced: { ipAddress: { ipAddressHeaders: ['cf-connecting-ip'] } },
    plugins: [bearer()],
  })
}

export type Auth = ReturnType<typeof createAuth>

// Compile-time proof the real auth satisfies the app's structural seam
const _contract: AuthLike = null as unknown as Auth
void _contract
