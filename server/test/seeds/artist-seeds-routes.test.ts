import { describe, it, expect } from 'vitest'
import { asc, eq } from 'drizzle-orm'
import { createApp, type AuthLike } from '../../src/app'
import { userArtistSeeds } from '../../src/db/schema'
import { createTestDb, type TestDb } from '../helpers/db'
import { now, seedUser } from '../helpers/listening-fixtures'

const authFor = (id: string | null): AuthLike => ({
  handler: () => new Response('ok'),
  api: { getSession: async () => id ? { user: { id } } : null },
})

function get(db: TestDb, auth: AuthLike) {
  return createApp({ auth, db }).request('http://x/me/artist-seeds')
}

function put(db: TestDb, auth: AuthLike, body: unknown) {
  return createApp({ auth, db }).request('http://x/me/artist-seeds', {
    method: 'PUT',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  })
}

async function rows(db: TestDb, userId: string) {
  return db.select({ name: userArtistSeeds.name, source: userArtistSeeds.source, createdAt: userArtistSeeds.createdAt })
    .from(userArtistSeeds)
    .where(eq(userArtistSeeds.userId, userId))
    .orderBy(asc(userArtistSeeds.name))
}

describe('GET /me/artist-seeds', () => {
  it('401s without a session', async () => {
    const db = await createTestDb()
    expect((await get(db, authFor(null))).status).toBe(401)
  })

  it("lists the caller's seeds by createdAt then name with ISO timestamps, never another user's", async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedUser(db, 'u2')
    const earlier = new Date(now.getTime() - 60_000)
    await db.insert(userArtistSeeds).values([
      { userId: 'u1', name: 'Tems', source: 'interview', createdAt: now },
      { userId: 'u1', name: 'Asake', source: 'pasted', spotifyId: '3a1lNhkSLSkpJE4MSHpDu9', createdAt: now },
      { userId: 'u1', name: 'Wizkid', source: 'spotify_export', createdAt: earlier },
      { userId: 'u2', name: 'Burna Boy', source: 'interview', createdAt: earlier },
    ])
    const response = await get(db, authFor('u1'))
    expect(response.status).toBe(200)
    expect(await response.json()).toEqual({
      seeds: [
        { name: 'Wizkid', spotifyId: null, source: 'spotify_export', createdAt: earlier.toISOString() },
        { name: 'Asake', spotifyId: '3a1lNhkSLSkpJE4MSHpDu9', source: 'pasted', createdAt: now.toISOString() },
        { name: 'Tems', spotifyId: null, source: 'interview', createdAt: now.toISOString() },
      ],
    })
  })
})

describe('PUT /me/artist-seeds', () => {
  it('401s without a session', async () => {
    const db = await createTestDb()
    expect((await put(db, authFor(null), { names: ['Tems'] })).status).toBe(401)
  })

  it('replaces the interview seeds: drops the ones missing from the list, adds the new ones, leaves other sources alone', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedUser(db, 'u2')
    const earlier = new Date(now.getTime() - 60_000)
    await db.insert(userArtistSeeds).values([
      { userId: 'u1', name: 'Old', source: 'interview', createdAt: earlier },
      { userId: 'u1', name: 'Kept', source: 'interview', createdAt: earlier },
      { userId: 'u1', name: 'Pasted', source: 'pasted', createdAt: earlier },
      { userId: 'u2', name: 'Old', source: 'interview', createdAt: earlier },
    ])

    const response = await put(db, authFor('u1'), { names: ['Kept', 'New'] })
    expect(response.status).toBe(200)
    const body = await response.json() as { seeds: Array<{ name: string; source: string }> }
    expect(body.seeds.map((s) => [s.name, s.source])).toEqual([
      ['Kept', 'interview'],
      ['Pasted', 'pasted'],
      ['New', 'interview'],
    ])

    const stored = await rows(db, 'u1')
    expect(stored.map((r) => [r.name, r.source])).toEqual([['Kept', 'interview'], ['New', 'interview'], ['Pasted', 'pasted']])
    // A kept seed keeps its original row, it is not re-inserted.
    expect(stored.find((r) => r.name === 'Kept')?.createdAt).toEqual(earlier)
    // Another user's interview seeds are untouched.
    expect((await rows(db, 'u2')).map((r) => r.name)).toEqual(['Old'])
  })

  it('leaves a name already present under another source untouched, matched case-insensitively', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await db.insert(userArtistSeeds).values({ userId: 'u1', name: 'Wizkid', source: 'pasted', createdAt: now })

    const response = await put(db, authFor('u1'), { names: ['wizkid', 'Tems'] })
    expect(response.status).toBe(200)
    expect((await rows(db, 'u1')).map((r) => [r.name, r.source])).toEqual([['Tems', 'interview'], ['Wizkid', 'pasted']])
  })

  it('trims and dedupes names case-insensitively, keeping the first spelling', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const response = await put(db, authFor('u1'), { names: ['  Wizkid ', 'wizkid', 'WIZKID', 'Tems'] })
    expect(response.status).toBe(200)
    expect((await rows(db, 'u1')).map((r) => r.name)).toEqual(['Tems', 'Wizkid'])
  })

  it('an empty list clears the interview seeds and nothing else', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await db.insert(userArtistSeeds).values([
      { userId: 'u1', name: 'A', source: 'interview' },
      { userId: 'u1', name: 'B', source: 'spotify_export' },
    ])
    const response = await put(db, authFor('u1'), { names: [] })
    expect(response.status).toBe(200)
    expect(await response.json()).toMatchObject({ seeds: [{ name: 'B', source: 'spotify_export' }] })
  })

  it('400s on more than 50 names, a blank name, an over-long name, a missing list, or an unknown key', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    for (const body of [
      { names: Array.from({ length: 51 }, (_, i) => `Artist ${i}`) },
      { names: ['   '] },
      { names: ['x'.repeat(501)] },
      { names: 'Tems' },
      {},
      { names: ['Tems'], extra: true },
    ]) {
      expect((await put(db, authFor('u1'), body)).status, JSON.stringify(body).slice(0, 40)).toBe(400)
    }
    expect(await rows(db, 'u1')).toHaveLength(0)
  })
})
