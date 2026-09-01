import { sql } from 'drizzle-orm'
import type { Db } from '../db/types'
import {
  PLAYLIST_SYNC_CLEANUP_RUN_LIMIT,
  PLAYLIST_SYNC_EXPIRE_AFTER_MS,
  PLAYLIST_SYNC_STAGING_RETENTION_MS,
} from '../playlists/cleanup'

export const LIBRARY_SYNC_CLEANUP_SONG_BATCH = 5_000
export const LIBRARY_SYNC_CLEANUP_RECENT_BATCH = 750

export type LibrarySyncCleanupResult = {
  touchedRuns: number
  expiredRuns: number
  deletedSongs: number
  deletedRecentTracks: number
  purgedRuns: number
}

type CleanupOptions = {
  now?: () => Date
  runLimit?: number
  songBatchSize?: number
  recentBatchSize?: number
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

export async function cleanupLibrarySyncStaging(
  db: Db,
  options: CleanupOptions = {},
): Promise<LibrarySyncCleanupResult> {
  const current = options.now?.() ?? new Date()
  const expireBefore = new Date(current.getTime() - PLAYLIST_SYNC_EXPIRE_AFTER_MS)
  const purgeBefore = new Date(current.getTime() - PLAYLIST_SYNC_STAGING_RETENTION_MS)
  const runLimit = boundedBatch(
    options.runLimit,
    PLAYLIST_SYNC_CLEANUP_RUN_LIMIT,
    PLAYLIST_SYNC_CLEANUP_RUN_LIMIT,
  )
  const songBatchSize = boundedBatch(
    options.songBatchSize,
    LIBRARY_SYNC_CLEANUP_SONG_BATCH,
    LIBRARY_SYNC_CLEANUP_SONG_BATCH,
  )
  const recentBatchSize = boundedBatch(
    options.recentBatchSize,
    LIBRARY_SYNC_CLEANUP_RECENT_BATCH,
    LIBRARY_SYNC_CLEANUP_RECENT_BATCH,
  )

  return db.transaction(async (rawTx) => {
    const tx = rawTx as unknown as Db
    const candidates = normalizeRows(await tx.execute(sql`
      SELECT r.id, r.status
      FROM library_sync_runs r
      WHERE
        (r.status = 'open' AND r.started_at < ${expireBefore})
        OR (
          r.status IN ('expired', 'completed')
          AND coalesce(r.completed_at, r.expires_at) < ${purgeBefore}
          AND (
            EXISTS (SELECT 1 FROM library_sync_songs s WHERE s.sync_id = r.id)
            OR EXISTS (SELECT 1 FROM library_sync_recent_tracks rt WHERE rt.sync_id = r.id)
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
        UPDATE library_sync_runs
        SET status = 'expired'
        WHERE id IN (${uuidList(openIds)}) AND status = 'open'
        RETURNING id
      `)).length
    }

    let deletedSongs = 0
    let deletedRecentTracks = 0
    let purgedRuns = 0
    if (purgeIds.length > 0) {
      deletedRecentTracks = normalizeRows(await tx.execute(sql`
        DELETE FROM library_sync_recent_tracks
        WHERE (sync_id, rank) IN (
          SELECT sync_id, rank
          FROM library_sync_recent_tracks
          WHERE sync_id IN (${uuidList(purgeIds)})
          ORDER BY sync_id, rank
          LIMIT ${recentBatchSize}
        )
        RETURNING sync_id
      `)).length
      deletedSongs = normalizeRows(await tx.execute(sql`
        DELETE FROM library_sync_songs
        WHERE (sync_id, ordinal) IN (
          SELECT sync_id, ordinal
          FROM library_sync_songs
          WHERE sync_id IN (${uuidList(purgeIds)})
          ORDER BY sync_id, ordinal
          LIMIT ${songBatchSize}
        )
        RETURNING sync_id
      `)).length
      purgedRuns = normalizeRows(await tx.execute(sql`
        SELECT r.id
        FROM library_sync_runs r
        WHERE r.id IN (${uuidList(purgeIds)})
          AND NOT EXISTS (SELECT 1 FROM library_sync_songs s WHERE s.sync_id = r.id)
          AND NOT EXISTS (
            SELECT 1 FROM library_sync_recent_tracks rt WHERE rt.sync_id = r.id
          )
      `)).length
    }

    return {
      touchedRuns: candidates.length,
      expiredRuns,
      deletedSongs,
      deletedRecentTracks,
      purgedRuns,
    }
  })
}
