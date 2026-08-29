import { betterAuth } from 'better-auth'
import { drizzleAdapter } from 'better-auth/adapters/drizzle'
import { bearer } from 'better-auth/plugins'
import * as schema from '../db/schema'

export type AuthEnv = {
  BETTER_AUTH_SECRET: string
  BETTER_AUTH_URL: string
  APPLE_BUNDLE_ID: string
}

// db is any drizzle pg database (neon-http in prod, pglite in tests)
export function createAuth(db: unknown, env: AuthEnv) {
  return betterAuth({
    baseURL: env.BETTER_AUTH_URL,
    secret: env.BETTER_AUTH_SECRET,
    database: drizzleAdapter(db as never, { provider: 'pg', schema }),
    socialProviders: {
      apple: {
        clientId: env.APPLE_BUNDLE_ID,
        clientSecret: '', // web-flow only; native idToken flow doesn't use it
        appBundleIdentifier: env.APPLE_BUNDLE_ID,
      },
    },
    plugins: [bearer()],
  })
}

export type Auth = ReturnType<typeof createAuth>
