import { and, eq, inArray, isNull, sql, type SQL } from 'drizzle-orm'
import { artworkRunLocks, trackArtworkStatus, tracks } from '../db/schema'
import type { Db } from '../db/types'
import { normalizeIsrc } from '../contracts/isrc'
import {
  AppleCatalogError,
  type AppleCatalogClient,
  type ArtworkMetadata,
  type CatalogSong,
} from '../musickit/catalog'

export const MAX_ARTWORK_BATCH = 300
export const ARTWORK_REFRESH_MS = 30 * 24 * 60 * 60 * 1000
export const ARTWORK_NO_MATCH_RETRY_MS = 30 * 24 * 60 * 60 * 1000
export const ARTWORK_MALFORMED_RETRY_MS = 7 * 24 * 60 * 60 * 1000
export const ARTWORK_RATE_LIMIT_RETRY_MS = 60 * 60 * 1000
export const ARTWORK_UPSTREAM_RETRY_MS = 15 * 60 * 1000
export const ARTWORK_AUTH_RETRY_MS = 6 * 60 * 60 * 1000
export const ARTWORK_INTERNAL_RETRY_MS = 60 * 60 * 1000
// The ISRC backfill asks for at most this many songs, one catalogue request.
export const ISRC_BACKFILL_BATCH = 300
// A song Apple returned no ISRC for is asked again after this long, not hourly.
export const ISRC_RECHECK_MS = 30 * 24 * 60 * 60 * 1000

export type ArtworkFailureCategory =
  | 'no_match'
  | 'rate_limit'
  | 'upstream'
  | 'timeout'
  | 'malformed'
  | 'authorization'
  | 'network'
  | 'internal'

export type ArtworkDeps = {
  storefront: string
  catalog: AppleCatalogClient
  now?: () => Date
}

export type ArtworkRunResult = {
  processed: number
  matched: number
  missing: number
  failed: number
  remaining: number
}

type Candidate = {
  id: string
  apple_id: string
  storefront: string
}

function normalizeRows(res: unknown): Record<string, unknown>[] {
  if (Array.isArray(res)) return res as Record<string, unknown>[]
  const rows = (res as { rows?: unknown } | null | undefined)?.rows
  return Array.isArray(rows) ? (rows as Record<string, unknown>[]) : []
}

function candidateWhere(now: Date): SQL {
  const staleBefore = new Date(now.getTime() - ARTWORK_REFRESH_MS)
  return sql`
    FROM tracks t
    LEFT JOIN track_artwork_status s ON s.track_id = t.id
    WHERE t.apple_id IS NOT NULL
      AND (
        t.artwork_url_template IS NULL
        OR t.artwork_fetched_at IS NULL
        OR t.artwork_fetched_at <= ${staleBefore}
      )
      AND (s.track_id IS NULL OR s.next_attempt_at <= ${now})
  `
}

function clampLimit(limit: number): number {
  if (!Number.isFinite(limit) || limit <= 0) return MAX_ARTWORK_BATCH
  return Math.min(MAX_ARTWORK_BATCH, Math.max(1, Math.floor(limit)))
}

function categoryForError(error: unknown): ArtworkFailureCategory {
  if (!(error instanceof AppleCatalogError)) return 'internal'
  if (error.category === 'response') return 'malformed'
  if (error.category === 'authorization') return 'authorization'
  if (error.category === 'rate_limit') return 'rate_limit'
  if (error.category === 'upstream') return 'upstream'
  if (error.category === 'timeout') return 'timeout'
  if (error.category === 'network') return 'network'
  return 'internal'
}

export function artworkRetryMs(category: ArtworkFailureCategory): number {
  if (category === 'no_match') return ARTWORK_NO_MATCH_RETRY_MS
  if (category === 'malformed') return ARTWORK_MALFORMED_RETRY_MS
  if (category === 'rate_limit') return ARTWORK_RATE_LIMIT_RETRY_MS
  if (category === 'upstream' || category === 'timeout' || category === 'network') {
    return ARTWORK_UPSTREAM_RETRY_MS
  }
  if (category === 'authorization') return ARTWORK_AUTH_RETRY_MS
  return ARTWORK_INTERNAL_RETRY_MS
}

type Failure = { trackId: string; category: ArtworkFailureCategory }
type Match = { trackId: string; artwork: ArtworkMetadata; isrc: string | null }

async function persistResults(db: Db, matches: Match[], failures: Failure[], now: Date) {
  if (matches.length > 0) {
    const payload = JSON.stringify(
      matches.map(({ trackId, artwork, isrc }) => ({
        track_id: trackId,
        url: artwork.url,
        width: artwork.width,
        height: artwork.height,
        bg_color: artwork.bgColor,
        isrc,
      })),
    )
    // The catalogue song carries its ISRC; keep it when the row has none, and
    // mark the row checked so the ISRC backfill does not ask again.
    await db.execute(sql`
      UPDATE tracks AS t
      SET artwork_url_template = a.url,
          artwork_width = COALESCE(a.width, t.artwork_width),
          artwork_height = COALESCE(a.height, t.artwork_height),
          artwork_bg_color = COALESCE(a.bg_color, t.artwork_bg_color),
          artwork_fetched_at = ${now},
          isrc = COALESCE(t.isrc, a.isrc),
          isrc_checked_at = ${now}
      FROM jsonb_to_recordset(${payload}::jsonb) AS a(
        track_id uuid,
        url text,
        width integer,
        height integer,
        bg_color text,
        isrc text
      )
      WHERE t.id = a.track_id
    `)
    await db
      .delete(trackArtworkStatus)
      .where(inArray(trackArtworkStatus.trackId, matches.map((match) => match.trackId)))
  }

  if (failures.length > 0) {
    await db
      .insert(trackArtworkStatus)
      .values(
        failures.map(({ trackId, category }) => ({
          trackId,
          attempts: 1,
          lastCategory: category,
          nextAttemptAt: new Date(now.getTime() + artworkRetryMs(category)),
          updatedAt: now,
        })),
      )
      .onConflictDoUpdate({
        target: trackArtworkStatus.trackId,
        set: {
          attempts: sql`${trackArtworkStatus.attempts} + 1`,
          lastCategory: sql`excluded.last_category`,
          nextAttemptAt: sql`excluded.next_attempt_at`,
          updatedAt: now,
        },
      })
  }
}

async function runLockedArtworkBatch(
  db: Db,
  deps: ArtworkDeps,
  requestedLimit: number,
): Promise<ArtworkRunResult> {
  const now = deps.now?.() ?? new Date()
  const fromWhere = candidateWhere(now)
  const selected = await db.execute(sql`
    WITH market AS (
      SELECT coalesce(t.apple_catalog_storefront, ${deps.storefront}) AS storefront
      ${fromWhere}
      ORDER BY t.created_at, t.id LIMIT 1
    )
    SELECT t.id, t.apple_id, coalesce(t.apple_catalog_storefront, ${deps.storefront}) AS storefront
    ${fromWhere}
      AND coalesce(t.apple_catalog_storefront, ${deps.storefront}) = (SELECT storefront FROM market)
    ORDER BY t.created_at, t.id
    LIMIT ${clampLimit(requestedLimit)}
  `)
  const candidates = normalizeRows(selected) as Candidate[]

  if (candidates.length === 0) {
    return { processed: 0, matched: 0, missing: 0, failed: 0, remaining: 0 }
  }

  let matches: Match[] = []
  let failures: Failure[] = []
  let missing = 0

  try {
    const songs = await deps.catalog.getSongs(
      candidates[0].storefront,
      candidates.map((candidate) => candidate.apple_id),
    )
    for (const candidate of candidates) {
      const returned = songs.get(candidate.apple_id)
      if (!returned || returned.appleId !== candidate.apple_id) {
        failures.push({ trackId: candidate.id, category: 'no_match' })
        missing++
      } else if (!returned.artwork) {
        failures.push({ trackId: candidate.id, category: 'malformed' })
      } else {
        matches.push({ trackId: candidate.id, artwork: returned.artwork, isrc: normalizeIsrc(returned.isrc) })
      }
    }
  } catch (error) {
    const category = categoryForError(error)
    failures = candidates.map((candidate) => ({ trackId: candidate.id, category }))
  }

  await persistResults(db, matches, failures, now)

  const remainingResult = await db.execute(sql`SELECT COUNT(*) AS count ${candidateWhere(now)}`)
  const remaining = Number(normalizeRows(remainingResult)[0]?.count ?? 0)
  return {
    processed: candidates.length,
    matched: matches.length,
    missing,
    failed: failures.length - missing,
    remaining,
  }
}

export async function runArtworkBatch(
  db: Db,
  deps: ArtworkDeps,
  requestedLimit: number,
): Promise<ArtworkRunResult> {
  return db.transaction(async (tx) => {
    const now = deps.now?.() ?? new Date()
    await tx
      .insert(artworkRunLocks)
      .values({ name: 'catalog', updatedAt: now })
      .onConflictDoNothing()
    await tx.execute(sql`
      SELECT name
      FROM artwork_run_locks
      WHERE name = 'catalog'
      FOR UPDATE
    `)

    const result = await runLockedArtworkBatch(tx as unknown as Db, deps, requestedLimit)
    await tx
      .update(artworkRunLocks)
      .set({ updatedAt: now })
      .where(eq(artworkRunLocks.name, 'catalog'))
    return result
  })
}

export type IsrcBackfillResult = {
  processed: number
  filled: number
  failed: number
  remaining: number
}

type BackfillCandidate = { id: string; apple_id: string; storefront: string }

function isrcBackfillWhere(now: Date): SQL {
  const recheckBefore = new Date(now.getTime() - ISRC_RECHECK_MS)
  return sql`
    FROM tracks t
    WHERE t.apple_id IS NOT NULL
      AND t.artwork_url_template IS NOT NULL
      AND t.isrc IS NULL
      AND (t.isrc_checked_at IS NULL OR t.isrc_checked_at <= ${recheckBefore})
  `
}

// Apple rows that got artwork before the artwork job kept ISRCs. One
// catalogue request per run, one market per run. A transient provider
// failure leaves the rows unmarked, so the next hourly run asks again; any
// other failure defers them. A success marks every asked row, found or not,
// and only fills an ISRC the row still lacks.
export async function runAppleIsrcBackfill(db: Db, deps: ArtworkDeps): Promise<IsrcBackfillResult> {
  const now = deps.now?.() ?? new Date()
  const fromWhere = isrcBackfillWhere(now)
  const candidates = normalizeRows(await db.execute(sql`
    WITH market AS (
      SELECT coalesce(t.apple_catalog_storefront, ${deps.storefront}) AS storefront
      ${fromWhere}
      ORDER BY t.id LIMIT 1
    )
    SELECT t.id, t.apple_id, coalesce(t.apple_catalog_storefront, ${deps.storefront}) AS storefront
    ${fromWhere}
      AND coalesce(t.apple_catalog_storefront, ${deps.storefront}) = (SELECT storefront FROM market)
    ORDER BY t.id
    LIMIT ${ISRC_BACKFILL_BATCH}
  `)) as BackfillCandidate[]
  if (candidates.length === 0) return { processed: 0, filled: 0, failed: 0, remaining: 0 }

  let songs: Map<string, CatalogSong>
  try {
    songs = await deps.catalog.getSongs(
      candidates[0].storefront,
      candidates.map((candidate) => candidate.apple_id),
    )
  } catch (error) {
    if (!isTransientBackfillError(error)) {
      // isrc_checked_at is one timestamp read against ISRC_RECHECK_MS. Writing
      // it that far back, less the artwork job's malformed retry window, makes
      // the rows due again after that shorter window instead of 30 days, and
      // lets the next run move on to later rows.
      const deferredTo = new Date(now.getTime() - ISRC_RECHECK_MS + ARTWORK_MALFORMED_RETRY_MS)
      await db
        .update(tracks)
        .set({ isrcCheckedAt: deferredTo })
        .where(and(inArray(tracks.id, candidates.map((candidate) => candidate.id)), isNull(tracks.isrc)))
    }
    return {
      processed: candidates.length,
      filled: 0,
      failed: candidates.length,
      remaining: await backfillRemaining(db, now),
    }
  }

  const payload = JSON.stringify(candidates.map((candidate) => {
    const song = songs.get(candidate.apple_id)
    return {
      track_id: candidate.id,
      apple_id: candidate.apple_id,
      isrc: song?.appleId === candidate.apple_id ? normalizeIsrc(song.isrc) : null,
    }
  }))
  const updated = normalizeRows(await db.execute(sql`
    UPDATE tracks AS t
    SET isrc = COALESCE(t.isrc, a.isrc),
        isrc_checked_at = ${now}
    FROM jsonb_to_recordset(${payload}::jsonb) AS a(track_id uuid, apple_id text, isrc text)
    WHERE t.id = a.track_id AND t.apple_id = a.apple_id
    RETURNING a.isrc IS NOT NULL AND t.isrc = a.isrc AS filled
  `))
  return {
    processed: candidates.length,
    filled: updated.filter((row) => row.filled === true).length,
    failed: 0,
    remaining: await backfillRemaining(db, now),
  }
}

async function backfillRemaining(db: Db, now: Date): Promise<number> {
  const result = await db.execute(sql`SELECT COUNT(*) AS count ${isrcBackfillWhere(now)}`)
  return Number(normalizeRows(result)[0]?.count ?? 0)
}

// Worth asking again next hour: rate limits, timeouts, network faults and
// server-side 5xx errors. Anything else (a malformed response, authorization,
// a 4xx, an unexpected error) would fail the same id-ordered batch every hour.
function isTransientBackfillError(error: unknown): boolean {
  const category = categoryForError(error)
  if (category === 'rate_limit' || category === 'timeout' || category === 'network') return true
  if (category !== 'upstream') return false
  const status = (error as AppleCatalogError).status
  return status === undefined || status >= 500
}

export type ArtworkStatus = {
  tracks: number
  withArtwork: number
  missingArtwork: number
  retryable: number
}

export async function artworkStatus(db: Db, now = new Date()): Promise<ArtworkStatus> {
  const result = await db.execute(sql`
    SELECT
      (SELECT COUNT(*) FROM tracks) AS tracks,
      (SELECT COUNT(*) FROM tracks WHERE artwork_url_template IS NOT NULL) AS with_artwork,
      (SELECT COUNT(*) FROM tracks WHERE artwork_url_template IS NULL) AS missing_artwork,
      (SELECT COUNT(*) ${candidateWhere(now)}) AS retryable
  `)
  const [row] = normalizeRows(result)
  return {
    tracks: Number(row?.tracks ?? 0),
    withArtwork: Number(row?.with_artwork ?? 0),
    missingArtwork: Number(row?.missing_artwork ?? 0),
    retryable: Number(row?.retryable ?? 0),
  }
}
