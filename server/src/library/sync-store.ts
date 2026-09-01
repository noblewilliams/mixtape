import { and, eq, inArray, or, sql } from 'drizzle-orm'
import type { Db } from '../db/types'
import {
  librarySyncRuns,
  librarySyncSongs,
  librarySyncRecentTracks,
  userMusicProfiles,
  userRecentTrackObservations,
} from '../db/schema'
import type { LibrarySongSnapshot, LibrarySyncSource } from './contracts'

export type LibrarySyncErrorCategory =
  | 'not_found'
  | 'conflict'
  | 'invalid_state'
  | 'count_mismatch'
  | 'internal'

export class LibrarySyncError extends Error {
  constructor(readonly category: LibrarySyncErrorCategory) {
    super(`library-sync:${category}`)
    this.name = 'LibrarySyncError'
  }
}

export type LibrarySyncSummary = {
  songs: number
  catalogResolved: number
  playCountsObserved: number
  recentTracks: number
}

export type LibrarySyncStore = {
  begin(
    userId: string,
    source: LibrarySyncSource,
    storefront: string,
    expectedSongs: number,
    expectedRecentTracks?: number,
  ): Promise<{ syncId: string; expiresAt: number }>
  putSongs(userId: string, syncId: string, songs: LibrarySongSnapshot[]): Promise<void>
  putRecentTracks(userId: string, syncId: string, catalogIds: string[]): Promise<void>
  complete(userId: string, syncId: string): Promise<LibrarySyncSummary>
}

type StoreDeps = {
  now?: () => Date
  ttlMs?: number
  beforeCommit?: () => void | Promise<void>
}

const DEFAULT_TTL_MS = 60 * 60 * 1_000
const toDate = (value: number | null) => value == null ? null : new Date(value)

function normalizeRows(value: unknown): Record<string, unknown>[] {
  if (Array.isArray(value)) return value as Record<string, unknown>[]
  if (value && typeof value === 'object' && 'rows' in value) {
    const rows = (value as { rows?: unknown }).rows
    return Array.isArray(rows) ? rows as Record<string, unknown>[] : []
  }
  return []
}

function sameDate(value: Date | null, millis: number | null) {
  return value?.getTime() === (millis == null ? undefined : millis)
    || (value == null && millis == null)
}

function sameSong(row: typeof librarySyncSongs.$inferSelect, value: LibrarySongSnapshot) {
  return row.ordinal === value.ordinal
    && row.appleLibraryId === value.appleLibraryId
    && row.appleCatalogId === value.appleCatalogId
    && row.title === value.title
    && row.artist === value.artist
    && row.album === value.album
    && row.genre === value.genre
    && row.releaseYear === value.releaseYear
    && row.explicit === value.explicit
    && row.playCount === value.playCount
    && sameDate(row.lastPlayedAt, value.lastPlayedAt)
    && sameDate(row.dateAdded, value.dateAdded)
}

function assertUniqueSongs(values: LibrarySongSnapshot[]) {
  const ordinals = new Set<number>()
  const catalogIds = new Set<string>()
  const libraryIds = new Set<string>()
  for (const value of values) {
    if (ordinals.has(value.ordinal) || catalogIds.has(value.appleCatalogId)) {
      throw new LibrarySyncError('conflict')
    }
    if (value.appleLibraryId != null && libraryIds.has(value.appleLibraryId)) {
      throw new LibrarySyncError('conflict')
    }
    ordinals.add(value.ordinal)
    catalogIds.add(value.appleCatalogId)
    if (value.appleLibraryId != null) libraryIds.add(value.appleLibraryId)
  }
}

function completedSummary(run: typeof librarySyncRuns.$inferSelect): LibrarySyncSummary {
  if (
    run.resultSongs == null
    || run.resultCatalogResolved == null
    || run.resultPlayCountsObserved == null
    || run.resultRecentTracks == null
  ) throw new LibrarySyncError('internal')
  return {
    songs: run.resultSongs,
    catalogResolved: run.resultCatalogResolved,
    playCountsObserved: run.resultPlayCountsObserved,
    recentTracks: run.resultRecentTracks,
  }
}

export function createLibrarySyncStore(db: Db, deps: StoreDeps = {}): LibrarySyncStore {
  const currentTime = () => deps.now?.() ?? new Date()
  const ttlMs = deps.ttlMs ?? DEFAULT_TTL_MS

  async function lockedOpenRun(tx: Db, userId: string, syncId: string, now: Date) {
    const [run] = await tx.select().from(librarySyncRuns)
      .where(and(eq(librarySyncRuns.id, syncId), eq(librarySyncRuns.userId, userId)))
      .for('update')
    if (!run) throw new LibrarySyncError('not_found')
    if (run.status !== 'open' || run.expiresAt.getTime() <= now.getTime()) {
      throw new LibrarySyncError('invalid_state')
    }
    return run
  }

  return {
    async begin(userId, source, storefront, expectedSongs, expectedRecentTracks = 0) {
      return db.transaction(async (rawTx) => {
        const tx = rawTx as unknown as Db
        const now = currentTime()
        const expiresAt = new Date(now.getTime() + ttlMs)
        await tx.insert(userMusicProfiles)
          .values({ userId, appleStorefront: storefront, createdAt: now, updatedAt: now })
          .onConflictDoNothing()
        const [profile] = await tx.select().from(userMusicProfiles)
          .where(eq(userMusicProfiles.userId, userId))
          .for('update')
        if (!profile) throw new LibrarySyncError('not_found')
        await tx.update(userMusicProfiles)
          .set({ appleStorefront: storefront, updatedAt: now })
          .where(eq(userMusicProfiles.userId, userId))
        await tx.update(librarySyncRuns)
          .set({ status: 'expired' })
          .where(and(eq(librarySyncRuns.userId, userId), eq(librarySyncRuns.status, 'open')))
        const [run] = await tx.insert(librarySyncRuns).values({
          userId,
          source,
          status: 'open',
          appleStorefront: storefront,
          expectedSongs,
          expectedRecentTracks,
          startedAt: now,
          expiresAt,
        }).returning({ id: librarySyncRuns.id })
        if (!run) throw new LibrarySyncError('internal')
        return { syncId: run.id, expiresAt: expiresAt.getTime() }
      })
    },

    async putSongs(userId, syncId, songs) {
      assertUniqueSongs(songs)
      await db.transaction(async (rawTx) => {
        const tx = rawTx as unknown as Db
        const run = await lockedOpenRun(tx, userId, syncId, currentTime())
        const ordinals = songs.map((value) => value.ordinal)
        const catalogIds = songs.map((value) => value.appleCatalogId)
        const libraryIds = songs.flatMap((value) => value.appleLibraryId == null ? [] : [value.appleLibraryId])
        const existing = await tx.select().from(librarySyncSongs).where(and(
          eq(librarySyncSongs.syncId, syncId),
          or(
            inArray(librarySyncSongs.ordinal, ordinals),
            inArray(librarySyncSongs.appleCatalogId, catalogIds),
            libraryIds.length > 0
              ? inArray(librarySyncSongs.appleLibraryId, libraryIds)
              : undefined,
          ),
        ))
        const byOrdinal = new Map(existing.map((row) => [row.ordinal, row]))
        const byCatalogId = new Map(existing.map((row) => [row.appleCatalogId, row]))
        const byLibraryId = new Map(existing.flatMap((row) =>
          row.appleLibraryId == null ? [] : [[row.appleLibraryId, row] as const]))
        const missing: LibrarySongSnapshot[] = []
        for (const value of songs) {
          const ordinalRow = byOrdinal.get(value.ordinal)
          const catalogRow = byCatalogId.get(value.appleCatalogId)
          const libraryRow = value.appleLibraryId == null
            ? undefined
            : byLibraryId.get(value.appleLibraryId)
          if (ordinalRow || catalogRow || libraryRow) {
            if (
              !ordinalRow
              || ordinalRow !== catalogRow
              || (value.appleLibraryId != null && ordinalRow !== libraryRow)
              || !sameSong(ordinalRow, value)
            ) throw new LibrarySyncError('conflict')
          } else {
            missing.push(value)
          }
        }
        if (run.receivedSongs + missing.length > run.expectedSongs) {
          throw new LibrarySyncError('count_mismatch')
        }
        if (missing.length > 0) {
          missing.sort((a, b) => a.appleCatalogId.localeCompare(b.appleCatalogId))
          await tx.insert(librarySyncSongs).values(missing.map((value) => ({
            syncId,
            ...value,
            lastPlayedAt: toDate(value.lastPlayedAt),
            dateAdded: toDate(value.dateAdded),
          })))
          await tx.update(librarySyncRuns)
            .set({ receivedSongs: run.receivedSongs + missing.length })
            .where(eq(librarySyncRuns.id, syncId))
        }
      })
    },

    async putRecentTracks(userId, syncId, catalogIds) {
      if (new Set(catalogIds).size !== catalogIds.length) {
        throw new LibrarySyncError('conflict')
      }
      await db.transaction(async (rawTx) => {
        const tx = rawTx as unknown as Db
        const run = await lockedOpenRun(tx, userId, syncId, currentTime())
        const ranks = catalogIds.map((_value, rank) => rank)
        const existing = await tx.select().from(librarySyncRecentTracks).where(and(
          eq(librarySyncRecentTracks.syncId, syncId),
          or(
            inArray(librarySyncRecentTracks.rank, ranks),
            inArray(librarySyncRecentTracks.appleCatalogId, catalogIds),
          ),
        ))
        const byRank = new Map(existing.map((row) => [row.rank, row]))
        const byCatalogId = new Map(existing.map((row) => [row.appleCatalogId, row]))
        const missing: Array<{ rank: number; appleCatalogId: string }> = []
        for (const [rank, appleCatalogId] of catalogIds.entries()) {
          const rankRow = byRank.get(rank)
          const catalogRow = byCatalogId.get(appleCatalogId)
          if (rankRow || catalogRow) {
            if (!rankRow || rankRow !== catalogRow || rankRow.appleCatalogId !== appleCatalogId) {
              throw new LibrarySyncError('conflict')
            }
          } else {
            missing.push({ rank, appleCatalogId })
          }
        }
        if (run.receivedRecentTracks + missing.length > run.expectedRecentTracks) {
          throw new LibrarySyncError('count_mismatch')
        }
        if (missing.length > 0) {
          await tx.insert(librarySyncRecentTracks).values(missing.map((value) => ({ syncId, ...value })))
          await tx.update(librarySyncRuns)
            .set({ receivedRecentTracks: run.receivedRecentTracks + missing.length })
            .where(eq(librarySyncRuns.id, syncId))
        }
      })
    },

    async complete(userId, syncId) {
      return db.transaction(async (rawTx) => {
        const tx = rawTx as unknown as Db
        const now = currentTime()
        const [profile] = await tx.select().from(userMusicProfiles)
          .where(eq(userMusicProfiles.userId, userId))
          .for('update')
        if (!profile) throw new LibrarySyncError('not_found')
        const [run] = await tx.select().from(librarySyncRuns)
          .where(and(eq(librarySyncRuns.id, syncId), eq(librarySyncRuns.userId, userId)))
          .for('update')
        if (!run) throw new LibrarySyncError('not_found')
        if (run.status === 'completed') return completedSummary(run)
        if (run.status !== 'open' || run.expiresAt.getTime() <= now.getTime()) {
          throw new LibrarySyncError('invalid_state')
        }
        if (
          run.receivedSongs !== run.expectedSongs
          || run.receivedRecentTracks !== run.expectedRecentTracks
        ) {
          throw new LibrarySyncError('count_mismatch')
        }

        const validation = normalizeRows(await tx.execute(sql`
          SELECT
            count(*)::int AS songs,
            count(play_count)::int AS play_counts_observed,
            count(*) = 0 OR (min(ordinal) = 0 AND max(ordinal) = count(*) - 1) AS ordinals_valid,
            (SELECT count(*)::int FROM library_sync_recent_tracks WHERE sync_id = ${syncId}) AS recent_tracks,
            NOT EXISTS (
              SELECT 1 FROM library_sync_recent_tracks
              WHERE sync_id = ${syncId}
              HAVING count(*) > 0 AND (min(rank) <> 0 OR max(rank) <> count(*) - 1)
            ) AS recent_ranks_valid
          FROM library_sync_songs
          WHERE sync_id = ${syncId}
        `))[0]
        if (
          Number(validation?.songs) !== run.expectedSongs
          || Number(validation?.recent_tracks) !== run.expectedRecentTracks
          || validation?.ordinals_valid !== true
          || validation?.recent_ranks_valid !== true
        ) throw new LibrarySyncError('count_mismatch')

        await tx.execute(sql`
          INSERT INTO tracks (
            apple_id, title, artist, album, genre, release_year, explicit, created_at
          )
          SELECT
            apple_catalog_id, title, artist, album, genre, release_year, explicit, ${now}
          FROM library_sync_songs
          WHERE sync_id = ${syncId}
          ORDER BY apple_catalog_id
          ON CONFLICT (apple_id) WHERE apple_id IS NOT NULL DO UPDATE SET
            title = excluded.title,
            artist = excluded.artist,
            album = coalesce(excluded.album, tracks.album),
            genre = coalesce(excluded.genre, tracks.genre),
            release_year = coalesce(excluded.release_year, tracks.release_year),
            explicit = coalesce(excluded.explicit, tracks.explicit)
        `)
        await tx.execute(sql`
          INSERT INTO user_tracks (
            user_id, track_id, play_count, play_count_observed, last_played_at,
            date_added, in_library, updated_at
          )
          SELECT
            ${userId}, t.id, coalesce(s.play_count, 0), s.play_count IS NOT NULL,
            s.last_played_at, s.date_added, true, ${now}
          FROM library_sync_songs s
          JOIN tracks t ON t.apple_id = s.apple_catalog_id
          WHERE s.sync_id = ${syncId}
          ORDER BY s.apple_catalog_id
          ON CONFLICT (user_id, track_id) DO UPDATE SET
            play_count = CASE
              WHEN excluded.play_count_observed
                THEN greatest(user_tracks.play_count, excluded.play_count)
              ELSE user_tracks.play_count
            END,
            play_count_observed = user_tracks.play_count_observed OR excluded.play_count_observed,
            last_played_at = greatest(user_tracks.last_played_at, excluded.last_played_at),
            date_added = coalesce(user_tracks.date_added, excluded.date_added),
            in_library = true,
            updated_at = excluded.updated_at
        `)
        await tx.execute(sql`
          UPDATE user_tracks ut
          SET in_library = false, updated_at = ${now}
          WHERE ut.user_id = ${userId}
            AND ut.in_library = true
            AND NOT EXISTS (
              SELECT 1
              FROM library_sync_songs s
              JOIN tracks t ON t.apple_id = s.apple_catalog_id
              WHERE s.sync_id = ${syncId} AND t.id = ut.track_id
            )
        `)

        let recentTracks = 0
        if (run.source === 'web_musickit') {
          await tx.delete(userRecentTrackObservations).where(and(
            eq(userRecentTrackObservations.userId, userId),
            eq(userRecentTrackObservations.source, 'web_musickit'),
          ))
          recentTracks = normalizeRows(await tx.execute(sql`
            INSERT INTO user_recent_track_observations (
              user_id, source, track_id, rank, observed_at
            )
            SELECT
              ${userId}, 'web_musickit', t.id, r.rank, ${now}
            FROM library_sync_recent_tracks r
            JOIN tracks t ON t.apple_id = r.apple_catalog_id
            WHERE r.sync_id = ${syncId}
            ORDER BY r.rank
            RETURNING track_id
          `)).length
        }

        const playCountsObserved = Number(validation?.play_counts_observed ?? 0)
        const summary: LibrarySyncSummary = {
          songs: run.expectedSongs,
          catalogResolved: run.expectedSongs,
          playCountsObserved,
          recentTracks,
        }
        await tx.update(userMusicProfiles)
          .set({ appleStorefront: run.appleStorefront, librarySyncedAt: now, updatedAt: now })
          .where(eq(userMusicProfiles.userId, userId))
        await deps.beforeCommit?.()
        await tx.update(librarySyncRuns).set({
          status: 'completed',
          receivedSongs: run.expectedSongs,
          resultSongs: summary.songs,
          resultCatalogResolved: summary.catalogResolved,
          resultPlayCountsObserved: summary.playCountsObserved,
          resultRecentTracks: summary.recentTracks,
          completedAt: now,
        }).where(eq(librarySyncRuns.id, syncId))
        return summary
      })
    },
  }
}
