import { describe, it, expect, vi } from 'vitest'
import {
  COOL_DOWN_MS,
  SUSTAINED_ERRORS,
  SeedStateError,
  listsOf,
  loadSeedConfig,
  parseSeedArgs,
  prepareSeed,
  seedCatalogue,
  type SeedConfig,
  type SeedState,
} from '../../scripts/seed-catalogue'
import { BACKOFF_MS } from '../../scripts/drain-enrichment'

const TOKEN = 'admin-token-value'
const BASE = 'https://api.example.test'

const CONFIG: SeedConfig = {
  genres: [{ id: null, name: 'All genres' }, { id: '14', name: 'Pop' }],
  playlistTerms: ['Afrobeats Essentials'],
  playlistsPerTerm: 1,
}

type Seen = { url: string; method?: string; token: string | null; body: Record<string, unknown> | null }
type Handler = (req: Seen) => Response | Promise<Response>

// A fake Worker: seed pages from per-list song counts, playlists by term,
// enrichment batches from a queue, and a status route.
function fakeWorker(opts: {
  listSizes?: Record<string, number>
  seedOverride?: Handler
  batches?: Array<{ processed: number; features: number; meaning: number; remaining: number; cooling?: number }>
  status?: Record<string, number> | Response
  playlists?: Array<{ id: string; name: string; curator: string | null }>
} = {}) {
  const requests: Seen[] = []
  const sizes = opts.listSizes ?? {}
  const batches = [...(opts.batches ?? [{ processed: 0, features: 0, meaning: 0, remaining: 0 }])]
  const fetchLike = vi.fn(async (url: string | URL, init?: RequestInit) => {
    const raw = typeof init?.body === 'string' ? init.body : null
    const req: Seen = {
      url: String(url), method: init?.method, token: new Headers(init?.headers).get('X-Admin-Token'),
      body: raw ? JSON.parse(raw) as Record<string, unknown> : null,
    }
    requests.push(req)
    const path = new URL(req.url).pathname
    if (path === '/enrich/seed/playlists') {
      if (opts.playlists) return Response.json({ playlists: opts.playlists })
      return Response.json({ playlists: [
        { id: 'pl.user', name: 'mine', curator: 'Someone' },
        { id: 'pl.u-listener', name: 'copycat', curator: 'Apple Music' },
        { id: 'pl.editorial', name: String(req.body?.term), curator: 'Apple Music' },
      ] })
    }
    if (path === '/enrich/seed') {
      if (opts.seedOverride) return opts.seedOverride(req)
      const b = req.body!
      const key = `${b.storefront}:${b.source === 'chart' ? `chart:${b.genreId ?? 'all'}` : `playlist:${b.playlistId}`}`
      const size = sizes[key] ?? 0
      const offset = Number(b.offset ?? 0)
      const fetched = Math.max(0, Math.min(Number(b.limit), size - offset))
      const next = offset + fetched < size ? offset + fetched : null
      return Response.json({ fetched, inserted: fetched, duplicates: 0, next })
    }
    if (path === '/enrich/run') {
      const batch = batches.shift() ?? { processed: 0, features: 0, meaning: 0, remaining: 0 }
      return Response.json(batch)
    }
    if (path === '/enrich/status') {
      return opts.status instanceof Response ? opts.status
        : Response.json(opts.status ?? { tracks: 10, withFeatures: 8, withMeaning: 7, withEmbedding: 7, exhausted: 1 })
    }
    return new Response('not found', { status: 404 })
  })
  return { fetchLike, requests }
}

function run(worker: ReturnType<typeof fakeWorker>, overrides: Partial<Parameters<typeof seedCatalogue>[0]> = {}) {
  const lines: string[] = []
  const sleep = vi.fn(async (_ms: number) => {})
  const saved: SeedState[] = []
  const result = seedCatalogue({
    storefronts: ['ng'], perList: 200, pageSize: 100, max: 50, delayMs: 1000, resume: false,
    base: BASE, token: TOKEN, config: CONFIG,
    fetchLike: worker.fetchLike, sleep, log: (line) => lines.push(line),
    loadState: () => null, saveState: (s) => saved.push(structuredClone(s)),
    ...overrides,
  })
  return { result, lines, sleep, saved }
}

const seedCalls = (w: ReturnType<typeof fakeWorker>) => w.requests.filter((r) => new URL(r.url).pathname === '/enrich/seed')

describe('parseSeedArgs', () => {
  it('requires --max and defaults the rest', () => {
    expect(() => parseSeedArgs([])).toThrow('--max')
    expect(parseSeedArgs(['--max', '700'])).toEqual({
      storefronts: ['ng', 'us', 'gb'], perList: 200, pageSize: 100, max: 700, delayMs: 10_000, resume: false,
    })
  })

  it('reads storefronts, per-list, page size, delay and resume', () => {
    expect(parseSeedArgs(['--max', '5', '--storefronts', 'ng,us', '--per-list', '50', '--page-size', '100', '--delay-ms', '2000', '--resume']))
      .toEqual({ storefronts: ['ng', 'us'], perList: 50, pageSize: 100, max: 5, delayMs: 2000, resume: true })
  })

  it.each([
    [['--max', '5', '--storefronts', 'NG']],
    [['--max', '5', '--storefronts', '']],
    [['--max', '5', '--per-list', '0']],
    [['--max', '5', '--page-size', '101']],
    [['--max', '5', '--delay-ms', '999']],
    [['--max', '0']],
    [['--max', '5', '--wat']],
  ])('rejects %j', (argv) => {
    expect(() => parseSeedArgs(argv)).toThrow()
  })
})

describe('prepareSeed', () => {
  it('takes the token from the environment, else .dev.vars, and never echoes it', () => {
    expect(prepareSeed(['--max', '5'], { ENRICH_ADMIN_TOKEN: 'env-token', DJ_BASE: 'http://localhost:8787' }))
      .toMatchObject({ token: 'env-token', base: 'http://localhost:8787', max: 5 })
    expect(prepareSeed(['--max', '5'], {}, () => ({ ENRICH_ADMIN_TOKEN: 'file-token' })))
      .toMatchObject({ token: 'file-token', base: 'https://mixtape-api.goalympics.workers.dev' })
    expect(() => prepareSeed(['--max', '5'], {}, () => { throw new Error('none') })).toThrow('ENRICH_ADMIN_TOKEN')
  })
})

describe('listsOf and the shipped list', () => {
  it('builds one chart list per genre and one playlist list per term', () => {
    expect(listsOf(CONFIG).map((l) => l.key)).toEqual(['chart:all', 'chart:14', 'playlist:Afrobeats Essentials'])
  })

  it('ships about 25 genres and the editorial playlist families', () => {
    const config = loadSeedConfig()
    const shipped = listsOf(config)
    expect(shipped.filter((l) => l.kind === 'chart').length).toBeGreaterThanOrEqual(25)
    expect(config.playlistTerms).toEqual(expect.arrayContaining([
      'Afrobeats Essentials', "Today's Hits", 'A-List Pop', 'Rap Life', 'R&B Now', 'K-Pop Essentials', 'Classical Essentials',
    ]))
    expect(new Set(shipped.map((l) => l.key)).size).toBe(shipped.length)
  })
})

describe('seedCatalogue', () => {
  it('pages each list until next is null, with the admin token, then drains and reports coverage', async () => {
    const worker = fakeWorker({
      listSizes: { 'ng:chart:all': 150, 'ng:chart:14': 40, 'ng:playlist:pl.editorial': 30 },
      batches: [{ processed: 20, features: 20, meaning: 20, remaining: 0 }],
    })
    const { result, saved } = run(worker)
    const report = await result

    const seeds = seedCalls(worker)
    expect(seeds.map((r) => r.body)).toEqual([
      { storefront: 'ng', source: 'chart', genreId: null, limit: 100, offset: 0 },
      { storefront: 'ng', source: 'chart', genreId: null, limit: 100, offset: 100 },
      { storefront: 'ng', source: 'chart', genreId: '14', limit: 100, offset: 0 },
      { storefront: 'ng', source: 'playlist', playlistId: 'pl.editorial', limit: 100, offset: 0 },
    ])
    expect(worker.requests.every((r) => r.token === TOKEN)).toBe(true)
    // Only the editorial (Apple Music) playlist is taken.
    expect(seeds.some((r) => r.body?.playlistId === 'pl.user' || r.body?.playlistId === 'pl.u-listener')).toBe(false)
    expect(saved.at(-1)).toEqual({ version: 1, done: { ng: ['chart:all', 'chart:14', 'playlist:Afrobeats Essentials'] } })
    expect(report).toEqual({
      seed: {
        stopped: 'done', calls: 5, lists: 3, skipped: 0, fetched: 220, inserted: 220, duplicates: 0,
        byStorefront: { ng: { lists: 3, fetched: 220, inserted: 220, duplicates: 0 } },
      },
      drain: { processed: 20, features: 20, meaning: 20, calls: 1, stopped: 'drained' },
      coverage: { tracks: 10, withFeatures: 8, withMeaning: 7, withEmbedding: 7, exhausted: 1 },
    })
  })

  it('stops a list at --per-list songs', async () => {
    const worker = fakeWorker({ listSizes: { 'ng:chart:all': 500 } })
    const report = await run(worker, { perList: 130, config: { ...CONFIG, genres: [{ id: null, name: 'All' }], playlistTerms: [] } }).result
    expect(seedCalls(worker).map((r) => [r.body?.limit, r.body?.offset])).toEqual([[100, 0], [30, 100]])
    expect(report.seed.fetched).toBe(130)
  })

  it('caps chart and playlist pages at the route ceilings even with a larger page size', async () => {
    const worker = fakeWorker({ listSizes: { 'ng:playlist:pl.editorial': 150, 'ng:chart:all': 150 } })
    await run(worker, { pageSize: 200, config: { ...CONFIG, genres: [{ id: null, name: 'All' }] } }).result
    expect(seedCalls(worker).map((r) => [r.body?.source, r.body?.limit, r.body?.offset])).toEqual([
      ['chart', 100, 0], ['chart', 100, 100], ['playlist', 100, 0], ['playlist', 100, 100],
    ])
  })

  it('walks every storefront in turn', async () => {
    const worker = fakeWorker({ listSizes: { 'ng:chart:all': 1, 'us:chart:all': 1, 'gb:chart:all': 1 } })
    const report = await run(worker, { storefronts: ['ng', 'us', 'gb'], config: { ...CONFIG, genres: [{ id: null, name: 'All' }], playlistTerms: [] } }).result
    expect(seedCalls(worker).map((r) => r.body?.storefront)).toEqual(['ng', 'us', 'gb'])
    expect(Object.keys(report.seed.byStorefront)).toEqual(['ng', 'us', 'gb'])
  })

  it('with --resume skips lists already fetched for that storefront', async () => {
    const worker = fakeWorker({ listSizes: { 'ng:chart:14': 10, 'us:chart:all': 10, 'us:chart:14': 10 } })
    const state: SeedState = { version: 1, done: { ng: ['chart:all', 'playlist:Afrobeats Essentials'], us: ['playlist:Afrobeats Essentials'] } }
    const { result, saved } = run(worker, { resume: true, storefronts: ['ng', 'us'], loadState: () => state })
    const report = await result

    expect(seedCalls(worker).map((r) => `${r.body?.storefront}:${r.body?.genreId}`)).toEqual(['ng:14', 'us:null', 'us:14'])
    expect(worker.requests.some((r) => r.url.includes('/seed/playlists'))).toBe(false)
    expect(report.seed.skipped).toBe(3)
    expect(saved.at(-1)?.done).toEqual({
      ng: ['chart:all', 'playlist:Afrobeats Essentials', 'chart:14'],
      us: ['playlist:Afrobeats Essentials', 'chart:all', 'chart:14'],
    })
  })

  it('without --resume ignores saved state and starts over', async () => {
    const worker = fakeWorker()
    const loadState = vi.fn(() => ({ version: 1, done: { ng: ['chart:all'] } }))
    await run(worker, { loadState }).result
    expect(loadState).not.toHaveBeenCalled()
    expect(seedCalls(worker)[0].body?.genreId).toBe(null)
  })

  it('rejects a malformed state file rather than reseeding everything', async () => {
    await expect(run(fakeWorker(), { resume: true, loadState: () => ({ done: 'x' }) }).result).rejects.toThrow('state')
  })

  it('cools down and retries a 429 or 503, then carries on', async () => {
    let n = 0
    const worker = fakeWorker({
      seedOverride: () => {
        n++
        if (n === 1) return Response.json({ error: 'apple_rate_limited' }, { status: 429 })
        if (n === 2) return Response.json({ error: 'apple_unavailable' }, { status: 503 })
        return Response.json({ fetched: 5, inserted: 4, duplicates: 1, next: null })
      },
    })
    const { result, sleep } = run(worker, { config: { ...CONFIG, genres: [{ id: null, name: 'All' }], playlistTerms: [] } })
    const report = await result
    expect(report.seed).toMatchObject({ stopped: 'done', calls: 3, fetched: 5, inserted: 4, duplicates: 1, lists: 1 })
    expect(sleep.mock.calls.filter(([ms]) => ms === COOL_DOWN_MS)).toHaveLength(2)
  })

  it('stops seeding on sustained 429/503, keeps finished lists, and still drains', async () => {
    let n = 0
    const worker = fakeWorker({
      seedOverride: () => {
        n++
        if (n === 1) return Response.json({ fetched: 3, inserted: 3, duplicates: 0, next: null })
        return Response.json({ error: 'apple_rate_limited' }, { status: n % 2 ? 429 : 503 })
      },
      batches: [{ processed: 3, features: 3, meaning: 3, remaining: 0 }],
    })
    const { result, saved, lines } = run(worker)
    const report = await result
    expect(SUSTAINED_ERRORS).toBe(3)
    expect(report.seed).toMatchObject({ stopped: 'rate-limited', lists: 1, calls: 1 + SUSTAINED_ERRORS, fetched: 3 })
    expect(saved.at(-1)?.done).toEqual({ ng: ['chart:all'] })
    expect(report.drain).toMatchObject({ stopped: 'drained', processed: 3 })
    expect(lines.join('\n')).toContain('--resume')
  })

  it('stops on any other error without draining, and never logs the token or base', async () => {
    const worker = fakeWorker({ seedOverride: () => new Response('boom secret', { status: 500 }) })
    const { result, lines } = run(worker)
    const report = await result
    expect(report.seed.stopped).toBe('error')
    expect(report.drain).toBeNull()
    expect(worker.requests.some((r) => r.url.includes('/enrich/run'))).toBe(false)
    const log = lines.join('\n')
    expect(log).not.toContain(TOKEN)
    expect(log).not.toContain(BASE)
    expect(log).not.toContain('boom secret')
  })

  it('treats a 502 from the seed route (a broken Apple token) as a hard stop, with no retry or drain', async () => {
    const worker = fakeWorker({
      seedOverride: () => Response.json({ error: 'apple_unavailable', category: 'authorization' }, { status: 502 }),
    })
    const { result, sleep } = run(worker)
    const report = await result
    expect(report.seed).toMatchObject({ stopped: 'error', calls: 1 })
    expect(sleep.mock.calls.filter(([ms]) => ms === COOL_DOWN_MS)).toHaveLength(0)
    expect(report.drain).toBeNull()
  })

  it('takes curators named Apple Music..., skips pl.u- ids, and logs picked=0 when none is editorial', async () => {
    const worker = fakeWorker({
      listSizes: { 'ng:playlist:pl.hiphop': 5 },
      playlists: [
        { id: 'pl.u-mine', name: 'x', curator: 'Apple Music' },
        { id: 'pl.hiphop', name: 'Rap Life', curator: 'Apple Music Hip-Hop' },
      ],
    })
    const one = run(worker, { config: { ...CONFIG, genres: [] } })
    expect((await one.result).seed.fetched).toBe(5)
    expect(seedCalls(worker).map((r) => r.body?.playlistId)).toEqual(['pl.hiphop'])

    const none = fakeWorker({ playlists: [{ id: 'pl.u-mine', name: 'x', curator: 'Apple Music' }, { id: 'pl.z', name: 'y', curator: null }] })
    const empty = run(none, { config: { ...CONFIG, genres: [] } })
    const report = await empty.result
    expect(seedCalls(none)).toEqual([])
    expect(report.seed.lists).toBe(1)
    expect(empty.lines.join('\n')).toContain('playlist:Afrobeats Essentials: picked=0')
  })

  it('raises a SeedStateError for a malformed state file', async () => {
    await expect(run(fakeWorker(), { resume: true, loadState: () => ({ version: 2, done: {} }) }).result)
      .rejects.toBeInstanceOf(SeedStateError)
  })

  it('says to pass --resume after the first sitting in its usage line', () => {
    expect(() => parseSeedArgs(['--wat'])).toThrow('--resume on every sitting after the first')
  })

  it('treats a malformed seed response as an error', async () => {
    const worker = fakeWorker({ seedOverride: () => Response.json({ fetched: -1 }) })
    expect((await run(worker).result).seed.stopped).toBe('error')
  })

  it('drives the drain with --max and the delay, backing off a transient streak as drain-enrichment does', async () => {
    const worker = fakeWorker({
      batches: [
        { processed: 5, features: 5, meaning: 5, remaining: 14 },
        { processed: 5, features: 0, meaning: 0, remaining: 9 },
        { processed: 5, features: 0, meaning: 0, remaining: 4 },
        { processed: 5, features: 5, meaning: 5, remaining: 0 },
      ],
    })
    const { result, sleep } = run(worker, { max: 40, delayMs: 2500 })
    const report = await result
    expect(report.drain).toMatchObject({ stopped: 'drained', calls: 4, processed: 20 })
    const runs = worker.requests.filter((r) => r.url.includes('/enrich/run'))
    expect(runs[0].url).toMatch(/\/enrich\/run\?limit=\d+$/)
    expect(sleep).toHaveBeenCalledWith(2500)
    expect(sleep.mock.calls.filter(([ms]) => ms === BACKOFF_MS)).toHaveLength(2)
  })

  it('stops the drain as provider-down after three transient calls in a row', async () => {
    const failing = { processed: 5, features: 0, meaning: 0, remaining: 30 }
    const worker = fakeWorker({ batches: [failing, failing, failing, { processed: 5, features: 5, meaning: 5, remaining: 0 }] })
    const report = await run(worker, { max: 40 }).result
    expect(report.drain).toMatchObject({ stopped: 'provider-down', calls: 3, processed: 15 })
  })

  it('reports null coverage when the status route is unavailable', async () => {
    const worker = fakeWorker({ status: new Response('no', { status: 404 }) })
    expect((await run(worker).result).coverage).toBeNull()
  })
})
