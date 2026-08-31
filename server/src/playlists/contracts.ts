import { z } from 'zod'
import { isAppleSongId } from '../musickit/apple-id'

export const PLAYLIST_SYNC_MAX_PLAYLISTS = 2_000
export const PLAYLIST_SYNC_MAX_ENTRIES = 100_000
export const PLAYLIST_CHUNK_MAX = 50
export const PLAYLIST_ENTRY_CHUNK_MAX = 200

const opaqueLibraryId = z.string().min(1).max(512).refine((value) => !value.includes('\0'))
const textSnapshot = (max: number) =>
  z.string().min(1).max(max).refine((value) => !value.includes('\0'))
const nullableTextSnapshot = (max: number) =>
  z.string().max(max).refine((value) => !value.includes('\0')).nullable()
const nullableAppleId = z.string().refine(isAppleSongId).nullable()
const postgresInteger = z.number().int().max(2_147_483_647)
const nullableTimestamp = z.number().int().min(0).max(8_640_000_000_000_000).nullable()
const nullablePositiveInteger = postgresInteger.positive().nullable()
const nullableNonnegativeInteger = postgresInteger.nonnegative().nullable()
const nullableArtworkColor = z.string().regex(/^[0-9a-f]{6}$/).nullable()

export const beginPlaylistSyncSchema = z.object({
  storefront: z.string().regex(/^[a-z]{2}$/),
  expectedPlaylists: z.number().int().min(0).max(PLAYLIST_SYNC_MAX_PLAYLISTS),
  expectedEntries: z.number().int().min(0).max(PLAYLIST_SYNC_MAX_ENTRIES),
}).strict()

export const playlistSnapshotSchema = z.object({
  ordinal: z.number().int().min(0).max(PLAYLIST_SYNC_MAX_PLAYLISTS - 1),
  appleLibraryId: opaqueLibraryId,
  appleCatalogId: nullableAppleId,
  name: textSnapshot(500),
  description: nullableTextSnapshot(10_000),
  curatorName: nullableTextSnapshot(500),
  artworkUrlTemplate: nullableTextSnapshot(4_096),
  artworkWidth: nullablePositiveInteger,
  artworkHeight: nullablePositiveInteger,
  artworkBgColor: nullableArtworkColor,
  kind: z.enum([
    'user',
    'editorial',
    'external',
    'personal_mix',
    'replay',
    'user_shared',
    'unknown',
  ]),
  canEdit: z.boolean(),
  appleDateAdded: nullableTimestamp,
  appleLastModifiedAt: nullableTimestamp,
  sourceFingerprint: z.string().regex(/^[0-9a-f]{64}$/),
  entryCount: z.number().int().nonnegative().max(PLAYLIST_SYNC_MAX_ENTRIES),
}).strict()

export const playlistEntrySnapshotSchema = z.object({
  position: z.number().int().min(0).max(PLAYLIST_SYNC_MAX_ENTRIES - 1),
  appleLibraryEntryId: opaqueLibraryId,
  appleLibraryTrackId: opaqueLibraryId.nullable(),
  appleCatalogId: nullableAppleId,
  isrcSnapshot: z.string().regex(/^[A-Z]{2}[A-Z0-9]{3}\d{7}$/).nullable(),
  titleSnapshot: textSnapshot(1_000),
  artistSnapshot: textSnapshot(1_000),
  albumSnapshot: nullableTextSnapshot(1_000),
  durationMsSnapshot: nullableNonnegativeInteger,
  artworkUrlTemplateSnapshot: nullableTextSnapshot(4_096),
  artworkWidthSnapshot: nullablePositiveInteger,
  artworkHeightSnapshot: nullablePositiveInteger,
  artworkBgColorSnapshot: nullableArtworkColor,
}).strict()

export const playlistChunkSchema = z.object({
  playlists: z.array(playlistSnapshotSchema).min(1).max(PLAYLIST_CHUNK_MAX),
}).strict()

export const playlistEntryChunkSchema = z.object({
  playlistAppleId: opaqueLibraryId,
  entries: z.array(playlistEntrySnapshotSchema).max(PLAYLIST_ENTRY_CHUNK_MAX),
}).strict()

export type BeginPlaylistSync = z.infer<typeof beginPlaylistSyncSchema>
export type PlaylistSnapshot = z.infer<typeof playlistSnapshotSchema>
export type PlaylistEntrySnapshot = z.infer<typeof playlistEntrySnapshotSchema>
