import { Hono } from 'hono'
import { describe, expect, it } from 'vitest'
import { createApp, type AppVars, type AuthLike } from '../../src/app'
import { playlistSyncRuns, user, userMusicProfiles } from '../../src/db/schema'
import { PlaylistSyncError, type PlaylistSyncStore } from '../../src/playlists/sync-store'
import { playlistIngestRoutes } from '../../src/routes/playlist-ingest'
import { createTestDb, type TestDb } from '../helpers/db'

const authFor = (id: string | null): AuthLike => ({
  handler: () => new Response('ok'),
  api: { getSession: async () => id ? { user: { id } } : null },
})

const playlist = (over: Record<string, unknown> = {}) => ({
  ordinal: 0,
  appleLibraryId: 'p-1',
  appleCatalogId: null,
  name: 'Evening',
  description: null,
  curatorName: null,
  artworkUrlTemplate: null,
  artworkWidth: null,
  artworkHeight: null,
  artworkBgColor: 'a1b2c3',
  kind: 'user',
  canEdit: false,
  appleDateAdded: null,
  appleLastModifiedAt: null,
  sourceFingerprint: 'a'.repeat(64),
  entryCount: 0,
  ...over,
})

const SPOTIFY_ID = '4uLU6hMCjMI75M1A2tKUQC'
const KEY = 'c'.repeat(64)

const entry = (over: Record<string, unknown> = {}) => ({
  position: 0,
  appleLibraryEntryId: `${KEY}:0`,
  appleLibraryTrackId: null,
  appleCatalogId: null,
  isrcSnapshot: null,
  titleSnapshot: 'Song',
  artistSnapshot: 'Artist',
  albumSnapshot: null,
  durationMsSnapshot: null,
  artworkUrlTemplateSnapshot: null,
  artworkWidthSnapshot: null,
  artworkHeightSnapshot: null,
  artworkBgColorSnapshot: null,
  ...over,
})

async function seedUser(db: TestDb, id: string) {
  await db.insert(user).values({
    id,
    name: id,
    email: `${id}@example.com`,
    emailVerified: false,
    createdAt: new Date(),
    updatedAt: new Date(),
  })
}

function request(db: TestDb, auth: AuthLike, path: string, method: string, body?: unknown) {
  return createApp({ auth, db }).request(`http://x${path}`, {
    method,
    headers: body === undefined ? undefined : { 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
}

describe('playlist ingest routes', () => {
  it('requires a session on every playlist sync endpoint', async () => {
    const db = await createTestDb()
    const auth = authFor(null)
    for (const [method, path] of [
      ['POST', '/ingest/playlists/syncs'],
      ['PUT', '/ingest/playlists/syncs/00000000-0000-4000-8000-000000000000/playlists'],
      ['PUT', '/ingest/playlists/syncs/00000000-0000-4000-8000-000000000000/entries'],
      ['POST', '/ingest/playlists/syncs/00000000-0000-4000-8000-000000000000/complete'],
    ]) {
      expect((await request(db, auth, path, method, {})).status).toBe(401)
    }
  })

  it('runs a zero-playlist sync and retries completion safely', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const auth = authFor('u1')
    const start = await request(db, auth, '/ingest/playlists/syncs', 'POST', {
      storefront: 'ng', expectedPlaylists: 0, expectedEntries: 0,
    })
    expect(start.status).toBe(201)
    const started = await start.json() as { syncId: string; expiresAt: number }
    expect(started.syncId).toMatch(/^[0-9a-f-]{36}$/)
    expect(started.expiresAt).toBeGreaterThan(Date.now())

    const first = await request(db, auth, `/ingest/playlists/syncs/${started.syncId}/complete`, 'POST')
    const second = await request(db, auth, `/ingest/playlists/syncs/${started.syncId}/complete`, 'POST')
    expect(first.status).toBe(200)
    expect(await first.json()).toEqual({ playlists: 0, entries: 0, resolvedEntries: 0, unresolvedEntries: 0 })
    expect(await second.json()).toEqual({ playlists: 0, entries: 0, resolvedEntries: 0, unresolvedEntries: 0 })
  })

  it('accepts playlist and empty-entry chunks before completion', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const auth = authFor('u1')
    const start = await request(db, auth, '/ingest/playlists/syncs', 'POST', {
      storefront: 'ng', expectedPlaylists: 1, expectedEntries: 0,
    })
    const { syncId } = await start.json() as { syncId: string }
    expect((await request(db, auth, `/ingest/playlists/syncs/${syncId}/playlists`, 'PUT', {
      playlists: [playlist()],
    })).status).toBe(200)
    expect((await request(db, auth, `/ingest/playlists/syncs/${syncId}/entries`, 'PUT', {
      playlistAppleId: 'p-1', entries: [],
    })).status).toBe(200)
    expect((await request(db, auth, `/ingest/playlists/syncs/${syncId}/complete`, 'POST')).status).toBe(200)
  })

  it('returns fixed 404 and conflict categories without private fields', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedUser(db, 'u2')
    const started = await request(db, authFor('u1'), '/ingest/playlists/syncs', 'POST', {
      storefront: 'ng', expectedPlaylists: 1, expectedEntries: 0,
    })
    const { syncId } = await started.json() as { syncId: string }
    const hidden = await request(db, authFor('u2'), `/ingest/playlists/syncs/${syncId}/playlists`, 'PUT', {
      playlists: [playlist({ name: 'private-name' })],
    })
    expect(hidden.status).toBe(404)
    expect(await hidden.json()).toEqual({ error: 'not_found' })

    await request(db, authFor('u1'), `/ingest/playlists/syncs/${syncId}/playlists`, 'PUT', {
      playlists: [playlist()],
    })
    const conflict = await request(db, authFor('u1'), `/ingest/playlists/syncs/${syncId}/playlists`, 'PUT', {
      playlists: [playlist({ name: 'private-name' })],
    })
    expect(conflict.status).toBe(409)
    expect(await conflict.json()).toEqual({ error: 'sync_conflict' })
  })

  it('hides a malformed sync id behind the same 404 and rejects oversized chunks before store work', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const auth = authFor('u1')
    const malformed = await request(db, auth, '/ingest/playlists/syncs/not-a-uuid/playlists', 'PUT', {
      playlists: [playlist()],
    })
    expect(malformed.status).toBe(404)
    expect(await malformed.json()).toEqual({ error: 'not_found' })
    expect((await request(db, auth, '/ingest/playlists/syncs', 'POST', {
      storefront: 'ng', expectedPlaylists: 2_001, expectedEntries: 0,
    })).status).toBe(400)
    expect((await request(db, auth, '/ingest/playlists/syncs/00000000-0000-4000-8000-000000000000/playlists', 'PUT', {
      playlists: Array.from({ length: 51 }, (_, ordinal) => playlist({ ordinal, appleLibraryId: `p-${ordinal}` })),
    })).status).toBe(400)
  })

  it('allows PUT in configured CORS preflights', async () => {
    const db = await createTestDb()
    const response = await createApp({
      auth: authFor(null), db, allowedOrigins: ['https://mixtape.example'],
    }).request('http://x/ingest/playlists/syncs/id/playlists', {
      method: 'OPTIONS',
      headers: {
        origin: 'https://mixtape.example',
        'access-control-request-method': 'PUT',
      },
    })
    expect(response.status).toBe(204)
    expect(response.headers.get('access-control-allow-methods')).toContain('PUT')
  })


  it('runs a Spotify export sync without a storefront and validates Spotify ids', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const auth = authFor('u1')
    const start = await request(db, auth, '/ingest/playlists/syncs', 'POST', {
      source: 'spotify_export', expectedPlaylists: 1, expectedEntries: 1,
    })
    expect(start.status).toBe(201)
    const { syncId } = await start.json() as { syncId: string }
    expect((await request(db, auth, `/ingest/playlists/syncs/${syncId}/playlists`, 'PUT', {
      playlists: [playlist({ appleLibraryId: KEY, entryCount: 1 })],
    })).status).toBe(200)
    expect((await request(db, auth, `/ingest/playlists/syncs/${syncId}/entries`, 'PUT', {
      playlistAppleId: KEY, entries: [entry({ spotifyId: `spotify:track:${SPOTIFY_ID}` })],
    })).status).toBe(400)
    expect((await request(db, auth, `/ingest/playlists/syncs/${syncId}/entries`, 'PUT', {
      playlistAppleId: KEY, entries: [entry({ spotifyId: SPOTIFY_ID })],
    })).status).toBe(200)
    const complete = await request(db, auth, `/ingest/playlists/syncs/${syncId}/complete`, 'POST')
    expect(complete.status).toBe(200)
    expect(await complete.json())
      .toEqual({ playlists: 1, entries: 1, resolvedEntries: 0, unresolvedEntries: 1 })
  })

  it.each([
    { source: 'ios_native' },
    { source: 'web_musickit', storefront: null },
    {},
  ])('rejects an Apple sync without a storefront %j', async (over) => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const response = await request(db, authFor('u1'), '/ingest/playlists/syncs', 'POST', {
      expectedPlaylists: 0, expectedEntries: 0, ...over,
    })
    expect(response.status).toBe(400)
  })

  it('rejects a Spotify export begin that carries a storefront before any store work', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const response = await request(db, authFor('u1'), '/ingest/playlists/syncs', 'POST', {
      source: 'spotify_export', storefront: 'ng', expectedPlaylists: 0, expectedEntries: 0,
    })
    expect(response.status).toBe(400)
    // The contract stops it: no run opens and no profile row is touched, so
    // a Spotify sync can never overwrite the listener's Apple storefront.
    expect(await db.select().from(playlistSyncRuns)).toEqual([])
    expect(await db.select().from(userMusicProfiles)).toEqual([])
  })

  it('maps a store invalid_storefront rejection to a 400', async () => {
    const db = await createTestDb()
    const fail = async () => { throw new Error('unexpected store call') }
    const store: PlaylistSyncStore = {
      begin: async () => { throw new PlaylistSyncError('invalid_storefront') },
      putPlaylists: fail,
      putEntries: fail,
      complete: fail,
    }
    // The routes alone with a session already resolved, so the stub drives
    // the error mapping with a body the contract itself accepts.
    const app = new Hono<{ Variables: AppVars }>()
    app.use('*', async (c, next) => {
      c.set('user', { id: 'u1' })
      await next()
    })
    app.route('/ingest', playlistIngestRoutes(db, store))
    const response = await app.request('http://x/ingest/playlists/syncs', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ storefront: 'ng', expectedPlaylists: 0, expectedEntries: 0 }),
    })
    expect(response.status).toBe(400)
    expect(await response.json()).toEqual({ error: 'invalid_storefront' })
  })
})
