import { describe, expect, it } from 'vitest'
import { createApp, type AuthLike } from '../../src/app'
import { user } from '../../src/db/schema'
import { createTestDb, type TestDb } from '../helpers/db'

const authFor = (id: string | null): AuthLike => ({
  handler: () => new Response('ok'),
  api: { getSession: async () => id ? { user: { id } } : null },
})

const song = (over: Record<string, unknown> = {}) => ({
  ordinal: 0,
  appleLibraryId: 'i.library-1',
  appleCatalogId: 'catalog-1',
  title: 'Song',
  artist: 'Artist',
  album: null,
  genre: null,
  releaseYear: null,
  explicit: null,
  playCount: null,
  lastPlayedAt: null,
  dateAdded: null,
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

describe('library sync routes', () => {
  it('requires a session on every endpoint', async () => {
    const db = await createTestDb()
    for (const [method, path] of [
      ['POST', '/ingest/library/syncs'],
      ['PUT', '/ingest/library/syncs/00000000-0000-4000-8000-000000000000/songs'],
      ['PUT', '/ingest/library/syncs/00000000-0000-4000-8000-000000000000/recent-tracks'],
      ['POST', '/ingest/library/syncs/00000000-0000-4000-8000-000000000000/complete'],
    ]) {
      expect((await request(db, authFor(null), path, method, {})).status).toBe(401)
    }
  })

  it('runs and safely retries a complete web snapshot', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const auth = authFor('u1')
    const start = await request(db, auth, '/ingest/library/syncs', 'POST', {
      source: 'web_musickit', storefront: 'ng', expectedSongs: 1, expectedRecentTracks: 1,
    })
    expect(start.status).toBe(201)
    const { syncId } = await start.json() as { syncId: string }
    expect((await request(db, auth, `/ingest/library/syncs/${syncId}/songs`, 'PUT', {
      songs: [song()],
    })).status).toBe(200)
    expect((await request(db, auth, `/ingest/library/syncs/${syncId}/recent-tracks`, 'PUT', {
      catalogIds: ['catalog-1'],
    })).status).toBe(200)

    const first = await request(db, auth, `/ingest/library/syncs/${syncId}/complete`, 'POST')
    const second = await request(db, auth, `/ingest/library/syncs/${syncId}/complete`, 'POST')
    expect(first.status).toBe(200)
    expect(await first.json()).toEqual({ songs: 1, catalogResolved: 1, playCountsObserved: 0, recentTracks: 1 })
    expect(await second.json()).toEqual({ songs: 1, catalogResolved: 1, playCountsObserved: 0, recentTracks: 1 })
  })

  it('uses fixed tenant-safe errors', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedUser(db, 'u2')
    const started = await request(db, authFor('u1'), '/ingest/library/syncs', 'POST', {
      source: 'web_musickit', storefront: 'ng', expectedSongs: 1,
    })
    const { syncId } = await started.json() as { syncId: string }
    const hidden = await request(db, authFor('u2'), `/ingest/library/syncs/${syncId}/songs`, 'PUT', {
      songs: [song({ title: 'Private song' })],
    })
    expect(hidden.status).toBe(404)
    expect(await hidden.json()).toEqual({ error: 'not_found' })

    await request(db, authFor('u1'), `/ingest/library/syncs/${syncId}/songs`, 'PUT', {
      songs: [song()],
    })
    const conflict = await request(db, authFor('u1'), `/ingest/library/syncs/${syncId}/songs`, 'PUT', {
      songs: [song({ title: 'Private song' })],
    })
    expect(conflict.status).toBe(409)
    expect(await conflict.json()).toEqual({ error: 'sync_conflict' })
  })

  it('rejects malformed parameters and oversized snapshots', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const auth = authFor('u1')
    expect((await request(db, auth, '/ingest/library/syncs/not-a-uuid/songs', 'PUT', {
      songs: [song()],
    })).status).toBe(400)
    expect((await request(db, auth, '/ingest/library/syncs', 'POST', {
      source: 'web_musickit', storefront: 'ng', expectedSongs: 100_001,
    })).status).toBe(400)
  })
})
