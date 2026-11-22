import type { ExecutionContext } from 'hono'
import { DurableObject, type DurableObjectState } from 'cloudflare:workers'
import { Pool } from '@neondatabase/serverless'
import { drizzle } from 'drizzle-orm/neon-serverless'
import * as schema from './db/schema'
import { createAuth, generateAppleClientSecret, parseWebOrigins } from './auth/create-auth'
import type { AppleRevokeDeps } from './auth/apple-revoke'
import { createApp } from './app'
import { resolveAndFetchFeatures } from './enrich/reccobeats'
import { fetchTracksBySpotifyIds, fetchAudioFeaturesBySpotifyIds } from './enrich/reccobeats-by-id'
import { fetchLyrics } from './enrich/lrclib'
import { workersAiEmbedder } from './enrich/embedder'
import type { EnrichDeps } from './enrich/pipeline'
import type { Db } from './db/types'
import { handleScheduled, jobsForCron } from './enrich/scheduled'
import { anthropicLlm, anthropicComplete, buildAnthropic } from './dj/llm'
import { pauseOnBilling, probeAutoPause, tripAutoPause } from './dj/auto-pause'
import type { DjDeps } from './dj/loop'
import type { FillDeps } from './dj/catalogue-fill'
import { generateMusicKitDeveloperToken } from './musickit/token'
import {
  createAppleCatalogClient,
  createAppleCatalogTokenCache,
  type AppleCatalogAlbumClient,
  type AppleCatalogArtistClient,
  type AppleCatalogClient,
  type AppleCatalogSearchClient,
  type AppleCatalogSeedClient,
  type AppleIsrcCatalogClient,
  type FetchLike,
} from './musickit/catalog'
import type { MusicKitWiring, ShareRateLimiter, SharesWiring, TranscribeWiring } from './app'
import type { ArtworkDeps } from './artwork/runner'
import { createSpotifyOEmbedArtworkClient } from './artwork/spotify-oembed'
import { createDeezerArtworkClient } from './artwork/deezer'
import { createDeezerTempoClient } from './enrich/deezer-tempo'
import type { SpotifyArtworkDeps } from './artwork/spotify-fallback'
import type { PlaylistEditDjDeps } from './playlist-editing/loop'
import type { AlbumDeps } from './albums/loop'
import { TurnRunnerCore, type TurnRunnerNamespace } from './dj/turn-runner'
import type { TurnJob } from './dj/turn-job'
import { budgetedFetch, notifyTurn, SWEEP_PUSH_FETCH_BUDGET, turnPushEnabled, type PushConfig } from './push/notify'
import type { FetchLike as PushFetchLike } from './push/apns'

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
  GOOGLE_CLIENT_ID: string
  GOOGLE_CLIENT_SECRET: string
  GOOGLE_IOS_CLIENT_ID?: string
  MUSICKIT_KEY_ID?: string
  MUSICKIT_PRIVATE_KEY?: string
  WEB_ORIGINS: string
  ENRICH_ADMIN_TOKEN?: string
  ITUNES_STOREFRONT?: string
  AI?: { run(model: string, input: { text: string[] }): Promise<unknown> }
  ANTHROPIC_API_KEY?: string
  GROQ_API_KEY?: string
  ALBUM_PICKS?: string
  NEVER_REFUSE?: string
  PROPOSE_FIRST?: string
  AI_CONSENT?: string
  DJ_PAUSED?: string
  SHARE_BASE_URL?: string
  SHARE_READ_LIMITER?: ShareRateLimiter
  // Durable mix turns (spec 2026-11-21): the TurnRunner namespace and its
  // two switches, both exact-"on".
  TURN_RUNNER?: TurnRunnerNamespace
  DURABLE_TURNS?: string
  TURN_PUSH?: string
  // Mix-ready push (spec 2026-11-21 durable-mix-turns, "APNs from Workers",
  // "Web push"). Required once TURN_PUSH is on (buildPush). APPLE_TEAM_ID
  // above is the provider token's issuer; APNS_TOPIC defaults to
  // APPLE_BUNDLE_ID.
  APNS_KEY_ID?: string
  APNS_PRIVATE_KEY?: string
  APNS_TOPIC?: string
  VAPID_PUBLIC_KEY?: string
  VAPID_PRIVATE_KEY?: string
  VAPID_SUBJECT?: string
}

// This cache holds signed server tokens only. The key is the non-secret Apple
// team/key identity, so separately constructed request/cron wiring can reuse a
// still-valid token without retaining the private key or any request data.
const serverCatalogTokenCache = createAppleCatalogTokenCache()

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
    spotify: { tracks: fetchTracksBySpotifyIds, features: fetchAudioFeaturesBySpotifyIds },
    lyrics: fetchLyrics,
    embed: workersAiEmbedder(env.AI),
  }
}

// Album picks (plan 2026-10-20, Phase 1): listeners may ask the DJ for one
// album. Only the exact string "on" enables it, so a typo or a missing var
// is the safe default, off.
export function albumPicksEnabled(env: { ALBUM_PICKS?: string }): boolean {
  return env.ALBUM_PICKS === 'on'
}

// Never refuse (spec 2026-10-21 everyone-gets-a-mix, step 4): a listener
// with too few seeds gets songs the DJ proposes, verified on Apple, instead
// of a refusal. Same exact-"on" rule as album picks.
// Plan 2026-11-02 AI consent: 'enforce' refuses AI routes to listeners who
// have not agreed. Anything else is off.
export function aiConsentMode(env: { AI_CONSENT?: string }): 'off' | 'enforce' {
  return env.AI_CONSENT === 'enforce' ? 'enforce' : 'off'
}

// DJ paused (2026-11-16): "on" refuses new mixes and changes to mixes and
// tells clients through /health, for when the model is unavailable to us
// (credits spent, an outage). Anything else is open.
export function djPausedMode(env: { DJ_PAUSED?: string }): boolean {
  return env.DJ_PAUSED === 'on'
}

export function neverRefuseEnabled(env: { NEVER_REFUSE?: string }): boolean {
  return env.NEVER_REFUSE === 'on'
}

// Propose first (spec 2026-11-16): personal mixes blend songs the DJ
// proposes from all of music, verified on Apple, and corpus mixes propose
// more of themselves. Same exact-"on" rule as album picks. On for everyone
// since 2026-11-17; "off" is the kill switch back to the pre-propose-first
// DJ.
export function proposeFirstEnabled(env: { PROPOSE_FIRST?: string }): boolean {
  return env.PROPOSE_FIRST === 'on'
}

// The album loop rides the DJ's model clients plus the Apple catalogue, so it
// exists only when the flag is on and both of those are configured; absent,
// createApp mounts no Listen later routes and album sessions are refused.
export function buildAlbumDeps(
  dj: DjDeps | undefined,
  musicKit: { catalog: AlbumDeps['catalog'] } | undefined,
  env: { ALBUM_PICKS?: string; ITUNES_STOREFRONT?: string },
): AlbumDeps | undefined {
  if (!albumPicksEnabled(env) || !dj || !musicKit) return undefined
  return {
    llm: dj.llm,
    embed: dj.embed,
    catalog: musicKit.catalog,
    defaultStorefront: env.ITUNES_STOREFRONT ?? 'ng',
    titleComplete: dj.titleComplete,
  }
}

// No ANTHROPIC_API_KEY (or no AI binding, for the intent embedder) → no dj
// deps. Same fail-loud-by-absence convention as buildDeps/enrich above:
// createApp only mounts /sessions/* when `dj` is present, so an unconfigured
// key means the route group 404s instead of every turn burning a request on
// a client that was never going to construct.
function buildDjDeps(env: Bindings, db: Db): DjDeps | undefined {
  if (!env.ANTHROPIC_API_KEY || !env.AI) return undefined
  const anthropic = buildAnthropic(env.ANTHROPIC_API_KEY)
  // Every model call this request makes (turns, curation, titles, album
  // picks, playlist edits) rides these two clients, so a billing refusal on
  // any of them trips the automatic DJ pause (dj/auto-pause.ts).
  const trip = () => tripAutoPause(db)
  return {
    llm: pauseOnBilling(anthropicLlm(anthropic), trip),
    embed: workersAiEmbedder(env.AI),
    // Same client, same env var — session titling (dj/title.ts) is gated on
    // the same ANTHROPIC_API_KEY the DJ loop already requires, no separate
    // config to fail-fast on.
    titleComplete: pauseOnBilling(anthropicComplete(anthropic), trip),
    neverRefuse: neverRefuseEnabled(env),
    proposeFirst: proposeFirstEnabled(env),
  }
}

// The DJ's catalogue fill (dj/catalogue-fill.ts) needs the Apple catalogue
// and the enrichment sources. Its ReccoBeats and LRCLIB calls go through a
// fetch that counts, per request, so the fill charges its subrequest budget
// what those calls actually fetched. The same ReccoBeats fetch and a Deezer
// tempo client serve the per-turn feature chain on verified proposals.
export function buildFillDeps(
  env: Pick<Bindings, 'AI' | 'ITUNES_STOREFRONT'>,
  musicKit: { catalog: FillDeps['catalog'] } | undefined,
  fetchLike: FetchLike = fetch,
): FillDeps | undefined {
  if (!env.AI || !musicKit) return undefined
  let fetches = 0
  const counted: FetchLike = (url, init) => {
    fetches += 1
    return fetchLike(url, init)
  }
  const storefront = env.ITUNES_STOREFRONT ?? 'ng'
  return {
    catalog: musicKit.catalog,
    defaultStorefront: storefront,
    enrich: {
      storefront,
      // Same as buildDeps: Apple 403s iTunes calls from Cloudflare.
      itunes: async () => null,
      features: (key) => resolveAndFetchFeatures(key, counted),
      lyrics: (key) => fetchLyrics(key, counted),
      embed: workersAiEmbedder(env.AI),
    },
    enrichFetches: () => fetches,
    // The per-turn feature chain's tempo fallback, on the same fetch as the
    // artwork Deezer client (uncounted: the chain charges its own worst case).
    deezerTempo: createDeezerTempoClient({ fetchLike }),
  }
}

export function buildMusicKit(
  env: {
    APPLE_TEAM_ID: string
    MUSICKIT_KEY_ID?: string
    MUSICKIT_PRIVATE_KEY?: string
  },
  allowedOrigins: string[],
  fetchLike: FetchLike = fetch,
): (MusicKitWiring & { catalog: AppleCatalogClient & AppleIsrcCatalogClient & AppleCatalogSearchClient & AppleCatalogAlbumClient & AppleCatalogArtistClient & AppleCatalogSeedClient }) | undefined {
  const keyId = env.MUSICKIT_KEY_ID
  const privateKey = env.MUSICKIT_PRIVATE_KEY

  if (!keyId && !privateKey) return undefined
  if (!keyId || !privateKey) {
    throw new Error('MUSICKIT_KEY_ID and MUSICKIT_PRIVATE_KEY must be configured together')
  }

  const issueServerToken = () =>
    generateMusicKitDeveloperToken({
      teamId: env.APPLE_TEAM_ID,
      keyId,
      privateKey,
    })

  return {
    allowedOrigins,
    issueDeveloperToken: (origin) =>
      generateMusicKitDeveloperToken({
        teamId: env.APPLE_TEAM_ID,
        keyId,
        privateKey,
        origin,
      }),
    catalog: createAppleCatalogClient({
      fetchLike,
      issueServerToken,
      tokenCache: serverCatalogTokenCache,
      tokenCacheKey: `${env.APPLE_TEAM_ID}:${keyId}`,
    }),
  }
}

// Checked explicitly (Workers has no NODE_ENV, so a missing key would otherwise
// just mean a mic that silently never transcribes) but scoped to this route:
// absent, POST /transcribe answers 503 and the rest of the API is untouched.
export function buildTranscribe(env: { GROQ_API_KEY?: string }): TranscribeWiring {
  if (!env.GROQ_API_KEY) console.error('GROQ_API_KEY is missing — POST /transcribe will answer 503')
  return { apiKey: env.GROQ_API_KEY || undefined }
}

function buildArtworkDeps(
  env: Pick<Bindings, 'ITUNES_STOREFRONT'>,
  musicKit: (MusicKitWiring & { catalog: AppleCatalogClient }) | undefined,
): ArtworkDeps | undefined {
  if (!musicKit) return undefined
  return {
    storefront: env.ITUNES_STOREFRONT ?? 'ng',
    catalog: musicKit.catalog,
  }
}

function buildPlaylistEditingDeps(
  dj: DjDeps | undefined,
  musicKit: (MusicKitWiring & { catalog: AppleCatalogClient & AppleIsrcCatalogClient & AppleCatalogSearchClient }) | undefined,
): PlaylistEditDjDeps | undefined {
  return dj && musicKit ? { llm: dj.llm, catalog: musicKit.catalog } : undefined
}

export function buildSpotifyArtworkDeps(fetchLike: FetchLike = fetch): SpotifyArtworkDeps {
  return {
    spotify: createSpotifyOEmbedArtworkClient({ fetchLike }),
    // Deezer is only attempted after a valid oEmbed miss and only by exact
    // public ISRC. Its response is never accepted as a track identity write.
    deezer: createDeezerArtworkClient({ fetchLike }),
  }
}

// Shared mixes (spec 2026-11-13). Both are required: Workers has no NODE_ENV,
// so a missing limiter must not quietly mean an unlimited public read, and a
// missing base URL must not mint links to nowhere. Thrown here, every request
// fails until wrangler.jsonc is fixed, rather than running without them.
export function buildShares(env: { SHARE_BASE_URL?: string; SHARE_READ_LIMITER?: ShareRateLimiter }): SharesWiring {
  const raw = env.SHARE_BASE_URL?.trim()
  if (!raw) throw new Error('SHARE_BASE_URL is required')
  let parsed: URL
  try {
    parsed = new URL(raw)
  } catch {
    throw new Error('SHARE_BASE_URL must be an absolute URL')
  }
  if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') throw new Error('SHARE_BASE_URL must be an http(s) URL')
  if (!env.SHARE_READ_LIMITER || typeof env.SHARE_READ_LIMITER.limit !== 'function') {
    throw new Error('SHARE_READ_LIMITER rate-limit binding is required')
  }
  return { baseUrl: raw.replace(/\/+$/, ''), limiter: env.SHARE_READ_LIMITER }
}

// Durable mix turns (spec 2026-11-21 durable-mix-turns): "on" runs mix
// turns in the TurnRunner Durable Object instead of on the request. Same
// exact-"on" rule as album picks.
export function durableTurnsEnabled(env: { DURABLE_TURNS?: string }): boolean {
  return env.DURABLE_TURNS === 'on'
}

// With the switch on, the binding is required: thrown here, every request
// fails until wrangler.jsonc is fixed (the buildShares pattern), rather than
// quietly running turns on the request. Off, there is nothing to wire.
export function buildDurableTurns(env: { DURABLE_TURNS?: string; TURN_RUNNER?: TurnRunnerNamespace }): { runner: TurnRunnerNamespace } | undefined {
  if (!durableTurnsEnabled(env)) return undefined
  if (!env.TURN_RUNNER || typeof env.TURN_RUNNER.idFromName !== 'function') {
    throw new Error('TURN_RUNNER durable object binding is required when DURABLE_TURNS is on')
  }
  return { runner: env.TURN_RUNNER }
}

// Mix-ready push (spec 2026-11-21 durable-mix-turns). TURN_PUSH exact "on"
// sends; with it on, every key is required: thrown here, every request fails
// until wrangler.jsonc and the secrets are fixed (the buildShares pattern),
// rather than quietly telling clients `push: true` and never pushing. Off,
// notify records 'off' and nothing is read.
export function buildPush(env: {
  TURN_PUSH?: string
  APPLE_TEAM_ID?: string
  APPLE_BUNDLE_ID?: string
  APNS_KEY_ID?: string
  APNS_PRIVATE_KEY?: string
  APNS_TOPIC?: string
  VAPID_PUBLIC_KEY?: string
  VAPID_PRIVATE_KEY?: string
  VAPID_SUBJECT?: string
}): PushConfig {
  if (!turnPushEnabled(env)) return { enabled: false }
  const required = ['APPLE_TEAM_ID', 'APNS_KEY_ID', 'APNS_PRIVATE_KEY', 'VAPID_PUBLIC_KEY', 'VAPID_PRIVATE_KEY', 'VAPID_SUBJECT'] as const
  for (const name of required) {
    if (!env[name]?.trim()) throw new Error(`${name} is required when TURN_PUSH is on`)
  }
  const topic = (env.APNS_TOPIC ?? env.APPLE_BUNDLE_ID)?.trim()
  if (!topic) throw new Error('APNS_TOPIC or APPLE_BUNDLE_ID is required when TURN_PUSH is on')
  const subject = env.VAPID_SUBJECT!.trim()
  if (!/^(mailto:|https:)/.test(subject)) throw new Error('VAPID_SUBJECT must be a mailto: or https: URL')
  return {
    enabled: true,
    apns: { teamId: env.APPLE_TEAM_ID!.trim(), keyId: env.APNS_KEY_ID!.trim(), privateKey: env.APNS_PRIVATE_KEY!, topic },
    vapid: { publicKey: env.VAPID_PUBLIC_KEY!.trim(), privateKey: env.VAPID_PRIVATE_KEY!.trim(), subject },
  }
}

// notifyTurn as the object and the cron call it, over their database.
// `fetch`: the cron's budgeted one (SWEEP_PUSH_FETCH_BUDGET a run).
export function pushNotifier(env: Parameters<typeof buildPush>[0], { fetch }: { fetch?: PushFetchLike } = {}) {
  return (db: Db, turnId: string, opts: { recheck?: boolean; scheduleRecheck?: (ms: number) => void } = {}) =>
    notifyTurn(
      { db, config: buildPush(env), ...(fetch ? { fetch } : {}), ...(opts.scheduleRecheck ? { scheduleRecheck: opts.scheduleRecheck } : {}) },
      turnId,
      { recheck: opts.recheck === true },
    )
}

// Plan 2026-11-02 account deletion: the same Sign in with Apple key that signs
// the web client secret signs one for whichever client a token belongs to.
// createAuth has already failed fast on a missing Apple binding.
function buildAppleRevoke(env: Bindings): AppleRevokeDeps {
  return {
    bundleId: env.APPLE_BUNDLE_ID,
    webClientId: env.APPLE_WEB_CLIENT_ID,
    clientSecret: (clientId) => generateAppleClientSecret({
      clientId,
      teamId: env.APPLE_TEAM_ID,
      keyId: env.APPLE_KEY_ID,
      privateKey: env.APPLE_PRIVATE_KEY,
    }),
  }
}

// The request's ExecutionContext with every waitUntil promise recorded in
// `recorded` and forwarded to the platform. Everything else is the
// platform's own member, methods bound to it (the runtime's methods refuse
// another `this`), so passThroughOnException, props and whatever the runtime
// adds keep working.
function recordingContext(ctx: ExecutionContext, recorded: Promise<unknown>[]): ExecutionContext {
  return new Proxy(ctx, {
    get(target, prop) {
      if (prop === 'waitUntil') {
        return (promise: Promise<unknown>) => {
          recorded.push(promise)
          target.waitUntil(promise)
        }
      }
      const value: unknown = Reflect.get(target, prop, target)
      return typeof value === 'function' ? value.bind(target) : value
    },
  })
}

/**
 * Runs one request with its Neon pool, and ends the pool once the request
 * is done with it (spec 2026-11-13 dj-turn-steps, "Pool lifetime"). A
 * streamed turn returns its Response at once and hands the turn to
 * waitUntil (routes/turn-stream.ts), so ending the pool when `handle`
 * returns would close it under the running turn: the pool ends only after
 * every promise the request handed to waitUntil has settled. A request that
 * recorded none ends it at once, as before. A promise handed to waitUntil
 * after `handle` returned is not waited for: nothing does that today.
 */
export async function withRequestPool<T>(
  ctx: ExecutionContext,
  pool: { end(): Promise<void> },
  handle: (ctx: ExecutionContext) => Promise<T>,
): Promise<T> {
  const recorded: Promise<unknown>[] = []
  // try/finally rather than a bare sequential call: buildDeps/createAuth/
  // createApp or app.fetch itself throwing must still close the pool —
  // otherwise a bad request (or a misconfigured binding) leaks a socket on
  // every failure instead of just the happy path.
  try {
    return await handle(recordingContext(ctx, recorded))
  } finally {
    // Closes the pool's socket(s) after the response is built rather than
    // blocking on it — waitUntil keeps the isolate alive just long enough to
    // flush the close, without holding up the response itself.
    ctx.waitUntil(recorded.length === 0 ? pool.end() : Promise.allSettled(recorded).then(() => pool.end()))
  }
}

// What one request is wired from: its database with the pool to end, and
// the app over that database. Production passes buildDb and buildRequestApp;
// tests pass their own, so the wiring below is the code under test.
export type FetchWiring<E> = {
  openDb: (env: E) => { db: Db; pool: { end(): Promise<void> } }
  buildApp: (db: Db, env: E) => { fetch: (req: Request, env: E, ctx: ExecutionContext) => Response | Promise<Response> }
}

// The fetch handler. The app gets the recording context, never the
// platform's own: that is what keeps the pool open under a streamed turn.
export function serveFetch<E>(req: Request, env: E, ctx: ExecutionContext, wiring: FetchWiring<E>): Promise<Response> {
  const { db, pool } = wiring.openDb(env)
  return withRequestPool(ctx, pool, async (requestCtx) => wiring.buildApp(db, env).fetch(req, env, requestCtx))
}

// How a mix turn is wired: the DJ's model clients, its catalogue fill and
// the Apple catalogue under both. The request path and the durable turn
// (TurnRunner below, spec 2026-11-21 durable-mix-turns, "Run (object side)")
// both build their DJ here, so a turn runs the same wherever it runs. The
// fill's subrequest counter is per call, so per request or per alarm. The
// MusicKit wiring is returned too, for the request's other routes.
export function buildTurnDeps(env: Bindings, db: Db, allowedOrigins: string[] = parseWebOrigins(env.WEB_ORIGINS)) {
  const musicKit = buildMusicKit(env, allowedOrigins)
  const baseDjDeps = buildDjDeps(env, db)
  const fill = buildFillDeps(env, musicKit)
  const djDeps: DjDeps | undefined = baseDjDeps && fill ? { ...baseDjDeps, fill } : baseDjDeps
  return { djDeps, musicKit }
}

function buildRequestApp(db: Db, env: Bindings) {
  const auth = createAuth(db, env)
  const allowedOrigins = parseWebOrigins(env.WEB_ORIGINS)
  const deps = buildDeps(env)
  const { djDeps, musicKit } = buildTurnDeps(env, db, allowedOrigins)
  const dj = djDeps ? { deps: djDeps } : undefined
  const playlistEditingDeps = buildPlaylistEditingDeps(djDeps, musicKit)
  const playlistEditing = playlistEditingDeps ? { deps: playlistEditingDeps } : undefined
  const albumDeps = buildAlbumDeps(djDeps, musicKit, env)
  const albums = albumDeps ? { deps: albumDeps } : undefined
  const artwork = buildArtworkDeps(env, musicKit)
  const seed = musicKit ? { catalog: musicKit.catalog } : undefined
  const enrich = env.ENRICH_ADMIN_TOKEN && (deps || artwork || seed)
    ? { adminToken: env.ENRICH_ADMIN_TOKEN, deps, artwork, seed }
    : undefined
  const transcribe = buildTranscribe(env)
  const accountDeletion = { apple: buildAppleRevoke(env) }
  const shares = buildShares(env)
  // Checked on every request so a missing binding fails loudly.
  const durable = buildDurableTurns(env)
  const durableTurns = durable ? { ...durable, push: { TURN_PUSH: env.TURN_PUSH } } : undefined
  // Checked on every request too, so TURN_PUSH on with a key missing fails loudly.
  const push = buildPush(env)
  const vapidPublicKey = push.enabled ? push.vapid?.publicKey : undefined
  return createApp({ auth, db, enrich, dj, albums, playlistEditing, musicKit, transcribe, accountDeletion, shares, aiConsent: aiConsentMode(env), djPaused: djPausedMode(env), durableTurns, vapidPublicKey, allowedOrigins })
}

// The Durable Object the platform instantiates, one per session (spec
// 2026-11-21 durable-mix-turns, "Run (object side)"; wrangler.jsonc binds it
// as TURN_RUNNER). A few lines over TurnRunnerCore (dj/turn-runner.ts),
// which Node tests drive with a fake storage and alarm: this only hands it
// the object's storage and the same wiring the request path uses.
export class TurnRunner extends DurableObject<Bindings> {
  private readonly core: TurnRunnerCore

  constructor(ctx: DurableObjectState, env: Bindings) {
    super(ctx, env)
    this.core = new TurnRunnerCore({
      storage: ctx.storage,
      setAlarm: (at) => ctx.storage.setAlarm(at),
      openDb: () => buildDb(env),
      buildDeps: (db) => buildTurnDeps(env, db).djDeps,
      notify: pushNotifier(env),
    })
  }

  start(job: TurnJob) {
    return this.core.start(job)
  }

  async alarm(): Promise<void> {
    await this.core.alarm()
  }

  fetch(req: Request): Promise<Response> {
    return this.core.fetch(req)
  }
}

export default {
  async fetch(req: Request, env: Bindings, ctx: ExecutionContext) {
    return serveFetch(req, env, ctx, { openDb: buildDb, buildApp: buildRequestApp })
  },
  async scheduled(event: ScheduledController, env: Bindings, ctx: ExecutionContext) {
    // Dispatch before any wiring so an unrecognised trigger opens no pool.
    const jobs = jobsForCron(event.cron)
    if (!jobs) {
      console.log('maintenance cron', JSON.stringify({ jobs: 'unknown' }))
      return
    }
    const deps = buildDeps(env)
    const musicKit = buildMusicKit(env, [])
    const artwork = buildArtworkDeps(env, musicKit)
    const spotifyArtwork = buildSpotifyArtworkDeps()
    const { db, pool } = buildDb(env)
    try {
      // Counts and fixed failure markers only — no track/playlist data, Apple payloads,
      // lyric/embedding content, tokens, or exception messages.
      console.log('maintenance cron', JSON.stringify({ jobs, ...await handleScheduled(db, jobs, {
        enrichment: deps,
        artwork,
        appleIsrc: musicKit
          ? { catalog: musicKit.catalog, defaultStorefront: env.ITUNES_STOREFRONT ?? 'ng' }
          : undefined,
        spotifyArtwork,
        // Lost durable turns (dj/turn-sweep.ts): swept whatever DURABLE_TURNS
        // says, so a turn left behind by a flip back to off still ends.
        // A lost turn's watched_result is false, so it pushes at once.
        // Its pushes share this run's subrequests: one budget for all of them.
        turns: (() => {
          const notify = pushNotifier(env, { fetch: budgetedFetch(SWEEP_PUSH_FETCH_BUDGET) })
          return { notify: async (turnDb: Db, turn: { turnId: string }) => void (await notify(turnDb, turn.turnId)) }
        })(),
      }) }))
      // While the DJ is paused for billing, one tiny call per run checks
      // whether credits are back and reopens it (dj/auto-pause.ts).
      if (env.ANTHROPIC_API_KEY) {
        try {
          const djPause = await probeAutoPause(db, anthropicComplete(buildAnthropic(env.ANTHROPIC_API_KEY)))
          if (djPause !== 'open') console.log('dj auto-pause probe', JSON.stringify({ djPause }))
        } catch {
          console.error('dj auto-pause probe failed')
        }
      }
    } finally {
      ctx.waitUntil(pool.end())
    }
  },
}
