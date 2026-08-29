import type { ExecutionContext } from 'hono'
import { neon } from '@neondatabase/serverless'
import { drizzle } from 'drizzle-orm/neon-http'
import * as schema from './db/schema'
import { createAuth } from './auth/create-auth'
import { createApp } from './app'

type Bindings = {
  DATABASE_URL: string
  BETTER_AUTH_SECRET: string
  BETTER_AUTH_URL: string
  APPLE_BUNDLE_ID: string
}

export default {
  fetch(req: Request, env: Bindings, ctx: ExecutionContext) {
    if (!env.DATABASE_URL) throw new Error('DATABASE_URL is required')
    const db = drizzle(neon(env.DATABASE_URL), { schema })
    const auth = createAuth(db, env)
    const app = createApp({ auth, db })
    return app.fetch(req, env, ctx)
  },
}
