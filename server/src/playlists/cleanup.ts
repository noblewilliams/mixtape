import { sql } from 'drizzle-orm'
import type { Db } from '../db/types'

export const PLAYLIST_SYNC_EXPIRE_AFTER_MS = 24 * 60 * 60 * 1_000
export const PLAYLIST_SYNC_STAGING_RETENTION_MS = 7 * 24 * 60 * 60 * 1_000
export const PLAYLIST_SYNC_CLEANUP_RUN_LIMIT = 25
export const PLAYLIST_SYNC_CLEANUP_ENTRY_BATCH = 5_000
export const PLAYLIST_SYNC_CLEANUP_PLAYLIST_BATCH = 500

export type PlaylistSyncCleanupResult = {
  touchedRuns: number
  expiredRuns: number
  deletedEntries: number
  deletedPlaylists: number
  purgedRuns: number
}

type CleanupOptions = {
  now?: () => Date
  runLimit?: number
  entryBatchSize?: number
  playlistBatchSize?: number
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

export async function cleanupPlaylistSyncStaging(
  db: Db,
  options: CleanupOptions = {},
): Promise<PlaylistSyncCleanupResult> {
  const current = options.now?.() ?? new Date()
  const expireBefore = new Date(current.getTime() - PLAYLIST_SYNC_EXPIRE_AFTER_MS)
  const purgeBefore = new Date(current.getTime() - PLAYLIST_SYNC_STAGING_RETENTION_MS)
  const runLimit = boundedBatch(
    options.runLimit,
    PLAYLIST_SYNC_CLEANUP_RUN_LIMIT,
    PLAYLIST_SYNC_CLEANUP_RUN_LIMIT,
  )
  const entryBatchSize = boundedBatch(
    options.entryBatchSize,
    PLAYLIST_SYNC_CLEANUP_ENTRY_BATCH,
    PLAYLIST_SYNC_CLEANUP_ENTRY_BATCH,
  )
  const playlistBatchSize = boundedBatch(
    options.playlistBatchSize,
    PLAYLIST_SYNC_CLEANUP_PLAYLIST_BATCH,
    PLAYLIST_SYNC_CLEANUP_PLAYLIST_BATCH,
  )

  return db.transaction(async (rawTx) => {
    const tx = rawTx as unknown as Db
    const candidates = normalizeRows(await tx.execute(sql`
      SELECT r.id, r.status
      FROM playlist_sync_runs r
      WHERE
        (r.status = 'open' AND r.started_at < ${expireBefore})
        OR (
          r.status = 'expired'
          AND r.expires_at < ${purgeBefore}
          AND (
            EXISTS (SELECT 1 FROM playlist_sync_playlists p WHERE p.sync_id = r.id)
            OR EXISTS (SELECT 1 FROM playlist_sync_entries e WHERE e.sync_id = r.id)
          )
        )
        OR (
          r.status = 'completed'
          AND r.completed_at < ${purgeBefore}
          AND (
            EXISTS (SELECT 1 FROM playlist_sync_playlists p WHERE p.sync_id = r.id)
            OR EXISTS (SELECT 1 FROM playlist_sync_entries e WHERE e.sync_id = r.id)
          )
        )
      ORDER BY
        CASE
          WHEN r.status = 'open' THEN r.started_at
          WHEN r.status = 'expired' THEN r.expires_at
          ELSE r.completed_at
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
        UPDATE playlist_sync_runs
        SET status = 'expired'
        WHERE id IN (${uuidList(openIds)}) AND status = 'open'
        RETURNING id
      `)).length
    }

    let deletedEntries = 0
    let deletedPlaylists = 0
    let purgedRuns = 0
    if (purgeIds.length > 0) {
      deletedEntries = normalizeRows(await tx.execute(sql`
        DELETE FROM playlist_sync_entries
        WHERE (sync_id, apple_playlist_id, position) IN (
          SELECT sync_id, apple_playlist_id, position
          FROM playlist_sync_entries
          WHERE sync_id IN (${uuidList(purgeIds)})
          ORDER BY sync_id, apple_playlist_id, position
          LIMIT ${entryBatchSize}
        )
        RETURNING sync_id
      `)).length

      deletedPlaylists = normalizeRows(await tx.execute(sql`
        DELETE FROM playlist_sync_playlists
        WHERE (sync_id, apple_library_id) IN (
          SELECT p.sync_id, p.apple_library_id
          FROM playlist_sync_playlists p
          WHERE p.sync_id IN (${uuidList(purgeIds)})
            AND NOT EXISTS (
              SELECT 1
              FROM playlist_sync_entries e
              WHERE e.sync_id = p.sync_id
                AND e.apple_playlist_id = p.apple_library_id
            )
          ORDER BY p.sync_id, p.ordinal
          LIMIT ${playlistBatchSize}
        )
        RETURNING sync_id
      `)).length

      purgedRuns = normalizeRows(await tx.execute(sql`
        SELECT r.id
        FROM playlist_sync_runs r
        WHERE r.id IN (${uuidList(purgeIds)})
          AND NOT EXISTS (
            SELECT 1 FROM playlist_sync_playlists p WHERE p.sync_id = r.id
          )
          AND NOT EXISTS (
            SELECT 1 FROM playlist_sync_entries e WHERE e.sync_id = r.id
          )
      `)).length
    }

    return {
      touchedRuns: candidates.length,
      expiredRuns,
      deletedEntries,
      deletedPlaylists,
      purgedRuns,
    }
  })
}
