import { sql, type SQL } from 'drizzle-orm'
import type { Db } from '../db/types'
import { enrichTrack, type EnrichDeps, type TrackRow } from './pipeline'

export const MAX_ATTEMPTS = 3

// A track is a candidate for this batch when at least one of its two
// derived-data stages (features/meaning) is still missing AND hasn't already
// burned through MAX_ATTEMPTS. Shared between the row-select and the
// remaining-count query so the two can never drift apart.
const CANDIDATE_FROM_WHERE: SQL = sql`
  FROM tracks t
  LEFT JOIN track_features f ON f.track_id = t.id
  LEFT JOIN track_meanings m ON m.track_id = t.id
  LEFT JOIN enrichment_failures ff ON ff.track_id = t.id AND ff.stage = 'features'
  LEFT JOIN enrichment_failures fm ON fm.track_id = t.id AND fm.stage = 'meaning'
  WHERE (f.track_id IS NULL AND COALESCE(ff.attempts, 0) < ${MAX_ATTEMPTS})
     OR (m.track_id IS NULL AND COALESCE(fm.attempts, 0) < ${MAX_ATTEMPTS})
`

// Raw `db.execute(sql...)` result shape differs by driver: neon-http (prod)
// and pglite (test, this version) both hand back `{ rows: [...] }`, but
// nothing guarantees a bare array never shows up on some other driver/version
// — normalize defensively rather than assume one shape.
function normalizeRows(res: unknown): Record<string, unknown>[] {
  if (Array.isArray(res)) return res as Record<string, unknown>[]
  const rows = (res as { rows?: unknown } | null | undefined)?.rows
  return Array.isArray(rows) ? (rows as Record<string, unknown>[]) : []
}

// A raw boolean column can come back as a real JS boolean (pglite, neon-http
// as observed) or as Postgres's wire-protocol 't'/'f' text under some driver
// configs — never trust plain JS truthiness on it directly.
const truthy = (v: unknown): boolean => v === true || v === 't' || v === 'true'

type CandidateRow = {
  id: string
  apple_id: string | null
  spotify_id: string | null
  isrc: string | null
  title: string
  artist: string
  album: string | null
  genre: string | null
  duration_ms: number | null
  release_year: number | null
  explicit: boolean | null
  artwork_url_template: string | null
  artwork_width: number | null
  artwork_height: number | null
  artwork_bg_color: string | null
  artwork_fetched_at: string | null
  artist_source: TrackRow['artistSource']
  enrich_priority: number
  created_at: string
  skip_features: boolean
  skip_meaning: boolean
}

function toTrackRow(r: CandidateRow): TrackRow {
  return {
    id: r.id,
    appleId: r.apple_id,
    spotifyId: r.spotify_id,
    isrc: r.isrc,
    title: r.title,
    artist: r.artist,
    album: r.album,
    genre: r.genre,
    durationMs: r.duration_ms,
    releaseYear: r.release_year,
    explicit: r.explicit,
    artworkUrlTemplate: r.artwork_url_template,
    artworkWidth: r.artwork_width,
    artworkHeight: r.artwork_height,
    artworkBgColor: r.artwork_bg_color,
    artworkFetchedAt:
      r.artwork_fetched_at === null ? null : new Date(r.artwork_fetched_at),
    artistSource: r.artist_source,
    enrichPriority: r.enrich_priority,
    // Raw SQL hands back created_at as a string, not a Date, despite the
    // schema type — a type-only accommodation. Nothing below does date
    // arithmetic on it, so this cast is safe as long as that stays true.
    createdAt: r.created_at as unknown as Date,
  }
}

export type RunResult = { processed: number; features: number; meaning: number; remaining: number }

export async function runEnrichmentBatch(db: Db, deps: EnrichDeps, limit: number): Promise<RunResult> {
  // skip_* is computed in SQL, not just from row-existence, so a stage that's
  // already burned through MAX_ATTEMPTS is never retried just because the
  // *other* stage is what made this track a candidate.
  const selectRes = await db.execute(sql`
    SELECT t.*,
      (f.track_id IS NOT NULL OR COALESCE(ff.attempts, 0) >= ${MAX_ATTEMPTS}) AS skip_features,
      (m.track_id IS NOT NULL OR COALESCE(fm.attempts, 0) >= ${MAX_ATTEMPTS}) AS skip_meaning
    ${CANDIDATE_FROM_WHERE}
    ORDER BY t.created_at, t.id
    LIMIT ${limit}
  `)
  const rows = normalizeRows(selectRes) as unknown as CandidateRow[]

  let features = 0
  let meaning = 0
  for (const row of rows) {
    const track = toTrackRow(row)
    const outcome = await enrichTrack(db, deps, track, {
      features: truthy(row.skip_features),
      meaning: truthy(row.skip_meaning),
    })
    if (outcome.features === 'ok') features++
    if (outcome.meaning === 'ok') meaning++
  }

  const remainingRes = await db.execute(sql`SELECT COUNT(*) AS count ${CANDIDATE_FROM_WHERE}`)
  const remainingRows = normalizeRows(remainingRes)
  const remaining = Number(remainingRows[0]?.count ?? 0)

  return { processed: rows.length, features, meaning, remaining }
}

export type EnrichmentStatus = {
  tracks: number
  withFeatures: number
  withMeaning: number
  withEmbedding: number
  exhausted: number
}

export async function enrichmentStatus(db: Db): Promise<EnrichmentStatus> {
  const res = await db.execute(sql`
    SELECT
      (SELECT COUNT(*) FROM tracks) AS tracks,
      (SELECT COUNT(*) FROM track_features) AS with_features,
      (SELECT COUNT(*) FROM track_meanings) AS with_meaning,
      (SELECT COUNT(*) FROM track_meanings WHERE embedding IS NOT NULL) AS with_embedding,
      (SELECT COUNT(DISTINCT track_id) FROM enrichment_failures WHERE attempts >= ${MAX_ATTEMPTS} AND stage <> 'itunes') AS exhausted
  `)
  const [row] = normalizeRows(res)
  return {
    tracks: Number(row?.tracks ?? 0),
    withFeatures: Number(row?.with_features ?? 0),
    withMeaning: Number(row?.with_meaning ?? 0),
    withEmbedding: Number(row?.with_embedding ?? 0),
    exhausted: Number(row?.exhausted ?? 0),
  }
}
