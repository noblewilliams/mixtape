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
import type { Db } from './db/types'
import { handleScheduled } from './enrich/scheduled'

type Bindings = {
  DATABASE_URL: string
  BETTER_AUTH_SECRET: string
  BETTER_AUTH_URL: string
  APPLE_BUNDLE_ID: string
  ENRICH_ADMIN_TOKEN?: string
  ITUNES_STOREFRONT?: string
  AI?: { run(model: string, input: { text: string[] }): Promise<unknown> }
}

function buildDb(env: Bindings): Db {
  if (!env.DATABASE_URL) throw new Error('DATABASE_URL is required')
  return drizzle(neon(env.DATABASE_URL), { schema })
}

// No AI binding → no deps to enrich with, for either surface (route or cron).
function buildDeps(env: Bindings): EnrichDeps | undefined {
  if (!env.AI) return undefined
  return {
    storefront: env.ITUNES_STOREFRONT ?? 'ng',
    itunes: lookupItunes,
    features: resolveAndFetchFeatures,
    lyrics: fetchLyrics,
    embed: workersAiEmbedder(env.AI),
  }
}

export default {
  fetch(req: Request, env: Bindings, ctx: ExecutionContext) {
    const db = buildDb(env)
    const auth = createAuth(db, env)
    const deps = buildDeps(env)
    // /enrich/* is only mounted when both an admin token and the AI binding
    // are configured. No AI binding → no enrich surface: better a 404 than
    // every track burning 3 'internal: TypeError' attempts.
    const enrich = deps && env.ENRICH_ADMIN_TOKEN ? { adminToken: env.ENRICH_ADMIN_TOKEN, deps } : undefined
    const app = createApp({ auth, db, enrich })
    return app.fetch(req, env, ctx)
  },
  async scheduled(_event: unknown, env: Bindings, _ctx: ExecutionContext) {
    const deps = buildDeps(env)
    if (!deps) return // no AI binding: nothing to enrich with
    await handleScheduled(buildDb(env), deps)
  },
}
