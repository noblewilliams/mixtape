import { asc, eq, getTableColumns, sql } from 'drizzle-orm'
import {
  listeningDays,
  listeningImportRuns,
  tracks,
  user,
  userArtistSeeds,
  userMusicSources,
  userTracks,
} from '../../src/db/schema'
import type {
  BeginListeningImport,
  ListeningArtistSnapshot,
  ListeningDaySnapshot,
  ListeningLibrarySnapshot,
  ListeningTrackSnapshot,
} from '../../src/listening/contracts'
import type { ListeningImportStore } from '../../src/listening/import-store'
import type { TestDb } from './db'

export const now = new Date('2026-09-01T12:00:00.000Z')
export const SPOTIFY_A = '4uLU6hMCjMI75M1A2tKUQC'
export const SPOTIFY_B = '7ouMYWpwJ422jRcDASZB7P'
export const SPOTIFY_C = '1301WleyT98MSxVHPZCA6M'
export const APPLE_A = '1440935467'
export const APPLE_B = '1440935468'
export const UNKNOWN_IMPORT = '00000000-0000-4000-8000-000000000000'

export const begin = (over: Partial<BeginListeningImport> = {}): BeginListeningImport => ({
  source: 'spotify_export',
  package: 'spotify_extended',
  timeZone: 'Africa/Lagos',
  country: 'NG',
  expectedTracks: 2,
  expectedDays: 2,
  expectedLibraryTracks: 0,
  expectedArtists: 0,
  unresolvedRows: 0,
  unresolvedPlays: 0,
  ...over,
})

export const accountBegin = (over: Partial<BeginListeningImport> = {}) => begin({
  package: 'spotify_account',
  expectedDays: 0,
  expectedLibraryTracks: 2,
  expectedArtists: 2,
  ...over,
})

export const appleBegin = (over: Partial<BeginListeningImport> = {}) => begin({
  source: 'apple_export',
  package: 'apple_media',
  expectedLibraryTracks: 2,
  ...over,
})

export const track = (over: Partial<ListeningTrackSnapshot> = {}): ListeningTrackSnapshot => ({
  ordinal: 0,
  platformId: SPOTIFY_A,
  title: 'Song',
  artist: 'Artist',
  album: 'Album',
  durationMs: 200_000,
  ...over,
})

export const day = (over: Partial<ListeningDaySnapshot> = {}): ListeningDaySnapshot => ({
  ordinal: 0,
  platformId: SPOTIFY_A,
  day: '2026-08-30',
  plays: 3,
  skips: 1,
  completes: 2,
  msPlayed: 600_000,
  hoursMask: 5,
  ...over,
})

export const libraryRow = (
  over: Partial<ListeningLibrarySnapshot> = {},
): ListeningLibrarySnapshot => ({
  ordinal: 0,
  platformId: SPOTIFY_A,
  playCount: null,
  skipCount: null,
  lastPlayedAt: null,
  dateAdded: 1_700_000_000_000,
  likeRating: null,
  ...over,
})

export const artist = (over: Partial<ListeningArtistSnapshot> = {}): ListeningArtistSnapshot => ({
  ordinal: 0,
  name: 'Artist',
  spotifyId: SPOTIFY_B,
  ...over,
})

export async function seedUser(db: TestDb, id: string) {
  await db.insert(user).values({
    id,
    name: id,
    email: `${id}@example.com`,
    emailVerified: false,
    createdAt: now,
    updatedAt: now,
  })
}

export async function runRow(db: TestDb, importId: string) {
  const [run] = await db.select().from(listeningImportRuns)
    .where(eq(listeningImportRuns.id, importId))
  return run
}

// The recent-play window is anchored on the database clock (CURRENT_DATE), so
// tests that probe it build their days from that clock, never from Date.now().
export async function dbToday(db: TestDb): Promise<string> {
  const result = await db.execute(sql`SELECT CURRENT_DATE::text AS today`)
  return String(result.rows[0]?.today)
}

export function shiftDay(dayValue: string, days: number): string {
  const date = new Date(`${dayValue}T00:00:00.000Z`)
  date.setUTCDate(date.getUTCDate() + days)
  return date.toISOString().slice(0, 10)
}

export const midnightUtc = (dayValue: string) => `${dayValue}T00:00:00.000Z`

export type Chunks = {
  tracks?: ListeningTrackSnapshot[]
  days?: ListeningDaySnapshot[]
  library?: ListeningLibrarySnapshot[]
  artists?: ListeningArtistSnapshot[]
}

// Begin with the expected counts the chunks imply, then stage every chunk.
export async function stage(
  store: ListeningImportStore,
  userId: string,
  input: BeginListeningImport,
  chunks: Chunks,
) {
  const { importId } = await store.begin(userId, {
    ...input,
    expectedTracks: chunks.tracks?.length ?? 0,
    expectedDays: chunks.days?.length ?? 0,
    expectedLibraryTracks: chunks.library?.length ?? 0,
    expectedArtists: chunks.artists?.length ?? 0,
  })
  if (chunks.tracks?.length) await store.putTracks(userId, importId, chunks.tracks)
  if (chunks.days?.length) await store.putDays(userId, importId, chunks.days)
  if (chunks.library?.length) await store.putLibrary(userId, importId, chunks.library)
  if (chunks.artists?.length) await store.putArtists(userId, importId, chunks.artists)
  return importId
}

export async function publish(
  store: ListeningImportStore,
  userId: string,
  input: BeginListeningImport,
  chunks: Chunks,
) {
  const importId = await stage(store, userId, input, chunks)
  return { importId, summary: await store.complete(userId, importId) }
}

export type UserTrackRow = typeof userTracks.$inferSelect

// The user's rows keyed by the track's platform id (Spotify first, else Apple).
export async function userTracksByPlatform(db: TestDb, userId: string) {
  const rows = await db.select({
    ...getTableColumns(userTracks),
    spotifyId: tracks.spotifyId,
    appleId: tracks.appleId,
  })
    .from(userTracks)
    .innerJoin(tracks, eq(tracks.id, userTracks.trackId))
    .where(eq(userTracks.userId, userId))
  return new Map<string, UserTrackRow>(rows.map(({ spotifyId, appleId, ...row }) =>
    [spotifyId ?? appleId ?? '', row]))
}

// Every row the import pipeline owns for one user, in a stable order, so a
// test can prove another tenant's import or reset left them untouched.
export async function tenantRows(db: TestDb, userId: string) {
  return {
    days: await db.select().from(listeningDays)
      .where(eq(listeningDays.userId, userId))
      .orderBy(asc(listeningDays.source), asc(listeningDays.trackId), asc(listeningDays.day)),
    tracks: await db.select().from(userTracks)
      .where(eq(userTracks.userId, userId))
      .orderBy(asc(userTracks.trackId)),
    seeds: await db.select().from(userArtistSeeds)
      .where(eq(userArtistSeeds.userId, userId))
      .orderBy(asc(userArtistSeeds.name)),
    sources: await db.select().from(userMusicSources)
      .where(eq(userMusicSources.userId, userId))
      .orderBy(asc(userMusicSources.source)),
  }
}

export const withoutIdentity = (row: UserTrackRow | undefined) => {
  if (!row) return undefined
  const { userId: _userId, trackId: _trackId, updatedAt: _updatedAt, ...rest } = row
  return rest
}
