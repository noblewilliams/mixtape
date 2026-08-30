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
      return { version: CHECKPOINT_VERSION, outcomes: { ...(parsed as Checkpoint).outcomes } }
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

type ItunesLookupResult = { trackId?: number; previewUrl?: string }

/**
 * Looks up many apple_ids in a single iTunes `lookup?id=a,b,c` call and
 * returns a map keyed by (string) apple_id -> previewUrl, or null when the
 * catalog has the track but no preview URL. An id absent from the returned
 * map means iTunes returned no result for it at all (a "no_hit").
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

  const hits = new Map<string, string | null>()
  if (Array.isArray(body?.results)) {
    for (const r of body.results) {
      if (r.trackId == null) continue
      hits.set(String(r.trackId), r.previewUrl ?? null)
    }
  }
  return hits
}

// --- download -----------------------------------------------------------------

/**
 * Downloads previewUrl to destPath via write-temp-then-rename, so a crash or
 * network drop mid-download can never leave a truncated file that a later
 * run's "cache hit" existence check would mistake for a complete one.
 */
async function downloadPreview(previewUrl: string, destPath: string, fetchLike: FetchLike): Promise<void> {
  const res = await fetchLike(previewUrl)
  if (!res.ok) throw new Error('preview download failed')
  const buf = Buffer.from(await res.arrayBuffer())
  const tmpPath = `${destPath}.tmp`
  await fs.writeFile(tmpPath, buf)
  await fs.rename(tmpPath, destPath)
}

async function fileExists(path: string): Promise<boolean> {
  try {
    await fs.access(path)
    return true
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

/**
 * Resolves each apple_id in `appleIds` to a local preview file, or a
 * terminal outcome. Never throws on a single id's failure — every failure
 * mode (batch lookup HTTP/JSON error, per-id download error) is isolated so
 * one bad id/chunk can't abort the run.
 *
 * A batch-level lookup failure (network/HTTP/JSON) is NOT recorded as a
 * terminal outcome for its ids — that's a transient fetch problem, not a
 * catalog fact, so those ids are simply left unresolved for a future run.
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
    if (await fileExists(cachedPath)) {
      ready.set(appleId, cachedPath)
      continue
    }
    pending.push(appleId)
  }

  const chunks = chunkIds(pending, chunkSize)
  const intervalMs = (60 * 1000) / callsPerMinute

  for (let i = 0; i < chunks.length; i++) {
    // Throttle between lookup calls only, never before the first one.
    if (i > 0) await sleep(intervalMs)
    const idsInChunk = chunks[i]

    let hits: Map<string, string | null>
    try {
      hits = await lookupItunesBatch(idsInChunk, storefront, fetchLike)
    } catch {
      // Fixed string only — never interpolate the underlying HTTP/JSON error,
      // which can carry response-body detail (credential-leak lesson).
      console.error('preview-fetcher: itunes batch lookup failed')
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
      try {
        await downloadPreview(previewUrl, destPath, fetchLike)
        ready.set(appleId, destPath)
      } catch {
        // Fixed string only, same rationale as the lookup catch above.
        console.error('preview-fetcher: preview download failed')
        checkpoint.outcomes[appleId] = 'download_failed'
        skipped.download_failed += 1
        await saveCheckpoint(checkpointPath, checkpoint)
      }
    }
  }

  return { ready, skipped }
}
