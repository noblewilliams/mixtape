/**
 * drain-enrichment: clears a fresh import's enrichment backlog by calling the
 * deployed Worker's admin `POST /enrich/run` in a loop, one batch per call.
 * Each call is its own invocation with its own free-plan budget, and the
 * database stays awake only while this runs.
 *
 * Usage (from server/):  npm run drain-enrichment -- --max <tracks> [--delay-ms 4000]
 * Reads ENRICH_ADMIN_TOKEN from the environment, else from .dev.vars
 * (scripts/lib/dev-vars.ts). Targets DJ_BASE, else the deployed Worker, as
 * scripts/dj-chat.ts does. Founder-run only; nothing runs it automatically.
 *
 * Stops at --max tracks, when a call processes nothing, when nothing remains,
 * when what remains is only tracks cooling down after provider errors (a
 * clean stop: nothing is eligible right now, the hourly cron picks them up
 * once their backoff passes), when two calls in a row process tracks with no
 * stage succeeding, or one such call that leaves nothing due (a provider
 * looks down; carrying on would only spend attempts on the next tracks while
 * the failed ones cool down), or on any
 * error. --delay-ms is at least 1000. Prints running counts only: never the token, the base URL,
 * or a response or exception text.
 */
import { pathToFileURL } from 'node:url'
import { resolve } from 'node:path'
import { MAX_BATCH } from '../src/routes/enrich'
import { loadDevVars } from './lib/dev-vars'

const DEFAULT_BASE = 'https://mixtape-api.goalympics.workers.dev'
export const DEFAULT_DELAY_MS = 4000
export const MIN_DELAY_MS = 1000
export const PROVIDER_DOWN_MESSAGE =
  'stopped: calls enriched nothing, so a provider looks down. Nothing more was attempted. '
  + 'Only tracks that hit a temporary provider error retry after their backoff; other failures used up an attempt.'
export const COOLING_MESSAGE =
  'stopped: nothing eligible right now. The tracks left are cooling down after provider errors and retry after their backoff.'

type FetchLike = (url: string | URL, init?: RequestInit) => Promise<Response>

export type DrainArgs = { max: number; delayMs: number }

function nonNegativeInt(raw: string | undefined): number | null {
  return raw !== undefined && /^\d+$/.test(raw) ? Number(raw) : null
}

export function parseDrainArgs(argv: string[]): DrainArgs {
  let max: number | null = null
  let delayMs = DEFAULT_DELAY_MS
  for (let i = 0; i < argv.length; i++) {
    const flag = argv[i]
    if (flag === '--max') {
      max = nonNegativeInt(argv[++i])
      if (!max) throw new Error('--max must be a positive integer')
    } else if (flag === '--delay-ms') {
      const value = nonNegativeInt(argv[++i])
      if (value === null || value < MIN_DELAY_MS) throw new Error(`--delay-ms must be an integer of at least ${MIN_DELAY_MS}`)
      delayMs = value
    } else {
      throw new Error('unknown argument; usage: --max <tracks> [--delay-ms <ms>]')
    }
  }
  if (!max) throw new Error('--max <tracks> is required')
  return { max, delayMs }
}

// HTTPS, or HTTP to loopback for a local worker; no credentials, query or
// fragment. Errors are fixed text and never echo the value.
export function resolveBase(raw: string): string {
  let url: URL
  try {
    url = new URL(raw)
  } catch {
    throw new Error('API base is not a valid URL')
  }
  const loopback = ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname)
  const safeTransport = url.protocol === 'https:' || (url.protocol === 'http:' && loopback)
  if (!safeTransport || url.username || url.password || raw.includes('?') || raw.includes('#')) {
    throw new Error('API base must use HTTPS or loopback HTTP without credentials, query, or fragment')
  }
  return raw.replace(/\/+$/, '')
}

export type DrainResult = {
  processed: number
  features: number
  meaning: number
  calls: number
  stopped: 'max' | 'empty' | 'drained' | 'cooling' | 'provider-down' | 'error'
}

type Batch = { processed: number; features: number; meaning: number; remaining: number; cooling: number }

const count = (v: unknown) => Number.isInteger(v) && (v as number) >= 0

// cooling is optional so a Worker deployed before it existed still drains.
function parseBatch(body: unknown): Batch | null {
  if (!body || typeof body !== 'object') return null
  const b = body as Record<string, unknown>
  const fields = ['processed', 'features', 'meaning', 'remaining'] as const
  if (!fields.every((key) => count(b[key]))) return null
  if (b.cooling !== undefined && !count(b.cooling)) return null
  return {
    processed: b.processed as number, features: b.features as number, meaning: b.meaning as number,
    remaining: b.remaining as number, cooling: (b.cooling as number | undefined) ?? 0,
  }
}

export async function drain(opts: DrainArgs & {
  base: string
  token: string
  fetchLike?: FetchLike
  sleep?: (ms: number) => Promise<void>
  log?: (line: string) => void
}): Promise<DrainResult> {
  const fetchLike = opts.fetchLike ?? fetch
  const sleep = opts.sleep ?? ((ms: number) => new Promise<void>((done) => setTimeout(done, ms)))
  const log = opts.log ?? ((line: string) => console.log(line))
  const result: DrainResult = { processed: 0, features: 0, meaning: 0, calls: 0, stopped: 'max' }
  let fruitless = 0

  while (result.processed < opts.max) {
    if (result.calls > 0) await sleep(opts.delayMs)
    // The route clamps to its own MAX_BATCH too, so --max is never exceeded
    // even if the deployed ceiling differs from this checkout's.
    const limit = Math.min(MAX_BATCH, opts.max - result.processed)
    result.calls++
    let batch: Batch | null
    try {
      const res = await fetchLike(`${opts.base}/enrich/run?limit=${limit}`, {
        method: 'POST',
        headers: { 'X-Admin-Token': opts.token },
      })
      if (!res.ok) {
        await res.body?.cancel().catch(() => undefined)
        log(`call=${result.calls} stopped: HTTP ${res.status}`)
        return { ...result, stopped: 'error' }
      }
      batch = parseBatch(await res.json().catch(() => null))
    } catch {
      log(`call=${result.calls} stopped: request failed`)
      return { ...result, stopped: 'error' }
    }
    if (!batch) {
      log(`call=${result.calls} stopped: malformed response`)
      return { ...result, stopped: 'error' }
    }
    result.processed += batch.processed
    result.features += batch.features
    result.meaning += batch.meaning
    log(`call=${result.calls} processed=${batch.processed} total=${result.processed}/${opts.max} `
      + `features=${result.features} meaning=${result.meaning} remaining=${batch.remaining} cooling=${batch.cooling}`)
    const enrichedNothing = batch.processed > 0 && batch.features === 0 && batch.meaning === 0
    // remaining counts only tracks due now; cooling ones are not, so once
    // nothing is due the drain is done for now rather than failed. Unless
    // this very call processed tracks and enriched none: that is the
    // provider-down case, and it must not exit 0.
    const nothingDue = batch.processed === 0 || batch.remaining === 0
    if (nothingDue && batch.cooling > 0) {
      if (enrichedNothing) {
        log(PROVIDER_DOWN_MESSAGE)
        return { ...result, stopped: 'provider-down' }
      }
      log(COOLING_MESSAGE)
      return { ...result, stopped: 'cooling' }
    }
    if (batch.processed === 0) return { ...result, stopped: 'empty' }
    // features and meaning are the route's per-stage ok counts. Tracks taken
    // with neither stage succeeding spend an attempt each; a provider error
    // also puts them on backoff, so the next call takes different tracks.
    fruitless = enrichedNothing ? fruitless + 1 : 0
    if (fruitless >= 2) {
      log(PROVIDER_DOWN_MESSAGE)
      return { ...result, stopped: 'provider-down' }
    }
    if (batch.remaining === 0) return { ...result, stopped: 'drained' }
  }
  return result
}

// Everything main needs, resolved up front. Every error here is fixed text
// that names the problem and never echoes the token or the base URL.
export function prepareDrain(
  argv: string[],
  env: { ENRICH_ADMIN_TOKEN?: string; DJ_BASE?: string },
  readDevVars: () => Record<string, string> = loadDevVars,
): DrainArgs & { base: string; token: string } {
  const args = parseDrainArgs(argv)
  let token = env.ENRICH_ADMIN_TOKEN
  if (!token) {
    try {
      token = readDevVars().ENRICH_ADMIN_TOKEN
    } catch {
      // Missing .dev.vars falls through to the fixed message below.
    }
  }
  if (!token) throw new Error('ENRICH_ADMIN_TOKEN is required (environment or .dev.vars)')
  const base = resolveBase(env.DJ_BASE ?? DEFAULT_BASE)
  return { ...args, base, token }
}

async function main() {
  let config: ReturnType<typeof prepareDrain>
  try {
    config = prepareDrain(process.argv.slice(2), process.env)
  } catch (e) {
    console.error((e as Error).message)
    process.exit(2)
  }
  console.log(`draining up to ${config.max} tracks, ${config.delayMs} ms between calls`)
  const result = await drain(config)
  console.log(`done: stopped=${result.stopped} calls=${result.calls} processed=${result.processed} `
    + `features=${result.features} meaning=${result.meaning}`)
  if (result.stopped === 'error' || result.stopped === 'provider-down') process.exit(1)
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch(() => {
    // Fixed string only: an exception's text could carry the base URL.
    console.error('drain-enrichment failed')
    process.exit(1)
  })
}
