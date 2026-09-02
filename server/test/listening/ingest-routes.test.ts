import { asc, eq } from 'drizzle-orm'
import { Hono } from 'hono'
import { describe, expect, it } from 'vitest'
import { createApp, type AppVars, type AuthLike } from '../../src/app'
import { listeningDays } from '../../src/db/schema'
import {
  LISTENING_ARTIST_CHUNK_MAX,
  LISTENING_TRACK_CHUNK_MAX,
} from '../../src/listening/contracts'
import {
  ListeningImportError,
  type ListeningImportErrorCategory,
  type ListeningImportStore,
} from '../../src/listening/import-store'
import { listeningIngestRoutes } from '../../src/routes/listening-ingest'
import { createTestDb, type TestDb } from '../helpers/db'
import {
  artist,
  day,
  libraryRow,
  seedUser,
  SPOTIFY_A,
  SPOTIFY_B,
  track,
  UNKNOWN_IMPORT,
  userTracksByPlatform,
} from '../helpers/listening-fixtures'

const authFor = (id: string | null): AuthLike => ({
  handler: () => new Response('ok'),
  api: { getSession: async () => id ? { user: { id } } : null },
})

function request(db: TestDb, auth: AuthLike, path: string, method: string, body?: unknown) {
  return createApp({ auth, db }).request(`http://x${path}`, {
    method,
    headers: body === undefined ? undefined : { 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
}

// The user's ledger rows in a stable order, to prove another tenant's reset
// left them untouched.
const ledger = (db: TestDb, userId: string) => db.select().from(listeningDays)
  .where(eq(listeningDays.userId, userId))
  .orderBy(asc(listeningDays.trackId), asc(listeningDays.day))

const extendedBegin = {
  source: 'spotify_export',
  package: 'spotify_extended',
  timeZone: 'Africa/Lagos',
  country: 'NG',
  expectedTracks: 1,
  expectedDays: 1,
  expectedLibraryTracks: 0,
  expectedArtists: 0,
}

const accountBegin = {
  ...extendedBegin,
  package: 'spotify_account',
  country: null,
  expectedDays: 0,
  expectedLibraryTracks: 1,
  expectedArtists: 1,
}

const imports = (importId: string) => `/ingest/listening/imports/${importId}`

async function beginImport(db: TestDb, auth: AuthLike, body: unknown) {
  const response = await request(db, auth, '/ingest/listening/imports', 'POST', body)
  expect(response.status).toBe(201)
  return (await response.json() as { importId: string }).importId
}

// Every endpoint with a body zValidator accepts, so a stubbed store is what
// decides the response.
const endpoints = (importId: string): Array<[string, string, unknown]> => [
  ['POST', '/ingest/listening/imports', extendedBegin],
  ['PUT', `${imports(importId)}/tracks`, { tracks: [track()] }],
  ['PUT', `${imports(importId)}/days`, { days: [day()] }],
  ['PUT', `${imports(importId)}/library`, { tracks: [libraryRow()] }],
  ['PUT', `${imports(importId)}/artists`, { artists: [artist()] }],
  ['POST', `${imports(importId)}/complete`, undefined],
  ['DELETE', '/ingest/listening/sources/spotify_export', undefined],
]

function failingStore(category: ListeningImportErrorCategory): ListeningImportStore {
  const fail = async () => { throw new ListeningImportError(category) }
  return {
    begin: fail,
    putTracks: fail,
    putDays: fail,
    putLibrary: fail,
    putArtists: fail,
    complete: fail,
    deleteSource: fail,
  }
}

// The routes alone, with a session already resolved, so a stubbed store can
// drive every error category through every handler.
function stubApp(db: TestDb, store: ListeningImportStore, onError: (error: unknown) => void) {
  const app = new Hono<{ Variables: AppVars }>()
  app.use('*', async (c, next) => {
    c.set('user', { id: 'u1' })
    await next()
  })
  app.onError((error, c) => {
    onError(error)
    return c.json({ error: 'internal' }, 500)
  })
  app.route('/ingest', listeningIngestRoutes(db, store))
  return app
}

describe('listening import routes', () => {
  it('requires a session on every endpoint', async () => {
    const db = await createTestDb()
    for (const [method, path, body] of [
      ...endpoints(UNKNOWN_IMPORT),
      ['GET', '/me/music-sources', undefined] as [string, string, unknown],
    ]) {
      const response = await request(db, authFor(null), path, method, body)
      expect(response.status, `${method} ${path}`).toBe(401)
    }
  })

  it('rejects a begin whose package and source disagree or whose counts a package cannot carry', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const auth = authFor('u1')
    const mismatch = await request(db, auth, '/ingest/listening/imports', 'POST', {
      ...extendedBegin, source: 'apple_export',
    })
    expect(mismatch.status).toBe(400)
    const notCarried = await request(db, auth, '/ingest/listening/imports', 'POST', {
      ...extendedBegin, expectedArtists: 1,
    })
    expect(notCarried.status).toBe(400)
  })

  it('treats a malformed import id as a missing run', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const auth = authFor('u1')
    for (const [method, path, body] of endpoints('not-a-uuid').slice(1, 6)) {
      const response = await request(db, auth, path, method, body)
      expect(response.status, `${method} ${path}`).toBe(404)
      expect(await response.json()).toEqual({ error: 'not_found' })
    }
  })

  // An unknown run would 404 from the store, so a 400 here proves the chunk
  // validator answered first; exactly the maximum passes through to the store.
  it('rejects empty and oversized chunks before store work', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const auth = authFor('u1')
    const tracksPath = `${imports(UNKNOWN_IMPORT)}/tracks`
    const artistsPath = `${imports(UNKNOWN_IMPORT)}/artists`
    const tracks = (length: number) => Array.from({ length }, (_, ordinal) =>
      track({ ordinal, platformId: String(ordinal).padStart(22, '0') }))
    const artists = (length: number) => Array.from({ length }, (_, ordinal) =>
      artist({ ordinal, name: `Artist ${ordinal}`, spotifyId: null }))

    for (const [path, body] of [
      [tracksPath, { tracks: [] }],
      [tracksPath, { tracks: tracks(LISTENING_TRACK_CHUNK_MAX + 1) }],
      [artistsPath, { artists: [] }],
      [artistsPath, { artists: artists(LISTENING_ARTIST_CHUNK_MAX + 1) }],
    ] as Array<[string, unknown]>) {
      expect((await request(db, auth, path, 'PUT', body)).status, path).toBe(400)
    }
    expect((await request(db, auth, tracksPath, 'PUT', {
      tracks: tracks(LISTENING_TRACK_CHUNK_MAX),
    })).status).toBe(404)
    expect((await request(db, auth, artistsPath, 'PUT', {
      artists: artists(LISTENING_ARTIST_CHUNK_MAX),
    })).status).toBe(404)
  })

  it('answers a body that is not JSON with a 400, not an internal error', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const response = await createApp({ auth: authFor('u1'), db }).request(
      'http://x/ingest/listening/imports',
      { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{"source": ' },
    )
    expect(response.status).toBe(400)
  })

  it('maps every store error category on every endpoint and rethrows internal', async () => {
    const db = await createTestDb()
    const expected: Record<ListeningImportErrorCategory, [number, string]> = {
      not_found: [404, 'not_found'],
      conflict: [409, 'sync_conflict'],
      invalid_state: [409, 'invalid_state'],
      count_mismatch: [409, 'count_mismatch'],
      invalid_id: [400, 'invalid_id'],
      internal: [500, 'internal'],
    }
    for (const category of Object.keys(expected) as ListeningImportErrorCategory[]) {
      const rethrown: unknown[] = []
      const app = stubApp(db, failingStore(category), (error) => rethrown.push(error))
      const [status, error] = expected[category]
      for (const [method, path, body] of endpoints(UNKNOWN_IMPORT)) {
        const response = await app.request(`http://x${path}`, {
          method,
          headers: body === undefined ? undefined : { 'content-type': 'application/json' },
          body: body === undefined ? undefined : JSON.stringify(body),
        })
        expect(response.status, `${category} ${method} ${path}`).toBe(status)
        expect(await response.json()).toEqual({ error })
      }
      if (category === 'internal') {
        expect(rethrown).toHaveLength(endpoints(UNKNOWN_IMPORT).length)
        expect(rethrown.every((e) => e instanceof ListeningImportError && e.category === 'internal')).toBe(true)
      } else {
        expect(rethrown).toEqual([])
      }
    }
  })

  it('imports extended streaming history end to end, then deletes the source', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const auth = authFor('u1')
    const started = await request(db, auth, '/ingest/listening/imports', 'POST', extendedBegin)
    expect(started.status).toBe(201)
    const { importId, expiresAt } = await started.json() as { importId: string; expiresAt: number }
    expect(importId).toMatch(/^[0-9a-f-]{36}$/)
    expect(expiresAt).toBeGreaterThan(Date.now())

    const tracksPut = await request(db, auth, `${imports(importId)}/tracks`, 'PUT', { tracks: [track()] })
    expect(tracksPut.status).toBe(200)
    expect(await tracksPut.json()).toEqual({ accepted: 1 })
    const daysPut = await request(db, auth, `${imports(importId)}/days`, 'PUT', { days: [day()] })
    expect(daysPut.status).toBe(200)
    expect(await daysPut.json()).toEqual({ accepted: 1 })

    const completed = await request(db, auth, `${imports(importId)}/complete`, 'POST')
    expect(completed.status).toBe(200)
    expect(await completed.json()).toEqual({
      tracks: 1,
      days: 1,
      libraryTracks: 0,
      artists: 0,
      unresolvedRows: 0,
      unresolvedPlays: 0,
      ledgerFrom: '2026-08-30',
      ledgerTo: '2026-08-30',
      likedRemoved: 0,
      likedRemovalSkipped: false,
    })
    expect((await userTracksByPlatform(db, 'u1')).get(SPOTIFY_A)).toMatchObject({
      playCount: 3, playCountObserved: true, inLibrary: false, seeded: false,
    })

    const deleted = await request(db, auth, '/ingest/listening/sources/spotify_export', 'DELETE')
    expect(deleted.status).toBe(200)
    expect(await deleted.json()).toEqual({ deletedDays: 1, deletedTracks: 1, unlibraried: 0 })
    expect((await userTracksByPlatform(db, 'u1')).size).toBe(0)

    const again = await request(db, auth, '/ingest/listening/sources/spotify_export', 'DELETE')
    expect(again.status).toBe(200)
    expect(await again.json()).toEqual({ deletedDays: 0, deletedTracks: 0, unlibraried: 0 })

    expect((await request(db, auth, '/ingest/listening/sources/deezer', 'DELETE')).status).toBe(400)
  })

  it('imports the account package with liked tracks and followed artists', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const auth = authFor('u1')
    const importId = await beginImport(db, auth, accountBegin)

    expect((await request(db, auth, `${imports(importId)}/tracks`, 'PUT', {
      tracks: [track()],
    })).status).toBe(200)
    expect((await request(db, auth, `${imports(importId)}/library`, 'PUT', {
      tracks: [libraryRow()],
    })).status).toBe(200)
    expect((await request(db, auth, `${imports(importId)}/artists`, 'PUT', {
      artists: [artist()],
    })).status).toBe(200)

    // The account package carries no days: the store's invalid_state, mapped.
    const days = await request(db, auth, `${imports(importId)}/days`, 'PUT', { days: [day()] })
    expect(days.status).toBe(409)
    expect(await days.json()).toEqual({ error: 'invalid_state' })

    const completed = await request(db, auth, `${imports(importId)}/complete`, 'POST')
    expect(completed.status).toBe(200)
    expect(await completed.json()).toEqual({
      tracks: 1,
      days: 0,
      libraryTracks: 1,
      artists: 1,
      unresolvedRows: 0,
      unresolvedPlays: 0,
      ledgerFrom: null,
      ledgerTo: null,
      likedRemoved: 0,
      likedRemovalSkipped: false,
    })
    expect((await userTracksByPlatform(db, 'u1')).get(SPOTIFY_A)).toMatchObject({
      playCount: 0, playCountObserved: false, inLibrary: true,
    })
  })

  it('surfaces the real store errors with fixed bodies', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const auth = authFor('u1')
    const importId = await beginImport(db, auth, extendedBegin)

    const badId = await request(db, auth, `${imports(importId)}/tracks`, 'PUT', {
      tracks: [track({ platformId: '1440935467' })],
    })
    expect(badId.status).toBe(400)
    expect(await badId.json()).toEqual({ error: 'invalid_id' })

    expect((await request(db, auth, `${imports(importId)}/tracks`, 'PUT', {
      tracks: [track()],
    })).status).toBe(200)
    const conflict = await request(db, auth, `${imports(importId)}/tracks`, 'PUT', {
      tracks: [track({ platformId: SPOTIFY_B })],
    })
    expect(conflict.status).toBe(409)
    expect(await conflict.json()).toEqual({ error: 'sync_conflict' })

    const short = await request(db, auth, `${imports(importId)}/complete`, 'POST')
    expect(short.status).toBe(409)
    expect(await short.json()).toEqual({ error: 'count_mismatch' })

    const missing = await request(db, auth, `${imports(UNKNOWN_IMPORT)}/complete`, 'POST')
    expect(missing.status).toBe(404)
    expect(await missing.json()).toEqual({ error: 'not_found' })
  })

  it("leaves another user's ledger and source alone when deleting the same source", async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedUser(db, 'u2')
    const owner = authFor('u1')
    const importId = await beginImport(db, owner, extendedBegin)
    expect((await request(db, owner, `${imports(importId)}/tracks`, 'PUT', { tracks: [track()] })).status).toBe(200)
    expect((await request(db, owner, `${imports(importId)}/days`, 'PUT', { days: [day()] })).status).toBe(200)
    expect((await request(db, owner, `${imports(importId)}/complete`, 'POST')).status).toBe(200)
    const before = await ledger(db, 'u1')
    expect(before).toHaveLength(1)

    const deleted = await request(db, authFor('u2'), '/ingest/listening/sources/spotify_export', 'DELETE')
    expect(deleted.status).toBe(200)
    expect(await deleted.json()).toEqual({ deletedDays: 0, deletedTracks: 0, unlibraried: 0 })

    expect(await ledger(db, 'u1')).toEqual(before)
    expect((await userTracksByPlatform(db, 'u1')).get(SPOTIFY_A)).toMatchObject({
      playCount: 3, playCountObserved: true,
    })
    const sources = await request(db, owner, '/me/music-sources', 'GET')
    expect(sources.status).toBe(200)
    expect(await sources.json()).toMatchObject({
      sources: [{ source: 'spotify_export', ledgerFrom: '2026-08-30', ledgerTo: '2026-08-30' }],
    })
  })

  it("hides another user's run behind the same 404", async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedUser(db, 'u2')
    const importId = await beginImport(db, authFor('u1'), extendedBegin)

    const hidden = await request(db, authFor('u2'), `${imports(importId)}/tracks`, 'PUT', {
      tracks: [track()],
    })
    expect(hidden.status).toBe(404)
    expect(await hidden.json()).toEqual({ error: 'not_found' })
    const completed = await request(db, authFor('u2'), `${imports(importId)}/complete`, 'POST')
    expect(completed.status).toBe(404)
    expect(await completed.json()).toEqual({ error: 'not_found' })
  })
})
