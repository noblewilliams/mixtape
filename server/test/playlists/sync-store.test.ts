import { and, eq } from 'drizzle-orm'
import { describe, expect, it } from 'vitest'
import {
  playlistEntries,
  playlistOrigins,
  playlistSyncEntries,
  playlistSyncPlaylists,
  playlistSyncRuns,
  tracks,
  user,
  userMusicProfiles,
  userPlaylists,
} from '../../src/db/schema'
import {
  PlaylistSyncError,
  createPlaylistSyncStore,
} from '../../src/playlists/sync-store'
import type { PlaylistEntrySnapshot, PlaylistSnapshot } from '../../src/playlists/contracts'
import { createTestDb, type TestDb } from '../helpers/db'
import { createPlaylistBrowseStore } from '../../src/playlists/browse-store'

const now = new Date('2026-08-31T12:00:00.000Z')
const SPOTIFY_ID_A = '4uLU6hMCjMI75M1A2tKUQC'
const SPOTIFY_ID_B = '7ouMYWpwJ422jRcDASZB7P'
const SPOTIFY_ID_C = '1301WleyT98MSxVHPZCA6M'
// Spotify playlists carry no platform id; the client keys them by fingerprint.
const KEY = 'c'.repeat(64)

const playlist = (over: Partial<PlaylistSnapshot> = {}): PlaylistSnapshot => ({
  ordinal: 0,
  appleLibraryId: 'p-1',
  appleCatalogId: null,
  name: 'Evening\nMix',
  description: 'Soft start\nLoud finish',
  curatorName: null,
  artworkUrlTemplate: null,
  artworkWidth: null,
  artworkHeight: null,
  artworkBgColor: 'a1b2c3',
  kind: 'user_shared',
  canEdit: false,
  appleDateAdded: null,
  appleLastModifiedAt: 1_788_200_000_000,
  sourceFingerprint: 'a'.repeat(64),
  entryCount: 2,
  ...over,
})

const entry = (over: Partial<PlaylistEntrySnapshot> = {}): PlaylistEntrySnapshot => ({
  position: 0,
  appleLibraryEntryId: 'entry-1',
  appleLibraryTrackId: 'library-track-1',
  appleCatalogId: null,
  spotifyId: null,
  isrcSnapshot: null,
  titleSnapshot: 'Song',
  artistSnapshot: 'Artist',
  albumSnapshot: null,
  durationMsSnapshot: 123_000,
  artworkUrlTemplateSnapshot: null,
  artworkWidthSnapshot: null,
  artworkHeightSnapshot: null,
  artworkBgColorSnapshot: '010203',
  ...over,
})

const spotifyEntry = (position: number, over: Partial<PlaylistEntrySnapshot> = {}) => entry({
  position,
  appleLibraryEntryId: `${KEY}:${position}`,
  appleLibraryTrackId: null,
  appleCatalogId: null,
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

describe('PlaylistSyncStore', () => {
  it('preserves origin through initial sync, rename, disappearance and reappearance', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await db.insert(playlistOrigins).values({ userId: 'u1', source: 'apple', libraryId: 'p-1', origin: 'mixtape' })
    const store = createPlaylistSyncStore(db, { now: () => now })
    const browse = createPlaylistBrowseStore(db)
    for (const name of ['Initial', 'Renamed', null, 'Returned']) {
      const run = await store.begin('u1', 'ng', name ? 1 : 0, 0)
      if (name) await store.putPlaylists('u1', run.syncId, [playlist({ name, entryCount: 0 })])
      await store.complete('u1', run.syncId)
      const view = await browse.list('u1', { status: 'all', limit: 10 })
      expect(view.playlists[0]).toMatchObject({ origin: 'mixtape', inLibrary: name !== null })
    }
  })
  it('publishes ordered duplicates and resolves catalog then unique ISRC', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const [catalogTrack, isrcTrack] = await db.insert(tracks).values([
      { appleId: 'catalog-1', isrc: 'USABC1234567', title: 'Catalog', artist: 'A' },
      { appleId: null, isrc: 'NGABC1234567', title: 'ISRC', artist: 'B' },
    ]).returning()
    const store = createPlaylistSyncStore(db, { now: () => now })
    const started = await store.begin('u1', 'ng', 1, 2)
    await store.putPlaylists('u1', started.syncId, [playlist()])
    await store.putEntries('u1', started.syncId, 'p-1', [
      entry({ appleCatalogId: 'catalog-1' }),
      entry({ position: 1, appleLibraryEntryId: 'entry-2', appleCatalogId: null, isrcSnapshot: 'NGABC1234567' }),
    ])

    await expect(store.complete('u1', started.syncId)).resolves.toEqual({
      playlists: 1,
      entries: 2,
      resolvedEntries: 2,
      unresolvedEntries: 0,
    })
    const [saved] = await db.select().from(userPlaylists)
    const savedEntries = await db.select().from(playlistEntries)
      .where(eq(playlistEntries.playlistId, saved.id))
      .orderBy(playlistEntries.position)
    expect(saved).toMatchObject({ name: 'Evening\nMix', artworkBgColor: 'a1b2c3', inLibrary: true })
    expect(savedEntries.map((row) => row.trackId)).toEqual([catalogTrack.id, isrcTrack.id])
    expect(savedEntries.map((row) => row.appleLibraryEntryId)).toEqual(['entry-1', 'entry-2'])
  })

  it('records the client capability source on the sync run', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const store = createPlaylistSyncStore(db, { now: () => now })
    const { syncId } = await store.begin('u1', 'ng', 0, 0, 'web_musickit')

    expect(await db.select({ source: playlistSyncRuns.source }).from(playlistSyncRuns)
      .where(eq(playlistSyncRuns.id, syncId))).toEqual([{ source: 'web_musickit' }])
  })

  it('accepts exact retries but rejects changed playlist and entry retries', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const store = createPlaylistSyncStore(db, { now: () => now })
    const { syncId } = await store.begin('u1', 'ng', 1, 1)
    const one = playlist({ entryCount: 1 })
    const firstEntry = entry()
    await store.putPlaylists('u1', syncId, [one])
    await store.putPlaylists('u1', syncId, [one])
    await store.putEntries('u1', syncId, 'p-1', [firstEntry])
    await store.putEntries('u1', syncId, 'p-1', [firstEntry])

    const [run] = await db.select().from(playlistSyncRuns).where(eq(playlistSyncRuns.id, syncId))
    expect([run.receivedPlaylists, run.receivedEntries]).toEqual([1, 1])
    await expect(store.putPlaylists('u1', syncId, [playlist({ entryCount: 1, name: 'Changed' })]))
      .rejects.toMatchObject({ category: 'conflict' })
    await expect(store.putEntries('u1', syncId, 'p-1', [entry({ titleSnapshot: 'Changed' })]))
      .rejects.toMatchObject({ category: 'conflict' })
  })

  it('preserves duplicate songs at different positions and leaves ambiguous ISRC unresolved', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await db.insert(tracks).values([
      { isrc: 'USABC1234567', title: 'One', artist: 'A' },
      { isrc: 'USABC1234567', title: 'Two', artist: 'B' },
    ])
    const store = createPlaylistSyncStore(db, { now: () => now })
    const { syncId } = await store.begin('u1', 'ng', 1, 2)
    await store.putPlaylists('u1', syncId, [playlist()])
    await store.putEntries('u1', syncId, 'p-1', [
      entry({ isrcSnapshot: 'USABC1234567' }),
      entry({ position: 1, appleLibraryEntryId: 'entry-2', isrcSnapshot: 'USABC1234567' }),
    ])

    const result = await store.complete('u1', syncId)
    expect(result).toMatchObject({ entries: 2, resolvedEntries: 0, unresolvedEntries: 2 })
    expect(await db.select().from(playlistEntries)).toHaveLength(2)
  })

  it('completes an empty snapshot and soft-removes the old playlist', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await db.insert(userMusicProfiles).values({ userId: 'u1', appleStorefront: 'ng' })
    await db.insert(userPlaylists).values({
      userId: 'u1', appleLibraryId: 'old', name: 'Old', kind: 'user',
      sourceFingerprint: 'b'.repeat(64), inLibrary: true,
    })
    const store = createPlaylistSyncStore(db, { now: () => now })
    const { syncId } = await store.begin('u1', 'ng', 0, 0)

    const first = await store.complete('u1', syncId)
    const second = await store.complete('u1', syncId)
    expect(second).toEqual(first)
    expect(first).toEqual({ playlists: 0, entries: 0, resolvedEntries: 0, unresolvedEntries: 0 })
    expect(await db.select().from(userPlaylists)).toMatchObject([{ inLibrary: false }])
    expect((await db.select().from(userMusicProfiles))[0].playlistsSyncedAt?.getTime()).toBe(now.getTime())
  })

  it('keeps the canonical playlist ID and trusted ownership across resyncs', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const store = createPlaylistSyncStore(db, { now: () => now })
    const first = await store.begin('u1', 'ng', 1, 0)
    await store.putPlaylists('u1', first.syncId, [playlist({ entryCount: 0 })])
    await store.complete('u1', first.syncId)
    const [created] = await db.select().from(userPlaylists)
    await db.update(userPlaylists).set({ isMixtapeOwned: true })
      .where(eq(userPlaylists.id, created.id))

    const second = await store.begin('u1', 'ng', 1, 0)
    await store.putPlaylists('u1', second.syncId, [playlist({ entryCount: 0, name: 'Renamed' })])
    await store.complete('u1', second.syncId)
    const [updated] = await db.select().from(userPlaylists)
    expect(updated).toMatchObject({ id: created.id, name: 'Renamed', isMixtapeOwned: true })
  })

  it('keeps canonical entry IDs across a reordered resync', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const store = createPlaylistSyncStore(db, { now: () => now })
    const first = await store.begin('u1', 'ng', 1, 2)
    await store.putPlaylists('u1', first.syncId, [playlist()])
    await store.putEntries('u1', first.syncId, 'p-1', [
      entry(),
      entry({ position: 1, appleLibraryEntryId: 'entry-2', titleSnapshot: 'Second' }),
    ])
    await store.complete('u1', first.syncId)
    const original = await db.select().from(playlistEntries)
    const ids = new Map(original.map((row) => [row.appleLibraryEntryId, row.id]))

    const second = await store.begin('u1', 'ng', 1, 2)
    await store.putPlaylists('u1', second.syncId, [playlist({ name: 'Reordered' })])
    await store.putEntries('u1', second.syncId, 'p-1', [
      entry({ appleLibraryEntryId: 'entry-2', titleSnapshot: 'Second updated' }),
      entry({ position: 1 }),
    ])
    await store.complete('u1', second.syncId)

    const reordered = await db.select().from(playlistEntries)
      .orderBy(playlistEntries.position)
    expect(reordered.map((row) => row.appleLibraryEntryId)).toEqual(['entry-2', 'entry-1'])
    expect(reordered.map((row) => row.id)).toEqual([
      ids.get('entry-2'),
      ids.get('entry-1'),
    ])
    expect(reordered[0].titleSnapshot).toBe('Second updated')
  })

  it('rejects count, position, ordinal, and duplicate entry-id mismatches', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const store = createPlaylistSyncStore(db, { now: () => now })
    const { syncId } = await store.begin('u1', 'ng', 1, 2)
    await store.putPlaylists('u1', syncId, [playlist({ ordinal: 1 })])
    await store.putEntries('u1', syncId, 'p-1', [
      entry(),
      entry({ position: 2, appleLibraryEntryId: 'entry-2' }),
    ])

    await expect(store.complete('u1', syncId)).rejects.toMatchObject({ category: 'count_mismatch' })
    expect(await db.select().from(userPlaylists)).toEqual([])

    const retry = await store.begin('u1', 'ng', 1, 2)
    await store.putPlaylists('u1', retry.syncId, [playlist()])
    await expect(store.putEntries('u1', retry.syncId, 'p-1', [
      entry(),
      entry({ position: 1, appleLibraryEntryId: 'entry-1' }),
    ])).rejects.toMatchObject({ category: 'conflict' })
  })

  it('hides cross-tenant runs and replaces an older open run', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedUser(db, 'u2')
    const store = createPlaylistSyncStore(db, { now: () => now })
    const first = await store.begin('u1', 'ng', 0, 0)
    await expect(store.putPlaylists('u2', first.syncId, [playlist({ entryCount: 0 })]))
      .rejects.toMatchObject({ category: 'not_found' })
    const second = await store.begin('u1', 'ng', 0, 0)
    expect(second.syncId).not.toBe(first.syncId)
    expect(await db.select({ status: playlistSyncRuns.status }).from(playlistSyncRuns)
      .where(and(eq(playlistSyncRuns.userId, 'u1'), eq(playlistSyncRuns.id, first.syncId))))
      .toEqual([{ status: 'expired' }])
  })

  it('serializes simultaneous starts to one open run', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const store = createPlaylistSyncStore(db, { now: () => now })

    await Promise.all([
      store.begin('u1', 'ng', 0, 0),
      store.begin('u1', 'ng', 0, 0),
    ])

    const runs = await db.select().from(playlistSyncRuns)
      .where(eq(playlistSyncRuns.userId, 'u1'))
    expect(runs.filter((run) => run.status === 'open')).toHaveLength(1)
    expect(runs.filter((run) => run.status === 'expired')).toHaveLength(1)
  })

  it('rejects expired writes and completion', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const store = createPlaylistSyncStore(db, { now: () => now, ttlMs: 1 })
    const { syncId } = await store.begin('u1', 'ng', 0, 0)
    const later = createPlaylistSyncStore(db, { now: () => new Date(now.getTime() + 2) })
    await expect(later.complete('u1', syncId)).rejects.toMatchObject({ category: 'invalid_state' })
  })

  it('rolls back canonical publish and profile time when completion fails', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const initial = createPlaylistSyncStore(db, { now: () => now })
    const { syncId } = await initial.begin('u1', 'ng', 1, 0)
    await initial.putPlaylists('u1', syncId, [playlist({ entryCount: 0 })])
    const failing = createPlaylistSyncStore(db, {
      now: () => now,
      beforeCommit: () => { throw new PlaylistSyncError('internal') },
    })

    await expect(failing.complete('u1', syncId)).rejects.toMatchObject({ category: 'internal' })
    expect(await db.select().from(userPlaylists)).toEqual([])
    expect((await db.select().from(userMusicProfiles))[0].playlistsSyncedAt).toBeNull()
    expect(await db.select().from(playlistSyncPlaylists)).toHaveLength(1)
    expect(await db.select().from(playlistSyncEntries)).toHaveLength(0)
  })


  it('publishes a Spotify export run without a storefront and links entries by Spotify id', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const [spotifyTrack, isrcTrack] = await db.insert(tracks).values([
      { spotifyId: SPOTIFY_ID_A, isrc: 'USABC1234567', title: 'Spotify', artist: 'A' },
      { spotifyId: null, isrc: 'GBABC1234567', title: 'ISRC', artist: 'B' },
    ]).returning()
    const store = createPlaylistSyncStore(db, { now: () => now })
    const started = await store.begin('u1', null, 1, 4, 'spotify_export')
    await store.putPlaylists('u1', started.syncId, [playlist({
      appleLibraryId: KEY, kind: 'user', canEdit: false, entryCount: 4,
    })])
    await store.putEntries('u1', started.syncId, KEY, [
      spotifyEntry(0, { spotifyId: SPOTIFY_ID_A }),
      // Same track again; the Spotify id outranks a matching ISRC.
      spotifyEntry(1, { spotifyId: SPOTIFY_ID_A, isrcSnapshot: 'GBABC1234567' }),
      spotifyEntry(2, { spotifyId: SPOTIFY_ID_B, isrcSnapshot: 'GBABC1234567' }),
      spotifyEntry(3, { spotifyId: null }),
    ])

    await expect(store.complete('u1', started.syncId)).resolves.toEqual({
      playlists: 1, entries: 4, resolvedEntries: 3, unresolvedEntries: 1,
    })
    const [run] = await db.select().from(playlistSyncRuns)
    expect(run).toMatchObject({ source: 'spotify_export', appleStorefront: null, status: 'completed' })
    const [saved] = await db.select().from(userPlaylists)
    expect(saved).toMatchObject({
      appleLibraryId: KEY, source: 'spotify_export', kind: 'user', canEdit: false, inLibrary: true,
    })
    const savedEntries = await db.select().from(playlistEntries)
      .where(eq(playlistEntries.playlistId, saved.id))
      .orderBy(playlistEntries.position)
    expect(savedEntries.map((row) => row.appleLibraryEntryId))
      .toEqual([`${KEY}:0`, `${KEY}:1`, `${KEY}:2`, `${KEY}:3`])
    expect(savedEntries.map((row) => row.trackId))
      .toEqual([spotifyTrack.id, spotifyTrack.id, isrcTrack.id, null])
    expect(savedEntries.map((row) => row.spotifyId))
      .toEqual([SPOTIFY_ID_A, SPOTIFY_ID_A, SPOTIFY_ID_B, null])
    const [profile] = await db.select().from(userMusicProfiles)
    expect(profile.appleStorefront).toBeNull()
    expect(profile.playlistsSyncedAt?.getTime()).toBe(now.getTime())
  })

  it('re-links and re-snapshots Spotify entries by position slot on a shifted resync', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const [spotifyTrack, isrcTrack, newTrack] = await db.insert(tracks).values([
      { spotifyId: SPOTIFY_ID_A, isrc: 'USABC1234567', title: 'Spotify', artist: 'A' },
      { spotifyId: null, isrc: 'GBABC1234567', title: 'ISRC', artist: 'B' },
      { spotifyId: SPOTIFY_ID_C, isrc: null, title: 'New', artist: 'C' },
    ]).returning()
    const store = createPlaylistSyncStore(db, { now: () => now })
    const spotifyPlaylist = (entryCount: number) =>
      playlist({ appleLibraryId: KEY, kind: 'user', canEdit: false, entryCount })
    const first = await store.begin('u1', null, 1, 4, 'spotify_export')
    await store.putPlaylists('u1', first.syncId, [spotifyPlaylist(4)])
    await store.putEntries('u1', first.syncId, KEY, [
      spotifyEntry(0, { spotifyId: SPOTIFY_ID_A, titleSnapshot: 'T0' }),
      spotifyEntry(1, { spotifyId: SPOTIFY_ID_A, isrcSnapshot: 'GBABC1234567', titleSnapshot: 'T1' }),
      spotifyEntry(2, { spotifyId: SPOTIFY_ID_B, isrcSnapshot: 'GBABC1234567', titleSnapshot: 'T2' }),
      spotifyEntry(3, { spotifyId: null, titleSnapshot: 'T3' }),
    ])
    await store.complete('u1', first.syncId)
    const before = await db.select().from(playlistEntries).orderBy(playlistEntries.position)
    expect(before.map((row) => row.trackId))
      .toEqual([spotifyTrack.id, spotifyTrack.id, isrcTrack.id, null])

    // The listener prepends a song. Spotify entry ids are `key:position`, so
    // every existing id now names the song that sat one slot earlier: the
    // canonical row per slot survives, but its Spotify id, snapshot, and link
    // all have to move with the song.
    const second = await store.begin('u1', null, 1, 5, 'spotify_export')
    await store.putPlaylists('u1', second.syncId, [spotifyPlaylist(5)])
    await store.putEntries('u1', second.syncId, KEY, [
      spotifyEntry(0, { spotifyId: SPOTIFY_ID_C, titleSnapshot: 'New' }),
      spotifyEntry(1, { spotifyId: SPOTIFY_ID_A, titleSnapshot: 'T0' }),
      spotifyEntry(2, { spotifyId: SPOTIFY_ID_A, isrcSnapshot: 'GBABC1234567', titleSnapshot: 'T1' }),
      spotifyEntry(3, { spotifyId: SPOTIFY_ID_B, isrcSnapshot: 'GBABC1234567', titleSnapshot: 'T2' }),
      spotifyEntry(4, { spotifyId: null, titleSnapshot: 'T3' }),
    ])
    await expect(store.complete('u1', second.syncId)).resolves.toEqual({
      playlists: 1, entries: 5, resolvedEntries: 4, unresolvedEntries: 1,
    })

    const after = await db.select().from(playlistEntries).orderBy(playlistEntries.position)
    expect(after).toHaveLength(before.length + 1)
    expect(after.map((row) => row.position)).toEqual([0, 1, 2, 3, 4])
    expect(after.map((row) => row.appleLibraryEntryId))
      .toEqual([`${KEY}:0`, `${KEY}:1`, `${KEY}:2`, `${KEY}:3`, `${KEY}:4`])
    expect(after.slice(0, 4).map((row) => row.id)).toEqual(before.map((row) => row.id))
    expect(before.map((row) => row.id)).not.toContain(after[4].id)
    expect(after.map((row) => row.spotifyId))
      .toEqual([SPOTIFY_ID_C, SPOTIFY_ID_A, SPOTIFY_ID_A, SPOTIFY_ID_B, null])
    expect(after.map((row) => row.titleSnapshot)).toEqual(['New', 'T0', 'T1', 'T2', 'T3'])
    expect(after.map((row) => row.isrcSnapshot))
      .toEqual([null, null, 'GBABC1234567', 'GBABC1234567', null])
    // Slot 2 moves from the ISRC fallback to the Spotify id; slot 3 from
    // name-only to the ISRC fallback.
    expect(after.map((row) => row.trackId))
      .toEqual([newTrack.id, spotifyTrack.id, spotifyTrack.id, isrcTrack.id, null])
    expect((await db.select().from(userMusicProfiles))[0].appleStorefront).toBeNull()
  })

  it('links a catalog id ahead of a Spotify id that names a different track', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const [catalogTrack, spotifyTrack] = await db.insert(tracks).values([
      { appleId: 'catalog-1', title: 'Catalog', artist: 'A' },
      { spotifyId: SPOTIFY_ID_A, title: 'Spotify', artist: 'B' },
    ]).returning()
    const store = createPlaylistSyncStore(db, { now: () => now })
    const one = playlist({ entryCount: 1 })
    const first = await store.begin('u1', 'ng', 1, 1)
    await store.putPlaylists('u1', first.syncId, [one])
    await store.putEntries('u1', first.syncId, 'p-1', [entry({ spotifyId: SPOTIFY_ID_A })])
    await store.complete('u1', first.syncId)
    expect((await db.select().from(playlistEntries)).map((row) => row.trackId))
      .toEqual([spotifyTrack.id])

    // The same entry gains a catalog pin on resync: the Apple row wins on the
    // update path just as it does on insert.
    const second = await store.begin('u1', 'ng', 1, 1)
    await store.putPlaylists('u1', second.syncId, [one])
    await store.putEntries('u1', second.syncId, 'p-1', [
      entry({ appleCatalogId: 'catalog-1', spotifyId: SPOTIFY_ID_A }),
    ])
    await expect(store.complete('u1', second.syncId))
      .resolves.toMatchObject({ entries: 1, resolvedEntries: 1 })
    expect((await db.select().from(playlistEntries)).map((row) => row.trackId))
      .toEqual([catalogTrack.id])

    const third = await store.begin('u1', 'ng', 1, 1)
    await store.putPlaylists('u1', third.syncId, [playlist({ entryCount: 1, appleLibraryId: 'p-2' })])
    await store.putEntries('u1', third.syncId, 'p-2', [
      entry({ appleLibraryEntryId: 'entry-9', appleCatalogId: 'catalog-1', spotifyId: SPOTIFY_ID_A }),
    ])
    await store.complete('u1', third.syncId)
    const inserted = await db.select().from(playlistEntries)
      .where(eq(playlistEntries.appleLibraryEntryId, 'entry-9'))
    expect(inserted.map((row) => row.trackId)).toEqual([catalogTrack.id])
  })

  it('rejects a null storefront for Apple sources without opening a run', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const store = createPlaylistSyncStore(db, { now: () => now })
    await expect(store.begin('u1', null, 0, 0))
      .rejects.toMatchObject({ category: 'invalid_storefront' })
    await expect(store.begin('u1', null, 0, 0, 'web_musickit'))
      .rejects.toMatchObject({ category: 'invalid_storefront' })
    expect(await db.select().from(playlistSyncRuns)).toEqual([])
    expect(await db.select().from(userMusicProfiles)).toEqual([])
  })

  it('rejects an entry retry whose Spotify id changed', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const store = createPlaylistSyncStore(db, { now: () => now })
    const { syncId } = await store.begin('u1', null, 1, 1, 'spotify_export')
    await store.putPlaylists('u1', syncId, [playlist({ appleLibraryId: KEY, kind: 'user', entryCount: 1 })])
    await store.putEntries('u1', syncId, KEY, [spotifyEntry(0, { spotifyId: SPOTIFY_ID_A })])
    await store.putEntries('u1', syncId, KEY, [spotifyEntry(0, { spotifyId: SPOTIFY_ID_A })])
    await expect(store.putEntries('u1', syncId, KEY, [spotifyEntry(0, { spotifyId: SPOTIFY_ID_B })]))
      .rejects.toMatchObject({ category: 'conflict' })
  })

  it('scopes soft-removal and the profile storefront to the run source', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const store = createPlaylistSyncStore(db, { now: () => now })
    const apple = await store.begin('u1', 'ng', 1, 0)
    await store.putPlaylists('u1', apple.syncId, [playlist({ entryCount: 0 })])
    await store.complete('u1', apple.syncId)
    const spotify = await store.begin('u1', null, 1, 0, 'spotify_export')
    await store.putPlaylists('u1', spotify.syncId, [
      playlist({ appleLibraryId: KEY, kind: 'user', entryCount: 0 }),
    ])
    await store.complete('u1', spotify.syncId)
    const inLibraryBySource = async () => Object.fromEntries(
      (await db.select().from(userPlaylists)).map((row) => [row.source, row.inLibrary]),
    )
    expect(await inLibraryBySource()).toEqual({ apple: true, spotify_export: true })
    expect((await db.select().from(userMusicProfiles))[0].appleStorefront).toBe('ng')

    const emptyApple = await store.begin('u1', 'ng', 0, 0)
    await store.complete('u1', emptyApple.syncId)
    expect(await inLibraryBySource()).toEqual({ apple: false, spotify_export: true })

    const emptySpotify = await store.begin('u1', null, 0, 0, 'spotify_export')
    await store.complete('u1', emptySpotify.syncId)
    expect(await inLibraryBySource()).toEqual({ apple: false, spotify_export: false })
    expect((await db.select().from(userMusicProfiles))[0].appleStorefront).toBe('ng')
  })
})
