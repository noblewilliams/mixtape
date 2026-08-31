import { describe, expect, it } from 'vitest'
import { eq } from 'drizzle-orm'
import { createTestDb } from '../helpers/db'
import {
  playlistEntries,
  playlistSyncEntries,
  playlistSyncPlaylists,
  playlistSyncRuns,
  tracks,
  user,
  userMusicProfiles,
  userPlaylists,
} from '../../src/db/schema'

async function insertUser(
  db: Awaited<ReturnType<typeof createTestDb>>,
  id: string,
) {
  await db.insert(user).values({
    id,
    name: 'Listener',
    email: `${id}@example.com`,
    emailVerified: false,
    createdAt: new Date(),
    updatedAt: new Date(),
  })
}

describe('playlist snapshot schema', () => {
  it('stores a user music profile with nullable sync timestamps', async () => {
    const db = await createTestDb()
    await insertUser(db, 'profile-user')

    const [profile] = await db
      .insert(userMusicProfiles)
      .values({ userId: 'profile-user', appleStorefront: 'ng' })
      .returning()

    expect(profile).toMatchObject({
      userId: 'profile-user',
      appleStorefront: 'ng',
      librarySyncedAt: null,
      playlistsSyncedAt: null,
    })
    expect(profile.createdAt).toBeInstanceOf(Date)
    expect(profile.updatedAt).toBeInstanceOf(Date)
  })

  it.each(['NG', 'n', 'nga', 'n1', ' ng'])('rejects invalid storefront %j', async (storefront) => {
    const db = await createTestDb()
    await insertUser(db, `storefront-${storefront}`)

    await expect(
      db.insert(userMusicProfiles).values({
        userId: `storefront-${storefront}`,
        appleStorefront: storefront,
      }),
    ).rejects.toThrow()
  })

  it('scopes Apple playlist IDs per user and supports soft removal', async () => {
    const db = await createTestDb()
    await insertUser(db, 'playlist-a')
    await insertUser(db, 'playlist-b')

    const base = {
      appleLibraryId: 'library-playlist-1',
      name: 'Evening',
      kind: 'user_shared' as const,
      sourceFingerprint: 'f'.repeat(64),
    }
    const [first] = await db
      .insert(userPlaylists)
      .values({ userId: 'playlist-a', ...base })
      .returning()
    await db.insert(userPlaylists).values({ userId: 'playlist-b', ...base })

    expect(first).toMatchObject({
      canEdit: false,
      isMixtapeOwned: false,
      inLibrary: true,
      artworkUrlTemplate: null,
      artworkBgColor: null,
    })
    await expect(
      db.insert(userPlaylists).values({ userId: 'playlist-a', ...base }),
    ).rejects.toThrow()

    const [removed] = await db
      .update(userPlaylists)
      .set({ inLibrary: false })
      .where(eq(userPlaylists.id, first.id))
      .returning()
    expect(removed.inLibrary).toBe(false)
  })

  it.each([
    { artworkBgColor: '#aabbcc' },
    { artworkBgColor: 'AABBCC' },
    { artworkWidth: 0 },
    { artworkHeight: -1 },
  ])('rejects invalid playlist artwork metadata: %j', async (artwork) => {
    const db = await createTestDb()
    await insertUser(db, `artwork-${JSON.stringify(artwork)}`)

    await expect(
      db.insert(userPlaylists).values({
        userId: `artwork-${JSON.stringify(artwork)}`,
        appleLibraryId: 'artwork-playlist',
        name: 'Artwork',
        kind: 'unknown',
        sourceFingerprint: 'a'.repeat(64),
        ...artwork,
      }),
    ).rejects.toThrow()
  })

  it('keeps playlist background colour without an artwork URL or dimensions', async () => {
    const db = await createTestDb()
    await insertUser(db, 'colour-only-user')

    const [playlist] = await db
      .insert(userPlaylists)
      .values({
        userId: 'colour-only-user',
        appleLibraryId: 'colour-only-playlist',
        name: 'Colour only',
        kind: 'external',
        sourceFingerprint: '9'.repeat(64),
        artworkBgColor: 'a1b2c3',
      })
      .returning()

    expect(playlist).toMatchObject({
      artworkUrlTemplate: null,
      artworkWidth: null,
      artworkHeight: null,
      artworkBgColor: 'a1b2c3',
    })
  })

  it('preserves duplicate songs at distinct positions and rejects duplicate slots', async () => {
    const db = await createTestDb()
    await insertUser(db, 'entries-user')
    const [playlist] = await db
      .insert(userPlaylists)
      .values({
        userId: 'entries-user',
        appleLibraryId: 'entries-playlist',
        name: 'Duplicates',
        kind: 'user',
        sourceFingerprint: 'b'.repeat(64),
      })
      .returning()
    const [track] = await db
      .insert(tracks)
      .values({ appleId: 'duplicate-track', title: 'Song', artist: 'Artist' })
      .returning()
    const duplicate = {
      playlistId: playlist.id,
      trackId: track.id,
      appleLibraryEntryId: 'entry-1',
      appleLibraryTrackId: 'library-track-1',
      titleSnapshot: 'Song',
      artistSnapshot: 'Artist',
    }

    await db.insert(playlistEntries).values([
      { ...duplicate, position: 0 },
      { ...duplicate, appleLibraryEntryId: 'entry-2', position: 1 },
    ])
    expect(await db.select().from(playlistEntries)).toHaveLength(2)

    await expect(
      db.insert(playlistEntries).values({
        ...duplicate,
        appleLibraryEntryId: 'entry-3',
        position: 1,
      }),
    ).rejects.toThrow()
  })

  it.each([
    { position: -1, durationMsSnapshot: 1000 },
    { position: 0, durationMsSnapshot: -1 },
  ])('rejects negative playlist entry values: %j', async (entry) => {
    const db = await createTestDb()
    await insertUser(db, `entry-${entry.position}-${entry.durationMsSnapshot}`)
    const [playlist] = await db
      .insert(userPlaylists)
      .values({
        userId: `entry-${entry.position}-${entry.durationMsSnapshot}`,
        appleLibraryId: 'invalid-entry-playlist',
        name: 'Invalid',
        kind: 'unknown',
        sourceFingerprint: 'c'.repeat(64),
      })
      .returning()

    await expect(
      db.insert(playlistEntries).values({
        playlistId: playlist.id,
        appleLibraryEntryId: 'invalid-entry',
        titleSnapshot: 'Song',
        artistSnapshot: 'Artist',
        ...entry,
      }),
    ).rejects.toThrow()
  })

  it('allows one open sync per user and accepts an empty snapshot', async () => {
    const db = await createTestDb()
    await insertUser(db, 'sync-user')
    const run = {
      userId: 'sync-user',
      status: 'open' as const,
      appleStorefront: 'ng',
      expectedPlaylists: 0,
      expectedEntries: 0,
      expiresAt: new Date('2026-09-01T00:00:00Z'),
    }

    const [created] = await db.insert(playlistSyncRuns).values(run).returning()
    expect(created).toMatchObject({
      receivedPlaylists: 0,
      receivedEntries: 0,
      resultPlaylists: null,
      resultEntries: null,
      resultResolvedEntries: null,
      resultUnresolvedEntries: null,
    })
    await expect(db.insert(playlistSyncRuns).values(run)).rejects.toThrow()

    await db
      .update(playlistSyncRuns)
      .set({ status: 'completed', completedAt: new Date() })
      .where(eq(playlistSyncRuns.id, created.id))
    await expect(db.insert(playlistSyncRuns).values(run)).resolves.toBeDefined()
  })

  it.each([
    { expectedPlaylists: -1, expectedEntries: 0 },
    { expectedPlaylists: 0, expectedEntries: -1 },
  ])('rejects negative sync expectations: %j', async (counts) => {
    const db = await createTestDb()
    const userId = `negative-sync-${counts.expectedPlaylists}-${counts.expectedEntries}`
    await insertUser(db, userId)

    await expect(
      db.insert(playlistSyncRuns).values({
        userId,
        status: 'open',
        appleStorefront: 'ng',
        expiresAt: new Date('2026-09-01T00:00:00Z'),
        ...counts,
      }),
    ).rejects.toThrow()
  })

  it('enforces typed staging order and playlist membership', async () => {
    const db = await createTestDb()
    await insertUser(db, 'staging-user')
    const [run] = await db
      .insert(playlistSyncRuns)
      .values({
        userId: 'staging-user',
        status: 'open',
        appleStorefront: 'ng',
        expectedPlaylists: 1,
        expectedEntries: 1,
        expiresAt: new Date('2026-09-01T00:00:00Z'),
      })
      .returning()
    await db.insert(playlistSyncPlaylists).values({
      syncId: run.id,
      ordinal: 0,
      appleLibraryId: 'staged-playlist',
      name: 'Staged',
      kind: 'user',
      sourceFingerprint: 'd'.repeat(64),
      entryCount: 1,
    })
    await db.insert(playlistSyncEntries).values({
      syncId: run.id,
      applePlaylistId: 'staged-playlist',
      position: 0,
      appleLibraryEntryId: 'staged-entry',
      titleSnapshot: 'Song',
      artistSnapshot: 'Artist',
    })

    await expect(
      db.insert(playlistSyncEntries).values({
        syncId: run.id,
        applePlaylistId: 'missing-playlist',
        position: 0,
        appleLibraryEntryId: 'orphan-entry',
        titleSnapshot: 'Song',
        artistSnapshot: 'Artist',
      }),
    ).rejects.toThrow()
    await expect(
      db.insert(playlistSyncPlaylists).values({
        syncId: run.id,
        ordinal: 0,
        appleLibraryId: 'same-ordinal',
        name: 'Duplicate ordinal',
        kind: 'unknown',
        sourceFingerprint: 'e'.repeat(64),
        entryCount: 0,
      }),
    ).rejects.toThrow()
  })

  it('cascades user deletion through canonical and staged playlist rows', async () => {
    const db = await createTestDb()
    await insertUser(db, 'cascade-user')
    await db
      .insert(userMusicProfiles)
      .values({ userId: 'cascade-user', appleStorefront: 'ng' })
    const [playlist] = await db
      .insert(userPlaylists)
      .values({
        userId: 'cascade-user',
        appleLibraryId: 'cascade-playlist',
        name: 'Cascade',
        kind: 'unknown',
        sourceFingerprint: 'f'.repeat(64),
      })
      .returning()
    await db.insert(playlistEntries).values({
      playlistId: playlist.id,
      position: 0,
      appleLibraryEntryId: 'cascade-entry',
      titleSnapshot: 'Song',
      artistSnapshot: 'Artist',
    })
    const [run] = await db
      .insert(playlistSyncRuns)
      .values({
        userId: 'cascade-user',
        status: 'open',
        appleStorefront: 'ng',
        expectedPlaylists: 1,
        expectedEntries: 0,
        expiresAt: new Date('2026-09-01T00:00:00Z'),
      })
      .returning()
    await db.insert(playlistSyncPlaylists).values({
      syncId: run.id,
      ordinal: 0,
      appleLibraryId: 'cascade-staged-playlist',
      name: 'Staged',
      kind: 'unknown',
      sourceFingerprint: 'a'.repeat(64),
      entryCount: 0,
    })

    await db.delete(user).where(eq(user.id, 'cascade-user'))

    expect(await db.select().from(userMusicProfiles)).toEqual([])
    expect(await db.select().from(userPlaylists)).toEqual([])
    expect(await db.select().from(playlistEntries)).toEqual([])
    expect(await db.select().from(playlistSyncRuns)).toEqual([])
    expect(await db.select().from(playlistSyncPlaylists)).toEqual([])
    expect(await db.select().from(playlistSyncEntries)).toEqual([])
  })

  it('nulls a resolved track without deleting the playlist entry snapshot', async () => {
    const db = await createTestDb()
    await insertUser(db, 'track-delete-user')
    const [playlist] = await db
      .insert(userPlaylists)
      .values({
        userId: 'track-delete-user',
        appleLibraryId: 'track-delete-playlist',
        name: 'Track deletion',
        kind: 'unknown',
        sourceFingerprint: '8'.repeat(64),
      })
      .returning()
    const [track] = await db
      .insert(tracks)
      .values({ appleId: 'track-delete', title: 'Song', artist: 'Artist' })
      .returning()
    await db.insert(playlistEntries).values({
      playlistId: playlist.id,
      position: 0,
      trackId: track.id,
      appleLibraryEntryId: 'track-delete-entry',
      titleSnapshot: 'Song',
      artistSnapshot: 'Artist',
    })

    await db.delete(tracks).where(eq(tracks.id, track.id))

    const [entry] = await db.select().from(playlistEntries)
    expect(entry).toMatchObject({ trackId: null, titleSnapshot: 'Song', artistSnapshot: 'Artist' })
  })
})
