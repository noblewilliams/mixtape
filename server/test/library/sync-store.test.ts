import { and, eq } from 'drizzle-orm'
import { describe, expect, it } from 'vitest'
import {
  librarySyncRuns,
  librarySyncSongs,
  tracks,
  user,
  userMusicProfiles,
  userMusicSources,
  userRecentTrackObservations,
  userTracks,
} from '../../src/db/schema'
import type { LibrarySongSnapshot } from '../../src/library/contracts'
import {
  createLibrarySyncStore,
  LibrarySyncError,
} from '../../src/library/sync-store'
import { createTestDb, type TestDb } from '../helpers/db'

const now = new Date('2026-09-01T12:00:00.000Z')

const song = (over: Partial<LibrarySongSnapshot> = {}): LibrarySongSnapshot => ({
  ordinal: 0,
  appleLibraryId: 'i.library-1',
  appleCatalogId: 'catalog-1',
  title: 'Song',
  artist: 'Artist',
  album: 'Album',
  genre: 'Alternative',
  releaseYear: 2024,
  explicit: false,
  playCount: null,
  lastPlayedAt: null,
  dateAdded: 1_700_000_000_000,
  ...over,
})

async function seedUser(db: TestDb, id: string) {
  await db.insert(user).values({
    id,
    name: id,
    email: `${id}@example.com`,
    emailVerified: false,
    createdAt: now,
    updatedAt: now,
  })
}

describe('LibrarySyncStore', () => {
  it('publishes a complete web snapshot and records unknown play counts honestly', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const store = createLibrarySyncStore(db, { now: () => now })
    const { syncId } = await store.begin('u1', 'web_musickit', 'ng', 2, 1)
    await store.putSongs('u1', syncId, [
      song(),
      song({
        ordinal: 1,
        appleLibraryId: 'i.library-2',
        appleCatalogId: 'catalog-2',
        title: 'Second',
      }),
    ])
    await store.putRecentTracks('u1', syncId, ['catalog-2'])

    await expect(store.complete('u1', syncId)).resolves.toEqual({
      songs: 2,
      catalogResolved: 2,
      playCountsObserved: 0,
      recentTracks: 1,
    })
    expect(await db.select().from(tracks)).toHaveLength(2)
    expect(await db.select().from(userTracks)).toMatchObject([
      { inLibrary: true, playCount: 0, playCountObserved: false },
      { inLibrary: true, playCount: 0, playCountObserved: false },
    ])
    const [profile] = await db.select().from(userMusicProfiles)
    expect(profile.librarySyncedAt?.getTime()).toBe(now.getTime())
    expect(profile.appleStorefront).toBe('ng')
    expect(await db.select().from(userRecentTrackObservations)).toMatchObject([
      { userId: 'u1', source: 'web_musickit', rank: 0 },
    ])
  })

  it('preserves a known native count when a later web snapshot cannot observe it', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const store = createLibrarySyncStore(db, { now: () => now })
    const native = await store.begin('u1', 'ios_native', 'ng', 1)
    await store.putSongs('u1', native.syncId, [song({ playCount: 27, lastPlayedAt: 1_720_000_000_000 })])
    await store.complete('u1', native.syncId)

    const web = await store.begin('u1', 'web_musickit', 'ng', 1)
    await store.putSongs('u1', web.syncId, [song({ playCount: null, lastPlayedAt: null })])
    await store.complete('u1', web.syncId)

    const [saved] = await db.select().from(userTracks)
    expect(saved.playCount).toBe(27)
    expect(saved.playCountObserved).toBe(true)
    expect(saved.lastPlayedAt?.getTime()).toBe(1_720_000_000_000)
  })

  it('accepts exact chunk retries and rejects changed or colliding retries', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const store = createLibrarySyncStore(db, { now: () => now })
    const { syncId } = await store.begin('u1', 'web_musickit', 'ng', 1)
    await store.putSongs('u1', syncId, [song()])
    await store.putSongs('u1', syncId, [song()])
    expect((await db.select().from(librarySyncRuns))[0].receivedSongs).toBe(1)

    await expect(store.putSongs('u1', syncId, [song({ title: 'Changed' })]))
      .rejects.toMatchObject({ category: 'conflict' })
    await expect(store.putSongs('u1', syncId, [
      song(),
      song({ ordinal: 1, appleLibraryId: 'i.library-2' }),
    ])).rejects.toMatchObject({ category: 'conflict' })
  })

  it('soft-removes songs missing from a completed snapshot', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const store = createLibrarySyncStore(db, { now: () => now })
    const previous = await store.begin('u1', 'ios_native', 'ng', 1)
    await store.putSongs('u1', previous.syncId, [song({ appleCatalogId: 'old-catalog', playCount: 8 })])
    await store.complete('u1', previous.syncId)
    const { syncId } = await store.begin('u1', 'web_musickit', 'ng', 0)

    const first = await store.complete('u1', syncId)
    const second = await store.complete('u1', syncId)
    expect(second).toEqual(first)
    expect(first).toEqual({ songs: 0, catalogResolved: 0, playCountsObserved: 0, recentTracks: 0 })
    expect(await db.select().from(userTracks)).toMatchObject([
      { playCount: 8, playCountObserved: true, inLibrary: false },
    ])
  })

  it('replaces the prior web recent window only after completion', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const store = createLibrarySyncStore(db, { now: () => now })
    const first = await store.begin('u1', 'web_musickit', 'ng', 2, 2)
    await store.putSongs('u1', first.syncId, [
      song(),
      song({ ordinal: 1, appleLibraryId: 'i.library-2', appleCatalogId: 'catalog-2' }),
    ])
    await store.putRecentTracks('u1', first.syncId, ['catalog-2', 'catalog-1'])
    await store.complete('u1', first.syncId)

    const incomplete = await store.begin('u1', 'web_musickit', 'ng', 1, 1)
    await store.putSongs('u1', incomplete.syncId, [song()])
    expect(await db.select().from(userRecentTrackObservations).orderBy(userRecentTrackObservations.rank))
      .toMatchObject([{ rank: 0 }, { rank: 1 }])

    await store.putRecentTracks('u1', incomplete.syncId, ['catalog-1'])
    await store.complete('u1', incomplete.syncId)
    expect(await db.select().from(userRecentTrackObservations)).toMatchObject([
      { rank: 0, source: 'web_musickit' },
    ])
  })

  it('reports only recent tracks that resolve into the synced library', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const store = createLibrarySyncStore(db, { now: () => now })
    const { syncId } = await store.begin('u1', 'web_musickit', 'ng', 1, 1)
    await store.putSongs('u1', syncId, [song()])
    await store.putRecentTracks('u1', syncId, ['not-in-library'])

    await expect(store.complete('u1', syncId)).resolves.toMatchObject({ recentTracks: 0 })
    expect(await db.select().from(userRecentTrackObservations)).toEqual([])
  })

  it('rejects incomplete and non-contiguous snapshots without publishing', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const store = createLibrarySyncStore(db, { now: () => now })
    const { syncId } = await store.begin('u1', 'web_musickit', 'ng', 2)
    await store.putSongs('u1', syncId, [song({ ordinal: 1 })])

    await expect(store.complete('u1', syncId)).rejects.toMatchObject({ category: 'count_mismatch' })
    expect(await db.select().from(tracks)).toEqual([])
    expect((await db.select().from(userMusicProfiles))[0].librarySyncedAt).toBeNull()
  })

  it('registers the live Apple source when a sync completes', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const store = createLibrarySyncStore(db, { now: () => now })
    const first = await store.begin('u1', 'web_musickit', 'ng', 1)
    await store.putSongs('u1', first.syncId, [song()])
    await store.complete('u1', first.syncId)

    let sources = await db.select().from(userMusicSources)
    expect(sources).toMatchObject([{ userId: 'u1', source: 'apple_live', ledgerFrom: null, ledgerTo: null }])
    expect(sources[0].connectedAt.getTime()).toBe(now.getTime())
    expect(sources[0].lastImportedAt?.getTime()).toBe(now.getTime())

    const later = new Date(now.getTime() + 60_000)
    const laterStore = createLibrarySyncStore(db, { now: () => later })
    const second = await laterStore.begin('u1', 'web_musickit', 'ng', 1)
    await laterStore.putSongs('u1', second.syncId, [song()])
    await laterStore.complete('u1', second.syncId)

    sources = await db.select().from(userMusicSources)
    expect(sources).toHaveLength(1)
    expect(sources[0].connectedAt.getTime()).toBe(now.getTime())
    expect(sources[0].lastImportedAt?.getTime()).toBe(later.getTime())
    expect(sources[0].updatedAt.getTime()).toBe(later.getTime())
  })

  it('hides cross-tenant runs, expires replaced runs, and rejects expired writes', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedUser(db, 'u2')
    const store = createLibrarySyncStore(db, { now: () => now, ttlMs: 1 })
    const first = await store.begin('u1', 'web_musickit', 'ng', 1)
    await expect(store.putSongs('u2', first.syncId, [song()]))
      .rejects.toMatchObject({ category: 'not_found' })

    const second = await store.begin('u1', 'web_musickit', 'ng', 0)
    expect(second.syncId).not.toBe(first.syncId)
    expect(await db.select({ status: librarySyncRuns.status }).from(librarySyncRuns)
      .where(and(eq(librarySyncRuns.userId, 'u1'), eq(librarySyncRuns.id, first.syncId))))
      .toEqual([{ status: 'expired' }])

    const later = createLibrarySyncStore(db, { now: () => new Date(now.getTime() + 2) })
    await expect(later.putSongs('u1', second.syncId, [song()]))
      .rejects.toMatchObject({ category: 'invalid_state' })
  })

  it('rolls back canonical rows and profile time when completion fails', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const store = createLibrarySyncStore(db, { now: () => now })
    const { syncId } = await store.begin('u1', 'web_musickit', 'ng', 1)
    await store.putSongs('u1', syncId, [song()])
    const failing = createLibrarySyncStore(db, {
      now: () => now,
      beforeCommit: () => { throw new LibrarySyncError('internal') },
    })

    await expect(failing.complete('u1', syncId)).rejects.toMatchObject({ category: 'internal' })
    expect(await db.select().from(tracks)).toEqual([])
    expect(await db.select().from(userTracks)).toEqual([])
    expect((await db.select().from(userMusicProfiles))[0].librarySyncedAt).toBeNull()
    expect(await db.select().from(librarySyncSongs)).toHaveLength(1)
  })
})
