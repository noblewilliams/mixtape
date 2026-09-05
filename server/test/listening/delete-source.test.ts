import { asc, eq } from 'drizzle-orm'
import { describe, expect, it } from 'vitest'
import {
  listeningDays,
  playlistOrigins,
  tracks,
  userArtistSeeds,
  userMusicSources,
  userPlaylists,
  userTracks,
} from '../../src/db/schema'
import { createListeningImportStore } from '../../src/listening/import-store'
import { createLibrarySyncStore } from '../../src/library/sync-store'
import { createTestDb, type TestDb } from '../helpers/db'
import {
  accountBegin,
  APPLE_A,
  APPLE_B,
  appleBegin,
  artist,
  begin,
  day,
  dbToday,
  libraryRow,
  now,
  publish,
  runRow,
  seedUser,
  shiftDay,
  SPOTIFY_A,
  SPOTIFY_B,
  SPOTIFY_C,
  tenantRows,
  track,
  userTracksByPlatform,
} from '../helpers/listening-fixtures'

const SEED_ID = 'aaaaaaaaaaaaaaaaaaaaaa'

async function liveApple(db: TestDb) {
  const store = createLibrarySyncStore(db, { now: () => now })
  const { syncId } = await store.begin('u1', 'web_musickit', 'ng', 1)
  await store.putSongs('u1', syncId, [{
    ordinal: 0, appleLibraryId: 'i.library', appleCatalogId: APPLE_A,
    title: 'Song', artist: 'Artist', album: null, genre: null, releaseYear: null,
    explicit: null, playCount: null, lastPlayedAt: null, dateAdded: null,
  }])
  await store.complete('u1', syncId)
}

async function playlist(db: TestDb, source: 'apple' | 'spotify_export', key: string) {
  await db.insert(userPlaylists).values({
    userId: 'u1',
    appleLibraryId: key,
    name: key,
    kind: 'user',
    source,
    sourceFingerprint: 'a'.repeat(64),
  })
}

describe('ListeningImportStore.deleteSource', () => {
  it('forgets Spotify playlist confirmations without erasing Apple creation receipts', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await db.insert(playlistOrigins).values([
      { userId: 'u1', source: 'spotify_export', libraryId: 'export-key', origin: 'user_confirmed' },
      { userId: 'u1', source: 'apple', libraryId: 'p-created', origin: 'mixtape' },
    ])
    await createListeningImportStore(db).deleteSource('u1', 'spotify_export')
    expect(await db.select().from(playlistOrigins)).toMatchObject([
      { source: 'apple', libraryId: 'p-created', origin: 'mixtape' },
    ])
  })
  it('removes a Spotify source: ledger, seeds, playlists, liked rows, orphaned user tracks', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const store = createListeningImportStore(db, { now: () => now })
    const today = await dbToday(db)
    const [d1, d2] = [shiftDay(today, -2), shiftDay(today, -1)]
    await db.insert(userArtistSeeds).values({ userId: 'u1', name: 'Kept', source: 'interview' })
    await publish(store, 'u1', begin(), {
      tracks: [track(), track({ ordinal: 1, platformId: SPOTIFY_B })],
      days: [
        day({ day: d1, plays: 5, skips: 1 }),
        day({ ordinal: 1, platformId: SPOTIFY_B, day: d2, plays: 1 }),
      ],
    })
    await publish(store, 'u1', accountBegin(), {
      tracks: [track(), track({ ordinal: 1, platformId: SPOTIFY_C })],
      library: [libraryRow(), libraryRow({ ordinal: 1, platformId: SPOTIFY_C })],
      artists: [artist()],
    })
    await publish(store, 'u1', appleBegin(), {
      tracks: [track({ platformId: APPLE_A })],
      days: [day({ platformId: APPLE_A, day: d1, plays: 2, skips: 1 })],
      library: [libraryRow({ platformId: APPLE_A })],
    })
    const [seededTrack] = await db.insert(tracks)
      .values({ spotifyId: SEED_ID, title: 'Seed', artist: 'Artist' })
      .returning({ id: tracks.id })
    await db.insert(userTracks).values({
      userId: 'u1', trackId: seededTrack.id, inLibrary: false, seeded: true, playCount: 0,
      playCountObserved: false, playCountRecent: 4, skipCount: 2,
    })
    await playlist(db, 'spotify_export', 'spotify-list')
    await playlist(db, 'apple', 'apple-list')
    const open = await store.begin('u1', begin())

    await expect(store.deleteSource('u1', 'spotify_export')).resolves.toEqual({
      deletedDays: 2,
      deletedTracks: 3,
      unlibraried: 2,
    })

    expect(await db.select().from(listeningDays)).toMatchObject([{ source: 'apple_export', plays: 2 }])
    expect(await db.select().from(userArtistSeeds)).toMatchObject([{ name: 'Kept', source: 'interview' }])
    expect(await db.select().from(userMusicSources)).toMatchObject([{ source: 'apple_export' }])
    expect(await db.select().from(userPlaylists).orderBy(asc(userPlaylists.appleLibraryId))).toMatchObject([
      { appleLibraryId: 'apple-list', inLibrary: true },
      { appleLibraryId: 'spotify-list', inLibrary: false },
    ])
    const rows = await userTracksByPlatform(db, 'u1')
    expect([...rows.keys()].sort()).toEqual([APPLE_A, SEED_ID])
    expect(rows.get(APPLE_A)).toMatchObject({ inLibrary: true, playCount: 2, playCountRecent: 2, skipCount: 1 })
    // Seeded rows survive with their ledger-derived fields reset; skip_count is
    // left alone for a row with no ledger.
    expect(rows.get(SEED_ID))
      .toMatchObject({ seeded: true, inLibrary: false, playCountRecent: 0, skipCount: 2 })
    expect(rows.get(SEED_ID)?.updatedAt.getTime()).toBe(now.getTime())
    expect((await runRow(db, open.importId)).status).toBe('expired')
    // The canonical track rows are shared and stay.
    expect(await db.select().from(tracks)).toHaveLength(5)
  })

  it('keeps liked rows for a listener with a live Apple library', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await db.insert(tracks).values({ spotifyId: SPOTIFY_A, appleId: APPLE_A, title: 'Song', artist: 'Artist' })
    await liveApple(db)
    const store = createListeningImportStore(db, { now: () => now })
    await publish(store, 'u1', accountBegin(), {
      tracks: [track(), track({ ordinal: 1, platformId: SPOTIFY_B })],
      library: [libraryRow()],
      artists: [artist()],
    })

    await expect(store.deleteSource('u1', 'spotify_export')).resolves.toEqual({
      deletedDays: 0,
      deletedTracks: 1,
      unlibraried: 0,
    })

    const rows = await userTracksByPlatform(db, 'u1')
    expect([...rows.keys()]).toEqual([SPOTIFY_A])
    expect(rows.get(SPOTIFY_A)?.inLibrary).toBe(true)
    expect(await db.select().from(userMusicSources)).toMatchObject([{ source: 'apple_live' }])
  })

  it('recomputes survivors from the remaining ledger and leaves play_count alone', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const store = createListeningImportStore(db, { now: () => now })
    const today = await dbToday(db)
    const [d1, d2] = [shiftDay(today, -2), shiftDay(today, -1)]
    await db.insert(tracks).values({ spotifyId: SPOTIFY_A, appleId: APPLE_A, title: 'Song', artist: 'Artist' })
    await publish(store, 'u1', appleBegin(), {
      tracks: [track({ platformId: APPLE_A })],
      days: [day({ platformId: APPLE_A, day: d1, plays: 2, skips: 1 })],
      library: [libraryRow({ platformId: APPLE_A })],
    })
    await publish(store, 'u1', begin(), {
      tracks: [track()],
      days: [day({ day: d2, plays: 5, skips: 2 })],
    })
    expect((await userTracksByPlatform(db, 'u1')).get(SPOTIFY_A))
      .toMatchObject({ playCount: 7, playCountRecent: 7, skipCount: 3, inLibrary: true })

    await expect(store.deleteSource('u1', 'spotify_export')).resolves.toEqual({
      deletedDays: 1,
      deletedTracks: 0,
      unlibraried: 0,
    })

    const rows = await userTracksByPlatform(db, 'u1')
    expect(rows.get(SPOTIFY_A)).toMatchObject({ playCount: 7, playCountRecent: 2, skipCount: 1, inLibrary: true })
    expect(await db.select().from(listeningDays)).toMatchObject([{ source: 'apple_export', day: d1 }])
  })

  it('resets the deleting user only', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedUser(db, 'u2')
    const store = createListeningImportStore(db, { now: () => now })
    const today = await dbToday(db)
    const [d1, d2] = [shiftDay(today, -2), shiftDay(today, -1)]
    for (const userId of ['u1', 'u2']) {
      await publish(store, userId, begin(), {
        tracks: [track(), track({ ordinal: 1, platformId: SPOTIFY_B })],
        days: [
          day({ day: d1, plays: 5, skips: 1 }),
          day({ ordinal: 1, platformId: SPOTIFY_B, day: d2, plays: 1 }),
        ],
      })
      await publish(store, userId, accountBegin(), {
        tracks: [track()],
        library: [libraryRow()],
        artists: [artist()],
      })
    }
    const before = await tenantRows(db, 'u1')
    expect(before.days).toHaveLength(2)
    expect(before.tracks.filter((row) => row.inLibrary)).toHaveLength(1)
    expect(before.seeds).toMatchObject([{ name: 'Artist', source: 'spotify_export' }])
    expect(before.sources).toMatchObject([{ source: 'spotify_export' }])
    // A later clock: any touch of u1's rows would move updated_at as well.
    const later = createListeningImportStore(db, { now: () => new Date(now.getTime() + 60_000) })

    await expect(later.deleteSource('u2', 'spotify_export')).resolves.toEqual({
      deletedDays: 2,
      deletedTracks: 2,
      unlibraried: 1,
    })

    expect(await tenantRows(db, 'u1')).toEqual(before)
    expect(await tenantRows(db, 'u2')).toEqual({ days: [], tracks: [], seeds: [], sources: [] })
    // The canonical track rows are shared and stay.
    expect(await db.select().from(tracks)).toHaveLength(2)
  })

  it('resets an Apple export for a listener without a live Apple library', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const store = createListeningImportStore(db, { now: () => now })
    const today = await dbToday(db)
    const d1 = shiftDay(today, -1)
    await publish(store, 'u1', appleBegin(), {
      tracks: [track({ platformId: APPLE_A }), track({ ordinal: 1, platformId: APPLE_B })],
      days: [day({ platformId: APPLE_A, day: d1, plays: 2, skips: 1 })],
      library: [
        libraryRow({ platformId: APPLE_A, playCount: 10 }),
        libraryRow({ ordinal: 1, platformId: APPLE_B, likeRating: 1 }),
      ],
    })
    const open = await store.begin('u1', appleBegin())
    expect([...(await userTracksByPlatform(db, 'u1')).values()].map((row) => row.inLibrary))
      .toEqual([true, true])

    await expect(store.deleteSource('u1', 'apple_export')).resolves.toEqual({
      deletedDays: 1,
      deletedTracks: 2,
      unlibraried: 2,
    })

    expect(await db.select().from(userTracks).where(eq(userTracks.userId, 'u1'))).toEqual([])
    expect(await db.select().from(listeningDays)).toEqual([])
    expect(await db.select().from(userMusicSources)).toEqual([])
    expect((await runRow(db, open.importId)).status).toBe('expired')
    // The canonical track rows are shared and stay.
    expect(await db.select().from(tracks)).toHaveLength(2)
  })

  it('keeps Apple library rows for a listener with a live Apple library', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await liveApple(db)
    const store = createListeningImportStore(db, { now: () => now })
    const today = await dbToday(db)
    const d1 = shiftDay(today, -1)
    await publish(store, 'u1', appleBegin(), {
      tracks: [track({ platformId: APPLE_A }), track({ ordinal: 1, platformId: APPLE_B })],
      days: [
        day({ platformId: APPLE_A, day: d1, plays: 2, skips: 1 }),
        day({ ordinal: 1, platformId: APPLE_B, day: d1, plays: 1, skips: 0 }),
      ],
      library: [libraryRow({ platformId: APPLE_A, playCount: 10, skipCount: 4 })],
    })
    expect((await userTracksByPlatform(db, 'u1')).get(APPLE_A))
      .toMatchObject({ inLibrary: true, playCount: 10, playCountRecent: 2, skipCount: 4 })
    const laterNow = new Date(now.getTime() + 60_000)
    const later = createListeningImportStore(db, { now: () => laterNow })

    await expect(later.deleteSource('u1', 'apple_export')).resolves.toEqual({
      deletedDays: 2,
      deletedTracks: 1,
      unlibraried: 0,
    })

    const rows = await userTracksByPlatform(db, 'u1')
    expect([...rows.keys()]).toEqual([APPLE_A])
    // Only the ledger-derived fields move; the library's own counts stay.
    expect(rows.get(APPLE_A)).toMatchObject({ inLibrary: true, playCount: 10, playCountRecent: 0, skipCount: 4 })
    expect(rows.get(APPLE_A)?.updatedAt.getTime()).toBe(laterNow.getTime())
    expect(await db.select().from(listeningDays)).toEqual([])
    expect(await db.select().from(userMusicSources)).toMatchObject([{ source: 'apple_live' }])
  })

  it('removes an Apple export and keeps the Spotify ledger and rows', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const store = createListeningImportStore(db, { now: () => now })
    const today = await dbToday(db)
    const d1 = shiftDay(today, -1)
    await publish(store, 'u1', appleBegin(), {
      tracks: [track({ platformId: APPLE_A }), track({ ordinal: 1, platformId: APPLE_B })],
      days: [day({ platformId: APPLE_A, day: d1, plays: 2, skips: 1 })],
      library: [libraryRow({ platformId: APPLE_A })],
    })
    await publish(store, 'u1', begin(), {
      tracks: [track()],
      days: [day({ day: d1, plays: 3, skips: 0 })],
    })

    await expect(store.deleteSource('u1', 'apple_export')).resolves.toEqual({
      deletedDays: 1,
      deletedTracks: 2,
      unlibraried: 1,
    })

    const rows = await userTracksByPlatform(db, 'u1')
    expect([...rows.keys()]).toEqual([SPOTIFY_A])
    expect(rows.get(SPOTIFY_A)).toMatchObject({ inLibrary: false, playCount: 3, playCountRecent: 3, skipCount: 0 })
    expect(await db.select().from(listeningDays)).toMatchObject([{ source: 'spotify_export', plays: 3 }])
    expect(await db.select().from(userMusicSources)).toMatchObject([{ source: 'spotify_export' }])
    expect(await db.select().from(tracks)).toHaveLength(3)
  })
})
