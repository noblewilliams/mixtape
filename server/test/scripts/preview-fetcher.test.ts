import { mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { chunkIds, fetchPreviews, lookupItunesBatch, type FetchPreviewsDeps } from '../../scripts/lib/preview-fetcher'
import type { FetchLike } from '../../src/enrich/types'

// --- fetch fakes --------------------------------------------------------------

/** Builds a FetchLike that answers itunes lookup calls from an id -> {trackId, previewUrl} table, and preview downloads from a url -> body table. */
function fakeFetch(opts: {
  itunes?: Record<string, { previewUrl?: string } | undefined>
  downloads?: Record<string, { ok: boolean; body?: string }>
  onLookup?: (ids: string[]) => void
  lookupError?: boolean
}): FetchLike {
  return async (url) => {
    const s = String(url)
    if (s.includes('itunes.apple.com/lookup')) {
      const requestedIds = new URL(s).searchParams.get('id')!.split(',')
      opts.onLookup?.(requestedIds)
      if (opts.lookupError) return new Response('nope', { status: 503 })
      const results = requestedIds
        .filter((id) => opts.itunes?.[id] !== undefined)
        .map((id) => ({ trackId: Number(id), previewUrl: opts.itunes![id]?.previewUrl }))
      return new Response(JSON.stringify({ resultCount: results.length, results }), { status: 200 })
    }
    const download = opts.downloads?.[s]
    if (download) {
      if (!download.ok) return new Response('nope', { status: 500 })
      return new Response(download.body ?? 'audio-bytes', { status: 200 })
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
})

describe('fetchPreviews', () => {
  it('downloads previews for hits and classifies no_hit vs no_preview vs download_failed', async () => {
    const fetchLike = fakeFetch({
      itunes: {
        '1': { previewUrl: 'https://x/1.m4a' }, // downloads fine -> ready
        '2': undefined, // no_hit
        '3': {}, // no_preview (hit, but no previewUrl)
        '4': { previewUrl: 'https://x/4.m4a' }, // download fails -> download_failed
      },
      downloads: {
        'https://x/1.m4a': { ok: true },
        'https://x/4.m4a': { ok: false },
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

  it('isolates a per-id download failure from other ids in the same batch', async () => {
    const fetchLike = fakeFetch({
      itunes: {
        '1': { previewUrl: 'https://x/1.m4a' },
        '2': { previewUrl: 'https://x/2.m4a' },
      },
      downloads: {
        'https://x/1.m4a': { ok: false },
        'https://x/2.m4a': { ok: true },
      },
    })

    const result = await fetchPreviews(['1', '2'], baseDeps({ fetch: fetchLike }))

    expect(result.ready.has('2')).toBe(true)
    expect(result.ready.has('1')).toBe(false)
    expect(result.skipped.download_failed).toBe(1)
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
  })
})
