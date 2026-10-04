import { describe, it, expect, vi } from 'vitest'
import { drain, prepareDrain, parseDrainArgs, resolveBase, DEFAULT_DELAY_MS, MIN_DELAY_MS, PROVIDER_DOWN_MESSAGE, COOLING_MESSAGE } from '../../scripts/drain-enrichment'
import { MAX_BATCH } from '../../src/routes/enrich'

const TOKEN = 'admin-token-value'
const BASE = 'https://api.example.test'

type Batch = { processed: number; features: number; meaning: number; remaining: number; cooling?: number }

function fakeApi(responses: Array<Batch | Response | Error>) {
  const requests: Array<{ url: string; method?: string; token?: string | null }> = []
  const fetchLike = vi.fn(async (url: string | URL, init?: RequestInit) => {
    requests.push({ url: String(url), method: init?.method, token: new Headers(init?.headers).get('X-Admin-Token') })
    const next = responses.shift()
    if (!next) throw new Error('no more responses')
    if (next instanceof Error) throw next
    return next instanceof Response ? next : Response.json(next)
  })
  return { fetchLike, requests }
}

function run(responses: Array<Batch | Response | Error>, max: number, delayMs = 10) {
  const api = fakeApi(responses)
  const lines: string[] = []
  const sleep = vi.fn(async () => {})
  const result = drain({
    max, delayMs, base: BASE, token: TOKEN, fetchLike: api.fetchLike, sleep, log: (line) => lines.push(line),
  })
  return { ...api, lines, sleep, result }
}

const batch = (processed: number, remaining: number): Batch => ({ processed, features: processed, meaning: processed, remaining })

describe('parseDrainArgs', () => {
  it('requires --max', () => {
    expect(() => parseDrainArgs([])).toThrow('--max')
    expect(() => parseDrainArgs(['--delay-ms', '2000'])).toThrow('--max')
  })

  it('rejects a non-positive or non-integer --max and a negative --delay-ms', () => {
    expect(() => parseDrainArgs(['--max', '0'])).toThrow()
    expect(() => parseDrainArgs(['--max', '2.5'])).toThrow()
    expect(() => parseDrainArgs(['--max', 'lots'])).toThrow()
    expect(() => parseDrainArgs(['--max'])).toThrow()
    expect(() => parseDrainArgs(['--max', '10', '--delay-ms', '-1'])).toThrow()
    expect(() => parseDrainArgs(['--max', '10', '--wat'])).toThrow()
  })

  it('defaults the delay to 4 seconds and accepts an override', () => {
    expect(DEFAULT_DELAY_MS).toBe(4000)
    expect(parseDrainArgs(['--max', '700'])).toEqual({ max: 700, delayMs: 4000 })
    expect(parseDrainArgs(['--delay-ms', '2500', '--max', '12'])).toEqual({ max: 12, delayMs: 2500 })
  })

  it('enforces a minimum delay of one second', () => {
    expect(MIN_DELAY_MS).toBe(1000)
    expect(parseDrainArgs(['--max', '5', '--delay-ms', '1000'])).toEqual({ max: 5, delayMs: 1000 })
    expect(() => parseDrainArgs(['--max', '5', '--delay-ms', '999'])).toThrow('1000')
    expect(() => parseDrainArgs(['--max', '5', '--delay-ms', '0'])).toThrow('1000')
  })
})

describe('resolveBase', () => {
  it('accepts HTTPS and loopback HTTP, trimming a trailing slash', () => {
    expect(resolveBase('https://api.example.test/')).toBe('https://api.example.test')
    expect(resolveBase('http://localhost:8787')).toBe('http://localhost:8787')
  })

  it('rejects credentials, queries and plain HTTP without echoing the value', () => {
    for (const raw of ['https://user:secretpw@api.example.test', 'https://api.example.test?x=1', 'http://api.example.test', 'nope']) {
      expect(() => resolveBase(raw)).toThrow()
      try { resolveBase(raw) } catch (e) { expect(String(e)).not.toContain('secretpw') }
    }
  })
})

describe('prepareDrain', () => {
  const noDevVars = () => { throw new Error('no .dev.vars') }

  it('takes the token from the environment, else .dev.vars, and the base from DJ_BASE, else the deployed Worker', () => {
    expect(prepareDrain(['--max', '3'], { ENRICH_ADMIN_TOKEN: TOKEN, DJ_BASE: `${BASE}/` }, noDevVars))
      .toEqual({ max: 3, delayMs: DEFAULT_DELAY_MS, token: TOKEN, base: BASE })
    const fromFile = prepareDrain(['--max', '3'], {}, () => ({ ENRICH_ADMIN_TOKEN: 'from-file' }))
    expect(fromFile.token).toBe('from-file')
    expect(fromFile.base).toMatch(/^https:\/\//)
  })

  it('fails with its own fixed message for a bad base, a missing token, or bad arguments', () => {
    expect(() => prepareDrain(['--max', '3'], { ENRICH_ADMIN_TOKEN: TOKEN, DJ_BASE: 'https://u:secretpw@x.test' }, noDevVars))
      .toThrow(/^API base must use HTTPS/)
    expect(() => prepareDrain(['--max', '3'], { ENRICH_ADMIN_TOKEN: TOKEN, DJ_BASE: 'secretpw' }, noDevVars))
      .toThrow(/^API base is not a valid URL$/)
    expect(() => prepareDrain(['--max', '3'], {}, noDevVars)).toThrow(/ENRICH_ADMIN_TOKEN is required/)
    expect(() => prepareDrain([], { ENRICH_ADMIN_TOKEN: TOKEN }, noDevVars)).toThrow(/--max/)
  })
})

describe('drain', () => {
  it('posts batches with the admin header until --max is reached, never asking for more than remains', async () => {
    const max = MAX_BATCH * 2 + 1
    const { requests, lines, sleep, result } = run([batch(MAX_BATCH, 100), batch(MAX_BATCH, 95), batch(1, 94)], max)
    expect(await result).toEqual({ processed: max, features: max, meaning: max, calls: 3, stopped: 'max' })
    expect(requests.map((r) => r.url)).toEqual([
      `${BASE}/enrich/run?limit=${MAX_BATCH}`, `${BASE}/enrich/run?limit=${MAX_BATCH}`, `${BASE}/enrich/run?limit=1`,
    ])
    expect(requests.every((r) => r.method === 'POST' && r.token === TOKEN)).toBe(true)
    expect(sleep).toHaveBeenCalledTimes(2)
    expect(sleep).toHaveBeenCalledWith(10)
    for (const line of lines) {
      expect(line).not.toContain(TOKEN)
      expect(line).not.toContain('example.test')
    }
  })

  it('stops early when a call processes nothing', async () => {
    const { requests, result } = run([batch(2, 5), batch(0, 5), batch(5, 0)], 100)
    expect(await result).toMatchObject({ processed: 2, calls: 2, stopped: 'empty' })
    expect(requests).toHaveLength(2)
  })

  it('stops after two consecutive calls that processed tracks with no stage succeeding', async () => {
    const failing = (processed: number, remaining: number): Batch => ({ processed, features: 0, meaning: 0, remaining })
    const { requests, lines, result } = run([failing(5, 50), failing(5, 50), batch(5, 45)], 100)
    expect(await result).toMatchObject({ processed: 10, features: 0, meaning: 0, calls: 2, stopped: 'provider-down' })
    expect(requests).toHaveLength(2)
    expect(lines.at(-1)).toBe(PROVIDER_DOWN_MESSAGE)
    expect(PROVIDER_DOWN_MESSAGE).not.toMatch(/\u2014/)
  })

  it('a single failing call, or a partial success, does not stop the drain', async () => {
    const { requests, result } = run([
      { processed: 5, features: 0, meaning: 0, remaining: 50 },
      { processed: 5, features: 0, meaning: 1, remaining: 45 },
      { processed: 5, features: 0, meaning: 0, remaining: 40 },
      { processed: 5, features: 1, meaning: 0, remaining: 35 },
    ], 20)
    expect(await result).toMatchObject({ processed: 20, calls: 4, stopped: 'max' })
    expect(requests).toHaveLength(4)
  })

  it('stops when nothing remains', async () => {
    const { requests, result } = run([batch(3, 0), batch(5, 0)], 100)
    expect(await result).toMatchObject({ processed: 3, calls: 1, stopped: 'drained' })
    expect(requests).toHaveLength(1)
  })

  it('ends cleanly when every pending track is cooling down after provider errors', async () => {
    const { requests, lines, result } = run([{ processed: 0, features: 0, meaning: 0, remaining: 0, cooling: 12 }, batch(5, 0)], 100)
    expect(await result).toEqual({ processed: 0, features: 0, meaning: 0, calls: 1, stopped: 'cooling' })
    expect(requests).toHaveLength(1)
    expect(lines.at(-2)).toContain('cooling=12')
    expect(lines.at(-1)).toBe(COOLING_MESSAGE)
    expect(COOLING_MESSAGE).toMatch(/nothing eligible right now/)
    expect(COOLING_MESSAGE).not.toMatch(/\u2014/)
  })

  it('reports the cooling stop once the due queue empties but some tracks still wait on backoff', async () => {
    const { requests, lines, result } = run([{ processed: 3, features: 3, meaning: 3, remaining: 0, cooling: 4 }], 100)
    expect(await result).toMatchObject({ processed: 3, calls: 1, stopped: 'cooling' })
    expect(requests).toHaveLength(1)
    expect(lines.at(-1)).toBe(COOLING_MESSAGE)
  })

  it('reports provider-down, not cooling, when the call that empties the due queue enriched nothing', async () => {
    const { requests, lines, result } = run([{ processed: 3, features: 0, meaning: 0, remaining: 0, cooling: 3 }, batch(5, 0)], 100)
    expect(await result).toMatchObject({ processed: 3, calls: 1, stopped: 'provider-down' })
    expect(requests).toHaveLength(1)
    expect(lines.at(-1)).toBe(PROVIDER_DOWN_MESSAGE)
  })

  it('reports cooling when the call that empties the due queue enriched something', async () => {
    const { result } = run([{ processed: 3, features: 0, meaning: 1, remaining: 0, cooling: 2 }], 100)
    expect(await result).toMatchObject({ processed: 3, calls: 1, stopped: 'cooling' })
  })

  it('words the provider-down message so it holds for permanent failures too', () => {
    expect(PROVIDER_DOWN_MESSAGE).toMatch(/only tracks that hit a temporary provider error retry after their backoff/i)
    expect(PROVIDER_DOWN_MESSAGE).not.toMatch(/\u2014/)
  })

  it('still reports empty and drained when nothing is cooling, including from a Worker that sends no cooling count', async () => {
    expect(await run([{ processed: 0, features: 0, meaning: 0, remaining: 0, cooling: 0 }], 10).result).toMatchObject({ stopped: 'empty' })
    expect(await run([{ processed: 2, features: 2, meaning: 2, remaining: 0, cooling: 0 }], 10).result).toMatchObject({ stopped: 'drained' })
    expect(await run([batch(2, 0)], 10).result).toMatchObject({ stopped: 'drained' })
  })

  it('rejects a malformed cooling count', async () => {
    const { result } = run([{ processed: 1, features: 1, meaning: 1, remaining: 3, cooling: -1 }], 10)
    expect(await result).toMatchObject({ stopped: 'error' })
  })

  it('stops on an HTTP error, a malformed body or a failed request, printing fixed text only', async () => {
    for (const failure of [
      new Response('unauthorized admin-token-value', { status: 401 }),
      Response.json({ processed: 'x' }),
      new Error(`fetch failed for ${BASE}/enrich/run with ${TOKEN}`),
    ]) {
      const { lines, result } = run([batch(1, 9), failure, batch(1, 8)], 100)
      expect(await result).toMatchObject({ processed: 1, calls: 2, stopped: 'error' })
      for (const line of lines) {
        expect(line).not.toContain(TOKEN)
        expect(line).not.toContain('example.test')
      }
    }
  })
})
