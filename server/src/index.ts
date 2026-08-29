import type { ExecutionContext } from 'hono'
import { neon } from '@neondatabase/serverless'
import { drizzle } from 'drizzle-orm/neon-http'
import * as schema from './db/schema'
import { createAuth } from './auth/create-auth'
import { createApp } from './app'
import { lookupItunes } from './enrich/itunes'
import { resolveAndFetchFeatures } from './enrich/reccobeats'
import { fetchLyrics } from './enrich/lrclib'
import { workersAiEmbedder } from './enrich/embedder'
import type { EnrichDeps } from './enrich/pipeline'

type Bindings = {
  DATABASE_URL: string
  BETTER_AUTH_SECRET: string
  BETTER_AUTH_URL: string
  APPLE_BUNDLE_ID: string
  ENRICH_ADMIN_TOKEN?: string
  ITUNES_STOREFRONT?: string
  AI?: { run(model: string, input: { text: string[] }): Promise<unknown> }
}

export default {
  fetch(req: Request, env: Bindings, ctx: ExecutionContext) {
    if (!env.DATABASE_URL) throw new Error('DATABASE_URL is required')
    const db = drizzle(neon(env.DATABASE_URL), { schema })
    const auth = createAuth(db, env)
    // /enrich/* is only mounted when both an admin token and the AI binding
    // are configured. No AI binding → no enrich surface: better a 404 than
    // every track burning 3 'internal: TypeError' attempts.
    const enrich = env.ENRICH_ADMIN_TOKEN && env.AI
      ? {
          adminToken: env.ENRICH_ADMIN_TOKEN,
          deps: {
            storefront: env.ITUNES_STOREFRONT ?? 'ng',
            itunes: lookupItunes,
            features: resolveAndFetchFeatures,
            lyrics: fetchLyrics,
            embed: workersAiEmbedder(env.AI),
          } satisfies EnrichDeps,
        }
      : undefined
    const app = createApp({ auth, db, enrich })
    return app.fetch(req, env, ctx)
  },
}
