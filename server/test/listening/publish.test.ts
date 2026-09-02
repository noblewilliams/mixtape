import { asc, eq } from 'drizzle-orm'
import { describe, expect, it } from 'vitest'
import {
  listeningDays,
  tracks,
  userArtistSeeds,
  userMusicProfiles,
  userMusicSources,
  userTracks,
} from '../../src/db/schema'
import {
  createListeningImportStore,
  ListeningImportError,
} from '../../src/listening/import-store'
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
  midnightUtc,
  now,
  publish,
  runRow,
  seedUser,
  shiftDay,
  SPOTIFY_A,
  SPOTIFY_B,
  SPOTIFY_C,
  stage,
  track,
  UNKNOWN_IMPORT,
  userTracksByPlatform,
  withoutIdentity,
} from '../helpers/listening-fixtures'

const twoTracks = () => [track(), track({ ordinal: 1, platformId: SPOTIFY_B, title: 'Second' })]

async function dayRows(db: TestDb, userId: string) {
  return db.select({
    source: listeningDays.source,
    spotifyId: tracks.spotifyId,
    appleId: tracks.appleId,
    day: listeningDays.day,
    plays: listeningDays.plays,
    skips: listeningDays.skips,
    msPlayed: listeningDays.msPlayed,
  })
    .from(listeningDays)
    .innerJoin(tracks, eq(tracks.id, listeningDays.trackId))
    .where(eq(listeningDays.userId, userId))
    .orderBy(asc(listeningDays.source), asc(tracks.spotifyId), asc(tracks.appleId), asc(listeningDays.day))
}

describe('ListeningImportStore.complete', () => {
  it('publishes an extended history: tracks, ledger, observed counts, and bounds', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const store = createListeningImportStore(db, { now: () => now })
    const today = await dbToday(db)
    const [d1, d2, d3] = [shiftDay(today, -10), shiftDay(today, -3), shiftDay(today, -20)]

    const { importId, summary } = await publish(
      store,
      'u1',
      begin({ unresolvedRows: 4, unresolvedPlays: 9 }),
      {
        tracks: [
          track(),
          track({ ordinal: 1, platformId: SPOTIFY_B, title: 'Second', album: null, durationMs: null }),
        ],
        days: [
          day({ day: d1, plays: 3, skips: 1 }),
          day({ ordinal: 1, day: d2, plays: 2, skips: null, completes: null, hoursMask: null }),
          day({ ordinal: 2, platformId: SPOTIFY_B, day: d3, plays: 1, skips: 0 }),
        ],
      },
    )

    expect(summary).toEqual({
      tracks: 2,
      days: 3,
      libraryTracks: 0,
      artists: 0,
      unresolvedRows: 4,
      unresolvedPlays: 9,
      ledgerFrom: d3,
      ledgerTo: d2,
      likedRemoved: 0,
      likedRemovalSkipped: false,
    })
    expect(await db.select().from(tracks).orderBy(asc(tracks.spotifyId))).toMatchObject([
      {
        spotifyId: SPOTIFY_A, appleId: null, title: 'Song', artist: 'Artist', album: 'Album',
        durationMs: 200_000, artistSource: 'export', enrichPriority: 6,
      },
      {
        spotifyId: SPOTIFY_B, appleId: null, title: 'Second', album: null, durationMs: null,
        artistSource: 'export', enrichPriority: 0,
      },
    ])
    const rows = await userTracksByPlatform(db, 'u1')
    expect(rows.get(SPOTIFY_A)).toMatchObject({
      playCount: 5, playCountObserved: true, playCountRecent: 5, skipCount: 1,
      likeRating: null, dateAdded: null, inLibrary: false, seeded: false,
    })
    expect(rows.get(SPOTIFY_A)?.lastPlayedAt?.toISOString()).toBe(midnightUtc(d2))
    expect(rows.get(SPOTIFY_A)?.updatedAt.getTime()).toBe(now.getTime())
    expect(rows.get(SPOTIFY_B)).toMatchObject({
      playCount: 1, playCountObserved: true, playCountRecent: 1, skipCount: 0, inLibrary: false,
    })
    expect(await dayRows(db, 'u1')).toMatchObject([
      { source: 'spotify_export', spotifyId: SPOTIFY_A, day: d1, plays: 3, skips: 1 },
      { source: 'spotify_export', spotifyId: SPOTIFY_A, day: d2, plays: 2, skips: null },
      { source: 'spotify_export', spotifyId: SPOTIFY_B, day: d3, plays: 1, skips: 0 },
    ])
    const [source] = await db.select().from(userMusicSources)
    expect(source).toMatchObject({ source: 'spotify_export', ledgerFrom: d3, ledgerTo: d2 })
    expect(source.lastImportedAt?.getTime()).toBe(now.getTime())
    const run = await runRow(db, importId)
    expect(run).toMatchObject({
      status: 'completed', resultTracks: 2, resultDays: 3, resultLibraryTracks: 0, resultArtists: 0,
      resultLikedRemoved: 0, resultLikedRemovalSkipped: false, ledgerFrom: d3, ledgerTo: d2,
    })
    expect(run.completedAt?.getTime()).toBe(now.getTime())
  })

  it('publishes an account package: liked rows, seeded artists, profile, no ledger', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const store = createListeningImportStore(db, { now: () => now })
    const importId = await stage(store, 'u1', accountBegin({ country: null, timeZone: 'Europe/London' }), {
      tracks: twoTracks(),
      library: [libraryRow(), libraryRow({ ordinal: 1, platformId: SPOTIFY_B, dateAdded: null })],
      artists: [artist(), artist({ ordinal: 1, name: 'Other', spotifyId: null })],
    })
    // Complete writes the run's zone and coalesces its (null) country.
    await db.update(userMusicProfiles).set({ timeZone: 'Asia/Tokyo', country: 'JP' })

    const summary = await store.complete('u1', importId)

    expect(summary).toEqual({
      tracks: 2, days: 0, libraryTracks: 2, artists: 2, unresolvedRows: 0, unresolvedPlays: 0,
      ledgerFrom: null, ledgerTo: null, likedRemoved: 0, likedRemovalSkipped: false,
    })
    const rows = await userTracksByPlatform(db, 'u1')
    expect(rows.get(SPOTIFY_A)).toMatchObject({
      playCount: 0, playCountObserved: false, playCountRecent: 0, lastPlayedAt: null,
      skipCount: null, likeRating: null, inLibrary: true, seeded: false,
    })
    expect(rows.get(SPOTIFY_A)?.dateAdded?.getTime()).toBe(1_700_000_000_000)
    expect(rows.get(SPOTIFY_B)).toMatchObject({ inLibrary: true, dateAdded: null, playCountObserved: false })
    expect(await db.select().from(listeningDays)).toEqual([])
    expect(await db.select().from(userArtistSeeds).orderBy(asc(userArtistSeeds.name))).toMatchObject([
      { userId: 'u1', name: 'Artist', spotifyId: SPOTIFY_B, source: 'spotify_export' },
      { userId: 'u1', name: 'Other', spotifyId: null, source: 'spotify_export' },
    ])
    // Liked rows are pool candidates: 1 + zero recent plays.
    expect((await db.select().from(tracks)).map((row) => row.enrichPriority)).toEqual([1, 1])
    const [source] = await db.select().from(userMusicSources)
    expect(source).toMatchObject({ source: 'spotify_export', ledgerFrom: null, ledgerTo: null })
    expect(source.lastImportedAt?.getTime()).toBe(now.getTime())
    expect(await db.select().from(userMusicProfiles))
      .toMatchObject([{ timeZone: 'Europe/London', country: 'JP' }])
    expect(await runRow(db, importId)).toMatchObject({
      status: 'completed', resultLibraryTracks: 2, resultArtists: 2, ledgerFrom: null,
    })
  })

  it('publishes an Apple media export: library counts, ratings, ledger, Apple ids', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const store = createListeningImportStore(db, { now: () => now })
    const today = await dbToday(db)
    const [d1, d2] = [shiftDay(today, -5), shiftDay(today, -1)]
    const libraryLastPlayed = Date.UTC(2026, 0, 15)

    const { summary } = await publish(store, 'u1', appleBegin(), {
      tracks: [track({ platformId: APPLE_A }), track({ ordinal: 1, platformId: APPLE_B, title: 'Second' })],
      days: [
        day({ platformId: APPLE_A, day: d1, plays: 3, skips: 1 }),
        day({ ordinal: 1, platformId: APPLE_A, day: d2, plays: 1, skips: null }),
      ],
      library: [
        libraryRow({ platformId: APPLE_A, playCount: 10, skipCount: 2, likeRating: 1 }),
        libraryRow({
          ordinal: 1, platformId: APPLE_B, lastPlayedAt: libraryLastPlayed, dateAdded: null, likeRating: -1,
        }),
      ],
    })

    expect(summary).toMatchObject({ tracks: 2, days: 2, libraryTracks: 2, artists: 0, ledgerFrom: d1, ledgerTo: d2 })
    expect(await db.select().from(tracks).orderBy(asc(tracks.appleId))).toMatchObject([
      { appleId: APPLE_A, spotifyId: null, title: 'Song', artistSource: 'export', enrichPriority: 5 },
      { appleId: APPLE_B, spotifyId: null, title: 'Second', artistSource: 'export', enrichPriority: 1 },
    ])
    const rows = await userTracksByPlatform(db, 'u1')
    expect(rows.get(APPLE_A)).toMatchObject({
      playCount: 10, playCountObserved: true, playCountRecent: 4, skipCount: 2, likeRating: 1, inLibrary: true,
    })
    expect(rows.get(APPLE_A)?.lastPlayedAt?.toISOString()).toBe(midnightUtc(d2))
    expect(rows.get(APPLE_A)?.dateAdded?.getTime()).toBe(1_700_000_000_000)
    expect(rows.get(APPLE_B)).toMatchObject({
      playCount: 0, playCountObserved: false, playCountRecent: 0, skipCount: null, likeRating: -1,
      inLibrary: true, dateAdded: null,
    })
    expect(rows.get(APPLE_B)?.lastPlayedAt?.getTime()).toBe(libraryLastPlayed)
    expect(await dayRows(db, 'u1')).toMatchObject([
      { source: 'apple_export', appleId: APPLE_A, day: d1 },
      { source: 'apple_export', appleId: APPLE_A, day: d2 },
    ])
    expect(await db.select().from(userMusicSources)).toMatchObject([
      { source: 'apple_export', ledgerFrom: d1, ledgerTo: d2 },
    ])
  })

  it('yields the same rows whichever Spotify package arrives first', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedUser(db, 'u2')
    const store = createListeningImportStore(db, { now: () => now })
    const today = await dbToday(db)
    const [d1, d2] = [shiftDay(today, -4), shiftDay(today, -2)]
    const extended = () => ({
      tracks: twoTracks(),
      days: [
        day({ day: d1, plays: 3, skips: 1 }),
        day({ ordinal: 1, platformId: SPOTIFY_B, day: d2, plays: 2, skips: null }),
      ],
    })
    const account = () => ({ tracks: twoTracks(), library: [libraryRow()], artists: [artist()] })

    await publish(store, 'u1', begin(), extended())
    const second = await publish(store, 'u1', accountBegin(), account())
    await publish(store, 'u2', accountBegin(), account())
    await publish(store, 'u2', begin(), extended())

    expect(second.summary).toMatchObject({ likedRemoved: 0, likedRemovalSkipped: false })
    const first = await userTracksByPlatform(db, 'u1')
    const reversed = await userTracksByPlatform(db, 'u2')
    for (const id of [SPOTIFY_A, SPOTIFY_B]) {
      expect(withoutIdentity(reversed.get(id))).toEqual(withoutIdentity(first.get(id)))
    }
    expect(first.get(SPOTIFY_A)).toMatchObject({
      playCount: 3, playCountObserved: true, playCountRecent: 3, skipCount: 1, inLibrary: true,
    })
    expect(first.get(SPOTIFY_A)?.dateAdded?.getTime()).toBe(1_700_000_000_000)
    expect(first.get(SPOTIFY_A)?.lastPlayedAt?.toISOString()).toBe(midnightUtc(d1))
    expect(first.get(SPOTIFY_B)).toMatchObject({
      playCount: 2, playCountObserved: true, playCountRecent: 2, skipCount: null, inLibrary: false, dateAdded: null,
    })
    expect(await db.select().from(tracks)).toHaveLength(2)
  })

  it('never lowers a native observed count and replaces an unobserved one', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const store = createListeningImportStore(db, { now: () => now })
    const today = await dbToday(db)
    const [a, b] = await db.insert(tracks).values([
      { spotifyId: SPOTIFY_A, title: 'Song', artist: 'Artist' },
      { spotifyId: SPOTIFY_B, title: 'Second', artist: 'Artist' },
    ]).returning({ id: tracks.id })
    await db.insert(userTracks).values([
      { userId: 'u1', trackId: a.id, playCount: 50, playCountObserved: true, inLibrary: false },
      { userId: 'u1', trackId: b.id, playCount: 7, playCountObserved: false, inLibrary: false },
    ])
    const history = (plays: number) => ({
      tracks: twoTracks(),
      days: [
        day({ day: shiftDay(today, -1), plays }),
        day({ ordinal: 1, platformId: SPOTIFY_B, day: shiftDay(today, -1), plays }),
      ],
    })

    await publish(store, 'u1', begin(), history(5))
    let rows = await userTracksByPlatform(db, 'u1')
    expect(rows.get(SPOTIFY_A)).toMatchObject({ playCount: 50, playCountObserved: true, playCountRecent: 5 })
    expect(rows.get(SPOTIFY_B)).toMatchObject({ playCount: 5, playCountObserved: true, playCountRecent: 5 })

    await publish(store, 'u1', begin(), history(3))
    rows = await userTracksByPlatform(db, 'u1')
    expect(rows.get(SPOTIFY_A)).toMatchObject({ playCount: 50, playCountRecent: 3 })
    expect(rows.get(SPOTIFY_B)).toMatchObject({ playCount: 5, playCountRecent: 3 })
    expect(await db.select().from(tracks)).toHaveLength(2)
  })

  it('drops liked tracks missing from a later account package and reports it idempotently', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const store = createListeningImportStore(db, { now: () => now })
    const [apple] = await db.insert(tracks).values({ appleId: APPLE_A, title: 'Song', artist: 'Artist' })
      .returning({ id: tracks.id })
    await db.insert(userTracks).values({ userId: 'u1', trackId: apple.id, inLibrary: true })
    await publish(store, 'u1', accountBegin(), {
      tracks: twoTracks(),
      library: [libraryRow(), libraryRow({ ordinal: 1, platformId: SPOTIFY_B })],
      artists: [artist()],
    })

    const { importId, summary } = await publish(store, 'u1', accountBegin(), {
      tracks: [track()],
      library: [libraryRow()],
      artists: [artist({ spotifyId: null })],
    })

    expect(summary).toMatchObject({
      tracks: 1, libraryTracks: 1, artists: 1, likedRemoved: 1, likedRemovalSkipped: false,
    })
    const rows = await userTracksByPlatform(db, 'u1')
    expect(rows.get(SPOTIFY_A)?.inLibrary).toBe(true)
    expect(rows.get(SPOTIFY_B)?.inLibrary).toBe(false)
    expect(rows.get(SPOTIFY_B)?.updatedAt.getTime()).toBe(now.getTime())
    expect(rows.get(APPLE_A)?.inLibrary).toBe(true)
    // The seed keeps the id it already had.
    expect(await db.select().from(userArtistSeeds)).toMatchObject([{ name: 'Artist', spotifyId: SPOTIFY_B }])
    expect(await runRow(db, importId)).toMatchObject({ resultLikedRemoved: 1, resultLikedRemovalSkipped: false })
    await expect(store.complete('u1', importId)).resolves.toEqual(summary)
  })

  it('keeps liked rows for a listener with a live Apple library and says so', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await db.insert(userMusicSources).values({ userId: 'u1', source: 'apple_live', lastImportedAt: now })
    const store = createListeningImportStore(db, { now: () => now })
    await publish(store, 'u1', accountBegin(), {
      tracks: twoTracks(),
      library: [libraryRow(), libraryRow({ ordinal: 1, platformId: SPOTIFY_B })],
      artists: [artist()],
    })

    const { importId, summary } = await publish(store, 'u1', accountBegin(), {
      tracks: [track()],
      library: [libraryRow()],
      artists: [artist()],
    })

    expect(summary).toMatchObject({ likedRemoved: 0, likedRemovalSkipped: true })
    const rows = await userTracksByPlatform(db, 'u1')
    expect(rows.get(SPOTIFY_B)?.inLibrary).toBe(true)
    expect(await runRow(db, importId)).toMatchObject({ resultLikedRemoved: 0, resultLikedRemovalSkipped: true })
    await expect(store.complete('u1', importId)).resolves.toEqual(summary)
  })

  it('counts recent plays from exactly 730 days back', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const store = createListeningImportStore(db, { now: () => now })
    const today = await dbToday(db)

    await publish(store, 'u1', begin(), {
      tracks: [track()],
      days: [
        day({ day: shiftDay(today, -730), plays: 2 }),
        day({ ordinal: 1, day: shiftDay(today, -731), plays: 4 }),
      ],
    })

    const rows = await userTracksByPlatform(db, 'u1')
    expect(rows.get(SPOTIFY_A)).toMatchObject({ playCount: 6, playCountObserved: true, playCountRecent: 2 })
    expect(rows.get(SPOTIFY_A)?.lastPlayedAt?.toISOString()).toBe(midnightUtc(shiftDay(today, -730)))
    // Two recent plays and no library row: not a candidate.
    expect((await db.select().from(tracks))[0].enrichPriority).toBe(0)
  })

  it('replaces day rows on re-import and prunes days the run no longer covers', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const store = createListeningImportStore(db, { now: () => now })
    const today = await dbToday(db)
    const [d1, d2, d3] = [shiftDay(today, -3), shiftDay(today, -2), shiftDay(today, -1)]
    await publish(store, 'u1', begin(), {
      tracks: twoTracks(),
      days: [
        day({ day: d1, plays: 3, skips: 1 }),
        day({ ordinal: 1, day: d2, plays: 2 }),
        day({ ordinal: 2, platformId: SPOTIFY_B, day: d3, plays: 1 }),
      ],
    })

    const { summary } = await publish(store, 'u1', begin(), {
      tracks: [track()],
      days: [day({ day: d1, plays: 1, skips: 0, msPlayed: 1 })],
    })

    expect(summary).toMatchObject({ tracks: 1, days: 1, ledgerFrom: d1, ledgerTo: d3 })
    expect(await dayRows(db, 'u1')).toMatchObject([
      { spotifyId: SPOTIFY_A, day: d1, plays: 1, skips: 0, msPlayed: 1 },
      { spotifyId: SPOTIFY_B, day: d3, plays: 1 },
    ])
    const rows = await userTracksByPlatform(db, 'u1')
    expect(rows.get(SPOTIFY_A)).toMatchObject({ playCount: 5, playCountRecent: 1, skipCount: 0 })
    expect(rows.get(SPOTIFY_A)?.lastPlayedAt?.toISOString()).toBe(midnightUtc(d2))
    expect(rows.get(SPOTIFY_B)).toMatchObject({ playCount: 1, playCountRecent: 1 })
    expect(await db.select().from(userMusicSources)).toMatchObject([{ ledgerFrom: d1, ledgerTo: d3 }])
  })

  it('pools every ledger source of a shared track row and prunes one source only', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const store = createListeningImportStore(db, { now: () => now })
    const today = await dbToday(db)
    const [d1, d2] = [shiftDay(today, -2), shiftDay(today, -1)]
    await db.insert(tracks).values({ spotifyId: SPOTIFY_A, appleId: APPLE_A, title: 'Song', artist: 'Artist' })

    await publish(store, 'u1', appleBegin(), {
      tracks: [track({ platformId: APPLE_A })],
      days: [day({ platformId: APPLE_A, day: d1, plays: 2, skips: 1 })],
      library: [libraryRow({ platformId: APPLE_A, likeRating: 1 })],
    })
    await publish(store, 'u1', begin(), {
      tracks: [track()],
      days: [day({ day: d2, plays: 5, skips: 2 })],
    })

    expect(await db.select().from(tracks)).toHaveLength(1)
    let rows = await userTracksByPlatform(db, 'u1')
    expect(rows.get(SPOTIFY_A)).toMatchObject({
      playCount: 7, playCountObserved: true, playCountRecent: 7, skipCount: 3, inLibrary: true, likeRating: 1,
    })
    expect(rows.get(SPOTIFY_A)?.lastPlayedAt?.toISOString()).toBe(midnightUtc(d2))
    expect(await dayRows(db, 'u1')).toMatchObject([
      { source: 'apple_export', day: d1, plays: 2 },
      { source: 'spotify_export', day: d2, plays: 5 },
    ])

    await publish(store, 'u1', begin(), { tracks: [track()] })

    expect(await dayRows(db, 'u1')).toMatchObject([{ source: 'apple_export', day: d1, plays: 2 }])
    rows = await userTracksByPlatform(db, 'u1')
    expect(rows.get(SPOTIFY_A)).toMatchObject({ playCount: 7, playCountRecent: 2, skipCount: 1, inLibrary: true })
    expect(await db.select().from(userMusicSources).orderBy(asc(userMusicSources.source))).toMatchObject([
      { source: 'apple_export', ledgerFrom: d1, ledgerTo: d1 },
      { source: 'spotify_export', ledgerFrom: null, ledgerTo: null },
    ])
  })

  it('rejects a day or library row whose platform id is not among the run tracks', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const store = createListeningImportStore(db, { now: () => now })

    const spotify = await stage(store, 'u1', begin(), {
      tracks: [track()],
      days: [day({ platformId: SPOTIFY_B })],
    })
    await expect(store.complete('u1', spotify)).rejects.toMatchObject({ category: 'conflict' })
    const apple = await stage(store, 'u1', appleBegin(), {
      tracks: [track({ platformId: APPLE_A })],
      library: [libraryRow({ platformId: APPLE_B })],
    })
    await expect(store.complete('u1', apple)).rejects.toMatchObject({ category: 'conflict' })

    expect(await db.select().from(tracks)).toEqual([])
    expect(await db.select().from(userTracks)).toEqual([])
    expect((await runRow(db, spotify)).status).toBe('open')
    expect((await runRow(db, apple)).status).toBe('open')
  })

  it('rejects short or misnumbered chunks and leaves canonical tables untouched', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const store = createListeningImportStore(db, { now: () => now })

    const short = await store.begin('u1', begin({ expectedTracks: 2, expectedDays: 0 }))
    await store.putTracks('u1', short.importId, [track()])
    await expect(store.complete('u1', short.importId))
      .rejects.toMatchObject({ category: 'count_mismatch' })

    const gapped = await store.begin('u1', begin({ expectedTracks: 2, expectedDays: 0 }))
    await store.putTracks('u1', gapped.importId, [track(), track({ ordinal: 2, platformId: SPOTIFY_B })])
    await expect(store.complete('u1', gapped.importId))
      .rejects.toMatchObject({ category: 'count_mismatch' })

    expect(await db.select().from(tracks)).toEqual([])
    expect(await db.select().from(userTracks)).toEqual([])
    expect(await db.select().from(listeningDays)).toEqual([])
    expect((await runRow(db, gapped.importId)).status).toBe('open')
    expect((await db.select().from(userMusicSources))[0].lastImportedAt).toBeNull()
  })

  it('rolls back the whole publish when the commit hook fails', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const importId = await stage(createListeningImportStore(db, { now: () => now }), 'u1', accountBegin(), {
      tracks: [track()],
      library: [libraryRow()],
      artists: [artist()],
    })
    const failing = createListeningImportStore(db, {
      now: () => now,
      beforeCommit: () => { throw new ListeningImportError('internal') },
    })

    await expect(failing.complete('u1', importId)).rejects.toMatchObject({ category: 'internal' })
    expect(await db.select().from(tracks)).toEqual([])
    expect(await db.select().from(userTracks)).toEqual([])
    expect(await db.select().from(userArtistSeeds)).toEqual([])
    expect((await db.select().from(userMusicSources))[0].lastImportedAt).toBeNull()
    expect((await runRow(db, importId)).status).toBe('open')
  })

  it('raises enrich_priority for candidates only and never lowers it', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const store = createListeningImportStore(db, { now: () => now })
    const today = await dbToday(db)
    await db.insert(tracks).values({ spotifyId: SPOTIFY_C, title: 'Third', artist: 'Artist', enrichPriority: 9 })
    const recent = shiftDay(today, -1)

    await publish(store, 'u1', begin(), {
      tracks: [...twoTracks(), track({ ordinal: 2, platformId: SPOTIFY_C, title: 'Third' })],
      days: [
        day({ day: recent, plays: 5 }),
        day({ ordinal: 1, platformId: SPOTIFY_B, day: recent, plays: 1 }),
        day({ ordinal: 2, platformId: SPOTIFY_C, day: recent, plays: 1 }),
      ],
    })
    await publish(store, 'u1', accountBegin(), {
      tracks: [track({ platformId: SPOTIFY_B, title: 'Second' })],
      library: [libraryRow({ platformId: SPOTIFY_B })],
      artists: [artist()],
    })

    const priorities = new Map(
      (await db.select().from(tracks)).map((row) => [row.spotifyId, row.enrichPriority]),
    )
    expect(priorities.get(SPOTIFY_A)).toBe(6)
    expect(priorities.get(SPOTIFY_B)).toBe(2)
    expect(priorities.get(SPOTIFY_C)).toBe(9)
  })

  it('keeps live-sync titles on Apple upserts and corrected artists on Spotify upserts', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const store = createListeningImportStore(db, { now: () => now })
    await db.insert(tracks).values([
      { appleId: APPLE_A, title: 'Live Title', artist: 'Live Artist', artistSource: 'sync' },
      {
        spotifyId: SPOTIFY_A, title: 'Old', artist: 'Old Artist', artistSource: 'sync',
        album: 'Old Album', durationMs: 1,
      },
      { spotifyId: SPOTIFY_B, title: 'Old', artist: 'Credited', artistSource: 'reccobeats' },
      { spotifyId: SPOTIFY_C, title: 'Old', artist: 'Catalog Artist', artistSource: 'apple_catalog' },
    ])

    await publish(store, 'u1', appleBegin(), {
      tracks: [track({
        platformId: APPLE_A, title: 'Export Title', artist: 'Export Artist',
        album: 'Export Album', durationMs: 1_000,
      })],
    })
    await publish(store, 'u1', begin(), {
      tracks: [
        track({ title: 'New', artist: 'New Artist', album: 'New Album', durationMs: 2 }),
        track({ ordinal: 1, platformId: SPOTIFY_B, title: 'New', artist: 'New Artist', album: 'New Album' }),
        track({ ordinal: 2, platformId: SPOTIFY_C, title: 'New', artist: 'New Artist' }),
      ],
    })

    const rows = await db.select().from(tracks)
    expect(rows).toHaveLength(4)
    const byId = new Map(rows.map((row) => [row.appleId ?? row.spotifyId, row]))
    expect(byId.get(APPLE_A)).toMatchObject({
      title: 'Live Title', artist: 'Live Artist', artistSource: 'sync', album: 'Export Album', durationMs: 1_000,
    })
    expect(byId.get(SPOTIFY_A)).toMatchObject({
      title: 'New', artist: 'New Artist', artistSource: 'export', album: 'Old Album', durationMs: 1,
    })
    expect(byId.get(SPOTIFY_B)).toMatchObject({
      title: 'New', artist: 'Credited', artistSource: 'reccobeats', album: 'New Album',
    })
    expect(byId.get(SPOTIFY_C))
      .toMatchObject({ title: 'New', artist: 'Catalog Artist', artistSource: 'apple_catalog' })
  })

  it('hides other tenants and refuses runs that are not open', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedUser(db, 'u2')
    const store = createListeningImportStore(db, { now: () => now })
    const first = await store.begin('u1', begin({ expectedTracks: 0, expectedDays: 0 }))

    await expect(store.complete('u2', first.importId)).rejects.toMatchObject({ category: 'not_found' })
    await expect(store.complete('u1', UNKNOWN_IMPORT)).rejects.toMatchObject({ category: 'not_found' })

    const replacement = await store.begin('u1', begin({ expectedTracks: 0, expectedDays: 0 }))
    await expect(store.complete('u1', first.importId)).rejects.toMatchObject({ category: 'invalid_state' })
    const later = createListeningImportStore(db, {
      now: () => new Date(now.getTime() + 3 * 60 * 60 * 1_000),
    })
    await expect(later.complete('u1', replacement.importId))
      .rejects.toMatchObject({ category: 'invalid_state' })
    expect((await db.select().from(userMusicSources))[0].lastImportedAt).toBeNull()
  })
})
