import { describe, it, expect } from 'vitest'
import { and, asc, eq } from 'drizzle-orm'
import { createApp, type AuthLike } from '../../src/app'
import { listeningDays, tracks, userArtistSeeds, userTracks } from '../../src/db/schema'
import { EnrichSourceError } from '../../src/enrich/types'
import {
  fetchTracksBySpotifyIds,
  type FetchTracksBySpotifyIds,
  type ReccoBeatsTrackHit,
} from '../../src/enrich/reccobeats-by-id'
import { createTestDb, type TestDb } from '../helpers/db'
import { now, seedUser, SPOTIFY_A, SPOTIFY_B, SPOTIFY_C } from '../helpers/listening-fixtures'

const authFor = (id: string | null): AuthLike => ({
  handler: () => new Response('ok'),
  api: { getSession: async () => id ? { user: { id } } : null },
})

const hit = (spotifyId: string, over: Partial<ReccoBeatsTrackHit> = {}): ReccoBeatsTrackHit => ({
  spotifyId,
  title: `Title ${spotifyId.slice(0, 4)}`,
  artists: ['Wizkid', 'Tems'],
  isrc: `ISRC${spotifyId.slice(0, 8)}`,
  durationMs: 200_000,
  ...over,
})

// Resolves exactly the listed hits; everything else is missing.
function stubFetch(hits: ReccoBeatsTrackHit[], calls: string[][] = []): FetchTracksBySpotifyIds {
  return async (ids) => {
    calls.push(ids)
    const byId = new Map(hits.map((h) => [h.spotifyId, h]))
    return {
      hits: ids.filter((id) => byId.has(id)).map((id) => byId.get(id)!),
      missing: ids.filter((id) => !byId.has(id)),
    }
  }
}

const app = (db: TestDb, auth: AuthLike, fetchTracks: FetchTracksBySpotifyIds = stubFetch([])) =>
  createApp({ auth, db, seeds: { fetchTracks } })

const json = (method: string, body?: unknown): RequestInit => ({
  method,
  headers: { 'content-type': 'application/json' },
  body: body === undefined ? undefined : JSON.stringify(body),
})

async function trackRows(db: TestDb) {
  return db.select().from(tracks).orderBy(asc(tracks.spotifyId))
}

async function userTrackRows(db: TestDb, userId: string) {
  return db.select().from(userTracks).where(eq(userTracks.userId, userId)).orderBy(asc(userTracks.trackId))
}

async function seedRows(db: TestDb, userId: string) {
  return db.select({ name: userArtistSeeds.name, source: userArtistSeeds.source })
    .from(userArtistSeeds)
    .where(eq(userArtistSeeds.userId, userId))
    .orderBy(asc(userArtistSeeds.name))
}

describe('POST /me/seed-tracks', () => {
  it('401s without a session', async () => {
    const db = await createTestDb()
    const response = await app(db, authFor(null)).request('http://x/me/seed-tracks', json('POST', { spotifyIds: [SPOTIFY_A] }))
    expect(response.status).toBe(401)
  })

  it('400s on an empty list, more than 200 ids, a malformed id, or an unknown key', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const calls: string[][] = []
    const a = app(db, authFor('u1'), stubFetch([hit(SPOTIFY_A)], calls))
    for (const body of [
      { spotifyIds: [] },
      { spotifyIds: Array.from({ length: 201 }, (_, i) => `${String(i).padStart(4, '0')}abcdefghijklmnopqr`) },
      { spotifyIds: ['spotify:track:4uLU6hMCjMI75M1A2tKUQC'] },
      { spotifyIds: [SPOTIFY_A], extra: 1 },
      {},
    ]) {
      expect((await a.request('http://x/me/seed-tracks', json('POST', body))).status, JSON.stringify(body).slice(0, 40)).toBe(400)
    }
    expect(calls).toHaveLength(0)
  })

  it('resolves through the fetch, writes tracks, seeded user_tracks (not in library), and pasted artist seeds', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const calls: string[][] = []
    const response = await app(db, authFor('u1'), stubFetch([hit(SPOTIFY_A), hit(SPOTIFY_B, { artists: ['Asake'], isrc: null, durationMs: null })], calls))
      .request('http://x/me/seed-tracks', json('POST', { spotifyIds: [SPOTIFY_A, SPOTIFY_C, SPOTIFY_A, SPOTIFY_B] }))
    expect(response.status).toBe(200)
    const body = await response.json() as { resolved: Array<Record<string, unknown>>; unresolved: string[] }
    expect(calls).toEqual([[SPOTIFY_A, SPOTIFY_C, SPOTIFY_B]])
    expect(body.unresolved).toEqual([SPOTIFY_C])
    expect(body.resolved.map((r) => r.spotifyId)).toEqual([SPOTIFY_A, SPOTIFY_B])
    expect(body.resolved[0]).toMatchObject({ spotifyId: SPOTIFY_A, title: hit(SPOTIFY_A).title, artist: 'Wizkid & Tems' })
    expect(body.resolved[1]).toMatchObject({ spotifyId: SPOTIFY_B, title: hit(SPOTIFY_B).title, artist: 'Asake' })

    const stored = await trackRows(db)
    expect(stored).toHaveLength(2)
    const a = stored.find((t) => t.spotifyId === SPOTIFY_A)!
    expect(a).toMatchObject({
      title: hit(SPOTIFY_A).title,
      artist: 'Wizkid & Tems',
      isrc: hit(SPOTIFY_A).isrc,
      durationMs: 200_000,
      artistSource: 'reccobeats',
      enrichPriority: 1,
      appleId: null,
    })
    expect(body.resolved[0].trackId).toBe(a.id)
    const b = stored.find((t) => t.spotifyId === SPOTIFY_B)!
    expect(b).toMatchObject({ artist: 'Asake', isrc: null, durationMs: null, enrichPriority: 1 })

    const mine = await userTrackRows(db, 'u1')
    expect(mine).toHaveLength(2)
    for (const row of mine) {
      expect(row).toMatchObject({ seeded: true, inLibrary: false, playCount: 0, playCountObserved: false, playCountRecent: 0 })
    }
    expect(await seedRows(db, 'u1')).toEqual([
      { name: 'Asake', source: 'pasted' },
      { name: 'Tems', source: 'pasted' },
      { name: 'Wizkid', source: 'pasted' },
    ])
  })

  it('protects an apple_catalog artist and title, fills isrc and duration only where empty, never lowers enrich_priority', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await db.insert(tracks).values([
      { spotifyId: SPOTIFY_A, title: 'Catalog Title', artist: 'Catalog Artist', artistSource: 'apple_catalog', isrc: 'KEEPME000001', enrichPriority: 5 },
      { spotifyId: SPOTIFY_B, title: 'Export Title', artist: 'Album Artist', artistSource: 'export', durationMs: 123_000, album: 'Album' },
    ])
    const response = await app(db, authFor('u1'), stubFetch([hit(SPOTIFY_A), hit(SPOTIFY_B)]))
      .request('http://x/me/seed-tracks', json('POST', { spotifyIds: [SPOTIFY_A, SPOTIFY_B] }))
    expect(response.status).toBe(200)

    const stored = await trackRows(db)
    expect(stored).toHaveLength(2)
    expect(stored.find((t) => t.spotifyId === SPOTIFY_A)).toMatchObject({
      title: 'Catalog Title',
      artist: 'Catalog Artist',
      artistSource: 'apple_catalog',
      isrc: 'KEEPME000001',
      durationMs: 200_000,
      enrichPriority: 5,
    })
    expect(stored.find((t) => t.spotifyId === SPOTIFY_B)).toMatchObject({
      title: hit(SPOTIFY_B).title,
      artist: 'Wizkid & Tems',
      artistSource: 'reccobeats',
      isrc: hit(SPOTIFY_B).isrc,
      durationMs: 123_000,
      album: 'Album',
      enrichPriority: 1,
    })
    const body = await response.json() as { resolved: Array<Record<string, unknown>> }
    expect(body.resolved[0]).toMatchObject({ title: 'Catalog Title', artist: 'Catalog Artist' })
  })

  it('marks an existing library row seeded without touching its membership or counts, and leaves existing artist seeds alone', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const [t] = await db.insert(tracks).values({ spotifyId: SPOTIFY_A, title: 'T', artist: 'Wizkid' }).returning()
    await db.insert(userTracks).values({ userId: 'u1', trackId: t.id, playCount: 7, playCountObserved: true, inLibrary: true, dateAdded: now })
    await db.insert(userArtistSeeds).values({ userId: 'u1', name: 'Wizkid', source: 'interview', createdAt: now })

    const response = await app(db, authFor('u1'), stubFetch([hit(SPOTIFY_A)]))
      .request('http://x/me/seed-tracks', json('POST', { spotifyIds: [SPOTIFY_A] }))
    expect(response.status).toBe(200)

    const [mine] = await userTrackRows(db, 'u1')
    expect(mine).toMatchObject({ seeded: true, inLibrary: true, playCount: 7, playCountObserved: true, dateAdded: now })
    expect(await seedRows(db, 'u1')).toEqual([{ name: 'Tems', source: 'pasted' }, { name: 'Wizkid', source: 'interview' }])
  })

  it('reports a hit without any credited artist as unresolved and writes nothing for it', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const response = await app(db, authFor('u1'), stubFetch([hit(SPOTIFY_A, { artists: [] })]))
      .request('http://x/me/seed-tracks', json('POST', { spotifyIds: [SPOTIFY_A] }))
    expect(response.status).toBe(200)
    expect(await response.json()).toEqual({ resolved: [], unresolved: [SPOTIFY_A] })
    expect(await trackRows(db)).toHaveLength(0)
  })

  it('answers 502 {error: "upstream"} on a ReccoBeats failure and writes nothing', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const failing: FetchTracksBySpotifyIds = async () => { throw new EnrichSourceError('reccobeats', 'track HTTP 500', 500) }
    const response = await app(db, authFor('u1'), failing)
      .request('http://x/me/seed-tracks', json('POST', { spotifyIds: [SPOTIFY_A] }))
    expect(response.status).toBe(502)
    expect(await response.json()).toEqual({ error: 'upstream' })
    expect(await trackRows(db)).toHaveLength(0)
    expect(await userTrackRows(db, 'u1')).toHaveLength(0)
  })

  it('answers 502 {error: "upstream"} when the ReccoBeats fetch itself rejects (DNS, connection, timeout)', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const unreachable: FetchTracksBySpotifyIds = (ids) =>
      fetchTracksBySpotifyIds(ids, async () => { throw new TypeError('fetch failed') })
    const response = await app(db, authFor('u1'), unreachable)
      .request('http://x/me/seed-tracks', json('POST', { spotifyIds: [SPOTIFY_A] }))
    expect(response.status).toBe(502)
    expect(await response.json()).toEqual({ error: 'upstream' })
    expect(await trackRows(db)).toHaveLength(0)
  })

  it('other failures stay internal 500s', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const failing: FetchTracksBySpotifyIds = async () => { throw new Error('boom') }
    const response = await app(db, authFor('u1'), failing)
      .request('http://x/me/seed-tracks', json('POST', { spotifyIds: [SPOTIFY_A] }))
    expect(response.status).toBe(500)
  })
})

describe('GET /me/seed-tracks', () => {
  it('401s without a session', async () => {
    const db = await createTestDb()
    expect((await app(db, authFor(null)).request('http://x/me/seed-tracks')).status).toBe(401)
  })

  it("lists only the caller's seeded rows in the {trackId, spotifyId, title, artist, album} shape", async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedUser(db, 'u2')
    const [seeded, library, theirs] = await db.insert(tracks).values([
      { spotifyId: SPOTIFY_A, title: 'Seeded', artist: 'Wizkid', album: 'Album' },
      { spotifyId: SPOTIFY_B, title: 'Library', artist: 'Tems' },
      { spotifyId: SPOTIFY_C, title: 'Theirs', artist: 'Asake' },
    ]).returning()
    await db.insert(userTracks).values([
      { userId: 'u1', trackId: seeded.id, seeded: true, inLibrary: false },
      { userId: 'u1', trackId: library.id, seeded: false, inLibrary: true },
      { userId: 'u2', trackId: theirs.id, seeded: true, inLibrary: false },
    ])
    const response = await app(db, authFor('u1')).request('http://x/me/seed-tracks')
    expect(response.status).toBe(200)
    expect(await response.json()).toEqual({
      tracks: [{ trackId: seeded.id, spotifyId: SPOTIFY_A, title: 'Seeded', artist: 'Wizkid', album: 'Album' }],
    })
  })
})

describe('DELETE /me/seed-tracks/:trackId', () => {
  const del = (db: TestDb, auth: AuthLike, id: string) =>
    app(db, auth).request(`http://x/me/seed-tracks/${id}`, { method: 'DELETE' })

  async function seededTrack(db: TestDb, userId: string, over: Partial<typeof userTracks.$inferInsert> = {}) {
    const [t] = await db.insert(tracks).values({ spotifyId: SPOTIFY_A, title: 'T', artist: 'A' }).returning()
    await db.insert(userTracks).values({ userId, trackId: t.id, seeded: true, inLibrary: false, ...over })
    return t
  }

  it('401s without a session', async () => {
    const db = await createTestDb()
    expect((await del(db, authFor(null), '00000000-0000-4000-8000-000000000000')).status).toBe(401)
  })

  it('404s for a malformed id, a missing row, a row that is not seeded, and another user\'s seeded row', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedUser(db, 'u2')
    const [notSeeded] = await db.insert(tracks).values({ spotifyId: SPOTIFY_B, title: 'T', artist: 'A' }).returning()
    await db.insert(userTracks).values({ userId: 'u1', trackId: notSeeded.id, seeded: false, inLibrary: true })
    const theirs = await seededTrack(db, 'u2')
    for (const id of ['not-a-uuid', '00000000-0000-4000-8000-000000000000', notSeeded.id, theirs.id]) {
      const response = await del(db, authFor('u1'), id)
      expect(response.status, id).toBe(404)
      expect(await response.json()).toEqual({ error: 'not_found' })
    }
    expect(await userTrackRows(db, 'u2')).toMatchObject([{ seeded: true }])
    expect(await userTrackRows(db, 'u1')).toMatchObject([{ seeded: false, inLibrary: true }])
  })

  it('deletes the row outright when nothing else keeps it, leaving the track in the corpus', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const t = await seededTrack(db, 'u1')
    const response = await del(db, authFor('u1'), t.id)
    expect(response.status).toBe(200)
    expect(await response.json()).toEqual({ removed: true, deleted: true })
    expect(await userTrackRows(db, 'u1')).toHaveLength(0)
    expect(await trackRows(db)).toHaveLength(1)
  })

  it('only clears the seed when the row is in the library', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const t = await seededTrack(db, 'u1', { inLibrary: true, playCount: 3 })
    const response = await del(db, authFor('u1'), t.id)
    expect(response.status).toBe(200)
    expect(await response.json()).toEqual({ removed: true, deleted: false })
    expect(await userTrackRows(db, 'u1')).toMatchObject([{ seeded: false, inLibrary: true, playCount: 3 }])
  })

  it('only clears the seed when the ledger holds plays for the track', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const t = await seededTrack(db, 'u1', { playCount: 2, playCountObserved: true })
    await db.insert(listeningDays).values({ userId: 'u1', source: 'spotify_export', trackId: t.id, day: '2026-08-30', plays: 2, msPlayed: 1000 })
    const response = await del(db, authFor('u1'), t.id)
    expect(response.status).toBe(200)
    expect(await response.json()).toEqual({ removed: true, deleted: false })
    expect(await userTrackRows(db, 'u1')).toMatchObject([{ seeded: false, inLibrary: false, playCount: 2 }])
    expect(await db.select().from(listeningDays).where(and(eq(listeningDays.userId, 'u1'), eq(listeningDays.trackId, t.id)))).toHaveLength(1)
  })
})
