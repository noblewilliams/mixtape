import { describe, expect, it } from 'vitest'
import { sql } from 'drizzle-orm'
import { Buffer } from 'node:buffer'
import { createApp, type AuthLike } from '../../src/app'
import {
  playlistEntries,
  user,
  userMusicProfiles,
  userPlaylists,
} from '../../src/db/schema'
import { createTestDb, type TestDb } from '../helpers/db'

const SPOTIFY_ID = '4uLU6hMCjMI75M1A2tKUQC'
const KEY = 'c'.repeat(64)

const authFor = (id: string | null): AuthLike => ({
  handler: () => new Response('ok'),
  api: { getSession: async () => id ? { user: { id } } : null },
})

async function seedUser(db: TestDb, id: string) {
  await db.insert(user).values({
    id,
    name: id,
    email: `${id}@example.com`,
    emailVerified: false,
    createdAt: new Date('2026-08-31T10:00:00Z'),
    updatedAt: new Date('2026-08-31T10:00:00Z'),
  })
  await db.insert(userMusicProfiles).values({
    userId: id,
    appleStorefront: 'ng',
    playlistsSyncedAt: new Date('2026-08-31T11:00:00Z'),
  })
}

async function seedPlaylist(
  db: TestDb,
  userId: string,
  appleLibraryId: string,
  name: string,
  modifiedAt: Date,
  inLibrary = true,
) {
  const [row] = await db.insert(userPlaylists).values({
    userId,
    appleLibraryId,
    name,
    kind: 'user',
    sourceFingerprint: 'a'.repeat(64),
    appleLastModifiedAt: modifiedAt,
    inLibrary,
  }).returning()
  return row
}

function get(db: TestDb, userId: string | null, path: string) {
  return createApp({ auth: authFor(userId), db }).request(`http://x${path}`)
}

describe('playlist browse routes', () => {
  it('requires authentication', async () => {
    const db = await createTestDb()
    expect((await get(db, null, '/playlists')).status).toBe(401)
    expect((await get(db, null, '/playlists/00000000-0000-4000-8000-000000000000')).status)
      .toBe(401)
  })

  it('lists active playlists in stable order with one-query aggregates', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const older = await seedPlaylist(
      db, 'u1', 'library-old', 'Older', new Date('2026-08-29T10:00:00Z'),
    )
    const newer = await seedPlaylist(
      db, 'u1', 'library-new', 'Newer', new Date('2026-08-30T10:00:00Z'),
    )
    await seedPlaylist(
      db, 'u1', 'library-gone', 'Gone', new Date('2026-08-31T10:00:00Z'), false,
    )
    await db.insert(playlistEntries).values([
      {
        playlistId: newer.id, position: 0, appleLibraryEntryId: 'e1',
        titleSnapshot: 'One', artistSnapshot: 'A', durationMsSnapshot: 60_000,
      },
      {
        playlistId: newer.id, position: 1, appleLibraryEntryId: 'e2',
        titleSnapshot: 'Two', artistSnapshot: 'B', durationMsSnapshot: null,
      },
    ])

    const response = await get(db, 'u1', '/playlists')
    expect(response.status).toBe(200)
    const body = await response.json() as { playlists: Record<string, unknown>[]; nextCursor: string | null }
    expect(body.playlists.map((row) => row.id)).toEqual([newer.id, older.id])
    expect(body.playlists[0]).toMatchObject({
      name: 'Newer', entryCount: 2, knownDurationMs: 60_000,
      artworkUrlTemplate: null, artworkBgColor: null, capability: 'copy_only',
      inLibrary: true,
    })
    expect(body.playlists[0]).not.toHaveProperty('appleLibraryId')
    expect(body.nextCursor).toBeNull()
  })

  it('supports all status, literal case-insensitive search, and keyset paging', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    for (var index = 0; index < 4; index++) {
      await seedPlaylist(
        db,
        'u1',
        `p-${index}`,
        index === 0 ? 'Fifty_% ENERGY' : `List ${index}`,
        new Date(Date.UTC(2026, 7, 31 - index)),
        index !== 3,
      )
    }

    const first = await (await get(db, 'u1', '/playlists?status=all&limit=2')).json() as {
      playlists: { id: string }[]; nextCursor: string
    }
    const second = await (await get(
      db, 'u1', `/playlists?status=all&limit=2&cursor=${encodeURIComponent(first.nextCursor)}`,
    )).json() as { playlists: { id: string }[]; nextCursor: string | null }
    expect(new Set([...first.playlists, ...second.playlists].map((row) => row.id)).size).toBe(4)
    expect(second.nextCursor).toBeNull()

    const searched = await (await get(db, 'u1', '/playlists?q=fifty_%25')).json() as {
      playlists: { name: string }[]
    }
    expect(searched.playlists.map((row) => row.name)).toEqual(['Fifty_% ENERGY'])

    const unicode = await seedPlaylist(
      db, 'u1', 'unicode', 'CAFÉ CALME', new Date('2026-08-27T10:00:00Z'),
    )
    const unicodeSearch = await (await get(db, 'u1', '/playlists?q=caf%C3%A9')).json() as {
      playlists: { id: string }[]
    }
    expect(unicodeSearch.playlists.map((row) => row.id)).toEqual([unicode.id])

    const empty = await (await get(db, 'u1', '/playlists?q=does-not-exist')).json() as {
      playlists: unknown[]; nextCursor: string | null
    }
    expect(empty).toEqual({ playlists: [], nextCursor: null })
  })

  it('keeps an old cursor safe after a newer playlist appears', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    for (var index = 0; index < 3; index++) {
      await seedPlaylist(
        db, 'u1', `stable-${index}`, `List ${index}`, new Date(Date.UTC(2026, 7, 30 - index)),
      )
    }
    const first = await (await get(db, 'u1', '/playlists?limit=2')).json() as {
      playlists: { id: string }[]; nextCursor: string
    }
    await seedPlaylist(db, 'u1', 'newest', 'Newest', new Date('2026-08-31T12:00:00Z'))

    const replay = await (await get(
      db, 'u1', `/playlists?limit=2&cursor=${encodeURIComponent(first.nextCursor)}`,
    )).json() as { playlists: { id: string }[] }
    expect(replay.playlists).toHaveLength(1)
    expect(first.playlists.map((row) => row.id)).not.toContain(replay.playlists[0].id)
  })

  it('rejects malformed and tampered cursors', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    expect((await get(db, 'u1', '/playlists?cursor=not-base64')).status).toBe(400)
    expect((await get(db, 'u1', '/playlists?cursor=eyJ2Ijo5OX0')).status).toBe(400)
    expect((await get(
      db,
      'u1',
      '/playlists/00000000-0000-4000-8000-000000000000?entryCursor=bad',
    )).status).toBe(400)
    const bigintOverflow = Buffer.from(JSON.stringify({
      v: 1,
      t: '9223372036854775808',
      id: '00000000-0000-4000-8000-000000000000',
    })).toString('base64url')
    const positionOverflow = Buffer.from(JSON.stringify({
      v: 1,
      p: 100_000,
      id: '00000000-0000-4000-8000-000000000000',
    })).toString('base64url')
    expect((await get(db, 'u1', `/playlists?cursor=${bigintOverflow}`)).status).toBe(400)
    expect((await get(
      db,
      'u1',
      `/playlists/00000000-0000-4000-8000-000000000000?entryCursor=${positionOverflow}`,
    )).status).toBe(400)
  })

  it('returns soft-removed detail with duplicate and unresolved entries', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const playlist = await seedPlaylist(
      db, 'u1', 'gone', 'Removed', new Date('2026-08-30T10:00:00Z'), false,
    )
    await db.insert(playlistEntries).values([
      {
        playlistId: playlist.id, position: 0, appleLibraryEntryId: 'e1',
        titleSnapshot: 'Same', artistSnapshot: 'A', appleCatalogId: null,
      },
      {
        playlistId: playlist.id, position: 1, appleLibraryEntryId: 'e2',
        titleSnapshot: 'Same', artistSnapshot: 'A', appleCatalogId: null,
      },
    ])

    const response = await get(db, 'u1', `/playlists/${playlist.id}?entryLimit=1`)
    expect(response.status).toBe(200)
    const first = await response.json() as {
      playlist: Record<string, unknown>
      entries: Record<string, unknown>[]
      nextEntryCursor: string
    }
    expect(first.playlist).toMatchObject({ id: playlist.id, inLibrary: false })
    expect(first.entries).toHaveLength(1)
    expect(first.entries[0]).toMatchObject({
      position: 0, trackId: null, appleCatalogId: null, resolved: false,
      title: 'Same', artist: 'A', artworkBgColor: null,
    })
    expect(first.entries[0]).not.toHaveProperty('appleLibraryEntryId')

    const second = await (await get(
      db,
      'u1',
      `/playlists/${playlist.id}?entryLimit=1&entryCursor=${encodeURIComponent(first.nextEntryCursor)}`,
    )).json() as { entries: { position: number }[]; nextEntryCursor: string | null }
    expect(second.entries.map((row) => row.position)).toEqual([1])
    expect(second.nextEntryCursor).toBeNull()
  })

  it('bounds detail pages for a 10,000-entry playlist', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const playlist = await seedPlaylist(
      db, 'u1', 'large', 'Large', new Date('2026-08-30T10:00:00Z'),
    )
    await db.execute(sql`
      INSERT INTO playlist_entries (
        playlist_id, position, apple_library_entry_id, title_snapshot, artist_snapshot
      )
      SELECT ${playlist.id}::uuid, value, 'entry-' || value, 'Song ' || value, 'Artist'
      FROM generate_series(0, 9999) AS value
    `)

    const response = await get(db, 'u1', `/playlists/${playlist.id}`)
    expect(response.status).toBe(200)
    const body = await response.json() as {
      playlist: { entryCount: number }
      entries: { position: number }[]
      nextEntryCursor: string | null
    }
    expect(body.playlist.entryCount).toBe(10_000)
    expect(body.entries).toHaveLength(200)
    expect(body.entries.at(-1)?.position).toBe(199)
    expect(body.nextEntryCursor).not.toBeNull()
  })

  it('uses the same 404 for malformed, missing, and cross-tenant IDs', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedUser(db, 'u2')
    const privatePlaylist = await seedPlaylist(
      db, 'u1', 'private', 'Private', new Date('2026-08-30T10:00:00Z'),
    )
    for (const id of ['not-a-uuid', '00000000-0000-4000-8000-000000000000', privatePlaylist.id]) {
      const response = await get(db, 'u2', `/playlists/${id}`)
      expect(response.status).toBe(404)
      expect(await response.json()).toEqual({ error: 'not_found' })
    }
  })


  it('carries the Spotify id on entries', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const [imported] = await db.insert(userPlaylists).values({
      userId: 'u1', appleLibraryId: KEY, name: 'Imported', kind: 'user',
      sourceFingerprint: 'a'.repeat(64), source: 'spotify_export',
    }).returning()
    await db.insert(playlistEntries).values([
      {
        playlistId: imported.id, position: 0, appleLibraryEntryId: `${KEY}:0`,
        titleSnapshot: 'One', artistSnapshot: 'A', spotifyId: SPOTIFY_ID,
      },
      {
        playlistId: imported.id, position: 1, appleLibraryEntryId: `${KEY}:1`,
        titleSnapshot: 'Two', artistSnapshot: 'B', spotifyId: null,
      },
    ])

    const response = await get(db, 'u1', `/playlists/${imported.id}`)
    expect(response.status).toBe(200)
    const body = await response.json() as { entries: Record<string, unknown>[] }
    expect(body.entries.map((row) => [row.spotifyId, row.appleCatalogId, row.resolved]))
      .toEqual([[SPOTIFY_ID, null, false], [null, null, false]])
  })
})
