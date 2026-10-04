import { sql, type SQL } from 'drizzle-orm'
import type { Db } from '../db/types'
import { enrichTrack, type EnrichDeps, type TrackRow } from './pipeline'
import { failureBlocked, failureCooling, failureExhausted } from './failures'

export { MAX_ATTEMPTS, MAX_TRANSIENT_ATTEMPTS } from './failures'

const CANDIDATE_FROM: SQL = sql`
  FROM tracks t
  LEFT JOIN track_features f ON f.track_id = t.id
  LEFT JOIN track_meanings m ON m.track_id = t.id
  LEFT JOIN enrichment_failures ff ON ff.track_id = t.id AND ff.stage = 'features'
  LEFT JOIN enrichment_failures fm ON fm.track_id = t.id AND fm.stage = 'meaning'
`

// A stage is skipped this run when its row exists, or when its failure row is
// exhausted or still cooling down after a transient failure (failures.ts).
const SKIP_FEATURES: SQL = sql`(f.track_id IS NOT NULL OR ${failureBlocked('ff')})`
const SKIP_MEANING: SQL = sql`(m.track_id IS NOT NULL OR ${failureBlocked('fm')})`

// A track is a candidate for this batch when at least one of its two
// derived-data stages (features/meaning) is due now. Shared between the
// row-select and the remaining/cooling counts so they can never drift apart.
const DUE: SQL = sql`(NOT ${SKIP_FEATURES} OR NOT ${SKIP_MEANING})`

// Not due now, but a missing stage will be once its backoff passes. Disjoint
// from DUE, so no track is counted in both remaining and cooling.
const COOLING: SQL = sql`(NOT ${DUE} AND (
  (f.track_id IS NULL AND ${failureCooling('ff')}) OR (m.track_id IS NULL AND ${failureCooling('fm')})))`

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
  apple_catalog_storefront: string | null
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
    appleCatalogStorefront: r.apple_catalog_storefront,
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

// remaining: tracks due now. cooling: tracks with nothing due now but a stage
// waiting out a transient-failure backoff.
export type RunResult = { processed: number; features: number; meaning: number; remaining: number; cooling: number }

// Cache only this invocation's pending batch. Each track still receives only
// its own requested records; a rejected batch is shared too, so an outage
// cannot trigger another identical request for every track in the batch.
function batchLookup<T extends { spotifyId: string }>(
  ids: string[],
  lookup: (ids: string[]) => Promise<{ hits: T[]; missing: string[] }>,
) {
  let pending: ReturnType<typeof lookup> | undefined
  return async (requested: string[]) => {
    const result = await (pending ??= lookup(ids))
    const wanted = new Set(requested)
    return {
      hits: result.hits.filter((hit) => wanted.has(hit.spotifyId)),
      missing: result.missing.filter((id) => wanted.has(id)),
    }
  }
}

export async function runEnrichmentBatch(db: Db, deps: EnrichDeps, limit: number): Promise<RunResult> {
  // skip_* is computed in SQL, not just from row-existence, so a stage that's
  // exhausted or cooling down is never retried just because the *other*
  // stage is what made this track a candidate.
  //
  // Highest enrich_priority first: an import raises it for the listener's pool
  // candidates, so a new listener's heavy-rotation tracks are enriched ahead
  // of the backlog instead of waiting their turn by creation date. Ties fall
  // back to creation order so the walk stays stable batch to batch.
  const selectRes = await db.execute(sql`
    SELECT t.*,
      ${SKIP_FEATURES} AS skip_features,
      ${SKIP_MEANING} AS skip_meaning
    ${CANDIDATE_FROM}
    WHERE ${DUE}
    ORDER BY t.enrich_priority DESC, t.created_at, t.id
    LIMIT ${limit}
  `)
  const rows = normalizeRows(selectRes) as unknown as CandidateRow[]
  const spotifyIds = rows.flatMap((row) =>
    row.spotify_id && !truthy(row.skip_features) ? [row.spotify_id] : [])
  const batchDeps: EnrichDeps = deps.spotify && spotifyIds.length > 0 ? {
    ...deps,
    spotify: {
      tracks: batchLookup(spotifyIds, deps.spotify.tracks),
      features: batchLookup(spotifyIds, deps.spotify.features),
    },
  } : deps

  let features = 0
  let meaning = 0
  for (const row of rows) {
    const track = toTrackRow(row)
    const outcome = await enrichTrack(db, batchDeps, track, {
      features: truthy(row.skip_features),
      meaning: truthy(row.skip_meaning),
    })
    if (outcome.features === 'ok') features++
    if (outcome.meaning === 'ok') meaning++
  }

  const countRes = await db.execute(sql`
    SELECT COUNT(*) FILTER (WHERE ${DUE}) AS remaining, COUNT(*) FILTER (WHERE ${COOLING}) AS cooling
    ${CANDIDATE_FROM}
  `)
  const [counts] = normalizeRows(countRes)
  const remaining = Number(counts?.remaining ?? 0)
  const cooling = Number(counts?.cooling ?? 0)

  return { processed: rows.length, features, meaning, remaining, cooling }
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
      (SELECT COUNT(DISTINCT ef.track_id) FROM enrichment_failures ef WHERE ${failureExhausted('ef')} AND ef.stage <> 'itunes') AS exhausted
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
