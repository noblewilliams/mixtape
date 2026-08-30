/**
 * analyze-previews — orchestrator CLI for the P2.5 local-preview
 * feature-coverage lift (see
 * docs/superpowers/plans/2026-08-30-p2.5-local-preview-analysis.md).
 *
 * For every track with an apple_id and no track_features row: look up its
 * iTunes 30s preview (scripts/lib/preview-fetcher.ts), decode + analyze it
 * locally (scripts/lib/preview-analyzer.ts), and insert a partial
 * track_features row — insert-only, never overwriting an existing (e.g.
 * ReccoBeats) row.
 *
 * Usage (from server/):
 *   npx tsx scripts/analyze-previews.ts             # dry run (default)
 *   npx tsx scripts/analyze-previews.ts --apply
 *   npx tsx scripts/analyze-previews.ts --apply --limit 50
 *
 * Loads DATABASE_URL from .dev.vars (same loading style as
 * scripts/retitle-sessions.ts). Dry run never touches the network, the
 * preview cache, or the database — it only reads candidates and prints them.
 *
 * Cache dir: ~/.cache/mixtape-previews/ (override with MIXTAPE_PREVIEW_CACHE).
 */
import { readFileSync } from 'node:fs'
import { rm } from 'node:fs/promises'
import { homedir, tmpdir } from 'node:os'
import { join } from 'node:path'
import { and, eq, isNotNull, isNull, sql } from 'drizzle-orm'
import { neon } from '@neondatabase/serverless'
import { drizzle } from 'drizzle-orm/neon-http'
import * as schema from '../src/db/schema'
import { tracks, trackFeatures } from '../src/db/schema'
import type { Db } from '../src/db/types'
import type { FetchLike } from '../src/enrich/types'
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

/** Tracks with an apple_id and no track_features row yet — excluded by the query itself, so a track that gains a row is never re-selected. */
export async function selectCandidates(db: Db, limit?: number): Promise<Candidate[]> {
  const query = db
    .select({ id: tracks.id, appleId: tracks.appleId, title: tracks.title, artist: tracks.artist })
    .from(tracks)
    .leftJoin(trackFeatures, eq(trackFeatures.trackId, tracks.id))
    .where(and(isNotNull(tracks.appleId), isNull(trackFeatures.trackId)))
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

// --- orchestration ------------------------------------------------------------

export type AnalyzePreviewsDeps = {
  db: Db
  apply: boolean
  limit?: number
  storefront: string
  cacheDir: string
  checkpointPath: string
  fetch: FetchLike
  fetchPreviews: typeof realFetchPreviews
  decodeToWav: typeof realDecodeToWav
  analyzePreview: typeof realAnalyzePreview
  log: (line: string) => void
}

export type RunSummary = {
  candidates: number
  analyzed: number
  noHit: number
  noPreview: number
  downloadFailed: number
  analysisFailed: number
  coveragePercent: number
}

export async function runAnalyzePreviews(deps: AnalyzePreviewsDeps): Promise<RunSummary> {
  const { db, apply, limit, storefront, cacheDir, checkpointPath, fetch, fetchPreviews, decodeToWav, analyzePreview, log } = deps

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
      analyzed: 0,
      noHit: 0,
      noPreview: 0,
      downloadFailed: 0,
      analysisFailed: 0,
      coveragePercent: await coveragePercent(db),
    }
  }

  const idToCandidate = new Map(candidates.map((c) => [c.appleId, c]))
  const appleIds = candidates.map((c) => c.appleId)

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
      await db
        .insert(trackFeatures)
        .values({ trackId: candidate.id, ...features, source: SOURCE })
        .onConflictDoNothing()
      analyzed++
    } catch {
      // Fixed string, id interpolation only — never a decode/analyze error's
      // own message (it can echo back filesystem paths and other detail we
      // don't want in logs; same lesson as scripts/retitle-sessions.ts).
      log(`failed: ${candidate.id}`)
      analysisFailed++
    } finally {
      await rm(wavPath, { force: true })
    }

    if (processed % PROGRESS_EVERY === 0 || processed === total) {
      log(`${processed}/${total} analyzed=${analyzed} failed=${analysisFailed}`)
    }
  }

  const coverage = await coveragePercent(db)
  log(
    `analyzed=${analyzed} no_hit=${skipped.no_hit} no_preview=${skipped.no_preview} download_failed=${skipped.download_failed} analysis_failed=${analysisFailed}`,
  )
  log(`features coverage: ${coverage.toFixed(1)}%`)

  return {
    candidates: candidates.length,
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
  if (limit != null && (!Number.isFinite(limit) || limit <= 0)) {
    throw new Error('--limit requires a positive number')
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

  const summary = await runAnalyzePreviews({
    db,
    apply,
    limit,
    storefront: 'ng',
    cacheDir,
    checkpointPath,
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

main().catch((e) => {
  console.error('analyze-previews failed:', e instanceof Error ? e.message : e)
  process.exit(1)
})
