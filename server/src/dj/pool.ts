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
// `feat` weighs tempo fit, `fam` weighs how well-known the track already is
// to this listener (play count). Each term is normalized to [0,1] (see below)
// so these weights are a true convex combination — the preset actually
// changes which candidate wins, not just the score's magnitude.
const FAMILIARITY_WEIGHTS: Record<Intent['familiarity'], { sim: number; feat: number; fam: number }> = {
  comfort: { sim: 0.35, feat: 0.2, fam: 0.45 },
  mix: { sim: 0.45, feat: 0.25, fam: 0.3 },
  adventurous: { sim: 0.55, feat: 0.3, fam: 0.15 },
}

// Play counts have no ceiling, so LN(1+plays) alone is unbounded — at ANY
// familiarity weight a hot-enough track would eventually swamp similarity,
// making the dial meaningless. Normalize against a heavy-rotation reference
// (200 plays) so the familiarity term saturates at 1 — P4 tunes this
// reference alongside the weights once real play-count distributions exist.
const FAM_REFERENCE_PLAYS = 200
const FAM_REFERENCE_LN = Math.log(1 + FAM_REFERENCE_PLAYS)

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
  // Defensive shape guard before the embedding touches SQL at all — the error
  // deliberately excludes the values themselves (only the length), since a
  // malformed embedding could in principle carry unexpected content.
  if (embedding.length !== 1024 || !embedding.every(Number.isFinite)) {
    throw new Error(`pool: bad embedding (len ${embedding.length})`)
  }
  // Bound as a STRING literal parameter, cast to ::vector in SQL below — the
  // themes text itself never reaches SQL at all (it only ever reaches the
  // embedder, above); only the resulting vector's numeric text touches the
  // query, and even that goes through drizzle's parameterization, never
  // string-interpolated into the query text.
  const vecLiteral = `[${embedding.join(',')}]`

  const weights = FAMILIARITY_WEIGHTS[intent.familiarity]
  const poolSize = Math.min(POOL_MULTIPLE * intent.targetCount, MAX_POOL_SIZE)

  // Tempo has two distinct shapes, not one:
  //  - TWO bounds (a real window, e.g. "120-140bpm"): a HARD filter below,
  //    plus proximity-to-centre scoring here.
  //  - ONE bound (an implied direction, e.g. "upbeat" -> tempoMin only): NOT a
  //    hard filter at all — a track just under the bound is still a fine
  //    candidate, so this is scoring-only, via a soft target at that bound
  //    with a default half-width (DEFAULT_TEMPO_HALF_WIDTH).
  // Either way, tempoCenter/tempoHalfWidth below drive the feature-fit term
  // the same way; only the WHERE clause treats the two shapes differently.
  const hasTempoWindow = intent.tempoMin !== undefined && intent.tempoMax !== undefined
  let tempoCenter: number | null = null
  let tempoHalfWidth: number | null = null
  if (hasTempoWindow) {
    tempoCenter = (intent.tempoMin! + intent.tempoMax!) / 2
    tempoHalfWidth = Math.max(1, (intent.tempoMax! - intent.tempoMin!) / 2)
  } else if (intent.tempoMin !== undefined) {
    tempoCenter = intent.tempoMin
    tempoHalfWidth = DEFAULT_TEMPO_HALF_WIDTH
  } else if (intent.tempoMax !== undefined) {
    tempoCenter = intent.tempoMax
    tempoHalfWidth = DEFAULT_TEMPO_HALF_WIDTH
  }

  // Feature-fit: a simple, documented v1 (P4 tunes it).
  //  - When the intent gives a tempo target (one or two bounds), this is
  //    proximity-to-centre: 1 - LEAST(1, |tempo - centre| / halfWidth). A
  //    track with no measured tempo (NULL, via the LEFT JOIN) COALESCEs to 0
  //    — it floors out at the same score as a track sitting right on the
  //    window's edge, which is an acceptable v1 tie rather than a dedicated
  //    "unknown" tier.
  //  - When the intent gives NO tempo target at all, this term is a CONSTANT
  //    0.5. A constant can't affect ordering — it exists only so the formula
  //    doesn't special-case away the term. There used to be an energy
  //    presence bonus here; removed, because "was this track's audio ever
  //    successfully re-enriched" must never itself be a ranking thumb.
  const featureFit: SQL =
    tempoCenter !== null && tempoHalfWidth !== null
      ? sql`COALESCE(1 - LEAST(1, ABS(f.tempo - ${tempoCenter}) / ${tempoHalfWidth}), 0)`
      : sql`0.5`

  // Meaning similarity: `<=>` is cosine DISTANCE, ranging [0, 2] (0 =
  // identical direction, 1 = orthogonal, 2 = exactly opposite), so
  // `1 - distance` alone can go negative for anti-correlated tracks —
  // GREATEST(0, ...) clamps it back into [0,1]. NULL (no track_meanings row
  // at all, via the LEFT JOIN) is COALESCEd to 0 — scores neutrally low
  // rather than excluding the track or poisoning the sum with NULL.
  const simFit = sql`COALESCE(GREATEST(0, 1 - (tm.embedding <=> ${vecLiteral}::vector)), 0)`

  // Familiarity: LN(1+plays) normalized against a heavy-rotation reference so
  // it saturates at 1 (see FAM_REFERENCE_PLAYS above) — a true [0,1] term,
  // not an unbounded one.
  const famFit = sql`LEAST(1, LN(1 + ut.play_count) / ${FAM_REFERENCE_LN})`

  const scoreExpr = sql`(${weights.sim} * ${simFit} + ${weights.feat} * ${featureFit} + ${weights.fam} * ${famFit})`

  const filters: SQL[] = [sql`ut.user_id = ${userId}`, sql`ut.in_library = true`]
  // Only a real two-bound window hard-filters — see the tempo comment above.
  // NULL tempo PASSES (consistent with releaseYear/explicit below): unknown
  // is not the same as out-of-window, and excluding it would just mean this
  // track never had a chance to compete on its other signals.
  if (hasTempoWindow) {
    filters.push(sql`(f.tempo IS NULL OR f.tempo >= ${intent.tempoMin})`)
    filters.push(sql`(f.tempo IS NULL OR f.tempo <= ${intent.tempoMax})`)
  }
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
    ORDER BY score DESC, t.id
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
