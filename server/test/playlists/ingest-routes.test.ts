import { describe, expect, it } from 'vitest'
import { createApp, type AuthLike } from '../../src/app'
import { user } from '../../src/db/schema'
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

  it('rejects malformed UUIDs and oversized chunks before store work', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const auth = authFor('u1')
    expect((await request(db, auth, '/ingest/playlists/syncs/not-a-uuid/playlists', 'PUT', {
      playlists: [playlist()],
    })).status).toBe(400)
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
})
