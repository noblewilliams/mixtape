/**
 * analyze-previews — orchestrator CLI for the P2.5 local-preview
 * feature-coverage lift (see
 * docs/superpowers/plans/2026-08-30-p2.5-local-preview-analysis.md).
 *
 * For every track with an apple_id, no track_features row, and an EXHAUSTED
 * ReccoBeats features attempt (enrichment_failures.stage = 'features' with
 * attempts >= MAX_ATTEMPTS — i.e. a track the nightly enrich runner
 * (src/enrich/runner.ts) has already given up on): look up its iTunes 30s
 * preview (scripts/lib/preview-fetcher.ts), decode + analyze it locally
 * (scripts/lib/preview-analyzer.ts), and insert a partial track_features row
 * — insert-only, never overwriting an existing (e.g. ReccoBeats) row.
 *
 * A track that hasn't yet exhausted its ReccoBeats attempts is deliberately
 * NOT a candidate here — the enrich runner still owns it (it works through
 * the backlog a few tracks at a time on a cron), and inserting a
 * `local_preview` row for it would permanently lock it out of ReccoBeats'
 * richer 11-field data (the runner skips any track that already has a
 * features row, regardless of source).
 *
 * Usage (from server/):
 *   npx tsx scripts/analyze-previews.ts             # dry run (default)
 *   npx tsx scripts/analyze-previews.ts --apply
 *   npx tsx scripts/analyze-previews.ts --apply --limit 50
 *
 * Loads DATABASE_URL (and optionally ITUNES_STOREFRONT) from .dev.vars (same
 * loading style as scripts/retitle-sessions.ts). Dry run never touches the
 * network, the preview cache, or the database — it only reads candidates and
 * prints them.
 *
 * Cache dir: ~/.cache/mixtape-previews/ (override with MIXTAPE_PREVIEW_CACHE).
 * This orchestrator keeps its own checkpoint (analysis-checkpoint.json,
 * tracking per-track decode/analyze failures) separate from the fetcher's
 * (checkpoint.json, tracking per-apple_id preview-lookup/download outcomes)
 * — the two record different failure classes and must never share a file.
 */
import { readFileSync } from 'node:fs'
import { mkdir, readFile, rename, rm, writeFile } from 'node:fs/promises'
import { homedir, tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { and, eq, gte, isNotNull, isNull, sql } from 'drizzle-orm'
import { neon } from '@neondatabase/serverless'
import { drizzle } from 'drizzle-orm/neon-http'
import * as schema from '../src/db/schema'
import { tracks, trackFeatures, enrichmentFailures } from '../src/db/schema'
import type { Db } from '../src/db/types'
import type { FetchLike } from '../src/enrich/types'
import { MAX_ATTEMPTS } from '../src/enrich/runner'
import { fetchPreviews as realFetchPreviews, type FetchPreviewsResult } from './lib/preview-fetcher'
import { decodeToWav as realDecodeToWav, analyzePreview as realAnalyzePreview, type PreviewFeatures } from './lib/preview-analyzer'

// This CLI writes ONLY the feature subset genuinely derivable from 30s of
// audio — never a fabricated proxy for valence/acousticness/instrumentalness/
// liveness/speechiness (see the plan's honesty rule). Distinguishes rows this
// script writes from `source: 'reccobeats'` rows (src/enrich/pipeline.ts).
const SOURCE = 'local_preview'

const PROGRESS_EVERY = 25
const TITLE_TRUNCATE = 40

function devVars(): Record<string, string> {
  const out: Record<string, string> = {}
  for (const line of readFileSync(new URL('../.dev.vars', import.meta.url), 'utf8').split('\n')) {
    const i = line.indexOf('=')
    if (i > 0 && !line.startsWith('#')) {
      const key = line.slice(0, i)
      let value = line.slice(i + 1).trim()
      // Strip a single layer of matching surrounding quotes — a quoted
      // DATABASE_URL would otherwise reach neon() with the quote characters
      // still attached, which throws with the full connection string
      // (credentials included) embedded in the error message.
      if (
        value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'")))
      ) {
        value = value.slice(1, -1)
      }
      out[key] = value
    }
  }
  return out
}

// --- candidate selection -----------------------------------------------------

export type Candidate = { id: string; appleId: string; title: string; artist: string }

/**
 * Tracks with an apple_id, no track_features row, and an EXHAUSTED features
 * enrichment attempt — excluded by the query itself, so a track that gains a
 * features row (from either source) or hasn't yet exhausted its ReccoBeats
 * attempts is never selected. The inner join on enrichment_failures means a
 * track with no failures row at all (never attempted) is excluded outright.
 */
export async function selectCandidates(db: Db, limit?: number): Promise<Candidate[]> {
  const query = db
    .select({ id: tracks.id, appleId: tracks.appleId, title: tracks.title, artist: tracks.artist })
    .from(tracks)
    .leftJoin(trackFeatures, eq(trackFeatures.trackId, tracks.id))
    .innerJoin(
      enrichmentFailures,
      and(eq(enrichmentFailures.trackId, tracks.id), eq(enrichmentFailures.stage, 'features')),
    )
    .where(
      and(
        isNotNull(tracks.appleId),
        isNull(trackFeatures.trackId),
        gte(enrichmentFailures.attempts, MAX_ATTEMPTS),
      ),
    )
    .orderBy(tracks.createdAt, tracks.id)

  const rows = limit != null ? await query.limit(limit) : await query
  // isNotNull(tracks.appleId) in the WHERE guarantees appleId is non-null here.
  return rows.map((r) => ({ ...r, appleId: r.appleId as string }))
}

async function coveragePercent(db: Db): Promise<number> {
  const [totalRow] = await db.select({ count: sql<number>`count(*)::int` }).from(tracks)
  const [withFeaturesRow] = await db.select({ count: sql<number>`count(*)::int` }).from(trackFeatures)
  const total = Number(totalRow?.count ?? 0)
  const withFeatures = Number(withFeaturesRow?.count ?? 0)
  return total > 0 ? (withFeatures / total) * 100 : 0
}

function truncateTitle(title: string): string {
  return title.length > TITLE_TRUNCATE ? `${title.slice(0, TITLE_TRUNCATE - 1)}…` : title
}

// --- orchestrator checkpoint --------------------------------------------------
//
// Records per-track (by track id) decode/analyze failures across runs. Kept
// deliberately separate from the fetcher's own checkpoint (which tracks
// per-apple_id lookup/download outcomes) — different failure class, different
// file. Without this, a rerun's deterministic candidate ordering would burn
// its first N slots on the same permanently-broken tracks every time.

const ANALYSIS_CHECKPOINT_VERSION = 1

type AnalysisCheckpoint = { version: typeof ANALYSIS_CHECKPOINT_VERSION; failed: Record<string, true> }

function freshAnalysisCheckpoint(): AnalysisCheckpoint {
  return { version: ANALYSIS_CHECKPOINT_VERSION, failed: {} }
}

/**
 * Missing file, corrupt JSON, or a schema/version mismatch all fall back to a
 * fresh (empty) checkpoint rather than throwing — same non-blocking
 * resumability-optimization stance as the fetcher's checkpoint.
 */
async function loadAnalysisCheckpoint(path: string): Promise<AnalysisCheckpoint> {
  try {
    const raw = await readFile(path, 'utf8')
    const parsed: unknown = JSON.parse(raw)
    if (
      parsed &&
      typeof parsed === 'object' &&
      (parsed as { version?: unknown }).version === ANALYSIS_CHECKPOINT_VERSION &&
      typeof (parsed as { failed?: unknown }).failed === 'object' &&
      (parsed as { failed?: unknown }).failed !== null
    ) {
      const rawFailed = (parsed as AnalysisCheckpoint).failed
      const failed: Record<string, true> = {}
      for (const [id, value] of Object.entries(rawFailed)) {
        if (value === true) failed[id] = true
      }
      return { version: ANALYSIS_CHECKPOINT_VERSION, failed }
    }
    return freshAnalysisCheckpoint()
  } catch {
    return freshAnalysisCheckpoint()
  }
}

/** Write-temp-then-rename so a crash mid-write never leaves a truncated/corrupt checkpoint. */
async function saveAnalysisCheckpoint(path: string, checkpoint: AnalysisCheckpoint): Promise<void> {
  await mkdir(dirname(path), { recursive: true })
  const tmpPath = `${path}.tmp`
  await writeFile(tmpPath, JSON.stringify(checkpoint))
  await rename(tmpPath, path)
}

// --- orchestration ------------------------------------------------------------

export type AnalyzePreviewsDeps = {
  db: Db
  apply: boolean
  limit?: number
  storefront: string
  cacheDir: string
  checkpointPath: string
  analysisCheckpointPath: string
  fetch: FetchLike
  fetchPreviews: typeof realFetchPreviews
  decodeToWav: typeof realDecodeToWav
  analyzePreview: typeof realAnalyzePreview
  log: (line: string) => void
}

export type RunSummary = {
  candidates: number
  previouslyFailed: number
  analyzed: number
  noHit: number
  noPreview: number
  downloadFailed: number
  analysisFailed: number
  coveragePercent: number
}

export async function runAnalyzePreviews(deps: AnalyzePreviewsDeps): Promise<RunSummary> {
  const {
    db,
    apply,
    limit,
    storefront,
    cacheDir,
    checkpointPath,
    analysisCheckpointPath,
    fetch,
    fetchPreviews,
    decodeToWav,
    analyzePreview,
    log,
  } = deps

  const candidates = await selectCandidates(db, limit)
  log(`${candidates.length} candidate(s)${apply ? '' : ' — dry run, no network/writes'}`)

  if (!apply) {
    log(`cache dir: ${cacheDir}`)
    log(`checkpoint: ${checkpointPath}`)
    for (const c of candidates.slice(0, 10)) {
      log(`  ${c.id}  ${truncateTitle(c.title)} — ${c.artist}`)
    }
    return {
      candidates: candidates.length,
      previouslyFailed: 0,
      analyzed: 0,
      noHit: 0,
      noPreview: 0,
      downloadFailed: 0,
      analysisFailed: 0,
      coveragePercent: await coveragePercent(db),
    }
  }

  // Consult the orchestrator's own checkpoint at candidate-filter time —
  // before any fetch — so a track whose decode/analyze permanently fails is
  // never re-fetched, re-decoded, and re-analyzed on every subsequent run.
  const analysisCheckpoint = await loadAnalysisCheckpoint(analysisCheckpointPath)
  const toProcess: Candidate[] = []
  let previouslyFailed = 0
  for (const c of candidates) {
    if (analysisCheckpoint.failed[c.id]) {
      previouslyFailed++
    } else {
      toProcess.push(c)
    }
  }

  const idToCandidate = new Map(toProcess.map((c) => [c.appleId, c]))
  const appleIds = toProcess.map((c) => c.appleId)

  const { ready, skipped }: FetchPreviewsResult = await fetchPreviews(appleIds, {
    fetch,
    storefront,
    cacheDir,
    checkpointPath,
  })

  let analyzed = 0
  let analysisFailed = 0
  let processed = 0
  const total = ready.size

  for (const [appleId, m4aPath] of ready) {
    processed++
    const candidate = idToCandidate.get(appleId)
    // Every key in `ready` came from `appleIds` above, so this is always
    // found — the guard just keeps the loop body's types honest.
    if (!candidate) continue

    const wavPath = join(tmpdir(), `mixtape-preview-${candidate.id}.wav`)
    try {
      await decodeToWav(m4aPath, wavPath)
      const features: PreviewFeatures = await analyzePreview(wavPath)
      const inserted = await db
        .insert(trackFeatures)
        .values({ trackId: candidate.id, ...features, source: SOURCE })
        .onConflictDoNothing()
        .returning()
      analyzed += inserted.length
    } catch {
      // Fixed string, id interpolation only — never a decode/analyze error's
      // own message (it can echo back filesystem paths and other detail we
      // don't want in logs; same lesson as scripts/retitle-sessions.ts).
      log(`failed: ${candidate.id}`)
      analysisFailed++
      analysisCheckpoint.failed[candidate.id] = true
      await saveAnalysisCheckpoint(analysisCheckpointPath, analysisCheckpoint)
    } finally {
      try {
        await rm(wavPath, { force: true })
      } catch {
        // Best-effort tmpfile cleanup — an EPERM/EBUSY here must never
        // escape and abort the per-track isolation the outer try/catch
        // exists to provide.
      }
    }

    if (processed % PROGRESS_EVERY === 0 || processed === total) {
      log(`${processed}/${total} analyzed=${analyzed} failed=${analysisFailed}`)
    }
  }

  const coverage = await coveragePercent(db)
  log(
    `analyzed=${analyzed} previously_failed=${previouslyFailed} no_hit=${skipped.no_hit} no_preview=${skipped.no_preview} download_failed=${skipped.download_failed} analysis_failed=${analysisFailed}`,
  )
  log(`features coverage: ${coverage.toFixed(1)}%`)

  return {
    candidates: candidates.length,
    previouslyFailed,
    analyzed,
    noHit: skipped.no_hit,
    noPreview: skipped.no_preview,
    downloadFailed: skipped.download_failed,
    analysisFailed,
    coveragePercent: coverage,
  }
}

// --- CLI entrypoint -------------------------------------------------------------

async function main() {
  const apply = process.argv.includes('--apply')
  const limitFlagIndex = process.argv.indexOf('--limit')
  const limit = limitFlagIndex >= 0 ? Number(process.argv[limitFlagIndex + 1]) : undefined
  if (limit != null && (!Number.isInteger(limit) || limit <= 0)) {
    throw new Error('--limit requires a positive integer')
  }

  const env = devVars()
  if (!env.DATABASE_URL) throw new Error('DATABASE_URL missing from .dev.vars')

  // Never let a construction failure here bubble e.message up to main's own
  // catch — an unstripped/malformed DATABASE_URL makes neon() throw with the
  // full connection string (credentials included) embedded in its message.
  let db: Db
  try {
    db = drizzle(neon(env.DATABASE_URL), { schema }) as unknown as Db
  } catch {
    throw new Error('invalid DATABASE_URL in .dev.vars')
  }

  const cacheDir = process.env.MIXTAPE_PREVIEW_CACHE || join(homedir(), '.cache', 'mixtape-previews')
  const checkpointPath = join(cacheDir, 'checkpoint.json')
  const analysisCheckpointPath = join(cacheDir, 'analysis-checkpoint.json')

  const summary = await runAnalyzePreviews({
    db,
    apply,
    limit,
    // Matches src/index.ts:54's buildDeps fallback exactly.
    storefront: env.ITUNES_STOREFRONT ?? 'ng',
    cacheDir,
    checkpointPath,
    analysisCheckpointPath,
    fetch,
    fetchPreviews: realFetchPreviews,
    decodeToWav: realDecodeToWav,
    analyzePreview: realAnalyzePreview,
    log: (line: string) => console.log(line),
  })

  if (!apply) {
    console.log(`${summary.candidates} candidate(s) would be analyzed`)
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch((e) => {
    console.error('analyze-previews failed:', e instanceof Error ? e.message : e)
    process.exit(1)
  })
}
