import { z } from 'zod'
import {
  MAX_ARTWORK_URL_LENGTH,
  parseNullableArtworkMetadata,
} from '../artwork/normalize'
import { SPOTIFY_ID_PATTERN } from '../listening/contracts'
import { isAppleSongId } from '../musickit/apple-id'

export const PLAYLIST_SYNC_MAX_PLAYLISTS = 2_000
export const PLAYLIST_SYNC_MAX_ENTRIES = 100_000
export const PLAYLIST_CHUNK_MAX = 50
export const PLAYLIST_ENTRY_CHUNK_MAX = 200

function hasValidUnicodeScalars(value: string) {
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index)
    if (code >= 0xd800 && code <= 0xdbff) {
      if (index + 1 >= value.length) return false
      const next = value.charCodeAt(index + 1)
      if (next < 0xdc00 || next > 0xdfff) return false
      index += 1
    } else if (code >= 0xdc00 && code <= 0xdfff) {
      return false
    }
  }
  return true
}

const safeString = (schema: z.ZodString) => schema.refine(
  (value) => !value.includes('\0') && hasValidUnicodeScalars(value),
)
const opaqueLibraryId = safeString(z.string().min(1).max(512))
const textSnapshot = (max: number) =>
  safeString(z.string().min(1).max(max))
const nullableTextSnapshot = (max: number) =>
  safeString(z.string().max(max)).nullable()
const nullableAppleId = z.string().refine(isAppleSongId).nullable()
const nullableSpotifyId = z.string().regex(SPOTIFY_ID_PATTERN).nullable()
const postgresInteger = z.number().int().max(2_147_483_647)
const nullableTimestamp = z.number().int().min(0).max(8_640_000_000_000_000).nullable()
const nullablePositiveInteger = postgresInteger.positive().nullable()
const nullableNonnegativeInteger = postgresInteger.nonnegative().nullable()
const nullableArtworkColor = z.string().regex(/^[0-9a-f]{6}$/).nullable()

export const playlistSyncSourceSchema = z.enum([
  'ios_native',
  'web_musickit',
  'spotify_export',
])

const beginPlaylistSyncObject = z.object({
  source: playlistSyncSourceSchema.default('ios_native'),
  // Every MusicKit source carries an Apple storefront; a Spotify export must
  // not, since begin() writes it over the listener's Apple storefront.
  storefront: z.string().regex(/^[a-z]{2}$/).nullable().default(null),
  expectedPlaylists: z.number().int().min(0).max(PLAYLIST_SYNC_MAX_PLAYLISTS),
  expectedEntries: z.number().int().min(0).max(PLAYLIST_SYNC_MAX_ENTRIES),
}).strict()

export const beginPlaylistSyncSchema = beginPlaylistSyncObject.superRefine((value, context) => {
  const spotify = value.source === 'spotify_export'
  if (spotify && value.storefront != null) {
    context.addIssue({
      code: 'custom',
      path: ['storefront'],
      message: 'storefront must be null for a Spotify export',
    })
  } else if (!spotify && value.storefront == null) {
    context.addIssue({
      code: 'custom',
      path: ['storefront'],
      message: 'storefront is required for this source',
    })
  }
})

const playlistSnapshotObject = z.object({
  ordinal: z.number().int().min(0).max(PLAYLIST_SYNC_MAX_PLAYLISTS - 1),
  appleLibraryId: opaqueLibraryId,
  appleCatalogId: nullableAppleId,
  name: textSnapshot(500),
  description: nullableTextSnapshot(10_000),
  curatorName: nullableTextSnapshot(500),
  artworkUrlTemplate: nullableTextSnapshot(MAX_ARTWORK_URL_LENGTH),
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

export const playlistSnapshotSchema = playlistSnapshotObject.superRefine((value, context) => {
  const artwork = parseNullableArtworkMetadata({
    url: value.artworkUrlTemplate,
    width: value.artworkWidth,
    height: value.artworkHeight,
    bgColor: value.artworkBgColor,
  })
  if (!artwork) context.addIssue({ code: 'custom', message: 'Invalid artwork metadata' })
})

const playlistEntrySnapshotObject = z.object({
  position: z.number().int().min(0).max(PLAYLIST_SYNC_MAX_ENTRIES - 1),
  appleLibraryEntryId: opaqueLibraryId,
  appleLibraryTrackId: opaqueLibraryId.nullable(),
  appleCatalogId: nullableAppleId,
  // Defaults to null so MusicKit clients that predate the field keep working.
  spotifyId: nullableSpotifyId.default(null),
  isrcSnapshot: z.string().regex(/^[A-Z]{2}[A-Z0-9]{3}\d{7}$/).nullable(),
  titleSnapshot: textSnapshot(1_000),
  artistSnapshot: textSnapshot(1_000),
  albumSnapshot: nullableTextSnapshot(1_000),
  durationMsSnapshot: nullableNonnegativeInteger,
  artworkUrlTemplateSnapshot: nullableTextSnapshot(MAX_ARTWORK_URL_LENGTH),
  artworkWidthSnapshot: nullablePositiveInteger,
  artworkHeightSnapshot: nullablePositiveInteger,
  artworkBgColorSnapshot: nullableArtworkColor,
}).strict()

export const playlistEntrySnapshotSchema = playlistEntrySnapshotObject.superRefine(
  (value, context) => {
    const artwork = parseNullableArtworkMetadata({
      url: value.artworkUrlTemplateSnapshot,
      width: value.artworkWidthSnapshot,
      height: value.artworkHeightSnapshot,
      bgColor: value.artworkBgColorSnapshot,
    })
    if (!artwork) context.addIssue({ code: 'custom', message: 'Invalid artwork metadata' })
  },
)

export const playlistChunkSchema = z.object({
  playlists: z.array(playlistSnapshotSchema).min(1).max(PLAYLIST_CHUNK_MAX),
}).strict()

export const playlistEntryChunkSchema = z.object({
  playlistAppleId: opaqueLibraryId,
  entries: z.array(playlistEntrySnapshotSchema).max(PLAYLIST_ENTRY_CHUNK_MAX),
}).strict()

export type PlaylistSyncSource = z.infer<typeof playlistSyncSourceSchema>
export type BeginPlaylistSync = z.infer<typeof beginPlaylistSyncSchema>
export type PlaylistSnapshot = z.infer<typeof playlistSnapshotSchema>
export type PlaylistEntrySnapshot = z.infer<typeof playlistEntrySnapshotSchema>
