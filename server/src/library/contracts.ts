import { z } from 'zod'
import { isAppleSongId } from '../musickit/apple-id'

export const LIBRARY_SYNC_MAX_SONGS = 100_000
export const LIBRARY_SONG_CHUNK_MAX = 500

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
const textSnapshot = (max: number) => safeString(z.string().min(1).max(max))
const nullableTextSnapshot = (max: number) => safeString(z.string().max(max)).nullable()
const postgresInteger = z.number().int().max(2_147_483_647)
const nullableTimestamp = z.number().int().min(0).max(8_640_000_000_000_000).nullable()

export const librarySyncSourceSchema = z.enum(['ios_native', 'web_musickit'])

export const beginLibrarySyncSchema = z.object({
  source: librarySyncSourceSchema,
  storefront: z.string().regex(/^[a-z]{2}$/),
  expectedSongs: z.number().int().min(0).max(LIBRARY_SYNC_MAX_SONGS),
  expectedRecentTracks: z.number().int().min(0).max(30).default(0),
}).strict()

export const librarySongSnapshotSchema = z.object({
  ordinal: z.number().int().min(0).max(LIBRARY_SYNC_MAX_SONGS - 1),
  appleLibraryId: opaqueLibraryId.nullable(),
  appleCatalogId: z.string().refine(isAppleSongId),
  title: textSnapshot(1_000),
  artist: textSnapshot(1_000),
  album: nullableTextSnapshot(1_000),
  genre: nullableTextSnapshot(500),
  releaseYear: z.number().int().min(1900).max(3000).nullable(),
  explicit: z.boolean().nullable(),
  playCount: postgresInteger.nonnegative().nullable(),
  lastPlayedAt: nullableTimestamp,
  dateAdded: nullableTimestamp,
}).strict()

export const librarySongChunkSchema = z.object({
  songs: z.array(librarySongSnapshotSchema).min(1).max(LIBRARY_SONG_CHUNK_MAX),
}).strict()

export const libraryRecentTrackChunkSchema = z.object({
  catalogIds: z.array(z.string().refine(isAppleSongId)).min(1).max(30),
}).strict()

export type LibrarySyncSource = z.infer<typeof librarySyncSourceSchema>
export type LibrarySongSnapshot = z.infer<typeof librarySongSnapshotSchema>
