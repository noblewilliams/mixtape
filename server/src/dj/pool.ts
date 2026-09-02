import { sql, type SQL } from 'drizzle-orm'
import type { Db } from '../db/types'
import { EMBEDDING_DIMENSIONS, type Embedder } from '../enrich/embedder'
import type { Intent } from './contracts'

export type PoolTrack = {
  trackId: string
  appleId: string | null
  // Peer of appleId (db/schema.ts → tracks.spotifyId), never a replacement:
  // a row carries either, both, or — a Spotify listener's export — only this
  // one. The queue UI renders a row with no Apple id as "Open in Spotify".
  spotifyId: string | null
  title: string
  artist: string
  playCount: number | null
  tempo: number | null
  energy: number | null
  valence: number | null
  releaseYear: number | null
  durationMs: number | null
  score: number
}

// Which candidate set buildPool draws from — decided by resolvePoolMode.
// `personal` is the listener's own rows (library, seeds, counted plays);
// `corpus` is the whole enriched catalog, for a listener who has shared
// taste (interview seeds, pasted songs) but owns no data of their own yet.
export type PoolMode = 'personal' | 'corpus'

export type PoolModeResolution = {
  mode: PoolMode | 'insufficient_seeds'
  seedTracks: number
  seedArtists: number
}

export type BuildPoolOptions = { mode?: PoolMode }

// Candidate rule, personal mode (spec 2026-09-01 → Pool): a user_tracks row
// is a candidate when it is in the library, was seeded (pasted/interview),
// OR the listening ledger counts at least RECENT_PLAY_MIN plays for it
// inside the last RECENT_PLAY_WINDOW_DAYS. Three plays in two years is the
// founder's threshold. Computed live from listening_days on every call — the
// window drifts with the calendar and needs no recompute job. Accepted edge:
// an Apple listener's removed library song that still had three plays in the
// window re-enters the pool; session removals still penalize it (the taste
// term below).
export const RECENT_PLAY_WINDOW_DAYS = 730
export const RECENT_PLAY_MIN = 3

// Corpus-mode gate (spec → Before the data arrives): a "not personal yet"
// mix unlocks only once the listener's seeds match at least MIN_SEED_TRACKS
// enriched corpus tracks across at least MIN_SEED_ARTISTS artists. Below
// that the DJ says it does not know enough yet (dj/loop.ts) rather than
// guessing off two names.
export const MIN_SEED_TRACKS = 25
export const MIN_SEED_ARTISTS = 3

// Corpus-mode familiarity (spec → Before the data arrives): 1.0 for a row
// the listener seeded themselves, this for a row by an artist they named,
// 0 for the rest of the catalog. Plays mean nothing here — a corpus-mode
// listener has no ledger and no library by construction.
const SEED_ARTIST_FAMILIARITY = 0.7

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
  spotify_id: string | null
  title: string
  artist: string
  play_count: number | string | null
  tempo: number | string | null
  energy: number | string | null
  valence: number | string | null
  release_year: number | null
  duration_ms: number | null
  score: number | string
}

type PoolModeRow = {
  has_source: boolean
  has_library: boolean
  seed_tracks: number | string
  seed_artists: number | string
}

const num = (v: number | string | null): number | null => (v === null ? null : Number(v))

/**
 * Decides which candidate set buildPool should draw from for this listener.
 *
 * `personal` as soon as ANY data of their own exists: a user_music_sources
 * row whose import actually landed (last_imported_at set — begin registers
 * the source before a single row arrives, so a bare source row is an
 * abandoned import and proves nothing), or any in_library row (a library
 * synced before user_music_sources existed has no source row at all).
 * Otherwise the seed matches decide: `corpus` at or above the MIN_SEED_*
 * thresholds, `insufficient_seeds` below them.
 *
 * Seed matches = enriched corpus tracks (a track_features or track_meanings
 * row — an unenriched row has nothing to score on, so it can't stand in for
 * taste) whose normalized artist equals one of the listener's
 * user_artist_seeds names, UNIONed by track id with the listener's own
 * seeded user_tracks rows (explicit taste, counted enriched or not). Artist
 * matching is lower(btrim()) equality on both sides — the same v1 limitation
 * the taste term records above ('Wizkid' and 'Wizkid feat. Tems' are two
 * artists here), accepted for the same reason.
 *
 * One query; the seed counts are computed even when the mode resolves
 * personal, so whoever surfaces them later (the funnel) gets honest numbers
 * rather than a placeholder zero. That costs one lower(btrim()) scan over
 * the corpus per call — single-digit ms at current scale, the same
 * acceptance as buildPool's own scored scan (see its doc comment).
 */
export async function resolvePoolMode(db: Db, userId: string): Promise<PoolModeResolution> {
  const res = await db.execute(sql`
    WITH seed_names AS (
      SELECT DISTINCT lower(btrim(name)) AS name
      FROM user_artist_seeds
      WHERE user_id = ${userId}
    ),
    seed_matches AS (
      SELECT t.id AS track_id, lower(btrim(t.artist)) AS artist
      FROM tracks t
      WHERE lower(btrim(t.artist)) IN (SELECT name FROM seed_names)
        AND (
          EXISTS (SELECT 1 FROM track_features f WHERE f.track_id = t.id)
          OR EXISTS (SELECT 1 FROM track_meanings tm WHERE tm.track_id = t.id)
        )
      UNION
      SELECT t.id AS track_id, lower(btrim(t.artist)) AS artist
      FROM user_tracks ut
      JOIN tracks t ON t.id = ut.track_id
      WHERE ut.user_id = ${userId} AND ut.seeded = true
    )
    SELECT
      EXISTS (
        SELECT 1 FROM user_music_sources
        WHERE user_id = ${userId} AND last_imported_at IS NOT NULL
      ) AS has_source,
      EXISTS (
        SELECT 1 FROM user_tracks
        WHERE user_id = ${userId} AND in_library = true
      ) AS has_library,
      (SELECT COUNT(*) FROM seed_matches)::int AS seed_tracks,
      (SELECT COUNT(DISTINCT artist) FROM seed_matches)::int AS seed_artists
  `)
  const [row] = normalizeRows(res) as unknown as PoolModeRow[]
  const seedTracks = Number(row.seed_tracks)
  const seedArtists = Number(row.seed_artists)
  if (row.has_source || row.has_library) return { mode: 'personal', seedTracks, seedArtists }
  const mode = seedTracks >= MIN_SEED_TRACKS && seedArtists >= MIN_SEED_ARTISTS ? 'corpus' : 'insufficient_seeds'
  return { mode, seedTracks, seedArtists }
}

/**
 * Builds a scored candidate pool for the given intent — from the requesting
 * user's own rows (personal mode, the default) or from the whole enriched
 * catalog (corpus mode; see resolvePoolMode and the mode switch inside).
 * Single-stage query — the plan accepted this at current scale (~4.6k
 * tracks total, far fewer per personal library): a scored seq scan over a
 * few hundred rows is single-digit ms. The HNSW index on
 * track_meanings.embedding is NOT used by this composite ORDER BY (the
 * planner can't use an ANN index when the sort key is a blended expression,
 * not the raw distance) — accepted for now. If P4's scale hurts this,
 * restructure as an ANN-inner-CTE (pull top-N by embedding distance first)
 * feeding a scored outer query (see Task 1 review).
 *
 * Every row that comes back is one RECORDING, not one tracks row: rows that
 * share an ISRC are collapsed to a single survivor after scoring (see the
 * dedupe comment in the query), so the pool never offers the same song
 * twice under two platform ids. `excludeTrackIds` works at the same grain —
 * excluding a row excludes its whole recording (see the filter comment).
 */
export async function buildPool(
  db: Db,
  embed: Embedder,
  userId: string,
  intent: Intent,
  excludeTrackIds?: string[],
  options: BuildPoolOptions = {},
): Promise<PoolTrack[]> {
  const mode: PoolMode = options.mode ?? 'personal'
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

  // Familiarity is capability-aware. Native syncs use observed lifetime play
  // counts. Web MusicKit cannot supply that number, so web-only rows use the
  // strongest honest signal available: bounded recent-play rank or deliberate
  // playlist membership. Missing stays missing; it never becomes a fake zero.
  // The play count read here is fam_plays' (see the query), not the row's
  // own user_tracks column: one recording can sit in several tracks rows (a
  // Spotify relink, an Apple reissue), so plays are summed across the
  // recording's ISRC group and `observed` is true if ANY row in the group
  // observed them — a listener's 100 Apple plays plus 100 Spotify plays of
  // one song are 200 plays of one song, not two half-familiar strangers.
  const observedPlayCountFit = sql`LEAST(1, LN(1 + fp.plays) / ${FAM_REFERENCE_LN})`
  const recentFit = sql`COALESCE(1 - (rs.rank::float8 / 30.0), 0)`
  // PostgreSQL LEAST ignores NULL operands, so COALESCE(LEAST(0.8, NULL), 0)
  // would incorrectly return 0.8. Branch before LEAST to keep no signal at 0.
  const playlistFit = sql`CASE
    WHEN ps.playlist_count IS NULL THEN 0
    ELSE LEAST(0.8, LN(1 + ps.playlist_count) / LN(6))
  END`
  const personalFamFit = sql`CASE
    WHEN fp.observed THEN ${observedPlayCountFit}
    ELSE GREATEST(${recentFit}, ${playlistFit})
  END`
  // Corpus mode has no plays worth reading — the listener owns nothing yet —
  // so familiarity is the one place their explicit taste enters the score: a
  // row they seeded themselves is fully familiar, a row by an artist they
  // named in the interview is SEED_ARTIST_FAMILIARITY, and the rest of the
  // catalog is a stranger. The recent-play and playlist signals contribute
  // NOTHING here on purpose (a web listener with a synced library is
  // personal mode anyway, so those signals have no honest corpus reading).
  // `ut.seeded` is NULL for a row the listener has no user_tracks row for
  // (the LEFT JOIN in the corpus candidate source below); CASE reads that
  // as not-seeded, which is exactly right.
  const corpusFamFit = sql`CASE
    WHEN ut.seeded THEN 1.0::float8
    WHEN lower(btrim(t.artist)) IN (SELECT name FROM seed_names) THEN ${SEED_ARTIST_FAMILIARITY}::float8
    ELSE 0::float8
  END`
  const famFit = mode === 'corpus' ? corpusFamFit : personalFamFit

  // Taste: COALESCE inside the expression (not wrapped around it) so a track
  // whose artist has no row in artist_taste at all (LEFT JOIN miss — no
  // signal ever recorded for that artist) evaluates boosts/penalties to 0,
  // TANH(k*0) = 0, landing exactly on the neutral 0.5 floor — never boosted
  // or punished for silence.
  const tasteFit = sql`(0.5 + 0.5 * TANH(${TASTE_K}::float8 * (COALESCE(at.boosts, 0) - COALESCE(at.penalties, 0))))`

  const scoreExpr = sql`(${weights.sim} * ${simFit} + ${weights.feat} * ${featureFit} + ${weights.fam} * ${famFit} + ${weights.taste} * ${tasteFit})`

  // The mode switch — where candidates come from is the ONE structural
  // difference between the two modes; the score formula (bar the familiarity
  // term above), the hard filters below, and the recording dedupe are all
  // shared, so a corpus mix is scored by exactly the rules a personal one is.
  //  - personal: the listener's own user_tracks rows, gated by the candidate
  //    rule (in_library OR seeded OR counted plays in the window — see
  //    RECENT_PLAY_* above). recent_plays is ONE aggregated CTE over
  //    listening_days, never a correlated subquery: a 20k-row lifetime
  //    history must not pay a per-candidate ledger lookup.
  //  - corpus: every track with a track_features or track_meanings row (an
  //    unenriched row has nothing to score on), LEFT JOINed to the
  //    listener's own user_tracks row purely so the familiarity term can see
  //    `seeded`. A corpus-mode listener has no library and no ledger by
  //    construction (resolvePoolMode), so nothing else of theirs is read.
  const candidateSource: SQL =
    mode === 'corpus'
      ? sql`tracks t LEFT JOIN user_tracks ut ON ut.track_id = t.id AND ut.user_id = ${userId}`
      : sql`user_tracks ut JOIN tracks t ON t.id = ut.track_id`
  const filters: SQL[] =
    mode === 'corpus'
      ? [sql`(f.track_id IS NOT NULL OR tm.track_id IS NOT NULL)`]
      : [
          sql`ut.user_id = ${userId}`,
          sql`(ut.in_library OR ut.seeded OR ut.track_id IN (SELECT track_id FROM recent_plays))`,
        ]
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
  // Used by the dj loop's swap/extend replacement lookup, where the ids are
  // the active queue's contents: a replacement picked from the pool that's
  // already sitting in the queue is a no-op (materialize would just drop it
  // as a duplicate) — excluding the queue up front means the pool's top
  // candidates are actually usable replacements, not the queue re-selecting
  // itself. Exclusion is by RECORDING, not by row: a queued track's ISRC
  // sibling (the same song under another platform id) is the same song to
  // the listener, so it must go too — otherwise a swap could replace a song
  // with itself under another id, and an extend could queue one recording
  // twice. The key is the dedupe's own COALESCE(isrc, id::text), so a row
  // with no ISRC is its own recording and only that row goes. Each id is its
  // own bound parameter (never string-joined into the query text); the
  // subquery never yields NULL (id is the primary key), so NOT IN is safe.
  if (excludeTrackIds && excludeTrackIds.length > 0) {
    const ids = sql.join(excludeTrackIds.map((id) => sql`${id}::uuid`), sql`, `)
    filters.push(sql`COALESCE(t.isrc, t.id::text) NOT IN (
      SELECT COALESCE(x.isrc, x.id::text) FROM tracks x WHERE x.id IN (${ids})
    )`)
  }

  const whereClause = sql.join(filters, sql` AND `)

  // recent_plays and seed_names are each read by only one mode (the personal
  // candidate rule and the corpus familiarity term respectively); Postgres
  // never evaluates an unreferenced CTE, so the other one costs nothing.
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
    ),
    recent_signal AS (
      SELECT track_id, MIN(rank) AS rank
      FROM user_recent_track_observations
      WHERE user_id = ${userId} AND source = 'web_musickit'
      GROUP BY track_id
    ),
    playlist_signal AS (
      SELECT pe.track_id, COUNT(DISTINCT pe.playlist_id)::int AS playlist_count
      FROM playlist_entries pe
      JOIN user_playlists up ON up.id = pe.playlist_id
      WHERE up.user_id = ${userId}
        AND up.in_library = true
        AND pe.track_id IS NOT NULL
      GROUP BY pe.track_id
    ),
    -- Candidate rule, the ledger leg (see RECENT_PLAY_* above): tracks this
    -- listener played at least RECENT_PLAY_MIN times, summed across every
    -- day and every source, inside the window. Aggregated once here; the
    -- personal candidate filter reads it as a plain IN.
    recent_plays AS (
      SELECT track_id
      FROM listening_days
      WHERE user_id = ${userId}
        AND day >= CURRENT_DATE - ${RECENT_PLAY_WINDOW_DAYS}::int
      GROUP BY track_id
      HAVING SUM(plays) >= ${RECENT_PLAY_MIN}
    ),
    seed_names AS (
      SELECT DISTINCT lower(btrim(name)) AS name
      FROM user_artist_seeds
      WHERE user_id = ${userId}
    ),
    -- Recording dedupe, part one (spec 2026-09-01 → Pool): Spotify relinks
    -- tracks across re-releases and regions and Apple reissues catalog ids,
    -- so one recording can hold several tracks rows over a lifetime history.
    -- Rows group on COALESCE(isrc, id::text) — no ISRC, no grouping, a row is
    -- its own recording — and this CTE is the group's play evidence: plays
    -- summed over every row of the listener's that the group holds, observed
    -- true if any of them observed a count. Read by the familiarity term
    -- and the returned play_count, in both modes (a corpus row the listener
    -- happens to own still reports its honest count).
    fam_plays AS (
      SELECT
        COALESCE(t.isrc, t.id::text) AS key,
        SUM(ut.play_count) AS plays,
        BOOL_OR(ut.play_count_observed) AS observed
      FROM user_tracks ut
      JOIN tracks t ON t.id = ut.track_id
      WHERE ut.user_id = ${userId}
      GROUP BY 1
    ),
    scored AS (
      SELECT
        COALESCE(t.isrc, t.id::text) AS key,
        -- Recording dedupe, part two — which row of a group survives. The
        -- queue can only play what the listener's player can open, so a
        -- listener with any Apple source (live sync or export, landed or
        -- not — it says which player they have) prefers the row with an
        -- apple_id. So does a listener with a library but NO source row at
        -- all: that library was synced before user_music_sources existed,
        -- when Apple was the only sync there was (the same legacy shape
        -- resolvePoolMode reads as personal). Everyone else prefers the row
        -- with a spotify_id — the bare default stays Spotify on purpose, so
        -- a corpus-mode listener with no source and no library (seeds only)
        -- is offered the ids they pasted. Uncorrelated subqueries, each
        -- evaluated once per query, not per row.
        CASE
          WHEN EXISTS (
            SELECT 1 FROM user_music_sources
            WHERE user_id = ${userId} AND source IN ('apple_live', 'apple_export')
          ) OR (
            NOT EXISTS (SELECT 1 FROM user_music_sources WHERE user_id = ${userId})
            AND EXISTS (SELECT 1 FROM user_tracks WHERE user_id = ${userId} AND in_library = true)
          ) THEN (t.apple_id IS NOT NULL)
          ELSE (t.spotify_id IS NOT NULL)
        END AS pref,
        t.id AS track_id,
        t.apple_id AS apple_id,
        t.spotify_id AS spotify_id,
        t.title AS title,
        t.artist AS artist,
        CASE WHEN fp.observed THEN fp.plays ELSE NULL END AS play_count,
        f.tempo AS tempo,
        f.energy AS energy,
        f.valence AS valence,
        t.release_year AS release_year,
        t.duration_ms AS duration_ms,
        ${scoreExpr} AS score
      FROM ${candidateSource}
      LEFT JOIN track_features f ON f.track_id = t.id
      LEFT JOIN track_meanings tm ON tm.track_id = t.id
      LEFT JOIN artist_taste at ON at.artist = t.artist
      LEFT JOIN recent_signal rs ON rs.track_id = t.id
      LEFT JOIN playlist_signal ps ON ps.track_id = t.id
      LEFT JOIN fam_plays fp ON fp.key = COALESCE(t.isrc, t.id::text)
      WHERE ${whereClause}
    )
    -- Recording dedupe, part three: exactly one row per group survives —
    -- the platform-preferred one first, then the best score (track_id last,
    -- for a stable tie) — and only THEN does the pool get ranked and cut to
    -- size, so a duplicate can never crowd a distinct song out of the LIMIT.
    SELECT * FROM (
      SELECT DISTINCT ON (key) *
      FROM scored
      ORDER BY key, pref DESC, score DESC, track_id
    ) deduped
    ORDER BY score DESC, track_id
    LIMIT ${poolSize}
  `)

  const rows = normalizeRows(res) as unknown as PoolRow[]
  return rows.map((r) => ({
    trackId: r.track_id,
    appleId: r.apple_id,
    spotifyId: r.spotify_id,
    title: r.title,
    artist: r.artist,
    playCount: num(r.play_count),
    tempo: num(r.tempo),
    energy: num(r.energy),
    valence: num(r.valence),
    releaseYear: r.release_year,
    durationMs: r.duration_ms,
    score: Number(r.score),
  }))
}
