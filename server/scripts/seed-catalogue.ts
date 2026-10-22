/**
 * seed-catalogue: seeds the catalogue ahead of demand (spec 2026-10-21
 * everyone-gets-a-mix, step 3). For each storefront and each list in
 * scripts/seed-catalogue.json (Apple's song chart per genre, and the
 * editorial playlist each search term resolves to), it pages the deployed
 * Worker's admin `POST /enrich/seed` until the list ends or --per-list songs
 * are fetched, then drives `POST /enrich/run` exactly as drain-enrichment.ts
 * does (same delay, cool-down and stop rules, --max tracks per sitting), and
 * ends with a coverage report from `GET /enrich/status`.
 *
 * Usage (from server/):
 *   npm run seed-catalogue -- --max <tracks> [--storefronts ng,us,gb]
 *     [--per-list 200] [--page-size 100] [--delay-ms 4000] [--resume]
 * The first sitting runs without --resume; every later sitting passes
 * --resume, or it starts the lists over (harmless, but it spends Apple calls
 * on pages already seeded).
 * Reads ENRICH_ADMIN_TOKEN from the environment, else .dev.vars; targets
 * DJ_BASE, else the deployed Worker. Founder-run only.
 *
 * --resume skips the lists already fetched per storefront, recorded in
 * server/.seed-catalogue-state.json (written after every finished list,
 * with or without --resume). A 429 or 503 from the seed route waits
 * COOL_DOWN_MS and retries; SUSTAINED_ERRORS in a row stop seeding (the
 * drain still runs; rerun with --resume later). Any other error stops
 * everything. Prints counts and list names only: never the token, the base
 * URL, or a response or exception text.
 */
import { readFileSync, writeFileSync } from 'node:fs'
import { pathToFileURL } from 'node:url'
import { resolve } from 'node:path'
import { drain, resolveBase, DEFAULT_DELAY_MS, MIN_DELAY_MS, type DrainResult } from './drain-enrichment'
import { loadDevVars } from './lib/dev-vars'
import { MAX_CHART_PAGE, MAX_PLAYLIST_PAGE } from '../src/enrich/seed-limits'

const DEFAULT_BASE = 'https://mixtape-api.goalympics.workers.dev'
const DEFAULT_STOREFRONTS = ['ng', 'us', 'gb']
export const DEFAULT_PER_LIST = 200
// Below the chart ceiling: one request parses and inserts a whole page
// inside the free plan's 10 ms CPU.
export const DEFAULT_PAGE_SIZE = 100
export const COOL_DOWN_MS = 60_000
export const SUSTAINED_ERRORS = 3
const PLAYLIST_SEARCH_LIMIT = 10
// Apple's own editorial playlists ("Apple Music", "Apple Music Hip-Hop", ...);
// listener playlists (ids pl.u-...) are noise for a seed.
const EDITORIAL_CURATOR_PREFIX = 'Apple Music'
const isEditorial = (p: { id: string; curator: string | null }) =>
  p.curator !== null && p.curator.startsWith(EDITORIAL_CURATOR_PREFIX) && !p.id.startsWith('pl.u-')
const STATE_FILE = new URL('../.seed-catalogue-state.json', import.meta.url)
const CONFIG_FILE = new URL('./seed-catalogue.json', import.meta.url)

type FetchLike = (url: string | URL, init?: RequestInit) => Promise<Response>

export type SeedConfig = {
  genres: { id: string | null; name: string }[]
  playlistTerms: string[]
  playlistsPerTerm: number
}

export type SeedList =
  | { key: string; kind: 'chart'; genreId: string | null; name: string }
  | { key: string; kind: 'playlist'; term: string }

export type SeedArgs = {
  storefronts: string[]
  perList: number
  pageSize: number
  max: number
  delayMs: number
  resume: boolean
}

export type SeedState = { version: 1; done: Record<string, string[]> }

type Counts = { lists: number; fetched: number; inserted: number; duplicates: number }

export type Coverage = { tracks: number; withFeatures: number; withMeaning: number; withEmbedding: number; exhausted: number }

export type SeedReport = {
  seed: Counts & {
    stopped: 'done' | 'rate-limited' | 'error'
    calls: number
    // Lists --resume skipped as already fetched.
    skipped: number
    byStorefront: Record<string, Counts>
  }
  drain: DrainResult | null
  coverage: Coverage | null
}

function positiveInt(raw: string | undefined): number | null {
  return raw !== undefined && /^\d+$/.test(raw) && Number(raw) > 0 ? Number(raw) : null
}

export function parseSeedArgs(argv: string[]): SeedArgs {
  const args: SeedArgs = {
    storefronts: DEFAULT_STOREFRONTS, perList: DEFAULT_PER_LIST, pageSize: DEFAULT_PAGE_SIZE,
    max: 0, delayMs: DEFAULT_DELAY_MS, resume: false,
  }
  for (let i = 0; i < argv.length; i++) {
    const flag = argv[i]
    if (flag === '--max') {
      const value = positiveInt(argv[++i])
      if (!value) throw new Error('--max must be a positive integer')
      args.max = value
    } else if (flag === '--storefronts') {
      const value = (argv[++i] ?? '').split(',').map((s) => s.trim())
      if (value.length === 0 || !value.every((s) => /^[a-z]{2}$/.test(s))) {
        throw new Error('--storefronts must be comma-separated two-letter codes, e.g. ng,us,gb')
      }
      args.storefronts = [...new Set(value)]
    } else if (flag === '--per-list') {
      const value = positiveInt(argv[++i])
      if (!value) throw new Error('--per-list must be a positive integer')
      args.perList = value
    } else if (flag === '--page-size') {
      const value = positiveInt(argv[++i])
      if (!value || value > MAX_CHART_PAGE) throw new Error(`--page-size must be an integer from 1 to ${MAX_CHART_PAGE}`)
      args.pageSize = value
    } else if (flag === '--delay-ms') {
      const value = positiveInt(argv[++i])
      if (value === null || value < MIN_DELAY_MS) throw new Error(`--delay-ms must be an integer of at least ${MIN_DELAY_MS}`)
      args.delayMs = value
    } else if (flag === '--resume') {
      args.resume = true
    } else {
      throw new Error('unknown argument; usage: --max <tracks> [--storefronts ng,us,gb] [--per-list n] [--page-size n] [--delay-ms ms] [--resume] (pass --resume on every sitting after the first)')
    }
  }
  if (!args.max) throw new Error('--max <tracks> is required')
  return args
}

export function loadSeedConfig(file: URL = CONFIG_FILE): SeedConfig {
  const raw = JSON.parse(readFileSync(file, 'utf8')) as Partial<SeedConfig>
  const genresOk = Array.isArray(raw.genres) && raw.genres.every((g) =>
    g && typeof g.name === 'string' && (g.id === null || (typeof g.id === 'string' && /^\d{1,12}$/.test(g.id))))
  const termsOk = Array.isArray(raw.playlistTerms) && raw.playlistTerms.every((t) => typeof t === 'string' && t.trim().length > 0)
  if (!genresOk || !termsOk) throw new Error('seed-catalogue.json is malformed')
  return { genres: raw.genres!, playlistTerms: raw.playlistTerms!, playlistsPerTerm: raw.playlistsPerTerm ?? 1 }
}

export function listsOf(config: SeedConfig): SeedList[] {
  return [
    ...config.genres.map((g): SeedList => ({ key: `chart:${g.id ?? 'all'}`, kind: 'chart', genreId: g.id, name: g.name })),
    ...config.playlistTerms.map((term): SeedList => ({ key: `playlist:${term}`, kind: 'playlist', term })),
  ]
}

function parseState(raw: unknown): SeedState {
  if (raw == null) return { version: 1, done: {} }
  const done = (raw as { done?: unknown }).done
  if (
    typeof raw !== 'object' || (raw as { version?: unknown }).version !== 1
    || !done || typeof done !== 'object' || Array.isArray(done)
    || !Object.values(done).every((keys) => Array.isArray(keys) && keys.every((k) => typeof k === 'string'))
  ) throw new SeedStateError('seed state file is malformed; remove it or run without --resume')
  return { version: 1, done: structuredClone(done as Record<string, string[]>) }
}

function defaultLoadState(): unknown {
  try {
    return JSON.parse(readFileSync(STATE_FILE, 'utf8'))
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code === 'ENOENT') return null
    throw new SeedStateError('seed state file is unreadable; remove it or run without --resume')
  }
}

function defaultSaveState(state: SeedState) {
  writeFileSync(STATE_FILE, `${JSON.stringify(state, null, 2)}\n`)
}

const count = (v: unknown) => Number.isInteger(v) && (v as number) >= 0

type SeedPage = { fetched: number; inserted: number; duplicates: number; next: number | null }

function parseSeedPage(body: unknown): SeedPage | null {
  if (!body || typeof body !== 'object') return null
  const b = body as Record<string, unknown>
  if (!count(b.fetched) || !count(b.inserted) || !count(b.duplicates)) return null
  if (b.next !== null && !count(b.next)) return null
  return { fetched: b.fetched as number, inserted: b.inserted as number, duplicates: b.duplicates as number, next: b.next as number | null }
}

function parsePlaylists(body: unknown): { id: string; curator: string | null }[] | null {
  const list = (body as { playlists?: unknown } | null)?.playlists
  if (!Array.isArray(list)) return null
  if (!list.every((p) => p && typeof p.id === 'string' && (p.curator === null || typeof p.curator === 'string'))) return null
  return list as { id: string; curator: string | null }[]
}

function parseCoverage(body: unknown): Coverage | null {
  if (!body || typeof body !== 'object') return null
  const b = body as Record<string, unknown>
  const keys = ['tracks', 'withFeatures', 'withMeaning', 'withEmbedding', 'exhausted'] as const
  if (!keys.every((k) => count(b[k]))) return null
  return Object.fromEntries(keys.map((k) => [k, b[k]])) as Coverage
}

// Fixed text that main prints as is, instead of the generic failure line.
export class SeedStateError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'SeedStateError'
  }
}

class SeedStop extends Error {
  constructor(readonly reason: 'rate-limited' | 'error') {
    super(reason)
  }
}

const emptyCounts = (): Counts => ({ lists: 0, fetched: 0, inserted: 0, duplicates: 0 })

export async function seedCatalogue(opts: SeedArgs & {
  base: string
  token: string
  config: SeedConfig
  fetchLike?: FetchLike
  sleep?: (ms: number) => Promise<void>
  log?: (line: string) => void
  loadState?: () => unknown
  saveState?: (state: SeedState) => void
}): Promise<SeedReport> {
  const fetchLike = opts.fetchLike ?? fetch
  const sleep = opts.sleep ?? ((ms: number) => new Promise<void>((done) => setTimeout(done, ms)))
  const log = opts.log ?? ((line: string) => console.log(line))
  const saveState = opts.saveState ?? defaultSaveState
  const state = opts.resume ? parseState((opts.loadState ?? defaultLoadState)()) : parseState(null)

  const seed: SeedReport['seed'] = { stopped: 'done', calls: 0, skipped: 0, byStorefront: {}, ...emptyCounts() }

  // One admin POST, with the cool-down on 429/503. Throws SeedStop.
  async function post(path: string, body: Record<string, unknown>): Promise<unknown> {
    let failures = 0
    while (true) {
      if (seed.calls > 0) await sleep(opts.delayMs)
      seed.calls++
      let res: Response
      try {
        res = await fetchLike(`${opts.base}${path}`, {
          method: 'POST',
          headers: { 'X-Admin-Token': opts.token, 'content-type': 'application/json' },
          body: JSON.stringify(body),
        })
      } catch {
        log(`call=${seed.calls} stopped: request failed`)
        throw new SeedStop('error')
      }
      if (res.ok) return res.json().catch(() => null)
      await res.body?.cancel().catch(() => undefined)
      if (res.status !== 429 && res.status !== 503) {
        log(`call=${seed.calls} stopped: HTTP ${res.status}`)
        throw new SeedStop('error')
      }
      failures++
      if (failures >= SUSTAINED_ERRORS) {
        log(`call=${seed.calls} stopped: HTTP ${res.status} ${failures} times in a row; rerun with --resume later`)
        throw new SeedStop('rate-limited')
      }
      log(`call=${seed.calls} HTTP ${res.status}, cooling down ${COOL_DOWN_MS / 1000} s`)
      await sleep(COOL_DOWN_MS)
    }
  }

  // Pages one source until it ends or the per-list cap; returns songs fetched.
  async function pageThrough(storefront: string, source: Record<string, unknown>, ceiling: number, cap: number, tally: Counts) {
    let offset = 0
    let fetched = 0
    while (fetched < cap) {
      const page = parseSeedPage(await post('/enrich/seed', {
        storefront, ...source, limit: Math.min(opts.pageSize, ceiling, cap - fetched), offset,
      }))
      if (!page) {
        log(`call=${seed.calls} stopped: malformed response`)
        throw new SeedStop('error')
      }
      fetched += page.fetched
      for (const t of [tally, seed]) {
        t.fetched += page.fetched
        t.inserted += page.inserted
        t.duplicates += page.duplicates
      }
      if (page.next === null || page.fetched === 0) break
      offset = page.next
    }
    return fetched
  }

  try {
    for (const storefront of opts.storefronts) {
      const tally = (seed.byStorefront[storefront] = emptyCounts())
      const done = (state.done[storefront] ??= [])
      for (const list of listsOf(opts.config)) {
        if (done.includes(list.key)) {
          seed.skipped++
          continue
        }
        const before = { ...tally }
        if (list.kind === 'chart') {
          await pageThrough(storefront, { source: 'chart', genreId: list.genreId }, MAX_CHART_PAGE, opts.perList, tally)
        } else {
          const found = parsePlaylists(await post('/enrich/seed/playlists', { storefront, term: list.term, limit: PLAYLIST_SEARCH_LIMIT }))
          if (!found) {
            log(`call=${seed.calls} stopped: malformed response`)
            throw new SeedStop('error')
          }
          const picked = found.filter(isEditorial).slice(0, opts.config.playlistsPerTerm)
          if (picked.length === 0) log(`${storefront} ${list.key}: picked=0, no editorial playlist found`)
          let left = opts.perList
          for (const playlist of picked) {
            if (left <= 0) break
            left -= await pageThrough(storefront, { source: 'playlist', playlistId: playlist.id }, MAX_PLAYLIST_PAGE, left, tally)
          }
        }
        done.push(list.key)
        saveState(state)
        tally.lists++
        seed.lists++
        log(`${storefront} ${list.key}: fetched=${tally.fetched - before.fetched} inserted=${tally.inserted - before.inserted} `
          + `lists=${seed.lists} inserted total=${seed.inserted}`)
      }
    }
  } catch (e) {
    if (!(e instanceof SeedStop)) throw e
    seed.stopped = e.reason
  }

  // A sustained Apple limit does not stop the enrichment providers.
  let drained: DrainResult | null = null
  if (seed.stopped !== 'error') {
    drained = await drain({ max: opts.max, delayMs: opts.delayMs, base: opts.base, token: opts.token, fetchLike, sleep, log })
  }

  let coverage: Coverage | null = null
  try {
    const res = await fetchLike(`${opts.base}/enrich/status`, { headers: { 'X-Admin-Token': opts.token } })
    if (res.ok) coverage = parseCoverage(await res.json().catch(() => null))
    else await res.body?.cancel().catch(() => undefined)
  } catch {
    // Coverage is best-effort; the seed counts above still stand.
  }

  return { seed, drain: drained, coverage }
}

export function prepareSeed(
  argv: string[],
  env: { ENRICH_ADMIN_TOKEN?: string; DJ_BASE?: string },
  readDevVars: () => Record<string, string> = loadDevVars,
): SeedArgs & { base: string; token: string } {
  const args = parseSeedArgs(argv)
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
  let config: ReturnType<typeof prepareSeed>
  let lists: SeedConfig
  try {
    config = prepareSeed(process.argv.slice(2), process.env)
    lists = loadSeedConfig()
  } catch (e) {
    console.error((e as Error).message)
    process.exit(2)
  }
  if (!config.resume) console.log('starting the lists over; pass --resume on every later sitting')
  console.log(`seeding ${config.storefronts.join(',')}: ${listsOf(lists).length} lists, up to ${config.perList} songs each`
    + `${config.resume ? ', resuming' : ''}; then enriching up to ${config.max} tracks, ${config.delayMs} ms between calls`)
  let report: SeedReport
  try {
    report = await seedCatalogue({ ...config, config: lists })
  } catch (e) {
    if (!(e instanceof SeedStateError)) throw e
    console.error(e.message)
    process.exit(2)
  }
  const s = report.seed
  console.log(`seed: stopped=${s.stopped} calls=${s.calls} lists=${s.lists} skipped=${s.skipped} `
    + `fetched=${s.fetched} inserted=${s.inserted} duplicates=${s.duplicates}`)
  for (const [storefront, c] of Object.entries(s.byStorefront)) {
    console.log(`  ${storefront}: lists=${c.lists} fetched=${c.fetched} inserted=${c.inserted} duplicates=${c.duplicates}`)
  }
  if (report.drain) {
    const d = report.drain
    console.log(`enrich: stopped=${d.stopped} calls=${d.calls} processed=${d.processed} features=${d.features} meaning=${d.meaning}`)
  }
  if (report.coverage) {
    const c = report.coverage
    console.log(`coverage: tracks=${c.tracks} features=${c.withFeatures} meaning=${c.withMeaning} `
      + `embedding=${c.withEmbedding} exhausted=${c.exhausted}`)
  } else {
    console.log('coverage: unavailable')
  }
  if (s.stopped === 'rate-limited') console.log('seeding paused on sustained Apple limits; rerun with --resume')
  if (s.stopped === 'error' || report.drain?.stopped === 'error' || report.drain?.stopped === 'provider-down') process.exit(1)
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch(() => {
    // Fixed string only: an exception's text could carry the base URL.
    console.error('seed-catalogue failed')
    process.exit(1)
  })
}
