import { and, asc, eq, inArray, sql } from 'drizzle-orm'
import type { Db } from '../db/types'
import {
  playlistEditDraftEntries,
  playlistEditDraftEvents,
  playlistEditDrafts,
  playlistEntries,
  tracks,
  userPlaylists,
} from '../db/schema'
import {
  DraftOperationError,
  applyDraftOperations,
  diffDraft,
  type DraftEntry,
  type DraftDiff,
  type ResolvedDraftOperation,
} from './domain'

const resumableStatuses = ['active', 'preparing', 'ready', 'applying', 'conflicted'] as const
const ENTRY_INSERT_BATCH = 250

export type DraftOperationInput =
  | { type: 'add'; trackId: string; afterEntryKey?: string; beforeEntryKey?: string }
  | { type: 'remove'; entryKey: string }
  | { type: 'move'; entryKey: string; afterEntryKey?: string; beforeEntryKey?: string }
  | { type: 'replace'; entryKey: string; trackId: string }

export type PlaylistEditDraftView = {
  draft: {
    id: string
    sourcePlaylistId: string
    status: string
    version: number
    baseSourceFingerprint: string
    baseName: string
    sourceType: 'apple' | 'spotify_export'
    createdAt: Date
    updatedAt: Date
  }
  entries: Array<DraftEntry & { position: number; resolved: boolean }>
  diff: DraftDiff
  capability: {
    possibleModes: ['revised_copy']
    sourceWillRemainUntouched: true
    applyAvailable: false
  }
}

type DraftMutationResult =
  | { kind: 'ok'; view: PlaylistEditDraftView }
  | { kind: 'not_found' }
  | { kind: 'version_conflict' }
  | { kind: 'terminal' }
  | { kind: 'invalid_track' }
  | { kind: 'invalid_operation' }

function rowToEntry(row: typeof playlistEditDraftEntries.$inferSelect): DraftEntry {
  return {
    entryKey: row.entryKey,
    origin: row.origin,
    sourceEntryId: row.sourceEntryId,
    trackId: row.trackId,
    appleLibraryTrackId: row.appleLibraryTrackId,
    appleCatalogId: row.appleCatalogId,
    spotifyId: row.spotifyId,
    title: row.titleSnapshot,
    artist: row.artistSnapshot,
    album: row.albumSnapshot,
    durationMs: row.durationMsSnapshot,
    artworkUrlTemplate: row.artworkUrlTemplateSnapshot,
    artworkWidth: row.artworkWidthSnapshot,
    artworkHeight: row.artworkHeightSnapshot,
    artworkBgColor: row.artworkBgColorSnapshot,
  }
}

function entryInsert(
  draftId: string,
  role: 'base' | 'draft',
  position: number,
  entry: DraftEntry,
): typeof playlistEditDraftEntries.$inferInsert {
  return {
    draftId,
    role,
    position,
    entryKey: entry.entryKey,
    origin: entry.origin,
    sourceEntryId: entry.sourceEntryId,
    trackId: entry.trackId,
    appleLibraryTrackId: entry.appleLibraryTrackId,
    appleCatalogId: entry.appleCatalogId,
    spotifyId: entry.spotifyId,
    titleSnapshot: entry.title,
    artistSnapshot: entry.artist,
    albumSnapshot: entry.album,
    durationMsSnapshot: entry.durationMs,
    artworkUrlTemplateSnapshot: entry.artworkUrlTemplate,
    artworkWidthSnapshot: entry.artworkWidth,
    artworkHeightSnapshot: entry.artworkHeight,
    artworkBgColorSnapshot: entry.artworkBgColor,
  }
}

function trackEntry(
  track: typeof tracks.$inferSelect,
  entryKey = crypto.randomUUID(),
): DraftEntry {
  return {
    entryKey,
    origin: 'catalog_addition',
    sourceEntryId: null,
    trackId: track.id,
    appleLibraryTrackId: null,
    appleCatalogId: track.appleId,
    spotifyId: track.spotifyId,
    title: track.title,
    artist: track.artist,
    album: track.album,
    durationMs: track.durationMs,
    artworkUrlTemplate: track.artworkUrlTemplate,
    artworkWidth: track.artworkWidth,
    artworkHeight: track.artworkHeight,
    artworkBgColor: track.artworkBgColor,
  }
}

function draftView(
  draft: typeof playlistEditDrafts.$inferSelect,
  base: DraftEntry[],
  current: DraftEntry[],
): PlaylistEditDraftView {
  return {
    draft: {
      id: draft.id,
      sourcePlaylistId: draft.sourcePlaylistId,
      status: draft.status,
      version: draft.version,
      baseSourceFingerprint: draft.baseSourceFingerprint,
      baseName: draft.baseName,
      sourceType: draft.sourceType,
      createdAt: draft.createdAt,
      updatedAt: draft.updatedAt,
    },
    entries: current.map((entry, position) => ({
      ...entry,
      position,
      resolved: entry.trackId != null,
    })),
    diff: diffDraft(base, current),
    capability: {
      possibleModes: ['revised_copy'],
      sourceWillRemainUntouched: true,
      applyAvailable: false,
    },
  }
}

async function loadView(
  db: Db,
  userId: string,
  draftId: string,
): Promise<PlaylistEditDraftView | null> {
  const [draft] = await db.select().from(playlistEditDrafts).where(and(
    eq(playlistEditDrafts.id, draftId),
    eq(playlistEditDrafts.userId, userId),
  )).limit(1)
  if (!draft) return null
  const rows = await db.select().from(playlistEditDraftEntries).where(
    eq(playlistEditDraftEntries.draftId, draft.id),
  ).orderBy(asc(playlistEditDraftEntries.role), asc(playlistEditDraftEntries.position))
  const base = rows.filter((row) => row.role === 'base').map(rowToEntry)
  const current = rows.filter((row) => row.role === 'draft').map(rowToEntry)
  return draftView(draft, base, current)
}

function eventRows(
  draftId: string,
  version: number,
  before: DraftEntry[],
  after: DraftEntry[],
): Array<typeof playlistEditDraftEvents.$inferInsert> {
  const delta = diffDraft(before, after)
  const beforeByKey = new Map(before.map((entry) => [entry.entryKey, entry]))
  const afterByKey = new Map(after.map((entry) => [entry.entryKey, entry]))
  return [
    ...delta.added.map((item) => ({
      draftId, version, kind: 'add' as const, entryKey: item.entryKey,
      toPosition: item.toPosition, trackId: afterByKey.get(item.entryKey)?.trackId,
    })),
    ...delta.removed.map((item) => ({
      draftId, version, kind: 'remove' as const, entryKey: item.entryKey,
      fromPosition: item.fromPosition, trackId: beforeByKey.get(item.entryKey)?.trackId,
    })),
    ...delta.moved.map((item) => ({
      draftId, version, kind: 'move' as const, entryKey: item.entryKey,
      fromPosition: item.fromPosition, toPosition: item.toPosition,
      trackId: afterByKey.get(item.entryKey)?.trackId,
    })),
    ...delta.replaced.map((item) => ({
      draftId, version, kind: 'replace' as const, entryKey: item.entryKey,
      fromPosition: item.position, toPosition: item.position,
      trackId: afterByKey.get(item.entryKey)?.trackId,
    })),
  ]
}

export function createPlaylistEditDraftStore(db: Db) {
  return {
    async createOrResume(userId: string, sourcePlaylistId: string) {
      const result = await db.transaction(async (tx) => {
        const [existing] = await tx.select().from(playlistEditDrafts).where(and(
          eq(playlistEditDrafts.userId, userId),
          eq(playlistEditDrafts.sourcePlaylistId, sourcePlaylistId),
          inArray(playlistEditDrafts.status, resumableStatuses),
        )).limit(1)
        if (existing) return { kind: 'ok' as const, id: existing.id, created: false }

        const [source] = await tx.select({
          id: userPlaylists.id,
          name: userPlaylists.name,
          source: userPlaylists.source,
          sourceFingerprint: userPlaylists.sourceFingerprint,
        }).from(userPlaylists).where(and(
          eq(userPlaylists.id, sourcePlaylistId),
          eq(userPlaylists.userId, userId),
          eq(userPlaylists.inLibrary, true),
        )).limit(1).for('share')
        if (!source) return { kind: 'not_found' as const }

        const [created] = await tx.insert(playlistEditDrafts).values({
          userId,
          sourcePlaylistId: source.id,
          baseSourceFingerprint: source.sourceFingerprint,
          baseName: source.name,
          sourceType: source.source,
        }).onConflictDoNothing().returning({ id: playlistEditDrafts.id })
        if (!created) {
          const [winner] = await tx.select({ id: playlistEditDrafts.id })
            .from(playlistEditDrafts).where(and(
              eq(playlistEditDrafts.userId, userId),
              eq(playlistEditDrafts.sourcePlaylistId, sourcePlaylistId),
              inArray(playlistEditDrafts.status, resumableStatuses),
            )).limit(1)
          return winner
            ? { kind: 'ok' as const, id: winner.id, created: false }
            : { kind: 'not_found' as const }
        }

        // One SQL copy keeps a stable occurrence key across immutable base and
        // mutable draft roles without transferring a 10k-entry playlist through
        // the Worker or holding a provider call inside the transaction.
        await tx.execute(sql`
          WITH source AS MATERIALIZED (
            SELECT gen_random_uuid() AS entry_key, pe.*
            FROM playlist_entries pe
            WHERE pe.playlist_id = ${source.id}
            ORDER BY pe.position, pe.id
          )
          INSERT INTO playlist_edit_draft_entries (
            draft_id, role, entry_key, position, origin, source_entry_id,
            track_id, apple_library_track_id, apple_catalog_id, spotify_id,
            title_snapshot, artist_snapshot, album_snapshot,
            duration_ms_snapshot, artwork_url_template_snapshot,
            artwork_width_snapshot, artwork_height_snapshot,
            artwork_bg_color_snapshot
          )
          SELECT ${created.id}::uuid, roles.role, source.entry_key,
            source.position, 'source', source.id, source.track_id,
            source.apple_library_track_id, source.apple_catalog_id,
            source.spotify_id, source.title_snapshot, source.artist_snapshot,
            source.album_snapshot, source.duration_ms_snapshot,
            source.artwork_url_template_snapshot, source.artwork_width_snapshot,
            source.artwork_height_snapshot, source.artwork_bg_color_snapshot
          FROM source CROSS JOIN (VALUES ('base'), ('draft')) AS roles(role)
        `)
        return { kind: 'ok' as const, id: created.id, created: true }
      })
      if (result.kind === 'not_found') return result
      const view = await loadView(db, userId, result.id)
      if (!view) throw new Error('playlist-edit:create-missing')
      return { ...result, view }
    },

    get(userId: string, draftId: string) {
      return loadView(db, userId, draftId)
    },

    async mutate(
      userId: string,
      draftId: string,
      expectedVersion: number,
      operations: DraftOperationInput[],
    ): Promise<DraftMutationResult> {
      const result = await db.transaction(async (tx) => {
        const [draft] = await tx.select().from(playlistEditDrafts).where(and(
          eq(playlistEditDrafts.id, draftId),
          eq(playlistEditDrafts.userId, userId),
        )).limit(1).for('update')
        if (!draft) return { kind: 'not_found' as const }
        if (draft.status !== 'active') return { kind: 'terminal' as const }
        if (draft.version !== expectedVersion) return { kind: 'version_conflict' as const }

        const rows = await tx.select().from(playlistEditDraftEntries).where(
          eq(playlistEditDraftEntries.draftId, draft.id),
        ).orderBy(asc(playlistEditDraftEntries.role), asc(playlistEditDraftEntries.position))
        const base = rows.filter((row) => row.role === 'base').map(rowToEntry)
        const before = rows.filter((row) => row.role === 'draft').map(rowToEntry)
        const trackIds = [...new Set(operations.flatMap((operation) =>
          operation.type === 'add' || operation.type === 'replace' ? [operation.trackId] : []))]
        const catalogTracks = trackIds.length
          ? await tx.select().from(tracks).where(inArray(tracks.id, trackIds))
          : []
        const tracksById = new Map(catalogTracks.map((track) => [track.id, track]))
        if (
          catalogTracks.length !== trackIds.length
          || catalogTracks.some((track) => track.appleId == null && track.spotifyId == null)
        ) return { kind: 'invalid_track' as const }

        const resolved: ResolvedDraftOperation[] = operations.map((operation) => {
          if (operation.type === 'add') return {
            ...operation,
            entry: trackEntry(tracksById.get(operation.trackId)!),
          }
          if (operation.type === 'replace') return {
            type: 'replace',
            entryKey: operation.entryKey,
            entry: trackEntry(tracksById.get(operation.trackId)!),
          }
          return operation
        })
        let after: DraftEntry[]
        try {
          after = applyDraftOperations(before, resolved)
        } catch (error) {
          if (error instanceof DraftOperationError) return { kind: 'invalid_operation' as const }
          throw error
        }
        const nextVersion = draft.version + 1
        const events = eventRows(draft.id, nextVersion, before, after)
        if (!events.length) return { kind: 'ok' as const, view: draftView(draft, base, before) }

        await tx.delete(playlistEditDraftEntries).where(and(
          eq(playlistEditDraftEntries.draftId, draft.id),
          eq(playlistEditDraftEntries.role, 'draft'),
        ))
        const inserts = after.map((entry, position) =>
          entryInsert(draft.id, 'draft', position, entry))
        for (let offset = 0; offset < inserts.length; offset += ENTRY_INSERT_BATCH) {
          await tx.insert(playlistEditDraftEntries)
            .values(inserts.slice(offset, offset + ENTRY_INSERT_BATCH))
        }
        await tx.insert(playlistEditDraftEvents).values(events)
        const updatedAt = new Date()
        await tx.update(playlistEditDrafts).set({
          version: nextVersion,
          updatedAt,
        }).where(eq(playlistEditDrafts.id, draft.id))
        return {
          kind: 'ok' as const,
          view: draftView({ ...draft, version: nextVersion, updatedAt }, base, after),
        }
      })
      return result
    },

    async abandon(userId: string, draftId: string) {
      return db.transaction(async (tx) => {
        const [draft] = await tx.select({ status: playlistEditDrafts.status })
          .from(playlistEditDrafts).where(and(
            eq(playlistEditDrafts.id, draftId),
            eq(playlistEditDrafts.userId, userId),
          )).limit(1).for('update')
        if (!draft) return 'not_found' as const
        if (draft.status === 'abandoned') return 'ok' as const
        if (!resumableStatuses.includes(draft.status as typeof resumableStatuses[number])) {
          return 'terminal' as const
        }
        await tx.update(playlistEditDrafts).set({
          status: 'abandoned',
          updatedAt: new Date(),
        }).where(and(
          eq(playlistEditDrafts.id, draftId),
          eq(playlistEditDrafts.userId, userId),
        ))
        return 'ok' as const
      })
    },
  }
}
