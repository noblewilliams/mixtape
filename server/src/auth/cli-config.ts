// CLI-only config for `npm run auth:generate` — never import from app code (the adapter target is a stub that explodes at runtime).
import { betterAuth } from 'better-auth'
import { drizzleAdapter } from 'better-auth/adapters/drizzle'
import { bearer } from 'better-auth/plugins'

export const auth = betterAuth({
  database: drizzleAdapter({} as never, { provider: 'pg' }),
  plugins: [bearer()],
})
