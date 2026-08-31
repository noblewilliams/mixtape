import { describe, it, expect } from 'vitest'
import { createTestDb, type TestDb } from './helpers/db'
import { createApp, type AuthLike } from '../src/app'
import { tracks, userTracks, user } from '../src/db/schema'

const authed: AuthLike = {
  handler: () => new Response('ok'),
  api: { getSession: async () => ({ user: { id: 'user-1' } }) },
}

const song = (over: Record<string, unknown> = {}) => ({
  appleId: '1001',
  title: 'Song',
  artist: 'Artist',
  album: 'Album',
  genre: 'Pop',
  playCount: 7,
  lastPlayedAt: 1724900000000,
  dateAdded: 1700000000000,
  ...over,
})

async function seedUser(db: TestDb) {
  await db.insert(user).values({
    id: 'user-1',
    name: 'Test',
    email: 't@example.com',
    emailVerified: false,
    createdAt: new Date(),
    updatedAt: new Date(),
  })
}

function post(db: TestDb, body: unknown, auth: AuthLike = authed) {
  return createApp({ auth, db }).request('http://x/ingest/library', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  })
}

describe('POST /ingest/library', () => {
  it('requires auth', async () => {
    const db = await createTestDb()
    const res = await post(db, { songs: [song()] }, { ...authed, api: { getSession: async () => null } })
    expect(res.status).toBe(401)
  })

  it('inserts tracks and user_tracks', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const res = await post(db, { songs: [song(), song({ appleId: '1002', title: 'Two' })] })
    expect(res.status).toBe(200)
    expect(await res.json()).toEqual({ ingested: 2 })
    expect(await db.select().from(tracks)).toHaveLength(2)
    const uts = await db.select().from(userTracks)
    expect(uts).toHaveLength(2)
    expect(uts.find((u) => u.playCount === 7)).toBeTruthy()
    expect(uts.find((u) => u.lastPlayedAt?.getTime() === 1724900000000)).toBeTruthy()
  })

  it('upserts on re-sync (play count updates, no duplicates)', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await post(db, { songs: [song()] })
    await post(db, { songs: [song({ playCount: 9 })] })
    expect(await db.select().from(tracks)).toHaveLength(1)
    const uts = await db.select().from(userTracks)
    expect(uts).toHaveLength(1)
    expect(uts[0].playCount).toBe(9)
  })

  it('dedupes repeated appleIds within one batch, keeping the max play count', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const res = await post(db, { songs: [song({ playCount: 3 }), song({ playCount: 11 })] })
    expect(res.status).toBe(200)
    expect(await res.json()).toEqual({ ingested: 1 })
    const uts = await db.select().from(userTracks)
    expect(uts).toHaveLength(1)
    expect(uts[0].playCount).toBe(11)
  })

  it('rejects malformed payloads', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const res = await post(db, { songs: [{ title: 'no appleId' }] })
    expect(res.status).toBe(400)
  })

  it.each([
    ['unsafe characters', '123/../../catalog'],
    ['non-numeric characters', '12abc34'],
    ['an overlong value', '1'.repeat(33)],
  ])('rejects an Apple catalog ID containing %s', async (_case, appleId) => {
    const db = await createTestDb()
    await seedUser(db)

    const res = await post(db, { songs: [song({ appleId })] })

    expect(res.status).toBe(400)
    expect(await db.select().from(tracks)).toEqual([])
  })

  it('rejects an empty batch', async () => {
    const db = await createTestDb()
    const res = await post(db, { songs: [] })
    expect(res.status).toBe(400)
  })

  it('stores releaseYear and explicit on the track row', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const res = await post(db, { songs: [song({ releaseYear: 2011, explicit: true })] })
    expect(res.status).toBe(200)
    const [track] = await db.select().from(tracks)
    expect(track.releaseYear).toBe(2011)
    expect(track.explicit).toBe(true)
  })

  it('does not clobber releaseYear/explicit on re-sync with nulls', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await post(db, { songs: [song({ releaseYear: 2011, explicit: true })] })
    await post(db, { songs: [song({ releaseYear: null, explicit: null })] })
    const [track] = await db.select().from(tracks)
    expect(track.releaseYear).toBe(2011)
    expect(track.explicit).toBe(true)
  })

  it('rejects an out-of-range releaseYear', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const res = await post(db, { songs: [song({ releaseYear: 1899 })] })
    expect(res.status).toBe(400)
  })

  it('merges cross-page duplicates monotonically (playCount and lastPlayedAt never regress, even to null)', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await post(db, { songs: [song({ playCount: 50, lastPlayedAt: 1724900000000 })] })
    await post(db, { songs: [song({ playCount: 0, lastPlayedAt: null })] })
    const uts = await db.select().from(userTracks)
    expect(uts).toHaveLength(1)
    expect(uts[0].playCount).toBe(50)
    expect(uts[0].lastPlayedAt?.getTime()).toBe(1724900000000)
  })

  it('shares one catalog track across users, with separate user_tracks rows', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await db.insert(user).values({
      id: 'user-2',
      name: 'Test Two',
      email: 't2@example.com',
      emailVerified: false,
      createdAt: new Date(),
      updatedAt: new Date(),
    })
    const authedTwo: AuthLike = {
      handler: () => new Response('ok'),
      api: { getSession: async () => ({ user: { id: 'user-2' } }) },
    }
    await post(db, { songs: [song()] })
    await post(db, { songs: [song()] }, authedTwo)
    expect(await db.select().from(tracks)).toHaveLength(1)
    expect(await db.select().from(userTracks)).toHaveLength(2)
  })

  it('rejects a batch over 500 songs', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const songs = Array.from({ length: 501 }, (_, i) => song({ appleId: String(100000 + i) }))
    const res = await post(db, { songs })
    expect(res.status).toBe(400)
  })
})
