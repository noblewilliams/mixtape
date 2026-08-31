import type { ExecutionContext } from 'hono'
import { Pool } from '@neondatabase/serverless'
import { drizzle } from 'drizzle-orm/neon-serverless'
import * as schema from './db/schema'
import { createAuth, parseWebOrigins } from './auth/create-auth'
import { createApp } from './app'
import { resolveAndFetchFeatures } from './enrich/reccobeats'
import { fetchLyrics } from './enrich/lrclib'
import { workersAiEmbedder } from './enrich/embedder'
import type { EnrichDeps } from './enrich/pipeline'
import type { Db } from './db/types'
import { handleScheduled } from './enrich/scheduled'
import { anthropicLlm, anthropicComplete, buildAnthropic } from './dj/llm'
import type { DjDeps } from './dj/loop'
import { generateMusicKitDeveloperToken } from './musickit/token'
import type { MusicKitWiring } from './app'

// Minimal structural stand-in for the platform's ScheduledController — this
// project's tsconfig doesn't pull in @cloudflare/workers-types, so the real
// global type isn't available; only the two fields used below are declared.
type ScheduledController = { cron: string; scheduledTime: number }

type Bindings = {
  DATABASE_URL: string
  BETTER_AUTH_SECRET: string
  BETTER_AUTH_URL: string
  APPLE_BUNDLE_ID: string
  APPLE_WEB_CLIENT_ID: string
  APPLE_TEAM_ID: string
  APPLE_KEY_ID: string
  APPLE_PRIVATE_KEY: string
  MUSICKIT_KEY_ID?: string
  MUSICKIT_PRIVATE_KEY?: string
  WEB_ORIGINS: string
  ENRICH_ADMIN_TOKEN?: string
  ITUNES_STOREFRONT?: string
  AI?: { run(model: string, input: { text: string[] }): Promise<unknown> }
  ANTHROPIC_API_KEY?: string
}

// neon-http (a single fetch() per query) can't run transactions at all — the
// queue store's SELECT ... FOR UPDATE needs a real session-scoped connection,
// so this switched to neon-serverless's Pool (a real libpq-over-WebSocket
// connection). The pool is per-request/per-invocation, not module-scoped: a
// Worker isolate can be reused across otherwise-unrelated requests, and
// stashing a live connection on a global would leak it across them.
function buildDb(env: Bindings): { db: Db; pool: Pool } {
  if (!env.DATABASE_URL) throw new Error('DATABASE_URL is required')
  // A single request needs at most two concurrent connections at once — its
  // own transaction (queue store's SELECT ... FOR UPDATE) plus one more
  // concurrent query (e.g. the dj loop's buildPool running alongside
  // something else) — so cap the pool at 2 rather than the client default,
  // which would let one Worker invocation hold far more sockets than it can
  // ever actually use concurrently.
  const pool = new Pool({ connectionString: env.DATABASE_URL, max: 2 })
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

// No ANTHROPIC_API_KEY (or no AI binding, for the intent embedder) → no dj
// deps. Same fail-loud-by-absence convention as buildDeps/enrich above:
// createApp only mounts /sessions/* when `dj` is present, so an unconfigured
// key means the route group 404s instead of every turn burning a request on
// a client that was never going to construct.
function buildDjDeps(env: Bindings): DjDeps | undefined {
  if (!env.ANTHROPIC_API_KEY || !env.AI) return undefined
  const anthropic = buildAnthropic(env.ANTHROPIC_API_KEY)
  return {
    llm: anthropicLlm(anthropic),
    embed: workersAiEmbedder(env.AI),
    // Same client, same env var — session titling (dj/title.ts) is gated on
    // the same ANTHROPIC_API_KEY the DJ loop already requires, no separate
    // config to fail-fast on.
    titleComplete: anthropicComplete(anthropic),
  }
}

function buildMusicKit(env: Bindings, allowedOrigins: string[]): MusicKitWiring | undefined {
  const keyId = env.MUSICKIT_KEY_ID
  const privateKey = env.MUSICKIT_PRIVATE_KEY

  if (!keyId && !privateKey) return undefined
  if (!keyId || !privateKey) {
    throw new Error('MUSICKIT_KEY_ID and MUSICKIT_PRIVATE_KEY must be configured together')
  }

  return {
    allowedOrigins,
    issueDeveloperToken: (origin) =>
      generateMusicKitDeveloperToken({
        teamId: env.APPLE_TEAM_ID,
        keyId,
        privateKey,
        origin,
      }),
  }
}

export default {
  async fetch(req: Request, env: Bindings, ctx: ExecutionContext) {
    const { db, pool } = buildDb(env)
    // try/finally rather than a bare sequential call: buildDeps/createAuth/
    // createApp or app.fetch itself throwing must still close the pool —
    // otherwise a bad request (or a misconfigured binding) leaks a socket on
    // every failure instead of just the happy path.
    try {
      const auth = createAuth(db, env)
      const allowedOrigins = parseWebOrigins(env.WEB_ORIGINS)
      const deps = buildDeps(env)
      // /enrich/* is only mounted when both an admin token and the AI binding
      // are configured. No AI binding → no enrich surface: better a 404 than
      // every track burning 3 'internal: TypeError' attempts.
      const enrich = deps && env.ENRICH_ADMIN_TOKEN ? { adminToken: env.ENRICH_ADMIN_TOKEN, deps } : undefined
      const djDeps = buildDjDeps(env)
      const dj = djDeps ? { deps: djDeps } : undefined
      const musicKit = buildMusicKit(env, allowedOrigins)
      const app = createApp({ auth, db, enrich, dj, musicKit, allowedOrigins })
      return await app.fetch(req, env, ctx)
    } finally {
      // Closes the pool's socket(s) after the response is built rather than
      // blocking on it — waitUntil keeps the isolate alive just long enough to
      // flush the close, without holding up the response itself.
      ctx.waitUntil(pool.end())
    }
  },
  async scheduled(_event: ScheduledController, env: Bindings, ctx: ExecutionContext) {
    const deps = buildDeps(env)
    if (!deps) return // no AI binding: nothing to enrich with
    const { db, pool } = buildDb(env)
    try {
      // Counts only — no track data, no lyric/embedding content.
      console.log('enrich cron', JSON.stringify(await handleScheduled(db, deps)))
    } finally {
      ctx.waitUntil(pool.end())
    }
  },
}
