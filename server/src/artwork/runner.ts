import { inArray, sql, type SQL } from 'drizzle-orm'
import { trackArtworkStatus, tracks } from '../db/schema'
import type { Db } from '../db/types'
import {
  AppleCatalogError,
  type AppleCatalogClient,
  type ArtworkMetadata,
} from '../musickit/catalog'

export const MAX_ARTWORK_BATCH = 300
export const ARTWORK_REFRESH_MS = 30 * 24 * 60 * 60 * 1000
export const ARTWORK_NO_MATCH_RETRY_MS = 30 * 24 * 60 * 60 * 1000
export const ARTWORK_MALFORMED_RETRY_MS = 7 * 24 * 60 * 60 * 1000
export const ARTWORK_RATE_LIMIT_RETRY_MS = 60 * 60 * 1000
export const ARTWORK_UPSTREAM_RETRY_MS = 15 * 60 * 1000
export const ARTWORK_AUTH_RETRY_MS = 6 * 60 * 60 * 1000
export const ARTWORK_INTERNAL_RETRY_MS = 60 * 60 * 1000

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

function retryMs(category: ArtworkFailureCategory): number {
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
type Match = { trackId: string; artwork: ArtworkMetadata }

async function persistResults(db: Db, matches: Match[], failures: Failure[], now: Date) {
  await db.transaction(async (tx) => {
    if (matches.length > 0) {
      const payload = JSON.stringify(
        matches.map(({ trackId, artwork }) => ({
          track_id: trackId,
          url: artwork.url,
          width: artwork.width,
          height: artwork.height,
          bg_color: artwork.bgColor,
        })),
      )
      await tx.execute(sql`
        UPDATE tracks AS t
        SET artwork_url_template = a.url,
            artwork_width = a.width,
            artwork_height = a.height,
            artwork_bg_color = a.bg_color,
            artwork_fetched_at = ${now}
        FROM jsonb_to_recordset(${payload}::jsonb) AS a(
          track_id uuid,
          url text,
          width integer,
          height integer,
          bg_color text
        )
        WHERE t.id = a.track_id
      `)
      await tx
        .delete(trackArtworkStatus)
        .where(inArray(trackArtworkStatus.trackId, matches.map((match) => match.trackId)))
    }

    if (failures.length > 0) {
      await tx
        .insert(trackArtworkStatus)
        .values(
          failures.map(({ trackId, category }) => ({
            trackId,
            attempts: 1,
            lastCategory: category,
            nextAttemptAt: new Date(now.getTime() + retryMs(category)),
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
  })
}

export async function runArtworkBatch(
  db: Db,
  deps: ArtworkDeps,
  requestedLimit: number,
): Promise<ArtworkRunResult> {
  const now = deps.now?.() ?? new Date()
  const fromWhere = candidateWhere(now)
  const selected = await db.execute(sql`
    SELECT t.id, t.apple_id
    ${fromWhere}
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
      deps.storefront,
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
        matches.push({ trackId: candidate.id, artwork: returned.artwork })
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
