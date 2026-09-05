import { and, eq, gt, sql } from 'drizzle-orm'
import type { Db } from '../db/types'
import { appleIsrcLookups, trackArtworkStatus } from '../db/schema'
import { AppleCatalogError, type AppleIsrcCatalogClient, type CatalogSong } from '../musickit/catalog'
import { isAppleSongId } from '../musickit/apple-id'
import { parseArtworkMetadata } from '../artwork/normalize'

export const APPLE_ISRC_BATCH = 25
export const APPLE_ISRC_LEASE_MS = 5 * 60_000
const RETRY_MS = {
  no_match: 30 * 86400_000, ambiguous: 30 * 86400_000, conflict: 30 * 86400_000,
  malformed: 7 * 86400_000, rate_limit: 3600_000, authorization: 6 * 3600_000,
  upstream: 15 * 60_000, timeout: 15 * 60_000, network: 15 * 60_000, internal: 3600_000,
} as const
type Failure = keyof typeof RETRY_MS
type Candidate = { track_id: string; storefront: string; isrc: string }
export type AppleIsrcDeps = { catalog: AppleIsrcCatalogClient; now?: () => Date }
export type AppleIsrcResult = {
  processed: number; linked: number; missing: number; ambiguous: number
  conflicts: number; failed: number; skipped: number
}

function rows<T>(value: unknown): T[] {
  return (Array.isArray(value) ? value : (value as { rows: T[] }).rows) as T[]
}

// This is public-catalog work for a current, successfully imported source.
// Connection begins and deleted sources do not qualify on their own.
const eligibleTracks = () => sql`
  SELECT DISTINCT t.id AS track_id, upper(t.isrc) AS isrc,
    coalesce(p.apple_storefront, lower(p.country)) AS storefront,
    t.enrich_priority AS priority, t.created_at
  FROM tracks t
  JOIN user_tracks ut ON ut.track_id = t.id
  JOIN user_music_profiles p ON p.user_id = ut.user_id
  JOIN user_music_sources src ON src.user_id = ut.user_id
    AND src.source = 'spotify_export' AND src.last_imported_at IS NOT NULL
  WHERE t.spotify_id IS NOT NULL AND t.apple_id IS NULL
    AND upper(t.isrc) ~ '^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$'
    AND coalesce(p.apple_storefront, lower(p.country)) ~ '^[a-z]{2}$'
`

async function claim(db: Db, now: Date, token: string): Promise<Candidate[]> {
  return rows(await db.execute(sql`
    WITH eligible AS (${eligibleTracks()}), ready AS (
      SELECT e.*, s.updated_at AS last_attempt
      FROM eligible e LEFT JOIN apple_isrc_lookups s
        ON s.track_id = e.track_id AND s.storefront = e.storefront AND s.isrc = e.isrc
      WHERE s.track_id IS NULL OR s.next_attempt_at <= ${now}
    ), market AS (
      SELECT storefront FROM ready
      ORDER BY priority DESC, last_attempt NULLS FIRST, created_at, track_id, storefront LIMIT 1
    ), chosen AS (
      SELECT r.* FROM ready r JOIN market m ON m.storefront = r.storefront
      ORDER BY r.priority DESC, r.last_attempt NULLS FIRST, r.created_at, r.track_id
      LIMIT ${APPLE_ISRC_BATCH}
    )
    INSERT INTO apple_isrc_lookups
      (track_id, storefront, isrc, attempts, last_category, next_attempt_at, lease_token, updated_at)
    SELECT track_id, storefront, isrc, 1, 'pending',
      ${new Date(now.getTime() + APPLE_ISRC_LEASE_MS)}, ${token}::uuid, ${now}
    FROM chosen ORDER BY track_id, storefront, isrc
    ON CONFLICT (track_id, storefront, isrc) DO UPDATE SET
      attempts = apple_isrc_lookups.attempts + 1, last_category = 'pending',
      next_attempt_at = excluded.next_attempt_at, lease_token = excluded.lease_token,
      updated_at = excluded.updated_at
    WHERE apple_isrc_lookups.next_attempt_at <= ${now}
    RETURNING track_id, storefront, isrc
  `))
}

function failureCategory(error: unknown): Failure {
  return error instanceof AppleCatalogError
    ? error.category === 'response' ? 'malformed' : error.category
    : 'internal'
}

function appleIdConflict(error: unknown): boolean {
  let cause = error
  for (let depth = 0; depth < 4 && cause && typeof cause === 'object'; depth++) {
    if ('code' in cause && cause.code === '23505'
      && 'constraint' in cause && cause.constraint === 'tracks_apple_id_idx') return true
    cause = 'cause' in cause ? cause.cause : undefined
  }
  return false
}

function cleanText(value: unknown, limit = 1000): string | null {
  return typeof value === 'string' && value.trim() && value.length <= limit && !value.includes('\0')
    ? value : null
}

async function link(db: Db, item: Candidate, song: CatalogSong, now: Date): Promise<boolean> {
  const artwork = parseArtworkMetadata(song.artwork)
  const duration = typeof song.durationMs === 'number' && Number.isInteger(song.durationMs)
    && song.durationMs > 0 && song.durationMs <= 2147483647 ? song.durationMs : null
  const year = typeof song.releaseYear === 'number' && Number.isInteger(song.releaseYear)
    && song.releaseYear >= 1000 && song.releaseYear <= 9999 ? song.releaseYear : null
  const result = await db.execute(sql`
    UPDATE tracks target SET
      apple_id = ${song.appleId}, apple_catalog_storefront = ${item.storefront},
      album = coalesce(target.album, ${cleanText(song.album)}),
      genre = coalesce(target.genre, ${cleanText(song.genre, 250)}),
      duration_ms = coalesce(target.duration_ms, ${duration}),
      release_year = coalesce(target.release_year, ${year}),
      explicit = coalesce(target.explicit, ${typeof song.explicit === 'boolean' ? song.explicit : null}),
      artwork_width = CASE WHEN target.artwork_url_template IS NULL THEN ${artwork?.width ?? null} ELSE target.artwork_width END,
      artwork_height = CASE WHEN target.artwork_url_template IS NULL THEN ${artwork?.height ?? null} ELSE target.artwork_height END,
      artwork_bg_color = CASE WHEN target.artwork_url_template IS NULL THEN ${artwork?.bgColor ?? null} ELSE target.artwork_bg_color END,
      artwork_fetched_at = CASE WHEN target.artwork_url_template IS NULL AND ${artwork != null} THEN ${now} ELSE target.artwork_fetched_at END,
      artwork_url_template = coalesce(target.artwork_url_template, ${artwork?.url ?? null})
    WHERE target.id = ${item.track_id} AND target.apple_id IS NULL AND upper(target.isrc) = ${item.isrc}
      AND NOT EXISTS (SELECT 1 FROM tracks other WHERE other.apple_id = ${song.appleId})
      AND EXISTS (
        SELECT 1 FROM (${eligibleTracks()}) active
        WHERE active.track_id = target.id AND active.storefront = ${item.storefront} AND active.isrc = ${item.isrc}
      )
    RETURNING target.id
  `)
  const linked = rows(result).length === 1
  // A Spotify fallback miss may have left source-specific artwork retry state.
  // Once this row owns an Apple catalog id, Apple artwork should run on its own
  // schedule rather than inherit that earlier provider's backoff.
  if (linked) {
    await db.delete(trackArtworkStatus).where(eq(trackArtworkStatus.trackId, item.track_id))
  }
  return linked
}

export async function runAppleIsrcBatch(db: Db, deps: AppleIsrcDeps): Promise<AppleIsrcResult> {
  const currentTime = () => deps.now?.() ?? new Date()
  const token = crypto.randomUUID()
  const batch = await claim(db, currentTime(), token)
  const result: AppleIsrcResult = { processed: 0, linked: 0, missing: 0, ambiguous: 0, conflicts: 0, failed: 0, skipped: 0 }
  if (!batch.length) return result
  const storefront = batch[0].storefront
  let songs = new Map<string, CatalogSong[]>()
  let failure: Failure | undefined
  try {
    songs = await deps.catalog.getSongsByIsrc(storefront, [...new Set(batch.map(item => item.isrc))])
  } catch (error) {
    failure = failureCategory(error)
  }
  // No transaction/row lock is held across the upstream request.
  await db.transaction(async (tx) => {
    const now = currentTime()
    const owned = await tx.select().from(appleIsrcLookups).where(and(
      eq(appleIsrcLookups.leaseToken, token), eq(appleIsrcLookups.lastCategory, 'pending'),
      gt(appleIsrcLookups.nextAttemptAt, now),
    )).orderBy(appleIsrcLookups.trackId).for('update')
    for (const record of owned) {
      const item = { track_id: record.trackId, storefront: record.storefront, isrc: record.isrc }
      const key = and(eq(appleIsrcLookups.trackId, item.track_id),
        eq(appleIsrcLookups.storefront, item.storefront), eq(appleIsrcLookups.isrc, item.isrc),
        eq(appleIsrcLookups.leaseToken, token))
      result.processed++
      const active = rows(await tx.execute(sql`
        SELECT 1 FROM (${eligibleTracks()}) e
        WHERE e.track_id = ${item.track_id} AND e.storefront = ${item.storefront} AND e.isrc = ${item.isrc}
      `)).length > 0
      if (!active) {
        result.skipped++
        await tx.delete(appleIsrcLookups).where(key)
        continue
      }
      const matches = songs.get(item.isrc) ?? []
      let category = failure
      if (!category) {
        if (!matches.length) category = 'no_match'
        else if (matches.some(song => song.isrc?.toUpperCase() !== item.isrc
          || !isAppleSongId(song.appleId) || !cleanText(song.title) || !cleanText(song.artist))) category = 'malformed'
        else if (matches.length !== 1) category = 'ambiguous'
        else {
          try {
            // Isolate an Apple-ID uniqueness race with other catalog writers.
            const linked = await tx.transaction(inner => link(inner as unknown as Db, item, matches[0], now))
            if (linked) result.linked++
            else category = 'conflict'
          } catch (error) {
            if (!appleIdConflict(error)) throw error
            category = 'conflict'
          }
        }
      }
      if (category) {
        if (category === 'no_match') result.missing++
        else if (category === 'ambiguous') result.ambiguous++
        else if (category === 'conflict') result.conflicts++
        else result.failed++
        await tx.update(appleIsrcLookups).set({
          lastCategory: category, nextAttemptAt: new Date(now.getTime() + RETRY_MS[category]), updatedAt: now,
        }).where(key)
      } else await tx.delete(appleIsrcLookups).where(key)
    }
  })
  return result
}
