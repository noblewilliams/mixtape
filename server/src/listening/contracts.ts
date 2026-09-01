import { z } from 'zod'

export const LISTENING_IMPORT_MAX_TRACKS = 100_000
export const LISTENING_IMPORT_MAX_DAYS = 2_000_000
export const LISTENING_IMPORT_MAX_LIBRARY_TRACKS = 100_000
export const LISTENING_IMPORT_MAX_ARTISTS = 10_000
export const LISTENING_TRACK_CHUNK_MAX = 500
export const LISTENING_DAY_CHUNK_MAX = 2_000
export const LISTENING_LIBRARY_CHUNK_MAX = 500
export const LISTENING_ARTIST_CHUNK_MAX = 500
// 24-bit mask: bit i set when the track played in local hour i.
export const LISTENING_HOURS_MASK_MAX = 16_777_215

// Spotify track and artist ids are 22 base62 characters; same pattern as the
// schema checks on tracks.spotify_id and user_artist_seeds.spotify_id.
export const SPOTIFY_ID_PATTERN = /^[0-9A-Za-z]{22}$/

export function isSpotifyId(value: string): boolean {
  return SPOTIFY_ID_PATTERN.test(value)
}

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
const textSnapshot = (max: number) => safeString(z.string().min(1).max(max))
const nullableTextSnapshot = (max: number) => safeString(z.string().max(max)).nullable()
const postgresInteger = z.number().int().max(2_147_483_647)
const nullableTimestamp = z.number().int().min(0).max(8_640_000_000_000_000).nullable()
// Spotify track id or Apple song id; the store validates it against the run's
// source, so the contract only bounds it.
const platformId = safeString(z.string().min(1).max(64))

const DAY_PATTERN = /^\d{4}-\d{2}-\d{2}$/

// A real calendar date in the listener's local zone; Postgres would reject
// 2026-02-30 at insert time, which must surface as a 400 instead.
function isCalendarDay(value: string) {
  if (!DAY_PATTERN.test(value)) return false
  const year = Number(value.slice(0, 4))
  const month = Number(value.slice(5, 7))
  const dayOfMonth = Number(value.slice(8, 10))
  if (year < 1) return false
  const date = new Date(0)
  date.setUTCFullYear(year, month - 1, dayOfMonth)
  return date.getUTCFullYear() === year
    && date.getUTCMonth() === month - 1
    && date.getUTCDate() === dayOfMonth
}

const daySchema = z.string().regex(DAY_PATTERN).refine(isCalendarDay)

export const listeningImportSourceSchema = z.enum(['spotify_export', 'apple_export'])
export const listeningImportPackageSchema = z.enum([
  'spotify_extended',
  'spotify_account',
  'apple_media',
])

export type ListeningImportSource = z.infer<typeof listeningImportSourceSchema>
export type ListeningImportPackage = z.infer<typeof listeningImportPackageSchema>

const PACKAGE_SOURCE: Record<ListeningImportPackage, ListeningImportSource> = {
  spotify_extended: 'spotify_export',
  spotify_account: 'spotify_export',
  apple_media: 'apple_export',
}

const beginListeningImportObject = z.object({
  source: listeningImportSourceSchema,
  package: listeningImportPackageSchema,
  timeZone: safeString(z.string().min(1).max(64)),
  country: z.string().regex(/^[A-Z]{2}$/).nullable(),
  expectedTracks: z.number().int().min(0).max(LISTENING_IMPORT_MAX_TRACKS),
  expectedDays: z.number().int().min(0).max(LISTENING_IMPORT_MAX_DAYS),
  expectedLibraryTracks: z.number().int().min(0).max(LISTENING_IMPORT_MAX_LIBRARY_TRACKS),
  expectedArtists: z.number().int().min(0).max(LISTENING_IMPORT_MAX_ARTISTS),
  unresolvedRows: postgresInteger.min(0).default(0),
  unresolvedPlays: postgresInteger.min(0).default(0),
}).strict()

type BeginListeningImportShape = z.infer<typeof beginListeningImportObject>
type ExpectedCount = 'expectedDays' | 'expectedLibraryTracks' | 'expectedArtists'

// Chunk types a package does not carry must be expected as zero; mirrors the
// listening_import_runs check constraints so a bad begin is a 400.
const NOT_CARRIED: Record<ListeningImportPackage, readonly ExpectedCount[]> = {
  spotify_extended: ['expectedLibraryTracks', 'expectedArtists'],
  spotify_account: ['expectedDays'],
  apple_media: ['expectedArtists'],
}

export const beginListeningImportSchema = beginListeningImportObject.superRefine(
  (value: BeginListeningImportShape, ctx) => {
    if (PACKAGE_SOURCE[value.package] !== value.source) {
      ctx.addIssue({
        code: 'custom',
        path: ['package'],
        message: 'package does not belong to source',
      })
    }
    for (const field of NOT_CARRIED[value.package]) {
      if (value[field] !== 0) {
        ctx.addIssue({
          code: 'custom',
          path: [field],
          message: 'package does not carry this chunk type',
        })
      }
    }
  },
)

export const listeningTrackSnapshotSchema = z.object({
  ordinal: z.number().int().min(0).max(LISTENING_IMPORT_MAX_TRACKS - 1),
  platformId,
  title: textSnapshot(1_000),
  artist: textSnapshot(1_000),
  album: nullableTextSnapshot(1_000),
  durationMs: postgresInteger.nonnegative().nullable(),
}).strict()

export const listeningDaySnapshotSchema = z.object({
  ordinal: z.number().int().min(0).max(LISTENING_IMPORT_MAX_DAYS - 1),
  platformId,
  day: daySchema,
  plays: postgresInteger.nonnegative(),
  skips: postgresInteger.nonnegative().nullable(),
  completes: postgresInteger.nonnegative().nullable(),
  // bigint column, read back as a JS number: stay inside the safe range.
  msPlayed: z.number().int().min(0).max(Number.MAX_SAFE_INTEGER),
  hoursMask: z.number().int().min(0).max(LISTENING_HOURS_MASK_MAX).nullable(),
}).strict()

export const listeningLibrarySnapshotSchema = z.object({
  ordinal: z.number().int().min(0).max(LISTENING_IMPORT_MAX_LIBRARY_TRACKS - 1),
  platformId,
  playCount: postgresInteger.nonnegative().nullable(),
  skipCount: postgresInteger.nonnegative().nullable(),
  lastPlayedAt: nullableTimestamp,
  dateAdded: nullableTimestamp,
  // -1 dislike, 0 neutral, 1 love (Apple library export).
  likeRating: z.union([z.literal(-1), z.literal(0), z.literal(1)]).nullable(),
}).strict()

export const listeningArtistSnapshotSchema = z.object({
  ordinal: z.number().int().min(0).max(LISTENING_IMPORT_MAX_ARTISTS - 1),
  name: textSnapshot(500),
  spotifyId: z.string().regex(SPOTIFY_ID_PATTERN).nullable(),
}).strict()

export const listeningTrackChunkSchema = z.object({
  tracks: z.array(listeningTrackSnapshotSchema).min(1).max(LISTENING_TRACK_CHUNK_MAX),
}).strict()

export const listeningDayChunkSchema = z.object({
  days: z.array(listeningDaySnapshotSchema).min(1).max(LISTENING_DAY_CHUNK_MAX),
}).strict()

export const listeningLibraryChunkSchema = z.object({
  tracks: z.array(listeningLibrarySnapshotSchema).min(1).max(LISTENING_LIBRARY_CHUNK_MAX),
}).strict()

export const listeningArtistChunkSchema = z.object({
  artists: z.array(listeningArtistSnapshotSchema).min(1).max(LISTENING_ARTIST_CHUNK_MAX),
}).strict()

export type BeginListeningImport = z.infer<typeof beginListeningImportSchema>
export type ListeningTrackSnapshot = z.infer<typeof listeningTrackSnapshotSchema>
export type ListeningDaySnapshot = z.infer<typeof listeningDaySnapshotSchema>
export type ListeningLibrarySnapshot = z.infer<typeof listeningLibrarySnapshotSchema>
export type ListeningArtistSnapshot = z.infer<typeof listeningArtistSnapshotSchema>
