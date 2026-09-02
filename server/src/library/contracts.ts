import { z } from 'zod'
import { safeString } from '../contracts/safe-string'
import { isAppleSongId } from '../musickit/apple-id'

export const LIBRARY_SYNC_MAX_SONGS = 100_000
export const LIBRARY_SONG_CHUNK_MAX = 500

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
