import { sql } from 'drizzle-orm'
import type { Db } from '../db/types'
import {
  PLAYLIST_SYNC_CLEANUP_RUN_LIMIT,
  PLAYLIST_SYNC_EXPIRE_AFTER_MS,
  PLAYLIST_SYNC_STAGING_RETENTION_MS,
} from '../playlists/cleanup'

export const LISTENING_IMPORT_CLEANUP_TRACK_BATCH = 5_000
export const LISTENING_IMPORT_CLEANUP_DAY_BATCH = 10_000
export const LISTENING_IMPORT_CLEANUP_LIBRARY_BATCH = 5_000
export const LISTENING_IMPORT_CLEANUP_ARTIST_BATCH = 1_000

export type ListeningImportCleanupResult = {
  touchedRuns: number
  expiredRuns: number
  deletedTracks: number
  deletedDays: number
  deletedLibraryTracks: number
  deletedArtists: number
  purgedRuns: number
}

type CleanupOptions = {
  now?: () => Date
  runLimit?: number
  trackBatchSize?: number
  dayBatchSize?: number
  libraryBatchSize?: number
  artistBatchSize?: number
}

function normalizeRows(value: unknown): Record<string, unknown>[] {
  if (Array.isArray(value)) return value as Record<string, unknown>[]
  if (value && typeof value === 'object' && 'rows' in value) {
    const rows = (value as { rows?: unknown }).rows
    return Array.isArray(rows) ? rows as Record<string, unknown>[] : []
  }
  return []
}

function uuidList(ids: string[]) {
  return sql.join(ids.map((id) => sql`${id}::uuid`), sql`, `)
}

function boundedBatch(value: number | undefined, fallback: number, maximum: number) {
  if (value == null) return fallback
  return Math.max(1, Math.min(Math.floor(value), maximum))
}

// Every staging table shares the (import_id, ordinal) primary key.
async function purgeBatch(tx: Db, table: string, purgeIds: string[], batchSize: number) {
  return normalizeRows(await tx.execute(sql`
    DELETE FROM ${sql.identifier(table)}
    WHERE (import_id, ordinal) IN (
      SELECT import_id, ordinal
      FROM ${sql.identifier(table)}
      WHERE import_id IN (${uuidList(purgeIds)})
      ORDER BY import_id, ordinal
      LIMIT ${batchSize}
    )
    RETURNING import_id
  `)).length
}

export async function cleanupListeningImportStaging(
  db: Db,
  options: CleanupOptions = {},
): Promise<ListeningImportCleanupResult> {
  const current = options.now?.() ?? new Date()
  const expireBefore = new Date(current.getTime() - PLAYLIST_SYNC_EXPIRE_AFTER_MS)
  const purgeBefore = new Date(current.getTime() - PLAYLIST_SYNC_STAGING_RETENTION_MS)
  const runLimit = boundedBatch(
    options.runLimit,
    PLAYLIST_SYNC_CLEANUP_RUN_LIMIT,
    PLAYLIST_SYNC_CLEANUP_RUN_LIMIT,
  )
  const trackBatchSize = boundedBatch(
    options.trackBatchSize,
    LISTENING_IMPORT_CLEANUP_TRACK_BATCH,
    LISTENING_IMPORT_CLEANUP_TRACK_BATCH,
  )
  const dayBatchSize = boundedBatch(
    options.dayBatchSize,
    LISTENING_IMPORT_CLEANUP_DAY_BATCH,
    LISTENING_IMPORT_CLEANUP_DAY_BATCH,
  )
  const libraryBatchSize = boundedBatch(
    options.libraryBatchSize,
    LISTENING_IMPORT_CLEANUP_LIBRARY_BATCH,
    LISTENING_IMPORT_CLEANUP_LIBRARY_BATCH,
  )
  const artistBatchSize = boundedBatch(
    options.artistBatchSize,
    LISTENING_IMPORT_CLEANUP_ARTIST_BATCH,
    LISTENING_IMPORT_CLEANUP_ARTIST_BATCH,
  )

  return db.transaction(async (rawTx) => {
    const tx = rawTx as unknown as Db
    const candidates = normalizeRows(await tx.execute(sql`
      SELECT r.id, r.status
      FROM listening_import_runs r
      WHERE
        (r.status = 'open' AND r.started_at < ${expireBefore})
        OR (
          r.status IN ('expired', 'completed')
          AND coalesce(r.completed_at, r.expires_at) < ${purgeBefore}
          AND (
            EXISTS (SELECT 1 FROM listening_import_tracks t WHERE t.import_id = r.id)
            OR EXISTS (SELECT 1 FROM listening_import_days d WHERE d.import_id = r.id)
            OR EXISTS (SELECT 1 FROM listening_import_library l WHERE l.import_id = r.id)
            OR EXISTS (SELECT 1 FROM listening_import_artists a WHERE a.import_id = r.id)
          )
        )
      ORDER BY
        CASE
          WHEN r.status = 'open' THEN r.started_at
          ELSE coalesce(r.completed_at, r.expires_at)
        END ASC,
        r.id ASC
      LIMIT ${runLimit}
      FOR UPDATE OF r SKIP LOCKED
    `))
    const openIds = candidates
      .filter((row) => row.status === 'open')
      .map((row) => String(row.id))
    const purgeIds = candidates
      .filter((row) => row.status === 'expired' || row.status === 'completed')
      .map((row) => String(row.id))

    let expiredRuns = 0
    if (openIds.length > 0) {
      expiredRuns = normalizeRows(await tx.execute(sql`
        UPDATE listening_import_runs
        SET status = 'expired'
        WHERE id IN (${uuidList(openIds)}) AND status = 'open'
        RETURNING id
      `)).length
    }

    let deletedTracks = 0
    let deletedDays = 0
    let deletedLibraryTracks = 0
    let deletedArtists = 0
    let purgedRuns = 0
    if (purgeIds.length > 0) {
      deletedDays = await purgeBatch(tx, 'listening_import_days', purgeIds, dayBatchSize)
      deletedLibraryTracks = await purgeBatch(tx, 'listening_import_library', purgeIds, libraryBatchSize)
      deletedArtists = await purgeBatch(tx, 'listening_import_artists', purgeIds, artistBatchSize)
      deletedTracks = await purgeBatch(tx, 'listening_import_tracks', purgeIds, trackBatchSize)
      purgedRuns = normalizeRows(await tx.execute(sql`
        SELECT r.id
        FROM listening_import_runs r
        WHERE r.id IN (${uuidList(purgeIds)})
          AND NOT EXISTS (SELECT 1 FROM listening_import_tracks t WHERE t.import_id = r.id)
          AND NOT EXISTS (SELECT 1 FROM listening_import_days d WHERE d.import_id = r.id)
          AND NOT EXISTS (SELECT 1 FROM listening_import_library l WHERE l.import_id = r.id)
          AND NOT EXISTS (SELECT 1 FROM listening_import_artists a WHERE a.import_id = r.id)
      `)).length
    }

    return {
      touchedRuns: candidates.length,
      expiredRuns,
      deletedTracks,
      deletedDays,
      deletedLibraryTracks,
      deletedArtists,
      purgedRuns,
    }
  })
}
