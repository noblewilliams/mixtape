import { and, eq, gt, inArray, ne, sql } from 'drizzle-orm'
import type { Db } from '../db/types'
import { appleIsrcLookups, trackArtworkStatus, tracks } from '../db/schema'
import { AppleCatalogError, type AppleIsrcCatalogClient, type CatalogSong } from '../musickit/catalog'
import { isAppleSongId } from '../musickit/apple-id'
import { parseArtworkMetadata } from '../artwork/normalize'
import { norm } from './types'

export const APPLE_ISRC_BATCH = 25
export const APPLE_ISRC_LEASE_MS = 5 * 60_000
const RETRY_MS = {
  no_match: 30 * 86400_000, ambiguous: 30 * 86400_000, conflict: 30 * 86400_000,
  malformed: 7 * 86400_000, rate_limit: 3600_000, authorization: 6 * 3600_000,
  upstream: 15 * 60_000, timeout: 15 * 60_000, network: 15 * 60_000, internal: 3600_000,
} as const
// A twin is settled: the claim only takes rows whose next attempt is due, and
// this one never is. The column is NOT NULL, so a sentinel stands in for none.
export const APPLE_ISRC_NEVER = new Date('9999-12-31T00:00:00.000Z')
type Failure = keyof typeof RETRY_MS
type Category = Failure | 'twin'
type Candidate = { track_id: string; storefront: string; isrc: string }
// defaultStorefront: the market to look in for a listener whose profile names
// none (a Spotify import records neither a storefront nor a country). The
// profile always wins; with no default such a listener is never eligible.
export type AppleIsrcDeps = { catalog: AppleIsrcCatalogClient; now?: () => Date; defaultStorefront?: string }
export type AppleIsrcResult = {
  processed: number; linked: number; picked: number; missing: number; ambiguous: number
  conflicts: number; twins: number; failed: number; skipped: number
}
// `picked` counts the links (also in `linked`) chosen from several catalogue
// songs. Nothing produces `ambiguous` any more; it stays because older lookup
// rows carry it and the result shape is logged as is.

function rows<T>(value: unknown): T[] {
  return (Array.isArray(value) ? value : (value as { rows: T[] }).rows) as T[]
}

// This is public-catalog work for a current, successfully imported source.
// Connection begins and deleted sources do not qualify on their own.
const eligibleTracks = (fallback: string | null) => sql`
  SELECT DISTINCT t.id AS track_id, upper(t.isrc) AS isrc,
    coalesce(p.apple_storefront, lower(p.country), ${fallback}::text) AS storefront,
    t.enrich_priority AS priority, t.created_at
  FROM tracks t
  JOIN user_tracks ut ON ut.track_id = t.id
  JOIN user_music_profiles p ON p.user_id = ut.user_id
  JOIN user_music_sources src ON src.user_id = ut.user_id
    AND src.source = 'spotify_export' AND src.last_imported_at IS NOT NULL
  WHERE t.spotify_id IS NOT NULL AND t.apple_id IS NULL
    AND upper(t.isrc) ~ '^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$'
    AND coalesce(p.apple_storefront, lower(p.country), ${fallback}::text) ~ '^[a-z]{2}$'
`

async function claim(db: Db, now: Date, token: string, fallback: string | null): Promise<Candidate[]> {
  return rows(await db.execute(sql`
    WITH eligible AS (${eligibleTracks(fallback)}), ready AS (
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

// Judged per song: one bad entry in Apple's answer does not spoil the rest.
function usable(song: CatalogSong, isrc: string): boolean {
  return song.isrc?.toUpperCase() === isrc && isAppleSongId(song.appleId)
    && !!cleanText(song.title) && !!cleanText(song.artist)
}

function releaseYear(song: CatalogSong): number | null {
  return typeof song.releaseYear === 'number' && Number.isInteger(song.releaseYear)
    && song.releaseYear >= 1000 && song.releaseYear <= 9999 ? song.releaseYear : null
}

// Songs sharing an ISRC are the same recording (single, album, deluxe), so any
// of them will do. Prefer the one that reads like the Spotify row, then the
// original release, then a stable order. IDs are opaque, so shorter sorts
// first to keep numeric IDs in numeric order.
function bestPick(songs: CatalogSong[], row: { title: string; artist: string } | undefined): CatalogSong {
  const title = row ? norm(row.title) : '', artist = row ? norm(row.artist) : ''
  const miss = (want: string, got: string) => want && norm(got) === want ? 0 : 1
  return [...songs].sort((a, b) =>
    miss(title, a.title) - miss(title, b.title)
    || miss(artist, a.artist) - miss(artist, b.artist)
    || (releaseYear(a) ?? Infinity) - (releaseYear(b) ?? Infinity)
    || a.appleId.length - b.appleId.length
    || (a.appleId < b.appleId ? -1 : a.appleId > b.appleId ? 1 : 0))[0]
}

// The Apple id is already held by another row with this ISRC: the same
// recording reached us twice, which is a state, not a conflict to retry.
async function heldByTwin(db: Db, item: Candidate, appleIds: string[]): Promise<boolean> {
  return (await db.select({ id: tracks.id }).from(tracks).where(and(
    inArray(tracks.appleId, appleIds), ne(tracks.id, item.track_id), sql`upper(${tracks.isrc}) = ${item.isrc}`,
  )).limit(1)).length > 0
}

async function link(db: Db, item: Candidate, song: CatalogSong, now: Date, fallback: string | null): Promise<boolean> {
  const artwork = parseArtworkMetadata(song.artwork)
  const duration = typeof song.durationMs === 'number' && Number.isInteger(song.durationMs)
    && song.durationMs > 0 && song.durationMs <= 2147483647 ? song.durationMs : null
  const year = releaseYear(song)
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
        SELECT 1 FROM (${eligibleTracks(fallback)}) active
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
  const market = deps.defaultStorefront?.trim().toLowerCase() ?? ''
  const fallback = /^[a-z]{2}$/.test(market) ? market : null
  const batch = await claim(db, currentTime(), token, fallback)
  const result: AppleIsrcResult = {
    processed: 0, linked: 0, picked: 0, missing: 0, ambiguous: 0, conflicts: 0, twins: 0, failed: 0, skipped: 0,
  }
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
    // Choosing among several songs needs the Spotify rows' names and who holds
    // each candidate id: one statement each for the whole batch, kept current
    // below as this batch links.
    const usableFor = (isrc: string) => (songs.get(isrc) ?? []).filter(song => usable(song, isrc))
    const several = owned.filter(record => usableFor(record.isrc).length > 1)
    const names = new Map<string, { title: string; artist: string }>()
    const holders = new Map<string, { id: string; isrc: string | null }>()
    if (!failure && several.length) {
      const ids = several.map(record => record.trackId)
      for (const row of await tx.select({ id: tracks.id, title: tracks.title, artist: tracks.artist })
        .from(tracks).where(inArray(tracks.id, ids))) names.set(row.id, row)
      const appleIds = [...new Set(several.flatMap(record => usableFor(record.isrc).map(song => song.appleId)))]
      for (const row of await tx.select({ id: tracks.id, appleId: tracks.appleId, isrc: tracks.isrc })
        .from(tracks).where(inArray(tracks.appleId, appleIds))) {
        holders.set(row.appleId!, { id: row.id, isrc: row.isrc?.toUpperCase() ?? null })
      }
    }
    for (const record of owned) {
      const item = { track_id: record.trackId, storefront: record.storefront, isrc: record.isrc }
      const key = and(eq(appleIsrcLookups.trackId, item.track_id),
        eq(appleIsrcLookups.storefront, item.storefront), eq(appleIsrcLookups.isrc, item.isrc),
        eq(appleIsrcLookups.leaseToken, token))
      result.processed++
      const active = rows(await tx.execute(sql`
        SELECT 1 FROM (${eligibleTracks(fallback)}) e
        WHERE e.track_id = ${item.track_id} AND e.storefront = ${item.storefront} AND e.isrc = ${item.isrc}
      `)).length > 0
      if (!active) {
        result.skipped++
        await tx.delete(appleIsrcLookups).where(key)
        continue
      }
      const matches = songs.get(item.isrc) ?? []
      const candidates = usableFor(item.isrc)
      let category: Category | undefined = failure
      // A twin among the candidates settles the row whichever song would win.
      const twin = candidates.length > 1 && candidates.some(song => {
        const holder = holders.get(song.appleId)
        return holder && holder.id !== item.track_id && holder.isrc === item.isrc
      })
      const free = candidates.length > 1 ? candidates.filter(song => !holders.has(song.appleId)) : candidates
      if (!category) {
        if (!matches.length) category = 'no_match'
        else if (!candidates.length) category = 'malformed'
        else if (twin) category = 'twin'
        else if (!free.length) category = 'conflict'
        else {
          const song = candidates.length > 1 ? bestPick(free, names.get(item.track_id)) : candidates[0]
          try {
            // Isolate an Apple-ID uniqueness race with other catalog writers.
            const linked = await tx.transaction(inner => link(inner as unknown as Db, item, song, now, fallback))
            if (linked) {
              result.linked++
              if (candidates.length > 1) result.picked++
              holders.set(song.appleId, { id: item.track_id, isrc: item.isrc })
            } else category = 'conflict'
          } catch (error) {
            if (!appleIdConflict(error)) throw error
            category = 'conflict'
          }
          if (category === 'conflict'
            && await heldByTwin(tx as unknown as Db, item, candidates.map(candidate => candidate.appleId))) {
            category = 'twin'
          }
        }
      }
      if (category) {
        if (category === 'no_match') result.missing++
        else if (category === 'ambiguous') result.ambiguous++
        else if (category === 'conflict') result.conflicts++
        else if (category === 'twin') result.twins++
        else result.failed++
        const nextAttemptAt = category === 'twin' ? APPLE_ISRC_NEVER : new Date(now.getTime() + RETRY_MS[category])
        await tx.update(appleIsrcLookups).set({ lastCategory: category, nextAttemptAt, updatedAt: now }).where(key)
      } else await tx.delete(appleIsrcLookups).where(key)
    }
  })
  return result
}
