import type { ExecutionContext } from 'hono'
import { Pool } from '@neondatabase/serverless'
import { drizzle } from 'drizzle-orm/neon-serverless'
import * as schema from './db/schema'
import { createAuth } from './auth/create-auth'
import { createApp } from './app'
import { resolveAndFetchFeatures } from './enrich/reccobeats'
import { fetchLyrics } from './enrich/lrclib'
import { workersAiEmbedder } from './enrich/embedder'
import type { EnrichDeps } from './enrich/pipeline'
import type { Db } from './db/types'
import { handleScheduled } from './enrich/scheduled'

// Minimal structural stand-in for the platform's ScheduledController — this
// project's tsconfig doesn't pull in @cloudflare/workers-types, so the real
// global type isn't available; only the two fields used below are declared.
type ScheduledController = { cron: string; scheduledTime: number }

type Bindings = {
  DATABASE_URL: string
  BETTER_AUTH_SECRET: string
  BETTER_AUTH_URL: string
  APPLE_BUNDLE_ID: string
  ENRICH_ADMIN_TOKEN?: string
  ITUNES_STOREFRONT?: string
  AI?: { run(model: string, input: { text: string[] }): Promise<unknown> }
}

// neon-http (a single fetch() per query) can't run transactions at all — the
// queue store's SELECT ... FOR UPDATE needs a real session-scoped connection,
// so this switched to neon-serverless's Pool (a real libpq-over-WebSocket
// connection). The pool is per-request/per-invocation, not module-scoped: a
// Worker isolate can be reused across otherwise-unrelated requests, and
// stashing a live connection on a global would leak it across them.
function buildDb(env: Bindings): { db: Db; pool: Pool } {
  if (!env.DATABASE_URL) throw new Error('DATABASE_URL is required')
  const pool = new Pool({ connectionString: env.DATABASE_URL })
  return { db: drizzle(pool, { schema }), pool }
}

// No AI binding → no deps to enrich with, for either surface (route or cron).
function buildDeps(env: Bindings): EnrichDeps | undefined {
  if (!env.AI) return undefined
  return {
    storefront: env.ITUNES_STOREFRONT ?? 'ng',
    // Apple 403s iTunes API calls from Cloudflare IPs (verified live, UA-independent).
    // Duration comes from the ReccoBeats match writeback; genre arrives with the
    // library sync. lookupItunes stays for local/P2.5 use.
    itunes: async () => null,
    features: resolveAndFetchFeatures,
    lyrics: fetchLyrics,
    embed: workersAiEmbedder(env.AI),
  }
}

export default {
  async fetch(req: Request, env: Bindings, ctx: ExecutionContext) {
    const { db, pool } = buildDb(env)
    const auth = createAuth(db, env)
    const deps = buildDeps(env)
    // /enrich/* is only mounted when both an admin token and the AI binding
    // are configured. No AI binding → no enrich surface: better a 404 than
    // every track burning 3 'internal: TypeError' attempts.
    const enrich = deps && env.ENRICH_ADMIN_TOKEN ? { adminToken: env.ENRICH_ADMIN_TOKEN, deps } : undefined
    const app = createApp({ auth, db, enrich })
    const res = await app.fetch(req, env, ctx)
    // Closes the pool's socket(s) after the response is built rather than
    // blocking on it — waitUntil keeps the isolate alive just long enough to
    // flush the close, without holding up the response itself.
    ctx.waitUntil(pool.end())
    return res
  },
  async scheduled(_event: ScheduledController, env: Bindings, ctx: ExecutionContext) {
    const deps = buildDeps(env)
    if (!deps) return // no AI binding: nothing to enrich with
    const { db, pool } = buildDb(env)
    // Counts only — no track data, no lyric/embedding content.
    console.log('enrich cron', JSON.stringify(await handleScheduled(db, deps)))
    ctx.waitUntil(pool.end())
  },
}
