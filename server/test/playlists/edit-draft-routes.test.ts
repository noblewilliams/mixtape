import { describe, expect, it } from 'vitest'
import { createApp, type AuthLike } from '../../src/app'
import {
  playlistEditDraftEntries,
  playlistEditDraftEvents,
  playlistEditDrafts,
  playlistEntries,
  tracks,
  user,
  userMusicProfiles,
  userPlaylists,
} from '../../src/db/schema'
import { createTestDb, type TestDb } from '../helpers/db'

const FINGERPRINT = 'a'.repeat(64)
const authFor = (id: string | null): AuthLike => ({
  handler: () => new Response('ok'),
  api: { getSession: async () => id ? { user: { id } } : null },
})

async function seedUser(db: TestDb, id: string) {
  await db.insert(user).values({ id, name: id, email: `${id}@example.com` })
  await db.insert(userMusicProfiles).values({ userId: id, appleStorefront: 'ng' })
}

async function seedPlaylist(db: TestDb, userId: string, libraryId: string) {
  const [playlist] = await db.insert(userPlaylists).values({
    userId,
    appleLibraryId: libraryId,
    name: 'Source playlist',
    kind: 'user',
    sourceFingerprint: FINGERPRINT,
  }).returning()
  const [track] = await db.insert(tracks).values({
    appleId: `${libraryId}-catalog-a`,
    title: 'Duplicate',
    artist: 'Artist',
  }).returning()
  await db.insert(playlistEntries).values([
    {
      playlistId: playlist.id,
      position: 0,
      trackId: track.id,
      appleLibraryEntryId: `${libraryId}-entry-a`,
      appleCatalogId: track.appleId,
      titleSnapshot: 'Duplicate',
      artistSnapshot: 'Artist',
    },
    {
      playlistId: playlist.id,
      position: 1,
      trackId: track.id,
      appleLibraryEntryId: `${libraryId}-entry-b`,
      appleCatalogId: track.appleId,
      titleSnapshot: 'Duplicate',
      artistSnapshot: 'Artist',
    },
    {
      playlistId: playlist.id,
      position: 2,
      appleLibraryEntryId: `${libraryId}-entry-local`,
      appleLibraryTrackId: `${libraryId}-local`,
      titleSnapshot: 'Local only',
      artistSnapshot: 'Artist',
    },
  ])
  return playlist
}

function request(
  db: TestDb,
  userId: string | null,
  path: string,
  method = 'GET',
  body?: unknown,
) {
  return createApp({ db, auth: authFor(userId) }).request(`http://x${path}`, {
    method,
    ...(body === undefined ? {} : {
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    }),
  })
}

describe('playlist edit draft routes', () => {
  it('creates and resumes one exact draft with duplicates and unresolved entries', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const playlist = await seedPlaylist(db, 'u1', 'p1')

    const first = await request(db, 'u1', `/playlists/${playlist.id}/edit-draft`, 'POST')
    expect(first.status).toBe(201)
    const body = await first.json() as any
    expect(body.draft).toMatchObject({
      sourcePlaylistId: playlist.id,
      status: 'active',
      version: 0,
      sourceType: 'apple',
      baseSourceFingerprint: FINGERPRINT,
    })
    expect(body.entries.map((entry: any) => entry.title)).toEqual([
      'Duplicate', 'Duplicate', 'Local only',
    ])
    expect(new Set(body.entries.map((entry: any) => entry.entryKey)).size).toBe(3)
    expect(body.entries[2]).toMatchObject({ resolved: false, sourceEntryId: expect.any(String) })
    expect(body.diff).toEqual({ added: [], removed: [], moved: [], replaced: [] })
    expect(body.capability).toEqual({
      possibleModes: ['revised_copy'],
      sourceWillRemainUntouched: true,
      applyAvailable: false,
    })

    const resumed = await request(db, 'u1', `/playlists/${playlist.id}/edit-draft`, 'POST')
    expect(resumed.status).toBe(200)
    expect((await resumed.json() as any).draft.id).toBe(body.draft.id)
    expect(await db.select().from(playlistEditDrafts)).toHaveLength(1)
    expect(await db.select().from(playlistEditDraftEntries)).toHaveLength(6)
  })

  it('isolates drafts by listener and hides malformed or foreign identifiers', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedUser(db, 'u2')
    const playlist = await seedPlaylist(db, 'u1', 'private')
    const created = await request(db, 'u1', `/playlists/${playlist.id}/edit-draft`, 'POST')
    const id = (await created.json() as any).draft.id

    expect((await request(db, null, `/playlist-edit-drafts/${id}`)).status).toBe(401)
    for (const value of [id, 'not-a-uuid', '00000000-0000-4000-8000-000000000000']) {
      expect((await request(db, 'u2', `/playlist-edit-drafts/${value}`)).status).toBe(404)
    }
    expect((await request(db, 'u2', `/playlists/${playlist.id}/edit-draft`, 'POST')).status)
      .toBe(404)
  })

  it('does not start a new draft from a playlist that left the source library', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const playlist = await seedPlaylist(db, 'u1', 'removed')
    await db.update(userPlaylists).set({ inLibrary: false })
    expect((await request(db, 'u1', `/playlists/${playlist.id}/edit-draft`, 'POST')).status)
      .toBe(404)
    expect(await db.select().from(playlistEditDrafts)).toHaveLength(0)
  })

  it('applies strict versioned operations and returns a deterministic diff', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const playlist = await seedPlaylist(db, 'u1', 'ops')
    const [newTrack] = await db.insert(tracks).values({
      appleId: 'new-catalog-song',
      title: 'New song',
      artist: 'New artist',
      artworkBgColor: 'a1b2c3',
    }).returning()
    const created = await request(db, 'u1', `/playlists/${playlist.id}/edit-draft`, 'POST')
    const draft = await created.json() as any
    const [first, second] = draft.entries

    const changed = await request(
      db,
      'u1',
      `/playlist-edit-drafts/${draft.draft.id}/operations`,
      'POST',
      {
        expectedVersion: 0,
        operations: [
          { type: 'add', trackId: newTrack.id, afterEntryKey: first.entryKey },
          { type: 'remove', entryKey: second.entryKey },
        ],
      },
    )
    expect(changed.status).toBe(200)
    const body = await changed.json() as any
    expect(body.draft.version).toBe(1)
    expect(body.entries.map((entry: any) => entry.title)).toEqual([
      'Duplicate', 'New song', 'Local only',
    ])
    expect(body.diff.added).toHaveLength(1)
    expect(body.diff.removed).toEqual([{ entryKey: second.entryKey, fromPosition: 1 }])
    expect(body.entries[1]).toMatchObject({
      trackId: newTrack.id,
      appleCatalogId: 'new-catalog-song',
      artworkBgColor: 'a1b2c3',
    })
    expect(body.review).toEqual({
      added: [{
        entryKey: body.entries[1].entryKey,
        position: 1,
        title: 'New song',
        artist: 'New artist',
        album: null,
        durationMs: null,
        artworkUrlTemplate: null,
        artworkWidth: null,
        artworkHeight: null,
        artworkBgColor: 'a1b2c3',
        resolved: true,
      }],
      removed: [{
        entryKey: second.entryKey,
        position: 1,
        title: 'Duplicate',
        artist: 'Artist',
        album: null,
        durationMs: null,
        artworkUrlTemplate: null,
        artworkWidth: null,
        artworkHeight: null,
        artworkBgColor: null,
        resolved: true,
      }],
      moved: [],
      replaced: [],
    })
    expect(await db.select().from(playlistEditDraftEvents)).toHaveLength(2)

    const stale = await request(
      db,
      'u1',
      `/playlist-edit-drafts/${draft.draft.id}/operations`,
      'POST',
      { expectedVersion: 0, operations: [{ type: 'remove', entryKey: first.entryKey }] },
    )
    expect(stale.status).toBe(409)
    expect(await db.select().from(playlistEditDraftEvents)).toHaveLength(2)
  })

  it('rejects malformed operations, missing anchors and non-catalog tracks without writes', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const playlist = await seedPlaylist(db, 'u1', 'invalid')
    const [unidentified] = await db.insert(tracks).values({ title: 'Ghost', artist: 'Artist' }).returning()
    const created = await request(db, 'u1', `/playlists/${playlist.id}/edit-draft`, 'POST')
    const body = await created.json() as any
    const path = `/playlist-edit-drafts/${body.draft.id}/operations`

    expect((await request(db, 'u1', path, 'POST', {
      expectedVersion: 0,
      operations: [{ type: 'add', trackId: unidentified.id }],
    })).status).toBe(409)
    expect((await request(db, 'u1', path, 'POST', {
      expectedVersion: 0,
      operations: [{ type: 'move', entryKey: body.entries[0].entryKey, beforeEntryKey: crypto.randomUUID() }],
    })).status).toBe(400)
    expect((await request(db, 'u1', path, 'POST', {
      expectedVersion: -1,
      operations: [],
    })).status).toBe(400)

    const unchanged = await request(db, 'u1', `/playlist-edit-drafts/${body.draft.id}`)
    expect((await unchanged.json() as any).draft.version).toBe(0)
  })

  it('does not advance the version for an operation with no effective change', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const playlist = await seedPlaylist(db, 'u1', 'unchanged')
    const created = await request(db, 'u1', `/playlists/${playlist.id}/edit-draft`, 'POST')
    const body = await created.json() as any
    const [first, second] = body.entries
    const response = await request(
      db,
      'u1',
      `/playlist-edit-drafts/${body.draft.id}/operations`,
      'POST',
      {
        expectedVersion: 0,
        operations: [{
          type: 'move',
          entryKey: first.entryKey,
          beforeEntryKey: second.entryKey,
        }],
      },
    )
    expect(response.status).toBe(200)
    expect((await response.json() as any).draft.version).toBe(0)
    expect(await db.select().from(playlistEditDraftEvents)).toHaveLength(0)
  })

  it('abandons idempotently, permits a fresh draft, and never deletes the source', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const playlist = await seedPlaylist(db, 'u1', 'abandon')
    const created = await request(db, 'u1', `/playlists/${playlist.id}/edit-draft`, 'POST')
    const id = (await created.json() as any).draft.id

    expect((await request(db, 'u1', `/playlist-edit-drafts/${id}`, 'DELETE')).status).toBe(204)
    expect((await request(db, 'u1', `/playlist-edit-drafts/${id}`, 'DELETE')).status).toBe(204)
    const fresh = await request(db, 'u1', `/playlists/${playlist.id}/edit-draft`, 'POST')
    expect(fresh.status).toBe(201)
    expect((await fresh.json() as any).draft.id).not.toBe(id)
    expect(await db.select().from(userPlaylists)).toHaveLength(1)
    expect(await db.select().from(playlistEntries)).toHaveLength(3)
  })

  it('cascades drafts on source or account deletion', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const playlist = await seedPlaylist(db, 'u1', 'cascade')
    await request(db, 'u1', `/playlists/${playlist.id}/edit-draft`, 'POST')
    expect(await db.select().from(playlistEditDrafts)).toHaveLength(1)
    await db.delete(userPlaylists)
    expect(await db.select().from(playlistEditDrafts)).toHaveLength(0)
    expect(await db.select().from(playlistEditDraftEntries)).toHaveLength(0)
    expect(await db.select().from(playlistEditDraftEvents)).toHaveLength(0)
  })
})
