import { sql } from 'drizzle-orm'
import type { Db } from '../db/types'
import { EMBEDDING_DIMENSIONS } from '../enrich/embedder'
import { PERSONAL_CANDIDATE_RULE, RECENT_PLAY_WINDOW_DAYS, personalCandidateCtes } from '../dj/pool'

// Album picks, "From the shelf" (spec 2026-10-20 → Candidates): albums the
// listener plainly owns, grouped by name from their mix-pool candidate rows.
export const SHELF_MIN_SONGS = 4
export const SHELF_LIMIT = 10
export const SHELF_MAX_LIMIT = 25
// A single-song group is never a shelf candidate (plan → Task 3), so the
// floor never drops below two whatever the caller asks.
const SHELF_MIN_SONGS_FLOOR = 2

export type ShelfAlbum = {
  artist: string
  album: string
  // Distinct recordings, not tracks rows: rows sharing an ISRC are one song.
  songCount: number
  // Summed observed play counts; null when no row in the group observed a
  // count (web MusicKit cannot), never a fake zero.
  plays: number | null
  similarity: number
  sampleAppleIds: string[]
}

export type BuildShelfOptions = Partial<{ minSongs: number; limit: number }>

// Score weights, hand-set by feel like the pool's: meaning similarity to the
// brief dominates; plays and recency only reorder albums that are close on
// meaning. Each term is in [0,1], so the weights are a convex combination.
const SIM_WEIGHT = 0.7
const PLAYS_WEIGHT = 0.2
const RECENCY_WEIGHT = 0.1

// The play term saturates at a heavy-rotation reference, as the pool's
// familiarity term does (dj/pool.ts → FAM_REFERENCE_PLAYS), here per album.
const PLAYS_REFERENCE = 200
const PLAYS_REFERENCE_LN = Math.log(1 + PLAYS_REFERENCE)

const SAMPLE_APPLE_IDS = 3

type ShelfRow = {
  artist: string
  album: string
  song_count: number | string
  plays: number | string | null
  similarity: number | string
  sample_apple_ids: string[] | null
}

function resolveOptions(options: BuildShelfOptions): { minSongs: number; limit: number } {
  const minSongs = options.minSongs ?? SHELF_MIN_SONGS
  const limit = options.limit ?? SHELF_LIMIT
  // Negative or fractional values are caller bugs, not requests to clamp.
  if (!Number.isSafeInteger(minSongs) || minSongs < 0) throw new Error(`shelf: bad minSongs (${minSongs})`)
  if (!Number.isSafeInteger(limit) || limit < 0) throw new Error(`shelf: bad limit (${limit})`)
  return {
    minSongs: Math.max(SHELF_MIN_SONGS_FLOOR, minSongs),
    limit: Math.min(SHELF_MAX_LIMIT, Math.max(1, limit)),
  }
}

function normalizeRows(res: unknown): Record<string, unknown>[] {
  if (Array.isArray(res)) return res as Record<string, unknown>[]
  const rows = (res as { rows?: unknown } | null | undefined)?.rows
  return Array.isArray(rows) ? (rows as Record<string, unknown>[]) : []
}

/**
 * The listener's shelf for a brief: their personal candidate rows (the mix
 * pool's rule, dj/pool.ts → PERSONAL_CANDIDATE_RULE) grouped by trimmed,
 * case-folded artist and album, groups of at least `minSongs` distinct
 * recordings (COALESCE(isrc, id::text), as buildPool's fam_plays dedupes),
 * best `limit` first. Rows with no album name never group.
 *
 * Score per group:
 *  - similarity: mean of GREATEST(0, 1 - cosine distance) over the group's
 *    rows that have a track_meanings embedding; 0 when none do.
 *  - plays: LEAST(1, ln(1 + summed observed play_count) / ln(1 + PLAYS_REFERENCE));
 *    0 when the group has no observed count (plays is null).
 *  - recency: 1 - days since the group's latest listening_days play inside
 *    RECENT_PLAY_WINDOW_DAYS, over that window; 0 with no play in it.
 * One statement; the ledger is aggregated once per track before the join so
 * it cannot fan out the group's rows.
 */
export async function buildShelf(
  db: Db,
  userId: string,
  briefEmbedding: number[],
  options: BuildShelfOptions = {},
): Promise<ShelfAlbum[]> {
  const { minSongs, limit } = resolveOptions(options)
  if (briefEmbedding.length !== EMBEDDING_DIMENSIONS || !briefEmbedding.every(Number.isFinite)) {
    throw new Error(`shelf: bad embedding (len ${briefEmbedding.length})`)
  }
  // Bound as a string parameter and cast in SQL, exactly as buildPool does.
  const vecLiteral = `[${briefEmbedding.join(',')}]`

  const res = await db.execute(sql`
    WITH ${personalCandidateCtes(userId)},
    -- A second scan of listening_days, on purpose: the shared recent_plays
    -- CTE is the candidate rule's (summed plays over a floor) and cannot
    -- carry MAX(day) without changing what every caller of it reads.
    last_plays AS (
      SELECT track_id, MAX(day) AS last_day
      FROM listening_days
      WHERE user_id = ${userId}
        AND day >= CURRENT_DATE - ${RECENT_PLAY_WINDOW_DAYS}::int
      GROUP BY track_id
    ),
    grouped AS (
      SELECT
        lower(btrim(t.artist)) AS artist_key,
        lower(btrim(t.album)) AS album_key,
        MIN(btrim(t.artist)) AS artist,
        MIN(btrim(t.album)) AS album,
        COUNT(DISTINCT COALESCE(t.isrc, t.id::text))::int AS song_count,
        -- Only observed counts are plays; a group with none stays NULL.
        CASE WHEN BOOL_OR(ut.play_count_observed)
          THEN (SUM(ut.play_count) FILTER (WHERE ut.play_count_observed))::int
        END AS plays,
        -- FILTER, not a NULL passthrough: GREATEST ignores NULL arguments,
        -- so an unembedded row would otherwise average in as 0.
        COALESCE(
          AVG(GREATEST(0, 1 - (tm.embedding <=> ${vecLiteral}::halfvec(1024))))
            FILTER (WHERE tm.embedding IS NOT NULL),
          0
        )::float8 AS similarity,
        -- GREATEST ignores NULL, so a group with no play in the window is 0.
        GREATEST(0, 1 - (CURRENT_DATE - MAX(lp.last_day))::float8 / ${RECENT_PLAY_WINDOW_DAYS}::float8) AS recency,
        COALESCE(
          (ARRAY_AGG(t.apple_id ORDER BY ut.play_count DESC, t.apple_id)
            FILTER (WHERE t.apple_id IS NOT NULL))[1:${SAMPLE_APPLE_IDS}::int],
          '{}'::text[]
        ) AS sample_apple_ids
      FROM user_tracks ut
      JOIN tracks t ON t.id = ut.track_id
      LEFT JOIN track_meanings tm ON tm.track_id = t.id
      LEFT JOIN last_plays lp ON lp.track_id = t.id
      WHERE ut.user_id = ${userId}
        AND ${PERSONAL_CANDIDATE_RULE}
        AND t.album IS NOT NULL
        AND btrim(t.album) <> ''
      GROUP BY 1, 2
      HAVING COUNT(DISTINCT COALESCE(t.isrc, t.id::text)) >= ${minSongs}::int
    )
    SELECT artist, album, song_count, plays, similarity, sample_apple_ids
    FROM grouped
    ORDER BY
      (${SIM_WEIGHT}::float8 * similarity
        + ${PLAYS_WEIGHT}::float8 * COALESCE(LEAST(1, LN(1 + plays) / ${PLAYS_REFERENCE_LN}::float8), 0)
        + ${RECENCY_WEIGHT}::float8 * recency) DESC,
      song_count DESC, artist, album
    LIMIT ${limit}::int
  `)

  return (normalizeRows(res) as unknown as ShelfRow[]).map((r) => ({
    artist: r.artist,
    album: r.album,
    songCount: Number(r.song_count),
    plays: r.plays === null ? null : Number(r.plays),
    similarity: Math.round(Number(r.similarity) * 1000) / 1000,
    sampleAppleIds: r.sample_apple_ids ?? [],
  }))
}
