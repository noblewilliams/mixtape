/**
 * preview-fetcher — iTunes preview lookup + download for the P2.5
 * feature-coverage lift (see
 * docs/superpowers/plans/2026-08-30-p2.5-local-preview-analysis.md).
 *
 * Runs ONLY from founder-Mac CLI scripts (never bundled into the Worker).
 *
 * `lookupItunes` (src/enrich/itunes.ts) takes exactly one apple_id per call
 * and only ever reads the FIRST result — it has no batch-id shape, so it
 * can't report which of several requested ids a given result belongs to.
 * The plan calls for batching many ids per call (iTunes `lookup?id=a,b,c`),
 * so this file adds its own `lookupItunesBatch` that hits the same endpoint
 * directly via the injected FetchLike seam, keyed by `trackId` in the
 * response. src/ itself is untouched, per the plan.
 *
 * Public entry point: fetchPreviews(appleIds, deps) — see FetchPreviewsResult
 * below for the shape Task 3's orchestrator consumes.
 */
import { promises as fs } from 'node:fs'
import { join } from 'node:path'
import { EnrichSourceError, SOURCE_TIMEOUT_MS, type FetchLike } from '../../src/enrich/types'

// --- checkpoint -------------------------------------------------------------

/** Terminal per-apple_id outcomes this module can reach — never retried once recorded. */
export type PreviewOutcome = 'no_hit' | 'no_preview' | 'download_failed'

const VALID_OUTCOMES: readonly PreviewOutcome[] = ['no_hit', 'no_preview', 'download_failed']

function isValidOutcome(value: unknown): value is PreviewOutcome {
  return typeof value === 'string' && (VALID_OUTCOMES as readonly string[]).includes(value)
}

const CHECKPOINT_VERSION = 1

type Checkpoint = {
  version: typeof CHECKPOINT_VERSION
  outcomes: Record<string, PreviewOutcome>
}

function freshCheckpoint(): Checkpoint {
  return { version: CHECKPOINT_VERSION, outcomes: {} }
}

/**
 * Missing file, corrupt JSON, or a schema/version mismatch all fall back to
 * a fresh (empty) checkpoint rather than throwing — a checkpoint is a
 * resumability optimization, never a source of truth that can block a run.
 * Individual outcome VALUES are validated too: an unrecognized value is
 * dropped rather than trusted, so that id is simply treated as unresolved
 * and retried this run.
 */
async function loadCheckpoint(path: string): Promise<Checkpoint> {
  try {
    const raw = await fs.readFile(path, 'utf8')
    const parsed: unknown = JSON.parse(raw)
    if (
      parsed &&
      typeof parsed === 'object' &&
      (parsed as { version?: unknown }).version === CHECKPOINT_VERSION &&
      typeof (parsed as { outcomes?: unknown }).outcomes === 'object' &&
      (parsed as { outcomes?: unknown }).outcomes !== null
    ) {
      const rawOutcomes = (parsed as Checkpoint).outcomes
      const outcomes: Record<string, PreviewOutcome> = {}
      for (const [id, outcome] of Object.entries(rawOutcomes)) {
        if (isValidOutcome(outcome)) outcomes[id] = outcome
      }
      return { version: CHECKPOINT_VERSION, outcomes }
    }
    return freshCheckpoint()
  } catch {
    return freshCheckpoint()
  }
}

/** Write-temp-then-rename so a crash mid-write never leaves a truncated/corrupt checkpoint. */
async function saveCheckpoint(path: string, checkpoint: Checkpoint): Promise<void> {
  const tmpPath = `${path}.tmp`
  await fs.writeFile(tmpPath, JSON.stringify(checkpoint))
  await fs.rename(tmpPath, path)
}

// --- chunking + throttling ---------------------------------------------------

/** Splits ids into groups of at most `size`, preserving order. Exported for direct chunking-math tests. */
export function chunkIds(ids: readonly string[], size: number): string[][] {
  const out: string[][] = []
  for (let i = 0; i < ids.length; i += size) out.push(ids.slice(i, i + size))
  return out
}

export type Sleep = (ms: number) => Promise<void>

const realSleep: Sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

// --- itunes batch lookup ------------------------------------------------------

type ItunesLookupResult = { trackId?: number; previewUrl?: string; wrapperType?: string; kind?: string }

/**
 * Looks up many apple_ids in a single iTunes `lookup?id=a,b,c` call and
 * returns a map keyed by (string) apple_id -> previewUrl, or null when the
 * catalog has the track but no preview URL. An id absent from the returned
 * map means iTunes returned no result for it at all (a "no_hit").
 *
 * Only `wrapperType === 'track' && kind === 'song'` results count as a hit —
 * a music-video result can carry the same trackId with an .m4v previewUrl,
 * which would otherwise be fed to the audio analyzer as if it were the song
 * preview. A duplicate trackId (e.g. storefront variants) prefers whichever
 * entry has a non-null previewUrl, instead of letting a later null entry
 * win just because it came last.
 */
export async function lookupItunesBatch(
  appleIds: readonly string[],
  storefront: string,
  fetchLike: FetchLike,
): Promise<Map<string, string | null>> {
  const u = new URL('https://itunes.apple.com/lookup')
  u.searchParams.set('id', appleIds.join(','))
  u.searchParams.set('country', storefront)
  const res = await fetchLike(u, {
    headers: { 'User-Agent': 'mixtape/0.1 (personal project; enrichment)' },
    signal: AbortSignal.timeout(SOURCE_TIMEOUT_MS),
  })
  if (!res.ok) throw new EnrichSourceError('itunes', `HTTP ${res.status}`, res.status)
  const body = (await res.json().catch(() => {
    throw new EnrichSourceError('itunes', 'malformed JSON')
  })) as { resultCount?: number; results?: ItunesLookupResult[] }

  if (!Array.isArray(body?.results)) {
    // A 200 with no results array is not "zero hits" — it's a response shape
    // the catalog shouldn't produce. Treating it as an empty map would
    // permanently checkpoint every id in the chunk as no_hit; throwing lets
    // the caller fold it into the same transient class as any other lookup
    // failure (retried next run, not blacklisted).
    throw new EnrichSourceError('itunes', 'missing results array')
  }

  const hits = new Map<string, string | null>()
  for (const r of body.results) {
    if (r.trackId == null) continue
    if (r.wrapperType !== 'track' || r.kind !== 'song') continue
    const id = String(r.trackId)
    const existing = hits.get(id)
    if (existing != null) continue // a non-null previewUrl already recorded for this id wins over any later duplicate
    hits.set(id, r.previewUrl ?? null)
  }
  return hits
}

// --- download -----------------------------------------------------------------

/** Definitive per-download outcome: a 4xx means the catalog rejected the request permanently. */
class TerminalDownloadError extends Error {}
/** Everything else (network throw, timeout, 5xx, empty body) — worth retrying, never a permanent fact. */
class TransientDownloadError extends Error {}

/**
 * Downloads previewUrl to destPath via write-temp-then-rename, so a crash or
 * network drop mid-download can never leave a truncated file that a later
 * run's cache-hit check would mistake for a complete one. Bounded by the
 * same timeout as the lookup path so a stalled CDN socket can't hang the
 * sequential run forever.
 */
async function downloadPreview(previewUrl: string, destPath: string, fetchLike: FetchLike): Promise<void> {
  let res: Response
  try {
    res = await fetchLike(previewUrl, { signal: AbortSignal.timeout(SOURCE_TIMEOUT_MS) })
  } catch {
    throw new TransientDownloadError('network error')
  }
  if (!res.ok) {
    if (res.status >= 400 && res.status < 500) throw new TerminalDownloadError(`HTTP ${res.status}`)
    throw new TransientDownloadError(`HTTP ${res.status}`)
  }
  const buf = Buffer.from(await res.arrayBuffer())
  if (buf.length === 0) {
    // A 2xx with an empty body is corrupt, not a silently-valid preview —
    // never rename it into the cache, where it'd be served as a ready hit
    // forever and fed to the analyzer as garbage.
    throw new TransientDownloadError('empty body')
  }
  const tmpPath = `${destPath}.tmp`
  await fs.writeFile(tmpPath, buf)
  await fs.rename(tmpPath, destPath)
}

type DownloadOutcome = 'success' | 'terminal' | 'transient'

async function attemptDownload(previewUrl: string, destPath: string, fetchLike: FetchLike): Promise<DownloadOutcome> {
  try {
    await downloadPreview(previewUrl, destPath, fetchLike)
    return 'success'
  } catch (err) {
    return err instanceof TerminalDownloadError ? 'terminal' : 'transient'
  }
}

/**
 * A cache "hit" requires a non-empty file: a 0-byte file left by some prior
 * bug or interrupted process is not a valid preview, and would otherwise be
 * served as ready forever. Such a file is unlinked so the id gets re-fetched
 * instead of silently poisoning the analyzer.
 */
async function isCachedHit(path: string): Promise<boolean> {
  try {
    const st = await fs.stat(path)
    if (st.size > 0) return true
    await fs.unlink(path).catch(() => {})
    return false
  } catch {
    return false
  }
}

// --- orchestration --------------------------------------------------------------

export type FetchPreviewsDeps = {
  fetch: FetchLike
  storefront: string
  cacheDir: string
  checkpointPath: string
  /** Injectable for tests; defaults to a real setTimeout-based sleep. */
  sleep?: Sleep
  /** ids per iTunes lookup call; plan default ~100. */
  chunkSize?: number
  /** throttle ceiling for lookup calls only — downloads are not throttled. */
  callsPerMinute?: number
}

export type FetchPreviewsResult = {
  /** apple_id -> local m4a file path, ready for Task 3's analyzer. */
  ready: Map<string, string>
  /** counts of ids that ended in each terminal (non-ready) outcome this run + from a prior checkpoint. */
  skipped: Record<PreviewOutcome, number>
}

const DEFAULT_CHUNK_SIZE = 100
const DEFAULT_CALLS_PER_MINUTE = 20
const MAX_CONSECUTIVE_CHUNK_FAILURES = 3

/**
 * Resolves each apple_id in `appleIds` to a local preview file, or a
 * terminal outcome. A single id's failure never aborts the run — every
 * per-id failure mode is isolated. The one exception is the chunk-level
 * iTunes lookup call: 3 consecutive chunk failures aborts the whole run
 * (throws) rather than grinding through every remaining chunk against
 * whatever is breaking upstream (e.g. the IP getting rate-limited mid-run).
 *
 * A batch-level lookup failure (network/HTTP/JSON) is NOT recorded as a
 * terminal outcome for its ids — that's a transient fetch problem, not a
 * catalog fact, so those ids are simply left unresolved for a future run.
 * Per-id download failures follow the same transient/terminal split: only a
 * definitive 4xx is checkpointed as `download_failed`; a 5xx or thrown
 * network error gets one immediate in-run retry, then — if still failing —
 * is left unresolved rather than permanently blacklisted.
 */
export async function fetchPreviews(
  appleIds: readonly string[],
  deps: FetchPreviewsDeps,
): Promise<FetchPreviewsResult> {
  const {
    fetch: fetchLike,
    storefront,
    cacheDir,
    checkpointPath,
    sleep = realSleep,
    chunkSize = DEFAULT_CHUNK_SIZE,
    callsPerMinute = DEFAULT_CALLS_PER_MINUTE,
  } = deps

  await fs.mkdir(cacheDir, { recursive: true })
  const checkpoint = await loadCheckpoint(checkpointPath)

  const ready = new Map<string, string>()
  const skipped: Record<PreviewOutcome, number> = { no_hit: 0, no_preview: 0, download_failed: 0 }

  const pending: string[] = []
  for (const appleId of appleIds) {
    const priorOutcome = checkpoint.outcomes[appleId]
    if (priorOutcome) {
      skipped[priorOutcome] += 1
      continue
    }
    const cachedPath = join(cacheDir, `${appleId}.m4a`)
    if (await isCachedHit(cachedPath)) {
      ready.set(appleId, cachedPath)
      continue
    }
    pending.push(appleId)
  }

  const chunks = chunkIds(pending, chunkSize)
  const intervalMs = (60 * 1000) / callsPerMinute
  let consecutiveChunkFailures = 0

  for (let i = 0; i < chunks.length; i++) {
    // Throttle between lookup calls only, never before the first one.
    if (i > 0) await sleep(intervalMs)
    const idsInChunk = chunks[i]

    let hits: Map<string, string | null>
    try {
      hits = await lookupItunesBatch(idsInChunk, storefront, fetchLike)
      consecutiveChunkFailures = 0
    } catch (err) {
      // Fixed string only — never interpolate the underlying HTTP/JSON error,
      // which can carry response-body detail (credential-leak lesson). The
      // numeric HTTP status is not a credential, so it's logged as separate
      // structured data when available.
      if (err instanceof EnrichSourceError && typeof err.status === 'number') {
        console.error('preview-fetcher: itunes batch lookup failed', { status: err.status })
      } else {
        console.error('preview-fetcher: itunes batch lookup failed')
      }
      consecutiveChunkFailures += 1
      if (consecutiveChunkFailures >= MAX_CONSECUTIVE_CHUNK_FAILURES) {
        throw new Error('preview-fetcher: aborting run after repeated itunes lookup failures')
      }
      continue
    }

    for (const appleId of idsInChunk) {
      if (!hits.has(appleId)) {
        checkpoint.outcomes[appleId] = 'no_hit'
        skipped.no_hit += 1
        await saveCheckpoint(checkpointPath, checkpoint)
        continue
      }

      const previewUrl = hits.get(appleId) ?? null
      if (!previewUrl) {
        checkpoint.outcomes[appleId] = 'no_preview'
        skipped.no_preview += 1
        await saveCheckpoint(checkpointPath, checkpoint)
        continue
      }

      const destPath = join(cacheDir, `${appleId}.m4a`)
      let outcome = await attemptDownload(previewUrl, destPath, fetchLike)
      if (outcome === 'transient') {
        outcome = await attemptDownload(previewUrl, destPath, fetchLike) // one immediate in-run retry
      }

      if (outcome === 'success') {
        ready.set(appleId, destPath)
      } else if (outcome === 'terminal') {
        console.error('preview-fetcher: preview download failed')
        checkpoint.outcomes[appleId] = 'download_failed'
        skipped.download_failed += 1
        await saveCheckpoint(checkpointPath, checkpoint)
      } else {
        // Still transient after the retry — leave unresolved for a future
        // run rather than permanently blacklisting what may be a CDN blip.
        console.error('preview-fetcher: preview download failed (transient, will retry next run)')
      }
    }
  }

  return { ready, skipped }
}
