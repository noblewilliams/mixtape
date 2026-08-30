import { mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { chunkIds, fetchPreviews, lookupItunesBatch, type FetchPreviewsDeps } from '../../scripts/lib/preview-fetcher'
import type { FetchLike } from '../../src/enrich/types'

// --- fetch fakes --------------------------------------------------------------

type DownloadSpec = { ok: boolean; status?: number; body?: string; throws?: boolean }

/**
 * Builds a FetchLike that answers itunes lookup calls from an id ->
 * {trackId, previewUrl, wrapperType, kind} table, and preview downloads from
 * a url -> outcome table. A url's outcome may be a single spec (repeated on
 * every call) or an array of specs consumed one per call (last one repeats
 * once exhausted) — used to simulate "fails once, then succeeds on retry".
 */
function fakeFetch(opts: {
  itunes?: Record<string, { previewUrl?: string; wrapperType?: string; kind?: string } | undefined>
  itunesMissingResults?: boolean
  downloads?: Record<string, DownloadSpec | DownloadSpec[]>
  downloadCalls?: string[]
  onLookup?: (ids: string[]) => void
  lookupError?: boolean
  lookupStatus?: number
}): FetchLike {
  const callIndex: Record<string, number> = {}
  return async (url) => {
    const s = String(url)
    if (s.includes('itunes.apple.com/lookup')) {
      const requestedIds = new URL(s).searchParams.get('id')!.split(',')
      opts.onLookup?.(requestedIds)
      if (opts.lookupError) return new Response('nope', { status: opts.lookupStatus ?? 503 })
      if (opts.itunesMissingResults) return new Response(JSON.stringify({ resultCount: 0 }), { status: 200 })
      const results = requestedIds
        .filter((id) => opts.itunes?.[id] !== undefined)
        .map((id) => ({
          trackId: Number(id),
          previewUrl: opts.itunes![id]?.previewUrl,
          wrapperType: opts.itunes![id]?.wrapperType ?? 'track',
          kind: opts.itunes![id]?.kind ?? 'song',
        }))
      return new Response(JSON.stringify({ resultCount: results.length, results }), { status: 200 })
    }
    const spec = opts.downloads?.[s]
    if (spec) {
      opts.downloadCalls?.push(s)
      const idx = callIndex[s] ?? 0
      callIndex[s] = idx + 1
      const attempt = Array.isArray(spec) ? spec[Math.min(idx, spec.length - 1)] : spec
      if (attempt.throws) throw new Error('network down')
      if (!attempt.ok) return new Response('nope', { status: attempt.status ?? 500 })
      return new Response(attempt.body ?? 'audio-bytes', { status: 200 })
    }
    throw new Error(`unexpected fetch: ${s}`)
  }
}

// --- suite ---------------------------------------------------------------------

let cacheDir = ''
let checkpointPath = ''

beforeEach(async () => {
  cacheDir = await mkdtemp(join(tmpdir(), 'mixtape-preview-cache-'))
  checkpointPath = join(await mkdtemp(join(tmpdir(), 'mixtape-preview-ckpt-')), 'checkpoint.json')
})

afterEach(async () => {
  await rm(cacheDir, { recursive: true, force: true })
})

function baseDeps(overrides: Partial<FetchPreviewsDeps> = {}): FetchPreviewsDeps {
  return {
    fetch: fakeFetch({}),
    storefront: 'ng',
    cacheDir,
    checkpointPath,
    sleep: async () => {},
    ...overrides,
  }
}

describe('chunkIds', () => {
  it('splits into groups of at most size, preserving order', () => {
    expect(chunkIds(['a', 'b', 'c', 'd', 'e'], 2)).toEqual([['a', 'b'], ['c', 'd'], ['e']])
  })

  it('returns one exact-size chunk when length is an exact multiple', () => {
    expect(chunkIds(['a', 'b', 'c', 'd'], 2)).toEqual([['a', 'b'], ['c', 'd']])
  })

  it('returns a single chunk when size exceeds the array length', () => {
    expect(chunkIds(['a', 'b'], 100)).toEqual([['a', 'b']])
  })

  it('returns no chunks for an empty input', () => {
    expect(chunkIds([], 100)).toEqual([])
  })
})

describe('lookupItunesBatch', () => {
  it('maps found ids to previewUrl and omits ids with no result', async () => {
    const fetchLike = fakeFetch({ itunes: { '1': { previewUrl: 'https://x/1.m4a' }, '2': undefined } })
    const hits = await lookupItunesBatch(['1', '2'], 'ng', fetchLike)
    expect(hits.get('1')).toBe('https://x/1.m4a')
    expect(hits.has('2')).toBe(false)
  })

  it('maps a hit with no previewUrl to null', async () => {
    const fetchLike = fakeFetch({ itunes: { '1': {} } })
    const hits = await lookupItunesBatch(['1'], 'ng', fetchLike)
    expect(hits.get('1')).toBeNull()
  })

  it('sends all ids comma-joined in one call', async () => {
    let seen = ''
    const fetchLike: FetchLike = async (url) => {
      seen = String(url)
      return new Response(JSON.stringify({ resultCount: 0, results: [] }), { status: 200 })
    }
    await lookupItunesBatch(['1', '2', '3'], 'ng', fetchLike)
    expect(seen).toContain('id=1%2C2%2C3')
  })

  it('throws on non-200', async () => {
    const fetchLike = fakeFetch({ itunes: {}, lookupError: true })
    await expect(lookupItunesBatch(['1'], 'ng', fetchLike)).rejects.toThrow()
  })

  it('throws when the response body has no results array (a shape, not a "zero hits" fact)', async () => {
    const fetchLike: FetchLike = async () => new Response(JSON.stringify({ resultCount: 0 }), { status: 200 })
    await expect(lookupItunesBatch(['1'], 'ng', fetchLike)).rejects.toThrow()
  })

  it('excludes a result whose wrapperType/kind is not a song track (e.g. a music-video sharing the trackId)', async () => {
    const fetchLike: FetchLike = async () =>
      new Response(
        JSON.stringify({
          resultCount: 1,
          results: [{ trackId: 1, previewUrl: 'https://x/1.m4v', wrapperType: 'track', kind: 'music-video' }],
        }),
        { status: 200 },
      )
    const hits = await lookupItunesBatch(['1'], 'ng', fetchLike)
    expect(hits.has('1')).toBe(false)
  })

  it('prefers a duplicate trackId entry with a non-null previewUrl over a later null one', async () => {
    const fetchLike: FetchLike = async () =>
      new Response(
        JSON.stringify({
          resultCount: 2,
          results: [
            { trackId: 1, previewUrl: 'https://x/1.m4a', wrapperType: 'track', kind: 'song' },
            { trackId: 1, wrapperType: 'track', kind: 'song' },
          ],
        }),
        { status: 200 },
      )
    const hits = await lookupItunesBatch(['1'], 'ng', fetchLike)
    expect(hits.get('1')).toBe('https://x/1.m4a')
  })

  it('prefers a duplicate trackId entry with a non-null previewUrl over an earlier null one', async () => {
    const fetchLike: FetchLike = async () =>
      new Response(
        JSON.stringify({
          resultCount: 2,
          results: [
            { trackId: 1, wrapperType: 'track', kind: 'song' },
            { trackId: 1, previewUrl: 'https://x/1.m4a', wrapperType: 'track', kind: 'song' },
          ],
        }),
        { status: 200 },
      )
    const hits = await lookupItunesBatch(['1'], 'ng', fetchLike)
    expect(hits.get('1')).toBe('https://x/1.m4a')
  })
})

describe('fetchPreviews', () => {
  it('downloads previews for hits and classifies no_hit vs no_preview vs download_failed (terminal 4xx only)', async () => {
    const fetchLike = fakeFetch({
      itunes: {
        '1': { previewUrl: 'https://x/1.m4a' }, // downloads fine -> ready
        '2': undefined, // no_hit
        '3': {}, // no_preview (hit, but no previewUrl)
        '4': { previewUrl: 'https://x/4.m4a' }, // download fails with a definitive 4xx -> download_failed
      },
      downloads: {
        'https://x/1.m4a': { ok: true },
        'https://x/4.m4a': { ok: false, status: 404 },
      },
    })

    const result = await fetchPreviews(['1', '2', '3', '4'], baseDeps({ fetch: fetchLike }))

    expect([...result.ready.keys()]).toEqual(['1'])
    expect(result.ready.get('1')).toBe(join(cacheDir, '1.m4a'))
    expect(result.skipped).toEqual({ no_hit: 1, no_preview: 1, download_failed: 1 })

    const written = await readFile(join(cacheDir, '1.m4a'), 'utf8')
    expect(written).toBe('audio-bytes')
    await expect(stat(join(cacheDir, '4.m4a'))).rejects.toThrow()
  })

  it('isolates a per-id terminal download failure from other ids in the same batch', async () => {
    const fetchLike = fakeFetch({
      itunes: {
        '1': { previewUrl: 'https://x/1.m4a' },
        '2': { previewUrl: 'https://x/2.m4a' },
      },
      downloads: {
        'https://x/1.m4a': { ok: false, status: 404 },
        'https://x/2.m4a': { ok: true },
      },
    })

    const result = await fetchPreviews(['1', '2'], baseDeps({ fetch: fetchLike }))

    expect(result.ready.has('2')).toBe(true)
    expect(result.ready.has('1')).toBe(false)
    expect(result.skipped.download_failed).toBe(1)
  })

  it('leaves a 5xx download failure unresolved after one retry, never checkpointing it as terminal', async () => {
    const calls: string[] = []
    const fetchLike = fakeFetch({
      itunes: { '1': { previewUrl: 'https://x/1.m4a' } },
      downloads: { 'https://x/1.m4a': { ok: false, status: 503 } },
      downloadCalls: calls,
    })

    const result = await fetchPreviews(['1'], baseDeps({ fetch: fetchLike }))

    expect(result.ready.has('1')).toBe(false)
    expect(result.skipped.download_failed).toBe(0)
    expect(calls).toEqual(['https://x/1.m4a', 'https://x/1.m4a']) // one immediate in-run retry
    await expect(readFile(checkpointPath, 'utf8')).rejects.toThrow() // never written — nothing to checkpoint
  })

  it('treats a thrown network error during download the same as a 5xx: retried once, then left unresolved', async () => {
    const calls: string[] = []
    const fetchLike = fakeFetch({
      itunes: { '1': { previewUrl: 'https://x/1.m4a' } },
      downloads: { 'https://x/1.m4a': { ok: false, throws: true } },
      downloadCalls: calls,
    })

    const result = await fetchPreviews(['1'], baseDeps({ fetch: fetchLike }))

    expect(result.ready.has('1')).toBe(false)
    expect(result.skipped.download_failed).toBe(0)
    expect(calls.length).toBe(2)
  })

  it('retries once after a transient download failure and succeeds if the retry works', async () => {
    const calls: string[] = []
    const fetchLike = fakeFetch({
      itunes: { '1': { previewUrl: 'https://x/1.m4a' } },
      downloads: { 'https://x/1.m4a': [{ ok: false, status: 503 }, { ok: true }] },
      downloadCalls: calls,
    })

    const result = await fetchPreviews(['1'], baseDeps({ fetch: fetchLike }))

    expect(result.ready.get('1')).toBe(join(cacheDir, '1.m4a'))
    expect(calls.length).toBe(2)
  })

  it('treats a 2xx download with an empty body as a transient failure and never caches it', async () => {
    const fetchLike = fakeFetch({
      itunes: { '1': { previewUrl: 'https://x/1.m4a' } },
      downloads: { 'https://x/1.m4a': { ok: true, body: '' } },
    })

    const result = await fetchPreviews(['1'], baseDeps({ fetch: fetchLike }))

    expect(result.ready.has('1')).toBe(false)
    expect(result.skipped.download_failed).toBe(0)
    await expect(stat(join(cacheDir, '1.m4a'))).rejects.toThrow()
    await expect(stat(join(cacheDir, '1.m4a.tmp'))).rejects.toThrow()
  })

  it('does not treat a zero-byte cached file as a hit, and unlinks it so the id is re-fetched', async () => {
    await writeFile(join(cacheDir, '1.m4a'), '')
    const fetchLike = fakeFetch({
      itunes: { '1': { previewUrl: 'https://x/1.m4a' } },
      downloads: { 'https://x/1.m4a': { ok: true } },
    })

    const result = await fetchPreviews(['1'], baseDeps({ fetch: fetchLike }))

    expect(result.ready.get('1')).toBe(join(cacheDir, '1.m4a'))
    const written = await readFile(join(cacheDir, '1.m4a'), 'utf8')
    expect(written).toBe('audio-bytes') // re-downloaded, not left as the stale empty file
  })

  it('passes an abort signal to the download fetch so a stalled socket cannot hang the run', async () => {
    let seenInit: RequestInit | undefined
    const fetchLike: FetchLike = async (url, init) => {
      const s = String(url)
      if (s.includes('itunes.apple.com/lookup')) {
        return new Response(
          JSON.stringify({
            resultCount: 1,
            results: [{ trackId: 1, previewUrl: 'https://x/1.m4a', wrapperType: 'track', kind: 'song' }],
          }),
          { status: 200 },
        )
      }
      seenInit = init
      return new Response('audio-bytes', { status: 200 })
    }

    await fetchPreviews(['1'], baseDeps({ fetch: fetchLike }))
    expect(seenInit?.signal).toBeInstanceOf(AbortSignal)
  })

  it('skips the download and the lookup call entirely when the file is already cached', async () => {
    await writeFile(join(cacheDir, '1.m4a'), 'already-here')
    let lookedUp: string[] = []
    const fetchLike = fakeFetch({ itunes: {}, onLookup: (ids) => (lookedUp = ids) })

    const result = await fetchPreviews(['1'], baseDeps({ fetch: fetchLike }))

    expect(result.ready.get('1')).toBe(join(cacheDir, '1.m4a'))
    expect(lookedUp).toEqual([])
    const stillThere = await readFile(join(cacheDir, '1.m4a'), 'utf8')
    expect(stillThere).toBe('already-here') // untouched, not re-downloaded
  })

  it('honors the throttle: sleeps between lookup calls (not before the first), scaled by callsPerMinute', async () => {
    const delays: number[] = []
    const fetchLike = fakeFetch({
      itunes: { '1': { previewUrl: 'https://x/1.m4a' }, '2': { previewUrl: 'https://x/2.m4a' }, '3': {} },
      downloads: { 'https://x/1.m4a': { ok: true }, 'https://x/2.m4a': { ok: true } },
    })

    await fetchPreviews(
      ['1', '2', '3'],
      baseDeps({
        fetch: fetchLike,
        chunkSize: 1,
        callsPerMinute: 30, // 2000ms interval
        sleep: async (ms) => {
          delays.push(ms)
        },
      }),
    )

    // 3 chunks -> sleep called twice (between call 1->2 and 2->3), never before the first.
    expect(delays).toEqual([2000, 2000])
  })

  it('does not sleep at all for a single chunk', async () => {
    const delays: number[] = []
    const fetchLike = fakeFetch({ itunes: { '1': { previewUrl: 'https://x/1.m4a' } }, downloads: { 'https://x/1.m4a': { ok: true } } })
    await fetchPreviews(['1'], baseDeps({ fetch: fetchLike, sleep: async (ms) => void delays.push(ms) }))
    expect(delays).toEqual([])
  })

  it('leaves ids unresolved (not checkpointed) when the whole batch lookup call fails', async () => {
    const fetchLike = fakeFetch({ itunes: {}, lookupError: true })
    const result = await fetchPreviews(['1', '2'], baseDeps({ fetch: fetchLike }))

    expect(result.ready.size).toBe(0)
    expect(result.skipped).toEqual({ no_hit: 0, no_preview: 0, download_failed: 0 })

    // A fresh run against a checkpoint-less state should retry them (not permanently skipped).
    const rerun = await fetchPreviews(
      ['1'],
      baseDeps({
        fetch: fakeFetch({ itunes: { '1': { previewUrl: 'https://x/1.m4a' } }, downloads: { 'https://x/1.m4a': { ok: true } } }),
      }),
    )
    expect(rerun.ready.has('1')).toBe(true)
  })

  it('logs the numeric HTTP status (not the raw error) when a chunk lookup fails with an HTTP error', async () => {
    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const fetchLike = fakeFetch({ itunes: {}, lookupError: true, lookupStatus: 503 })

    await fetchPreviews(['1'], baseDeps({ fetch: fetchLike }))

    expect(errorSpy).toHaveBeenCalledWith('preview-fetcher: itunes batch lookup failed', { status: 503 })
    errorSpy.mockRestore()
  })

  it('aborts the run after 3 consecutive chunk-lookup failures instead of grinding through every remaining chunk', async () => {
    let lookupCalls = 0
    const fetchLike = fakeFetch({
      itunes: {},
      lookupError: true,
      lookupStatus: 503,
      onLookup: () => {
        lookupCalls += 1
      },
    })

    await expect(
      fetchPreviews(['1', '2', '3', '4', '5'], baseDeps({ fetch: fetchLike, chunkSize: 1 })),
    ).rejects.toThrow('preview-fetcher: aborting run after repeated itunes lookup failures')

    expect(lookupCalls).toBe(3) // stops after the 3rd consecutive failure, never touches chunks 4/5
  })

  describe('checkpoint', () => {
    it('loads prior terminal outcomes and skips those ids without calling fetch', async () => {
      await writeFile(checkpointPath, JSON.stringify({ version: 1, outcomes: { '1': 'no_hit', '2': 'download_failed' } }))
      let lookedUp: string[] = []
      const fetchLike = fakeFetch({ itunes: { '3': { previewUrl: 'https://x/3.m4a' } }, downloads: { 'https://x/3.m4a': { ok: true } }, onLookup: (ids) => (lookedUp = ids) })

      const result = await fetchPreviews(['1', '2', '3'], baseDeps({ fetch: fetchLike }))

      expect(lookedUp).toEqual(['3'])
      expect(result.skipped).toEqual({ no_hit: 1, no_preview: 0, download_failed: 1 })
      expect(result.ready.has('3')).toBe(true)
    })

    it('saves incrementally: outcomes recorded this run are readable back from disk', async () => {
      const fetchLike = fakeFetch({ itunes: { '1': undefined } })
      await fetchPreviews(['1'], baseDeps({ fetch: fetchLike }))

      const onDisk = JSON.parse(await readFile(checkpointPath, 'utf8'))
      expect(onDisk).toEqual({ version: 1, outcomes: { '1': 'no_hit' } })
    })

    it('starts fresh when the checkpoint file is missing', async () => {
      const fetchLike = fakeFetch({ itunes: { '1': { previewUrl: 'https://x/1.m4a' } }, downloads: { 'https://x/1.m4a': { ok: true } } })
      const result = await fetchPreviews(['1'], baseDeps({ fetch: fetchLike }))
      expect(result.ready.has('1')).toBe(true)
    })

    it('starts fresh when the checkpoint file is corrupt JSON', async () => {
      await writeFile(checkpointPath, '{not valid json')
      const fetchLike = fakeFetch({ itunes: { '1': { previewUrl: 'https://x/1.m4a' } }, downloads: { 'https://x/1.m4a': { ok: true } } })
      const result = await fetchPreviews(['1'], baseDeps({ fetch: fetchLike }))
      expect(result.ready.has('1')).toBe(true)
    })

    it('starts fresh when the checkpoint version does not match', async () => {
      await writeFile(checkpointPath, JSON.stringify({ version: 2, outcomes: { '1': 'no_hit' } }))
      let lookedUp: string[] = []
      const fetchLike = fakeFetch({
        itunes: { '1': { previewUrl: 'https://x/1.m4a' } },
        downloads: { 'https://x/1.m4a': { ok: true } },
        onLookup: (ids) => (lookedUp = ids),
      })
      const result = await fetchPreviews(['1'], baseDeps({ fetch: fetchLike }))
      // A stale/mismatched-version checkpoint is discarded, so id '1' is retried rather than skipped.
      expect(lookedUp).toEqual(['1'])
      expect(result.ready.has('1')).toBe(true)
    })

    it('treats an unrecognized checkpoint outcome value as absent (retries that id)', async () => {
      await writeFile(checkpointPath, JSON.stringify({ version: 1, outcomes: { '1': 'no_hit', '2': 'not_a_real_outcome' } }))
      let lookedUp: string[] = []
      const fetchLike = fakeFetch({
        itunes: { '2': { previewUrl: 'https://x/2.m4a' } },
        downloads: { 'https://x/2.m4a': { ok: true } },
        onLookup: (ids) => (lookedUp = ids),
      })

      const result = await fetchPreviews(['1', '2'], baseDeps({ fetch: fetchLike }))

      expect(lookedUp).toEqual(['2'])
      expect(result.skipped.no_hit).toBe(1)
      expect(result.ready.has('2')).toBe(true)
    })
  })
})
