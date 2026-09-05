import { and, eq } from 'drizzle-orm'
import { describe, expect, it } from 'vitest'
import { createApp } from '../../src/app'
import { tracks, userTracks, userTrackLibrarySources } from '../../src/db/schema'
import { createLibrarySyncStore } from '../../src/library/sync-store'
import { createListeningImportStore } from '../../src/listening/import-store'
import { createTestDb, type TestDb } from '../helpers/db'
import {
  accountBegin, appleBegin, begin, day, libraryRow, now, publish, seedUser,
  SPOTIFY_A, SPOTIFY_B, APPLE_A, APPLE_B, track,
} from '../helpers/listening-fixtures'

async function appleSync(db: TestDb, ids: string[], userId = 'u1') {
  const store = createLibrarySyncStore(db, { now: () => now })
  const { syncId } = await store.begin(userId, 'web_musickit', 'ng', ids.length)
  if (ids.length) await store.putSongs(userId, syncId, ids.map((id, ordinal) => ({
    ordinal, appleLibraryId: `i.${id}`, appleCatalogId: id,
    title: 'Song', artist: 'Artist', album: null, genre: null, releaseYear: null,
    explicit: null, playCount: null, lastPlayedAt: null, dateAdded: null,
  })))
  await store.complete(userId, syncId)
}

async function spotifyLikes(db: TestDb, ids: string[], userId = 'u1') {
  return publish(createListeningImportStore(db, { now: () => now }), userId, accountBegin(), {
    tracks: ids.map((platformId, ordinal) => track({ platformId, ordinal })),
    library: ids.map((platformId, ordinal) => libraryRow({ platformId, ordinal })),
  })
}

async function appleExport(db: TestDb, userId = 'u1') {
  return publish(createListeningImportStore(db, { now: () => now }), userId, appleBegin(), {
    tracks: [track({ platformId: APPLE_A })],
    library: [libraryRow({ platformId: APPLE_A })],
  })
}

async function savedIds(db: TestDb, userId = 'u1') {
  return (await db.select({ id: userTracks.trackId }).from(userTracks)
    .where(and(eq(userTracks.userId, userId), eq(userTracks.inLibrary, true))))
    .map((row) => row.id).sort()
}

async function dualTrack(db: TestDb) {
  const [row] = await db.insert(tracks).values({
    spotifyId: SPOTIFY_A, appleId: APPLE_A, title: 'Song', artist: 'Artist',
  }).returning()
  return row
}

describe('saved-library source ownership', () => {
  it.each(['apple_export', 'spotify_export'] as const)('keeps a dual-ID song when removing only %s', async (source) => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const row = await dualTrack(db)
    await appleExport(db)
    await spotifyLikes(db, [SPOTIFY_A])
    const store = createListeningImportStore(db)

    expect(await store.deleteSource('u1', source)).toMatchObject({ unlibraried: 0, deletedTracks: 0 })
    expect(await savedIds(db)).toEqual([row.id])
    const remaining = source === 'apple_export' ? 'spotify_export' : 'apple_export'
    expect(await store.deleteSource('u1', remaining)).toMatchObject({ unlibraried: 1, deletedTracks: 1 })
    expect(await savedIds(db)).toEqual([])
    expect(await db.select().from(tracks)).toHaveLength(1)
  })

  it('does not let Spotify history deletion claim Apple-export membership', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const row = await dualTrack(db)
    await appleExport(db)
    const store = createListeningImportStore(db)
    await publish(store, 'u1', begin(), { tracks: [track()], days: [day()] })
    expect(await store.deleteSource('u1', 'spotify_export')).toMatchObject({ unlibraried: 0, deletedTracks: 0 })
    expect(await savedIds(db)).toEqual([row.id])
  })

  it('removes only Spotify membership on re-import, preserving Apple ownership and summary retries', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const row = await dualTrack(db)
    await appleExport(db)
    await spotifyLikes(db, [SPOTIFY_A, SPOTIFY_B])
    const { importId, summary } = await spotifyLikes(db, [])
    expect(summary).toMatchObject({ likedRemoved: 1, likedRemovalSkipped: false })
    expect(await savedIds(db)).toEqual([row.id])
    expect(await createListeningImportStore(db).complete('u1', importId)).toEqual(summary)
  })

  it('reconciles Spotify-only likes even when a different Apple song is live-synced', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await appleSync(db, [APPLE_B])
    const before = await savedIds(db)
    await spotifyLikes(db, [SPOTIFY_A])
    expect((await spotifyLikes(db, [])).summary).toMatchObject({ likedRemoved: 1, likedRemovalSkipped: false })
    expect(await savedIds(db)).toEqual(before)
  })

  it('Apple snapshots remove only live membership and preserve Spotify and Apple exports', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const row = await dualTrack(db)
    await spotifyLikes(db, [SPOTIFY_A])
    await appleExport(db)
    await appleSync(db, [APPLE_A, APPLE_B])
    await appleSync(db, [])
    expect(await savedIds(db)).toEqual([row.id])
    await createListeningImportStore(db).deleteSource('u1', 'spotify_export')
    expect(await savedIds(db)).toEqual([row.id])
  })

  it('does not remove another listener or seeded tracks when the final owner leaves', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedUser(db, 'u2')
    const row = await dualTrack(db)
    await spotifyLikes(db, [SPOTIFY_A])
    await appleExport(db, 'u2')
    await db.update(userTracks).set({ seeded: true }).where(eq(userTracks.userId, 'u1'))
    expect(await createListeningImportStore(db).deleteSource('u1', 'spotify_export'))
      .toMatchObject({ unlibraried: 1, deletedTracks: 0 })
    expect(await savedIds(db, 'u2')).toEqual([row.id])
    expect(await db.select().from(userTracks).where(eq(userTracks.userId, 'u1')))
      .toMatchObject([{ seeded: true, inLibrary: false }])
  })

  it('preserves unattributed saved rows even after a provider ID is added', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const [row] = await db.insert(tracks).values({ appleId: APPLE_A, title: 'Song', artist: 'Artist' }).returning()
    await db.insert(userTracks).values({ userId: 'u1', trackId: row.id, inLibrary: true })
    await db.update(tracks).set({ spotifyId: SPOTIFY_A }).where(eq(tracks.id, row.id))
    await spotifyLikes(db, [SPOTIFY_A])
    await appleSync(db, [])
    await createListeningImportStore(db).deleteSource('u1', 'spotify_export')
    expect(await savedIds(db)).toEqual([row.id])
  })

  it('rolls membership back with an interrupted import publish', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await spotifyLikes(db, [SPOTIFY_A])
    const before = await savedIds(db)
    const sourcesBefore = await db.select().from(userTrackLibrarySources)
    const store = createListeningImportStore(db, { beforeCommit: () => { throw new Error('test-abort') } })
    await expect(publish(store, 'u1', accountBegin(), { tracks: [], library: [] })).rejects.toThrow('test-abort')
    expect(await savedIds(db)).toEqual(before)
    expect(await db.select().from(userTrackLibrarySources)).toEqual(sourcesBefore)
    expect(await createListeningImportStore(db).deleteSource('u1', 'spotify_export'))
      .toMatchObject({ unlibraried: 1, deletedTracks: 1 })
  })

  it('does not resurrect a legacy row removed by the old runtime after migration', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const row = await dualTrack(db)
    // Migration copied the old true flag, then the pre-upgrade writer removed it.
    await db.insert(userTracks).values({ userId: 'u1', trackId: row.id, inLibrary: false })
    await db.insert(userTrackLibrarySources).values({ userId: 'u1', trackId: row.id, source: 'legacy' })
    await spotifyLikes(db, [])
    expect(await savedIds(db)).toEqual([])
    expect(await db.select().from(userTrackLibrarySources)).toEqual([])
  })

  it('records legacy paged native ingest as Apple membership and remains additive', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const row = await dualTrack(db)
    await spotifyLikes(db, [SPOTIFY_A])
    const app = createApp({ db, auth: {
      handler: () => new Response('ok'), api: { getSession: async () => ({ user: { id: 'u1' } }) },
    } })
    for (const appleId of [APPLE_A, APPLE_B]) {
      const res = await app.request('http://x/ingest/library', {
        method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ songs: [{ appleId, title: 'Song', artist: 'Artist', playCount: 7 }] }),
      })
      expect(res.status).toBe(200)
    }
    await createListeningImportStore(db).deleteSource('u1', 'spotify_export')
    expect(await savedIds(db)).toContain(row.id)
    expect(await savedIds(db)).toHaveLength(2)
    await appleSync(db, [])
    expect(await savedIds(db)).toEqual([])
  })

  it('rolls back an Apple replacement before publishing its new source membership', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await appleSync(db, [APPLE_A])
    await spotifyLikes(db, [SPOTIFY_B])
    const before = await savedIds(db)
    const sourcesBefore = await db.select().from(userTrackLibrarySources)
    const store = createLibrarySyncStore(db, { beforeCommit: () => { throw new Error('test-abort') } })
    const { syncId } = await store.begin('u1', 'ios_native', 'ng', 0)
    await expect(store.complete('u1', syncId)).rejects.toThrow('test-abort')
    expect(await savedIds(db)).toEqual(before)
    expect(await db.select().from(userTrackLibrarySources)).toEqual(sourcesBefore)
  })

  it('preserves saved evidence when an Apple export omits a prior library row', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await appleExport(db)
    const before = await savedIds(db)
    await publish(createListeningImportStore(db), 'u1', appleBegin(), {
      tracks: [track({ platformId: APPLE_A })], days: [day({ platformId: APPLE_A })], library: [],
    })
    expect(await savedIds(db)).toEqual(before)
  })
})
