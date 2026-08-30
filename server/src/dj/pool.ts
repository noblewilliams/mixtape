import { sql, type SQL } from 'drizzle-orm'
import type { Db } from '../db/types'
import { EMBEDDING_DIMENSIONS, type Embedder } from '../enrich/embedder'
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
// to this listener (play count), `taste` weighs this listener's learned
// per-artist affinity from DJ-session behavior (see TASTE_* below). Each term
// is normalized to [0,1] so these weights are a true convex combination — the
// preset actually changes which candidate wins, not just the score's
// magnitude. `taste` sits at a flat 0.12 across all three presets (within the
// P4 plan's 0.10-0.15 band) and is carved out by scaling the PRE-P4 sim/feat/
// fam weights by (1 - 0.12) — a uniform scale preserves their relative ratios
// (the actual "preset" character) while making room for taste, and the four
// terms still sum to exactly 1.
const TASTE_WEIGHT = 0.12
const PRE_TASTE_SCALE = 1 - TASTE_WEIGHT
const FAMILIARITY_WEIGHTS: Record<Intent['familiarity'], { sim: number; feat: number; fam: number; taste: number }> = {
  comfort: { sim: 0.35 * PRE_TASTE_SCALE, feat: 0.2 * PRE_TASTE_SCALE, fam: 0.45 * PRE_TASTE_SCALE, taste: TASTE_WEIGHT },
  mix: { sim: 0.45 * PRE_TASTE_SCALE, feat: 0.25 * PRE_TASTE_SCALE, fam: 0.3 * PRE_TASTE_SCALE, taste: TASTE_WEIGHT },
  adventurous: { sim: 0.55 * PRE_TASTE_SCALE, feat: 0.3 * PRE_TASTE_SCALE, fam: 0.15 * PRE_TASTE_SCALE, taste: TASTE_WEIGHT },
}

// Taste term: per-ARTIST (not per-track — too sparse at one user's library
// scale, see plan) learned affinity in [0,1], 0.5 = neutral/no-signal.
// Signals, both scoped to the requesting user via dj_sessions.user_id
// (session_events/queue_tracks carry no user column of their own):
//   - PENALTY: a queue_tracks row the USER removed (state='removed' AND
//     removed_by='user') — a DJ swap (removed_by='dj') is routine curation,
//     not taste signal, and contributes nothing. Full weight (1x) — this is
//     an ACTIVE signal, the user reaching in and rejecting a specific pick.
//   - BOOST: a queue_tracks row KEPT (state='active') in a session that has
//     at least one 'played' or 'saved_playlist' event — the session_events
//     type column has no DB-level CHECK, so unknown event types are filtered
//     out explicitly rather than trusted. Weighted at KEEP_WEIGHT (0.25x,
//     below) — this is only a PASSIVE signal, see the asymmetry note there.
// Both signals are aggregated per DISTINCT SESSION, never per event/row
// count directly: the client posts session events fire-and-forget, so a
// client bug retrying the same POST must never multiply its influence (a
// session with 5 duplicate 'played' events counts exactly once). Concretely:
// qualifying_sessions collapses events to one row per session_id (MAX(created_at)
// picks the latest qualifying event as that session's signal timestamp), and
// removal_events collapses to one row per (artist, session_id) pair (MAX(updated_at)
// as its timestamp) — so even multiple user-removals of the same artist within
// one session count as a single penalty for that session.
//
// In-session dominance: a removal always wins over a same-session keep of the
// same artist. If the user removed an ArtistX track from a session AND
// another ArtistX track survived to that session's end, keep_events excludes
// that (artist, session) pair outright (it's already present in
// removal_events) — it contributes NO boost, only the removal's penalty
// counts. Without this, one removal + one surviving same-artist track in a
// played session nets to roughly zero (a full-weight penalty largely
// cancelling a KEEP_WEIGHT-scaled boost), silently erasing a signal the user
// just went out of their way to give. An active edit beats passive survival,
// full stop, within the session where they conflict.
//
// Active-vs-passive asymmetry (KEEP_WEIGHT) and its saturation shape: a
// "kept" track was never actually chosen by the user — the DJ picked it and
// the user merely didn't remove it, which is a far weaker signal than an
// active removal. At full weight this also self-reinforces with no
// counterweight: the DJ keeps picking an artist -> the user doesn't bother
// removing it -> that counts as a full +1 boost per played session -> the
// artist's taste score rises -> the DJ picks it even more. And it saturates
// fast: TANH(0.3 * net) is already past 90% of its way to the ceiling by
// net = +/-5, so as few as ~5 played sessions of passive keeps (at full
// weight) would nearly max out an artist's score on nothing but the DJ's own
// repeated picks, before the user ever actively chose anything. KEEP_WEIGHT
// = 0.25 makes a kept-and-played session worth a quarter of a removal, so
// reaching that same saturated boost purely from keeps now takes ~4x as many
// qualifying sessions (net = +2 needs 8 sessions of keeps, not 2) — an active
// "stop picking this" still moves the score 4x faster than silent
// acceptance, which is the point: removal is a deliberate signal, a keep is
// just the absence of one.
//
// Recency decay: exponential half-life of 90 days on the signal timestamp
// (a removal row's updated_at; a kept-session's latest qualifying event's
// created_at) — a 200-day-old signal has decayed far more than a 5-day-old one.
//
// v1 known limitation, recorded rather than fixed: artist matching is
// exact-string equality on tracks.artist (no artist entity exists to join
// on). 'Wizkid', 'Wizkid & Ayra Starr', and 'Wizkid feat. Tems' are three
// unrelated strings to this query even though they share a performer — on a
// collab-dense library this fragments one artist's real signal across
// several disjoint taste rows instead of pooling it. Accepted for v1;
// revisit if/when tracks gain a real artist entity to join on.
const TASTE_HALF_LIFE_DAYS = 90
const TASTE_DECAY_RATE_PER_DAY = Math.LN2 / TASTE_HALF_LIFE_DAYS

// See "Active-vs-passive asymmetry" above: a kept-and-played session earns
// its artist only a quarter of a full removal's weight toward the boost sum.
const KEEP_WEIGHT = 0.25

// Squash net signal (recency-weighted boosts minus penalties, roughly one
// unit of full-strength weight per qualifying session) into [0,1] around a
// neutral 0.5: score = 0.5 + 0.5*tanh(k * net). tanh is bounded (never
// cratering an artist to 0 or blowing past 1) and monotonic (more signal
// always moves the score further from neutral, in the signalled direction).
// k = 0.3 is chosen so a SINGLE full-strength removal only nudges an artist
// to ~0.35 (a subtle rerank, matching the plan's "a single removal must not
// crater an artist"), while sustained removals across several sessions (net
// penalty ~3) push it down near ~0.14 — meaningfully below neutral once the
// signal is sustained rather than a one-off.
const TASTE_K = 0.3

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
export async function buildPool(
  db: Db,
  embed: Embedder,
  userId: string,
  intent: Intent,
  excludeTrackIds?: string[],
): Promise<PoolTrack[]> {
  const embedding = await embed(intent.themes)
  // Defensive shape guard before the embedding touches SQL at all — the error
  // deliberately excludes the values themselves (only the length), since a
  // malformed embedding could in principle carry unexpected content.
  if (embedding.length !== EMBEDDING_DIMENSIONS || !embedding.every(Number.isFinite)) {
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
  const { tempoMin, tempoMax } = intent
  const hasTempoWindow = tempoMin !== undefined && tempoMax !== undefined
  let tempoCenter: number | null = null
  let tempoHalfWidth: number | null = null
  if (tempoMin !== undefined && tempoMax !== undefined) {
    tempoCenter = (tempoMin + tempoMax) / 2
    tempoHalfWidth = Math.max(1, (tempoMax - tempoMin) / 2)
  } else if (tempoMin !== undefined) {
    tempoCenter = tempoMin
    tempoHalfWidth = DEFAULT_TEMPO_HALF_WIDTH
  } else if (tempoMax !== undefined) {
    tempoCenter = tempoMax
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

  // Taste: COALESCE inside the expression (not wrapped around it) so a track
  // whose artist has no row in artist_taste at all (LEFT JOIN miss — no
  // signal ever recorded for that artist) evaluates boosts/penalties to 0,
  // TANH(k*0) = 0, landing exactly on the neutral 0.5 floor — never boosted
  // or punished for silence.
  const tasteFit = sql`(0.5 + 0.5 * TANH(${TASTE_K}::float8 * (COALESCE(at.boosts, 0) - COALESCE(at.penalties, 0))))`

  const scoreExpr = sql`(${weights.sim} * ${simFit} + ${weights.feat} * ${featureFit} + ${weights.fam} * ${famFit} + ${weights.taste} * ${tasteFit})`

  const filters: SQL[] = [sql`ut.user_id = ${userId}`, sql`ut.in_library = true`]
  // Only a real two-bound window hard-filters — see the tempo comment above.
  // NULL tempo PASSES (consistent with releaseYear/explicit below): unknown
  // is not the same as out-of-window, and excluding it would just mean this
  // track never had a chance to compete on its other signals.
  if (hasTempoWindow) {
    filters.push(sql`(f.tempo IS NULL OR f.tempo >= ${tempoMin})`)
    filters.push(sql`(f.tempo IS NULL OR f.tempo <= ${tempoMax})`)
  }
  if (intent.allowExplicit === false) filters.push(sql`COALESCE(t.explicit, false) = false`)
  // NULL release_year passes an era filter rather than being excluded — most
  // rows lack a year until re-sync; excluding them would empty pools.
  if (intent.eraFrom !== undefined) filters.push(sql`(t.release_year IS NULL OR t.release_year >= ${intent.eraFrom})`)
  if (intent.eraTo !== undefined) filters.push(sql`(t.release_year IS NULL OR t.release_year <= ${intent.eraTo})`)
  // Used by the dj loop's swap/extend replacement lookup: a replacement
  // picked from the pool that's already sitting in the active queue is a
  // no-op (materialize would just drop it as a duplicate) — excluding the
  // queue's own tracks up front means the pool's top candidates are actually
  // usable replacements, not the queue re-selecting itself. Each id is its
  // own bound parameter (never string-joined into the query text).
  if (excludeTrackIds && excludeTrackIds.length > 0) {
    filters.push(sql`t.id NOT IN (${sql.join(excludeTrackIds.map((id) => sql`${id}::uuid`), sql`, `)})`)
  }

  const whereClause = sql.join(filters, sql` AND `)

  const res = await db.execute(sql`
    WITH removal_events AS (
      SELECT t.artist AS artist, qt.session_id AS session_id, MAX(qt.updated_at) AS ts
      FROM queue_tracks qt
      JOIN dj_sessions ds ON ds.id = qt.session_id
      JOIN tracks t ON t.id = qt.track_id
      WHERE ds.user_id = ${userId}
        AND qt.state = 'removed'
        AND qt.removed_by = 'user'
      GROUP BY t.artist, qt.session_id
    ),
    qualifying_sessions AS (
      SELECT se.session_id AS session_id, MAX(se.created_at) AS ts
      FROM session_events se
      JOIN dj_sessions ds ON ds.id = se.session_id
      WHERE ds.user_id = ${userId}
        AND se.type IN ('played', 'saved_playlist')
      GROUP BY se.session_id
    ),
    -- Note: replaceQueue deletes a session's active queue_tracks rows outright
    -- on regenerate (see dj/loop.ts), so a played-then-regenerated session
    -- only ever has the FINAL regenerated queue's rows left to read as
    -- "kept" here — last state wins, intentionally.
    keep_events AS (
      SELECT DISTINCT t.artist AS artist, qt.session_id AS session_id
      FROM queue_tracks qt
      JOIN tracks t ON t.id = qt.track_id
      WHERE qt.state = 'active'
        AND qt.session_id IN (SELECT session_id FROM qualifying_sessions)
        -- In-session dominance (see comment above KEEP_WEIGHT): a same-
        -- session, same-artist removal wins outright, so a surviving track
        -- of that artist contributes no boost at all here.
        AND NOT EXISTS (
          SELECT 1 FROM removal_events re
          WHERE re.artist = t.artist AND re.session_id = qt.session_id
        )
    ),
    taste_signals AS (
      SELECT
        artist,
        'penalty' AS kind,
        EXP(-${TASTE_DECAY_RATE_PER_DAY}::float8 * (EXTRACT(EPOCH FROM (NOW() - ts)) / 86400.0)) AS weight
      FROM removal_events
      UNION ALL
      SELECT
        ke.artist AS artist,
        'boost' AS kind,
        ${KEEP_WEIGHT}::float8 * EXP(-${TASTE_DECAY_RATE_PER_DAY}::float8 * (EXTRACT(EPOCH FROM (NOW() - qs.ts)) / 86400.0)) AS weight
      FROM keep_events ke
      JOIN qualifying_sessions qs ON qs.session_id = ke.session_id
    ),
    artist_taste AS (
      SELECT
        artist,
        SUM(CASE WHEN kind = 'boost' THEN weight ELSE 0 END) AS boosts,
        SUM(CASE WHEN kind = 'penalty' THEN weight ELSE 0 END) AS penalties
      FROM taste_signals
      GROUP BY artist
    )
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
    LEFT JOIN artist_taste at ON at.artist = t.artist
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
