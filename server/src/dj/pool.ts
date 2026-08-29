import { sql, type SQL } from 'drizzle-orm'
import type { Db } from '../db/types'
import type { Embedder } from '../enrich/embedder'
import type { Intent } from './contracts'

export type PoolTrack = {
  trackId: string
  appleId: string | null
  title: string
  artist: string
  playCount: number
  tempo: number | null
  energy: number | null
  valence: number | null
  releaseYear: number | null
  durationMs: number | null
  score: number
}

// Score weights per familiarity preset — v1, hand-set by feel rather than fit
// to any data; P4 tunes these against real skip/favorite signal once it
// exists. `sim` weighs meaning (lyric) similarity to the requested themes,
// `feat` weighs tempo/energy fit, `fam` weighs how well-known the track
// already is to this listener (play count).
const FAMILIARITY_WEIGHTS: Record<Intent['familiarity'], { sim: number; feat: number; fam: number }> = {
  comfort: { sim: 0.35, feat: 0.2, fam: 0.45 },
  mix: { sim: 0.45, feat: 0.25, fam: 0.3 },
  adventurous: { sim: 0.55, feat: 0.3, fam: 0.15 },
}

// A lone tempo bound (only tempoMin or only tempoMax given) is treated as a
// soft target at that bound rather than a hard edge — this is the half-width
// of the implied window around it.
const DEFAULT_TEMPO_HALF_WIDTH = 60

const MAX_POOL_SIZE = 300
const POOL_MULTIPLE = 15

// Raw `db.execute(sql...)` result shape differs by driver: neon-http (prod)
// and pglite (test) both hand back `{ rows: [...] }`, but nothing guarantees
// a bare array never shows up on some other driver/version — normalize
// defensively rather than assume one shape (mirrors enrich/runner.ts).
function normalizeRows(res: unknown): Record<string, unknown>[] {
  if (Array.isArray(res)) return res as Record<string, unknown>[]
  const rows = (res as { rows?: unknown } | null | undefined)?.rows
  return Array.isArray(rows) ? (rows as Record<string, unknown>[]) : []
}

type PoolRow = {
  track_id: string
  apple_id: string | null
  title: string
  artist: string
  play_count: number | string
  tempo: number | string | null
  energy: number | string | null
  valence: number | string | null
  release_year: number | null
  duration_ms: number | null
  score: number | string
}

const num = (v: number | string | null): number | null => (v === null ? null : Number(v))

/**
 * Builds a scored candidate pool from the requesting user's library for the
 * given intent. Single-stage query — the plan accepted this at current scale
 * (~4.6k tracks total, far fewer per personal library): a scored seq scan
 * over a few hundred rows is single-digit ms. The HNSW index on
 * track_meanings.embedding is NOT used by this composite ORDER BY (the
 * planner can't use an ANN index when the sort key is a blended expression,
 * not the raw distance) — accepted for now. If P4's scale hurts this,
 * restructure as an ANN-inner-CTE (pull top-N by embedding distance first)
 * feeding a scored outer query (see Task 1 review).
 */
export async function buildPool(db: Db, embed: Embedder, userId: string, intent: Intent): Promise<PoolTrack[]> {
  const embedding = await embed(intent.themes)
  // Bound as a STRING literal parameter, cast to ::vector in SQL below — the
  // themes text itself never reaches SQL at all (it only ever reaches the
  // embedder, above); only the resulting vector's numeric text touches the
  // query, and even that goes through drizzle's parameterization, never
  // string-interpolated into the query text.
  const vecLiteral = `[${embedding.join(',')}]`

  const weights = FAMILIARITY_WEIGHTS[intent.familiarity]
  const poolSize = Math.min(POOL_MULTIPLE * intent.targetCount, MAX_POOL_SIZE)

  let tempoCenter: number | null = null
  let tempoHalfWidth: number | null = null
  if (intent.tempoMin !== undefined && intent.tempoMax !== undefined) {
    tempoCenter = (intent.tempoMin + intent.tempoMax) / 2
    tempoHalfWidth = Math.max(1, (intent.tempoMax - intent.tempoMin) / 2)
  } else if (intent.tempoMin !== undefined) {
    tempoCenter = intent.tempoMin
    tempoHalfWidth = DEFAULT_TEMPO_HALF_WIDTH
  } else if (intent.tempoMax !== undefined) {
    tempoCenter = intent.tempoMax
    tempoHalfWidth = DEFAULT_TEMPO_HALF_WIDTH
  }

  // Feature-fit: a simple, documented v1 (P4 tunes it) — averages two
  // [0,1] terms:
  //  - tempo proximity to the requested window's centre. Only scored when the
  //    intent actually specifies a tempo window AND the track has a measured
  //    tempo; otherwise this term is 0 — "missing dimensions contribute 0,
  //    never exclude" (a track is never dropped just for lacking this signal).
  //  - a flat presence credit for having a measured energy value at all. There
  //    is no per-track energy target in the intent (energyArc describes the
  //    queue's overall shape across positions, not a per-track filter — P4's
  //    job, not this query's), so "was energy ever measured" is the only
  //    signal available here: 1.0 if present, 0.5 (neutral, not a penalty)
  //    if not.
  const tempoTerm: SQL =
    tempoCenter !== null && tempoHalfWidth !== null
      ? sql`COALESCE(1 - LEAST(1, ABS(f.tempo - ${tempoCenter}) / ${tempoHalfWidth}), 0)`
      : sql`0`
  const energyTerm = sql`(CASE WHEN f.energy IS NOT NULL THEN 1.0 ELSE 0.5 END)`
  const featureFit = sql`((${tempoTerm} + ${energyTerm}) / 2)`

  // Meaning similarity: `<=>` is cosine DISTANCE (0 = identical direction, 1 =
  // orthogonal), so similarity = 1 - distance. NULL (no track_meanings row at
  // all, via the LEFT JOIN) is COALESCEd to 0 — scores neutrally low rather
  // than excluding the track or poisoning the sum with NULL.
  const simFit = sql`COALESCE(1 - (tm.embedding <=> ${vecLiteral}::vector), 0)`

  const scoreExpr = sql`(${weights.sim} * ${simFit} + ${weights.feat} * ${featureFit} + ${weights.fam} * LN(1 + ut.play_count))`

  const filters: SQL[] = [sql`ut.user_id = ${userId}`, sql`ut.in_library = true`]
  if (intent.tempoMin !== undefined) filters.push(sql`f.tempo >= ${intent.tempoMin}`)
  if (intent.tempoMax !== undefined) filters.push(sql`f.tempo <= ${intent.tempoMax}`)
  if (intent.allowExplicit === false) filters.push(sql`COALESCE(t.explicit, false) = false`)
  // NULL release_year passes an era filter rather than being excluded — most
  // rows lack a year until re-sync; excluding them would empty pools.
  if (intent.eraFrom !== undefined) filters.push(sql`(t.release_year IS NULL OR t.release_year >= ${intent.eraFrom})`)
  if (intent.eraTo !== undefined) filters.push(sql`(t.release_year IS NULL OR t.release_year <= ${intent.eraTo})`)

  const whereClause = sql.join(filters, sql` AND `)

  const res = await db.execute(sql`
    SELECT
      t.id AS track_id,
      t.apple_id AS apple_id,
      t.title AS title,
      t.artist AS artist,
      ut.play_count AS play_count,
      f.tempo AS tempo,
      f.energy AS energy,
      f.valence AS valence,
      t.release_year AS release_year,
      t.duration_ms AS duration_ms,
      ${scoreExpr} AS score
    FROM user_tracks ut
    JOIN tracks t ON t.id = ut.track_id
    LEFT JOIN track_features f ON f.track_id = t.id
    LEFT JOIN track_meanings tm ON tm.track_id = t.id
    WHERE ${whereClause}
    ORDER BY score DESC
    LIMIT ${poolSize}
  `)

  const rows = normalizeRows(res) as unknown as PoolRow[]
  return rows.map((r) => ({
    trackId: r.track_id,
    appleId: r.apple_id,
    title: r.title,
    artist: r.artist,
    playCount: Number(r.play_count),
    tempo: num(r.tempo),
    energy: num(r.energy),
    valence: num(r.valence),
    releaseYear: r.release_year,
    durationMs: r.duration_ms,
    score: Number(r.score),
  }))
}
