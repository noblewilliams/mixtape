import { betterAuth } from 'better-auth'
import { drizzleAdapter } from 'better-auth/adapters/drizzle'
import { bearer } from 'better-auth/plugins'
import * as schema from '../db/schema'
import type { AuthLike } from '../app'

export type AuthEnv = {
  BETTER_AUTH_SECRET: string
  BETTER_AUTH_URL: string
  APPLE_BUNDLE_ID: string
}

// db is any drizzle pg database (neon-http in prod, pglite in tests)
export function createAuth(db: object, env: AuthEnv) {
  if (!env.BETTER_AUTH_SECRET || env.BETTER_AUTH_SECRET.length < 32) {
    throw new Error('BETTER_AUTH_SECRET is missing or too short (min 32 chars)')
  }
  if (!env.BETTER_AUTH_URL) throw new Error('BETTER_AUTH_URL is required')
  if (!env.APPLE_BUNDLE_ID) throw new Error('APPLE_BUNDLE_ID is required')

  return betterAuth({
    baseURL: env.BETTER_AUTH_URL,
    secret: env.BETTER_AUTH_SECRET,
    database: drizzleAdapter(db as never, { provider: 'pg', schema }),
    socialProviders: {
      apple: {
        clientId: env.APPLE_BUNDLE_ID,
        // web OAuth flow is unsupported (would throw CLIENT_ID_AND_SECRET_REQUIRED); native idToken flow doesn't use it
        clientSecret: '',
        appBundleIdentifier: env.APPLE_BUNDLE_ID,
      },
    },
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
