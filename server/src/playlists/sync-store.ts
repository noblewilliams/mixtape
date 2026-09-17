import { and, eq, inArray, or, sql } from 'drizzle-orm'
import { playlistReviewFingerprint } from '../listening/collection-review'
import type { Db } from '../db/types'
import {
  playlistSyncEntries,
  playlistSyncPlaylists,
  playlistSyncRuns,
  userMusicProfiles,
  userPlaylists,
} from '../db/schema'
import type {
  PlaylistReview,
  PlaylistEntrySnapshot,
  PlaylistSnapshot,
  PlaylistSyncSource,
} from './contracts'

export type PlaylistSyncErrorCategory =
  | 'not_found'
  | 'conflict'
  | 'invalid_state'
  | 'count_mismatch'
  | 'invalid_storefront'
  | 'internal'

export class PlaylistSyncError extends Error {
  constructor(readonly category: PlaylistSyncErrorCategory) {
    super(`playlist-sync:${category}`)
    this.name = 'PlaylistSyncError'
  }
}

export type PlaylistSyncSummary = {
  playlists: number
  entries: number
  resolvedEntries: number
  unresolvedEntries: number
}

export type PlaylistSyncStore = {
  begin(
    userId: string,
    storefront: string | null,
    expectedPlaylists: number,
    expectedEntries: number,
    source?: PlaylistSyncSource,
    review?: PlaylistReview,
  ): Promise<{ syncId: string; expiresAt: number }>
  putPlaylists(
    userId: string,
    syncId: string,
    playlists: PlaylistSnapshot[],
  ): Promise<void>
  putEntries(
    userId: string,
    syncId: string,
    playlistAppleId: string,
    entries: PlaylistEntrySnapshot[],
  ): Promise<void>
  complete(userId: string, syncId: string): Promise<PlaylistSyncSummary>
}

type StoreDeps = {
  now?: () => Date
  ttlMs?: number
  beforeCommit?: () => void | Promise<void>
}

const DEFAULT_TTL_MS = 60 * 60 * 1_000
const POSITION_REORDER_OFFSET = 100_001
const toDate = (value: number | null) =>
  value == null ? null : new Date(value)
// user_playlists.source: both MusicKit clients publish Apple playlists.
const playlistSourceFor = (source: PlaylistSyncSource) =>
  source === 'spotify_export' ? 'spotify_export' : 'apple'

function normalizeRows(value: unknown): Record<string, unknown>[] {
  if (Array.isArray(value)) return value as Record<string, unknown>[]
  if (value && typeof value === 'object' && 'rows' in value) {
    const rows = (value as { rows?: unknown }).rows
    return Array.isArray(rows) ? (rows as Record<string, unknown>[]) : []
  }
  return []
}

function sameDate(value: Date | null, millis: number | null) {
  return (
    value?.getTime() === (millis == null ? undefined : millis) ||
    (value == null && millis == null)
  )
}

function samePlaylist(
  row: typeof playlistSyncPlaylists.$inferSelect,
  value: PlaylistSnapshot,
) {
  return (
    row.ordinal === value.ordinal &&
    row.appleLibraryId === value.appleLibraryId &&
    row.appleCatalogId === value.appleCatalogId &&
    row.name === value.name &&
    row.description === value.description &&
    row.curatorName === value.curatorName &&
    row.artworkUrlTemplate === value.artworkUrlTemplate &&
    row.artworkWidth === value.artworkWidth &&
    row.artworkHeight === value.artworkHeight &&
    row.artworkBgColor === value.artworkBgColor &&
    row.kind === value.kind &&
    row.canEdit === value.canEdit &&
    sameDate(row.appleDateAdded, value.appleDateAdded) &&
    sameDate(row.appleLastModifiedAt, value.appleLastModifiedAt) &&
    row.sourceFingerprint === value.sourceFingerprint &&
    row.entryCount === value.entryCount
  )
}

// A retry may bypass a stale review only when every field it would write
// already matches. A metadata-only edit must remain protected too.
function sameImportedPlaylist(
  row: typeof userPlaylists.$inferSelect,
  value: typeof playlistSyncPlaylists.$inferSelect,
) {
  const fields = [
    'appleCatalogId',
    'name',
    'description',
    'curatorName',
    'artworkUrlTemplate',
    'artworkWidth',
    'artworkHeight',
    'artworkBgColor',
    'kind',
    'canEdit',
    'sourceFingerprint',
  ] as const
  return (
    fields.every((key) => row[key] === value[key]) &&
    sameDate(row.appleDateAdded, value.appleDateAdded?.getTime() ?? null) &&
    sameDate(
      row.appleLastModifiedAt,
      value.appleLastModifiedAt?.getTime() ?? null,
    )
  )
}

function sameEntry(
  row: typeof playlistSyncEntries.$inferSelect,
  value: PlaylistEntrySnapshot,
) {
  return (
    row.position === value.position &&
    row.appleLibraryEntryId === value.appleLibraryEntryId &&
    row.appleLibraryTrackId === value.appleLibraryTrackId &&
    row.appleCatalogId === value.appleCatalogId &&
    row.spotifyId === value.spotifyId &&
    row.isrcSnapshot === value.isrcSnapshot &&
    row.titleSnapshot === value.titleSnapshot &&
    row.artistSnapshot === value.artistSnapshot &&
    row.albumSnapshot === value.albumSnapshot &&
    row.durationMsSnapshot === value.durationMsSnapshot &&
    row.artworkUrlTemplateSnapshot === value.artworkUrlTemplateSnapshot &&
    row.artworkWidthSnapshot === value.artworkWidthSnapshot &&
    row.artworkHeightSnapshot === value.artworkHeightSnapshot &&
    row.artworkBgColorSnapshot === value.artworkBgColorSnapshot
  )
}

function completedSummary(
  run: typeof playlistSyncRuns.$inferSelect,
): PlaylistSyncSummary {
  if (
    run.resultPlaylists == null ||
    run.resultEntries == null ||
    run.resultResolvedEntries == null ||
    run.resultUnresolvedEntries == null
  )
    throw new PlaylistSyncError('internal')
  return {
    playlists: run.resultPlaylists,
    entries: run.resultEntries,
    resolvedEntries: run.resultResolvedEntries,
    unresolvedEntries: run.resultUnresolvedEntries,
  }
}

function assertUniquePlaylists(values: PlaylistSnapshot[]) {
  const ids = new Set<string>()
  const ordinals = new Set<number>()
  for (const value of values) {
    if (ids.has(value.appleLibraryId) || ordinals.has(value.ordinal)) {
      throw new PlaylistSyncError('conflict')
    }
    ids.add(value.appleLibraryId)
    ordinals.add(value.ordinal)
  }
}

function assertUniqueEntries(values: PlaylistEntrySnapshot[]) {
  const positions = new Set<number>()
  const ids = new Set<string>()
  for (const value of values) {
    if (positions.has(value.position) || ids.has(value.appleLibraryEntryId)) {
      throw new PlaylistSyncError('conflict')
    }
    positions.add(value.position)
    ids.add(value.appleLibraryEntryId)
  }
}

export function createPlaylistSyncStore(
  db: Db,
  deps: StoreDeps = {},
): PlaylistSyncStore {
  const currentTime = () => deps.now?.() ?? new Date()
  const ttlMs = deps.ttlMs ?? DEFAULT_TTL_MS

  async function lockedOpenRun(
    tx: Db,
    userId: string,
    syncId: string,
    now: Date,
  ) {
    const [run] = await tx
      .select()
      .from(playlistSyncRuns)
      .where(
        and(
          eq(playlistSyncRuns.id, syncId),
          eq(playlistSyncRuns.userId, userId),
        ),
      )
      .for('update')
    if (!run) throw new PlaylistSyncError('not_found')
    if (run.status !== 'open' || run.expiresAt.getTime() <= now.getTime()) {
      throw new PlaylistSyncError('invalid_state')
    }
    return run
  }

  return {
    async begin(
      userId,
      storefront,
      expectedPlaylists,
      expectedEntries,
      source = 'ios_native',
      review,
    ) {
      if (
        review &&
        (source !== 'spotify_export' ||
          review.length !== expectedPlaylists ||
          new Set(review.map((r) => r.key)).size !== review.length)
      )
        throw new PlaylistSyncError('conflict')
      if (storefront == null && source !== 'spotify_export') {
        throw new PlaylistSyncError('invalid_storefront')
      }
      return db.transaction(async (rawTx) => {
        const tx = rawTx as unknown as Db
        const now = currentTime()
        const expiresAt = new Date(now.getTime() + ttlMs)
        await tx
          .insert(userMusicProfiles)
          .values({
            userId,
            appleStorefront: storefront,
            createdAt: now,
            updatedAt: now,
          })
          .onConflictDoNothing()
        const [profile] = await tx
          .select()
          .from(userMusicProfiles)
          .where(eq(userMusicProfiles.userId, userId))
          .for('update')
        if (!profile) throw new PlaylistSyncError('not_found')
        if (storefront != null) {
          await tx
            .update(userMusicProfiles)
            .set({ appleStorefront: storefront, updatedAt: now })
            .where(eq(userMusicProfiles.userId, userId))
        }
        await tx
          .update(playlistSyncRuns)
          .set({ status: 'expired' })
          .where(
            and(
              eq(playlistSyncRuns.userId, userId),
              eq(playlistSyncRuns.status, 'open'),
            ),
          )
        const [run] = await tx
          .insert(playlistSyncRuns)
          .values({
            userId,
            source,
            status: 'open',
            appleStorefront: storefront,
            review: review ?? null,
            expectedPlaylists,
            expectedEntries,
            startedAt: now,
            expiresAt,
          })
          .returning({ id: playlistSyncRuns.id })
        if (!run) throw new PlaylistSyncError('internal')
        return { syncId: run.id, expiresAt: expiresAt.getTime() }
      })
    },

    async putPlaylists(userId, syncId, playlists) {
      assertUniquePlaylists(playlists)
      await db.transaction(async (rawTx) => {
        const tx = rawTx as unknown as Db
        const run = await lockedOpenRun(tx, userId, syncId, currentTime())
        const ids = playlists.map((value) => value.appleLibraryId)
        const ordinals = playlists.map((value) => value.ordinal)
        const existing = await tx
          .select()
          .from(playlistSyncPlaylists)
          .where(
            and(
              eq(playlistSyncPlaylists.syncId, syncId),
              or(
                inArray(playlistSyncPlaylists.appleLibraryId, ids),
                inArray(playlistSyncPlaylists.ordinal, ordinals),
              ),
            ),
          )
        const byId = new Map(existing.map((row) => [row.appleLibraryId, row]))
        const byOrdinal = new Map(existing.map((row) => [row.ordinal, row]))
        const missing: PlaylistSnapshot[] = []
        for (const value of playlists) {
          const row = byId.get(value.appleLibraryId)
          const ordinalRow = byOrdinal.get(value.ordinal)
          if (row || ordinalRow) {
            if (!row || row !== ordinalRow || !samePlaylist(row, value)) {
              throw new PlaylistSyncError('conflict')
            }
          } else {
            missing.push(value)
          }
        }
        if (run.receivedPlaylists + missing.length > run.expectedPlaylists) {
          throw new PlaylistSyncError('count_mismatch')
        }
        if (missing.length > 0) {
          missing.sort((a, b) =>
            a.appleLibraryId.localeCompare(b.appleLibraryId),
          )
          await tx.insert(playlistSyncPlaylists).values(
            missing.map((value) => ({
              syncId,
              ...value,
              appleDateAdded: toDate(value.appleDateAdded),
              appleLastModifiedAt: toDate(value.appleLastModifiedAt),
            })),
          )
          await tx
            .update(playlistSyncRuns)
            .set({ receivedPlaylists: run.receivedPlaylists + missing.length })
            .where(eq(playlistSyncRuns.id, syncId))
        }
      })
    },

    async putEntries(userId, syncId, playlistAppleId, entries) {
      assertUniqueEntries(entries)
      await db.transaction(async (rawTx) => {
        const tx = rawTx as unknown as Db
        const run = await lockedOpenRun(tx, userId, syncId, currentTime())
        const [playlist] = await tx
          .select({ id: playlistSyncPlaylists.appleLibraryId })
          .from(playlistSyncPlaylists)
          .where(
            and(
              eq(playlistSyncPlaylists.syncId, syncId),
              eq(playlistSyncPlaylists.appleLibraryId, playlistAppleId),
            ),
          )
        if (!playlist) throw new PlaylistSyncError('not_found')
        if (entries.length === 0) return
        const positions = entries.map((value) => value.position)
        const entryIds = entries.map((value) => value.appleLibraryEntryId)
        const existing = await tx
          .select()
          .from(playlistSyncEntries)
          .where(
            and(
              eq(playlistSyncEntries.syncId, syncId),
              eq(playlistSyncEntries.applePlaylistId, playlistAppleId),
              or(
                inArray(playlistSyncEntries.position, positions),
                inArray(playlistSyncEntries.appleLibraryEntryId, entryIds),
              ),
            ),
          )
        const byPosition = new Map(existing.map((row) => [row.position, row]))
        const byEntryId = new Map(
          existing.map((row) => [row.appleLibraryEntryId, row]),
        )
        const missing: PlaylistEntrySnapshot[] = []
        for (const value of entries) {
          const row = byPosition.get(value.position)
          const idRow = byEntryId.get(value.appleLibraryEntryId)
          if (row || idRow) {
            if (!row || row !== idRow || !sameEntry(row, value)) {
              throw new PlaylistSyncError('conflict')
            }
          } else {
            missing.push(value)
          }
        }
        if (run.receivedEntries + missing.length > run.expectedEntries) {
          throw new PlaylistSyncError('count_mismatch')
        }
        if (missing.length > 0) {
          missing.sort((a, b) => a.position - b.position)
          await tx.insert(playlistSyncEntries).values(
            missing.map((value) => ({
              syncId,
              applePlaylistId: playlistAppleId,
              ...value,
            })),
          )
          await tx
            .update(playlistSyncRuns)
            .set({ receivedEntries: run.receivedEntries + missing.length })
            .where(eq(playlistSyncRuns.id, syncId))
        }
      })
    },

    async complete(userId, syncId) {
      return db.transaction(async (rawTx) => {
        const tx = rawTx as unknown as Db
        const now = currentTime()
        const [profile] = await tx
          .select()
          .from(userMusicProfiles)
          .where(eq(userMusicProfiles.userId, userId))
          .for('update')
        if (!profile) throw new PlaylistSyncError('not_found')
        const [run] = await tx
          .select()
          .from(playlistSyncRuns)
          .where(
            and(
              eq(playlistSyncRuns.id, syncId),
              eq(playlistSyncRuns.userId, userId),
            ),
          )
          .for('update')
        if (!run) throw new PlaylistSyncError('not_found')
        if (run.status === 'completed') return completedSummary(run)
        if (run.status !== 'open' || run.expiresAt.getTime() <= now.getTime()) {
          throw new PlaylistSyncError('invalid_state')
        }
        if (
          run.receivedPlaylists !== run.expectedPlaylists ||
          run.receivedEntries !== run.expectedEntries
        )
          throw new PlaylistSyncError('count_mismatch')

        const validationResult = await tx.execute(sql`
          SELECT
            (SELECT count(*)::int FROM playlist_sync_playlists WHERE sync_id = ${syncId}) AS playlists,
            (SELECT count(*)::int FROM playlist_sync_entries WHERE sync_id = ${syncId}) AS entries,
            (SELECT count(*)::int FROM playlist_sync_playlists WHERE sync_id = ${syncId}) = 0
              OR (SELECT min(ordinal) = 0 AND max(ordinal) = count(*) - 1
                  FROM playlist_sync_playlists WHERE sync_id = ${syncId}) AS ordinals_valid,
            NOT EXISTS (
              SELECT 1
              FROM playlist_sync_playlists sp
              LEFT JOIN playlist_sync_entries se
                ON se.sync_id = sp.sync_id AND se.apple_playlist_id = sp.apple_library_id
              WHERE sp.sync_id = ${syncId}
              GROUP BY sp.apple_library_id, sp.entry_count
              HAVING count(se.position) <> sp.entry_count
                OR (sp.entry_count > 0 AND (min(se.position) <> 0 OR max(se.position) <> sp.entry_count - 1))
                OR count(DISTINCT se.apple_library_entry_id) <> count(se.apple_library_entry_id)
            ) AS entries_valid
        `)
        const validation = normalizeRows(validationResult)[0]
        if (
          Number(validation?.playlists) !== run.expectedPlaylists ||
          Number(validation?.entries) !== run.expectedEntries ||
          validation?.ordinals_valid !== true ||
          validation?.entries_valid !== true
        )
          throw new PlaylistSyncError('count_mismatch')

        const playlistSource = playlistSourceFor(run.source)
        const staged = await tx
          .select()
          .from(playlistSyncPlaylists)
          .where(eq(playlistSyncPlaylists.syncId, syncId))
        const current = await tx
          .select()
          .from(userPlaylists)
          .where(eq(userPlaylists.userId, userId))
        if (
          !run.review &&
          playlistSource === 'spotify_export' &&
          current.some((p) => p.importFileHash !== null)
        )
          throw new PlaylistSyncError('conflict')
        for (const value of staged) {
          const existing = current.find(
            (p) => p.appleLibraryId === value.appleLibraryId,
          )
          if (existing && existing.source !== playlistSource)
            throw new PlaylistSyncError('conflict')
          if (run.review) {
            const reviewed = run.review.find(
              (r) => r.key === value.appleLibraryId,
            )
            if (!reviewed) throw new PlaylistSyncError('conflict')
            if (reviewed.baseFingerprint === null) {
              // The same reviewed creation can be retried after a lost response.
              if (
                existing &&
                !(
                  existing.inLibrary &&
                  existing.importFileHash === reviewed.fileHash &&
                  sameImportedPlaylist(existing, value)
                )
              )
                throw new PlaylistSyncError('conflict')
            } else if (
              !existing ||
              !existing.inLibrary ||
              (await playlistReviewFingerprint(existing)) !==
                reviewed.baseFingerprint
            ) {
              // Exact repeat of an already-published intent is a no-op only if all imported content agrees.
              if (
                !existing ||
                !existing.inLibrary ||
                existing.importFileHash !== reviewed.fileHash ||
                !sameImportedPlaylist(existing, value)
              )
                throw new PlaylistSyncError('conflict')
            }
          } else if (
            playlistSource === 'spotify_export' &&
            current.some((p) => p.importFileHash !== null)
          ) {
            throw new PlaylistSyncError('conflict')
          }
        }
        await tx.execute(sql`
          INSERT INTO user_playlists (
            user_id, apple_library_id, apple_catalog_id, name, description, curator_name,
            artwork_url_template, artwork_width, artwork_height, artwork_bg_color, kind,
            can_edit, apple_date_added, apple_last_modified_at, source_fingerprint,
            source, in_library, created_at, updated_at
          )
          SELECT
            ${userId}, apple_library_id, apple_catalog_id, name, description, curator_name,
            artwork_url_template, artwork_width, artwork_height, artwork_bg_color, kind,
            can_edit, apple_date_added, apple_last_modified_at, source_fingerprint,
            ${playlistSource}, true, ${now}, ${now}
          FROM playlist_sync_playlists
          WHERE sync_id = ${syncId}
          ORDER BY apple_library_id
          ON CONFLICT (user_id, apple_library_id) DO UPDATE SET
            apple_catalog_id = excluded.apple_catalog_id,
            name = excluded.name,
            description = excluded.description,
            curator_name = excluded.curator_name,
            artwork_url_template = excluded.artwork_url_template,
            artwork_width = excluded.artwork_width,
            artwork_height = excluded.artwork_height,
            artwork_bg_color = excluded.artwork_bg_color,
            kind = excluded.kind,
            can_edit = excluded.can_edit,
            apple_date_added = excluded.apple_date_added,
            apple_last_modified_at = excluded.apple_last_modified_at,
            source_fingerprint = excluded.source_fingerprint,
            source = excluded.source,
            in_library = true,
            updated_at = excluded.updated_at
        `)
        if (!run.review)
          await tx.execute(sql`
          UPDATE user_playlists up
          SET in_library = false, updated_at = ${now}
          WHERE up.user_id = ${userId}
            AND up.source = ${playlistSource}
            AND up.in_library = true
            AND NOT EXISTS (
              SELECT 1 FROM playlist_sync_playlists sp
              WHERE sp.sync_id = ${syncId} AND sp.apple_library_id = up.apple_library_id
            )
        `)
        if (run.review)
          for (const reviewed of run.review) {
            await tx
              .update(userPlaylists)
              .set({ importFileHash: reviewed.fileHash })
              .where(
                and(
                  eq(userPlaylists.userId, userId),
                  eq(userPlaylists.appleLibraryId, reviewed.key),
                ),
              )
          }
        // Move current positions into a disjoint range so rows can be reordered
        // without transiently colliding with the canonical position constraint.
        await tx.execute(sql`
          UPDATE playlist_entries pe
          SET position = pe.position + ${POSITION_REORDER_OFFSET}, updated_at = ${now}
          FROM user_playlists up
          WHERE pe.playlist_id = up.id
            AND up.user_id = ${userId}
            AND EXISTS (
              SELECT 1 FROM playlist_sync_playlists sp
              WHERE sp.sync_id = ${syncId} AND sp.apple_library_id = up.apple_library_id
            )
        `)
        await tx.execute(sql`
          UPDATE playlist_entries pe
          SET
            position = se.position,
            track_id = coalesce(catalog_track.id, spotify_track.id, unique_isrc.id),
            apple_library_track_id = se.apple_library_track_id,
            apple_catalog_id = se.apple_catalog_id,
            spotify_id = se.spotify_id,
            isrc_snapshot = se.isrc_snapshot,
            title_snapshot = se.title_snapshot,
            artist_snapshot = se.artist_snapshot,
            album_snapshot = se.album_snapshot,
            duration_ms_snapshot = se.duration_ms_snapshot,
            artwork_url_template_snapshot = se.artwork_url_template_snapshot,
            artwork_width_snapshot = se.artwork_width_snapshot,
            artwork_height_snapshot = se.artwork_height_snapshot,
            artwork_bg_color_snapshot = se.artwork_bg_color_snapshot,
            updated_at = ${now}
          FROM playlist_sync_entries se
          JOIN user_playlists up
            ON up.user_id = ${userId} AND up.apple_library_id = se.apple_playlist_id
          LEFT JOIN tracks catalog_track ON catalog_track.apple_id = se.apple_catalog_id
          LEFT JOIN tracks spotify_track
            ON catalog_track.id IS NULL AND spotify_track.spotify_id = se.spotify_id
          LEFT JOIN (
            SELECT isrc, min(id::text)::uuid AS id
            FROM tracks
            WHERE isrc IS NOT NULL
            GROUP BY isrc
            HAVING count(*) = 1
          ) unique_isrc
            ON catalog_track.id IS NULL
            AND spotify_track.id IS NULL
            AND unique_isrc.isrc = se.isrc_snapshot
          WHERE se.sync_id = ${syncId}
            AND pe.playlist_id = up.id
            AND pe.apple_library_entry_id = se.apple_library_entry_id
        `)
        await tx.execute(sql`
          INSERT INTO playlist_entries (
            playlist_id, position, track_id, apple_library_entry_id, apple_library_track_id,
            apple_catalog_id, spotify_id, isrc_snapshot, title_snapshot, artist_snapshot,
            album_snapshot, duration_ms_snapshot, artwork_url_template_snapshot,
            artwork_width_snapshot, artwork_height_snapshot, artwork_bg_color_snapshot,
            created_at, updated_at
          )
          SELECT
            up.id,
            se.position,
            coalesce(catalog_track.id, spotify_track.id, unique_isrc.id),
            se.apple_library_entry_id,
            se.apple_library_track_id,
            se.apple_catalog_id,
            se.spotify_id,
            se.isrc_snapshot,
            se.title_snapshot,
            se.artist_snapshot,
            se.album_snapshot,
            se.duration_ms_snapshot,
            se.artwork_url_template_snapshot,
            se.artwork_width_snapshot,
            se.artwork_height_snapshot,
            se.artwork_bg_color_snapshot,
            ${now},
            ${now}
          FROM playlist_sync_entries se
          JOIN user_playlists up
            ON up.user_id = ${userId} AND up.apple_library_id = se.apple_playlist_id
          LEFT JOIN tracks catalog_track ON catalog_track.apple_id = se.apple_catalog_id
          LEFT JOIN tracks spotify_track
            ON catalog_track.id IS NULL AND spotify_track.spotify_id = se.spotify_id
          LEFT JOIN (
            SELECT isrc, min(id::text)::uuid AS id
            FROM tracks
            WHERE isrc IS NOT NULL
            GROUP BY isrc
            HAVING count(*) = 1
          ) unique_isrc
            ON catalog_track.id IS NULL
            AND spotify_track.id IS NULL
            AND unique_isrc.isrc = se.isrc_snapshot
          WHERE se.sync_id = ${syncId}
            AND NOT EXISTS (
              SELECT 1 FROM playlist_entries pe
              WHERE pe.playlist_id = up.id
                AND pe.apple_library_entry_id = se.apple_library_entry_id
            )
          ORDER BY se.apple_playlist_id, se.position
        `)
        await tx.execute(sql`
          DELETE FROM playlist_entries pe
          USING user_playlists up
          WHERE pe.playlist_id = up.id
            AND up.user_id = ${userId}
            AND EXISTS (
              SELECT 1 FROM playlist_sync_playlists sp
              WHERE sp.sync_id = ${syncId} AND sp.apple_library_id = up.apple_library_id
            )
            AND NOT EXISTS (
              SELECT 1 FROM playlist_sync_entries se
              WHERE se.sync_id = ${syncId}
                AND se.apple_playlist_id = up.apple_library_id
                AND se.apple_library_entry_id = pe.apple_library_entry_id
            )
        `)
        const result = normalizeRows(
          await tx.execute(sql`
          SELECT count(*)::int AS entries,
            count(track_id)::int AS resolved
          FROM playlist_entries pe
          JOIN user_playlists up ON up.id = pe.playlist_id
          WHERE up.user_id = ${userId}
            AND EXISTS (
              SELECT 1 FROM playlist_sync_playlists sp
              WHERE sp.sync_id = ${syncId} AND sp.apple_library_id = up.apple_library_id
            )
        `),
        )[0]
        const entries = Number(result?.entries ?? 0)
        const resolvedEntries = Number(result?.resolved ?? 0)
        const summary: PlaylistSyncSummary = {
          playlists: run.expectedPlaylists,
          entries,
          resolvedEntries,
          unresolvedEntries: entries - resolvedEntries,
        }
        await tx
          .update(userMusicProfiles)
          .set({
            // A Spotify run carries no storefront and must not clear the profile's.
            ...(run.appleStorefront == null
              ? {}
              : { appleStorefront: run.appleStorefront }),
            playlistsSyncedAt: now,
            updatedAt: now,
          })
          .where(eq(userMusicProfiles.userId, userId))
        await deps.beforeCommit?.()
        await tx
          .update(playlistSyncRuns)
          .set({
            status: 'completed',
            receivedPlaylists: run.expectedPlaylists,
            receivedEntries: run.expectedEntries,
            resultPlaylists: summary.playlists,
            resultEntries: summary.entries,
            resultResolvedEntries: summary.resolvedEntries,
            resultUnresolvedEntries: summary.unresolvedEntries,
            completedAt: now,
          })
          .where(eq(playlistSyncRuns.id, syncId))
        return summary
      })
    },
  }
}
