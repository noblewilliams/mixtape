import { and, eq, inArray, sql } from 'drizzle-orm'
import type { Db } from '../db/types'
import { playlistCatalogLookups, tracks } from '../db/schema'
import { AppleCatalogError, type AppleCatalogClient, type CatalogSong } from '../musickit/catalog'
import { parseArtworkMetadata } from '../artwork/normalize'

export const PLAYLIST_CATALOG_BATCH = 25
export const PLAYLIST_RELINK_BATCH = 1000
export const PLAYLIST_CATALOG_LEASE_MS = 5 * 60_000
const RETRY_MS = {
  no_match: 30 * 86400_000, malformed: 7 * 86400_000,
  rate_limit: 3600_000, authorization: 6 * 3600_000,
  upstream: 15 * 60_000, timeout: 15 * 60_000, network: 15 * 60_000, internal: 3600_000,
} as const
type Failure = keyof typeof RETRY_MS

export type PlaylistCatalogDeps = { catalog: AppleCatalogClient; now?: () => Date }
export type PlaylistCatalogResult = {
  processed: number; matched: number; missing: number; failed: number; linkedEntries: number
}
type Candidate = { apple_id: string; storefront: string }

function rows<T>(result: unknown): T[] {
  if (Array.isArray(result)) return result as T[]
  const values = (result as { rows?: unknown } | null)?.rows
  return Array.isArray(values) ? values as T[] : []
}

// Relinking does not change the source snapshot or manufacture user_tracks.
// A cap bounds popular-song fan-out, independently of the catalog batch size.
async function linkExisting(db: Db): Promise<number> {
  const result = await db.execute(sql`
    WITH ready AS (
      SELECT pe.id, t.id AS track_id, t.apple_id
      FROM playlist_entries pe
      JOIN user_playlists up ON up.id = pe.playlist_id
      JOIN tracks t ON t.apple_id = pe.apple_catalog_id
      WHERE pe.track_id IS NULL AND up.in_library = true AND up.source = 'apple'
      ORDER BY pe.id
      LIMIT ${PLAYLIST_RELINK_BATCH}
    )
    UPDATE playlist_entries pe SET track_id = ready.track_id
    FROM ready
    WHERE pe.id = ready.id AND pe.track_id IS NULL AND pe.apple_catalog_id = ready.apple_id
    RETURNING pe.id
  `)
  return rows(result).length
}

function text(value: string | null | undefined, maxLength = 1000): string | null {
  return typeof value === 'string' && value.trim().length > 0 && value.length <= maxLength && !value.includes('\0')
    ? value : null
}

function record(song: CatalogSong, now: Date): typeof tracks.$inferInsert | null {
  const title = text(song.title)
  const artist = text(song.artist)
  if (!title || !artist) return null
  const artwork = parseArtworkMetadata(song.artwork)
  return {
    appleId: song.appleId, title, artist, album: text(song.album),
    artistSource: 'apple_catalog',
    isrc: song.isrc && /^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$/.test(song.isrc.toUpperCase())
      ? song.isrc.toUpperCase() : null,
    durationMs: typeof song.durationMs === 'number' && Number.isInteger(song.durationMs)
      && song.durationMs > 0 && song.durationMs <= 2147483647 ? song.durationMs : null,
    genre: text(song.genre, 250),
    releaseYear: typeof song.releaseYear === 'number' && Number.isInteger(song.releaseYear)
      && song.releaseYear >= 1000 && song.releaseYear <= 9999 ? song.releaseYear : null,
    explicit: typeof song.explicit === 'boolean' ? song.explicit : null,
    artworkUrlTemplate: artwork?.url,
    artworkWidth: artwork?.width, artworkHeight: artwork?.height,
    artworkBgColor: artwork?.bgColor, artworkFetchedAt: artwork ? now : null,
  }
}

async function claim(db: Db, now: Date, token: string): Promise<Candidate[]> {
  // One statement claims one market. The conflict predicate makes overlapping
  // invocations harmless; a crash becomes retryable when next_attempt_at passes.
  return rows<Candidate>(await db.execute(sql`
    WITH eligible AS (
      SELECT DISTINCT pe.apple_catalog_id AS apple_id, p.apple_storefront AS storefront,
        s.updated_at AS last_attempt
      FROM playlist_entries pe
      JOIN user_playlists up ON up.id = pe.playlist_id
      JOIN user_music_profiles p ON p.user_id = up.user_id
      LEFT JOIN tracks t ON t.apple_id = pe.apple_catalog_id
      LEFT JOIN playlist_catalog_lookups s
        ON s.apple_id = pe.apple_catalog_id AND s.storefront = p.apple_storefront
      WHERE pe.track_id IS NULL AND t.id IS NULL
        AND pe.apple_catalog_id ~ '^[A-Za-z0-9._~-]{1,128}$'
        AND up.in_library = true AND up.source = 'apple'
        AND p.apple_storefront ~ '^[a-z]{2}$'
        AND (s.apple_id IS NULL OR s.next_attempt_at <= ${now})
    ), market AS (
      SELECT storefront FROM eligible
      ORDER BY last_attempt NULLS FIRST, storefront, apple_id LIMIT 1
    ), chosen AS (
      SELECT e.* FROM eligible e JOIN market m ON m.storefront = e.storefront
      ORDER BY e.last_attempt NULLS FIRST, e.apple_id LIMIT ${PLAYLIST_CATALOG_BATCH}
    )
    INSERT INTO playlist_catalog_lookups
      (storefront, apple_id, attempts, last_category, next_attempt_at, lease_token, updated_at)
    SELECT storefront, apple_id, 1, 'pending', ${new Date(now.getTime() + PLAYLIST_CATALOG_LEASE_MS)},
      ${token}::uuid, ${now} FROM chosen ORDER BY storefront, apple_id
    ON CONFLICT (storefront, apple_id) DO UPDATE SET
      attempts = playlist_catalog_lookups.attempts + 1, last_category = 'pending',
      next_attempt_at = excluded.next_attempt_at, lease_token = excluded.lease_token,
      updated_at = excluded.updated_at
    WHERE playlist_catalog_lookups.next_attempt_at <= ${now}
    RETURNING apple_id, storefront
  `))
}

function failureCategory(error: unknown): Failure {
  if (!(error instanceof AppleCatalogError)) return 'internal'
  return error.category === 'response' ? 'malformed' : error.category
}

export async function runPlaylistCatalogBatch(
  db: Db, deps: PlaylistCatalogDeps,
): Promise<PlaylistCatalogResult> {
  const now = deps.now?.() ?? new Date()
  const result: PlaylistCatalogResult = {
    processed: 0, matched: 0, missing: 0, failed: 0, linkedEntries: await linkExisting(db),
  }
  const token = crypto.randomUUID()
  const batch = await claim(db, now, token)
  if (!batch.length) return result
  const storefront = batch[0].storefront
  let songs = new Map<string, CatalogSong>()
  let failure: Failure | undefined
  try {
    songs = await deps.catalog.getSongs(storefront, batch.map(candidate => candidate.apple_id))
  } catch (error) {
    failure = failureCategory(error)
  }
  // The HTTP request above holds no database lock or transaction open.
  await db.transaction(async tx => {
    const owned = await tx.select().from(playlistCatalogLookups)
      .where(and(eq(playlistCatalogLookups.storefront, storefront), eq(playlistCatalogLookups.leaseToken, token)))
      .orderBy(playlistCatalogLookups.appleId).for('update')
    if (!owned.length) return // A newer lease owns these results now.
    result.processed = owned.length
    const active = new Set(rows<{ apple_id: string }>(await tx.execute(sql`
      SELECT DISTINCT pe.apple_catalog_id AS apple_id
      FROM playlist_entries pe
      JOIN user_playlists up ON up.id = pe.playlist_id
      JOIN user_music_profiles p ON p.user_id = up.user_id
      WHERE pe.track_id IS NULL AND up.in_library = true AND up.source = 'apple'
        AND p.apple_storefront = ${storefront}
        AND pe.apple_catalog_id IN (${sql.join(owned.map(item => sql`${item.appleId}`), sql`, `)})
    `)).map(item => item.apple_id))
    const matches: (typeof tracks.$inferInsert)[] = []
    const done: string[] = []
    const failures = new Map<Failure, string[]>()
    for (const item of owned) {
      if (!active.has(item.appleId)) { done.push(item.appleId); continue }
      const song = songs.get(item.appleId)
      const value = song?.appleId === item.appleId ? record(song, now) : null
      const category = failure ?? (song?.appleId !== item.appleId ? 'no_match' : value ? undefined : 'malformed')
      if (category) {
        failures.set(category, [...(failures.get(category) ?? []), item.appleId])
        if (category === 'no_match') result.missing++
        else result.failed++
      } else if (value) {
        matches.push(value)
        done.push(item.appleId)
        result.matched++
      }
    }
    if (matches.length) await tx.insert(tracks).values(matches).onConflictDoNothing()
    if (done.length) await tx.delete(playlistCatalogLookups).where(and(
      eq(playlistCatalogLookups.leaseToken, token), inArray(playlistCatalogLookups.appleId, done),
    ))
    for (const [category, ids] of failures) {
      await tx.update(playlistCatalogLookups).set({
        lastCategory: category, nextAttemptAt: new Date(now.getTime() + RETRY_MS[category]), updatedAt: now,
      }).where(and(eq(playlistCatalogLookups.leaseToken, token), inArray(playlistCatalogLookups.appleId, ids)))
    }
  })
  result.linkedEntries += await linkExisting(db)
  return result
}
