import { describe, it, expect } from 'vitest'
import { and, eq } from 'drizzle-orm'
import { createTestDb, type TestDb } from '../helpers/db'
import {
  AlbumStoreError,
  choosePick,
  goBack,
  readPickState,
  upsertAlbums,
  writePickVersion,
} from '../../src/albums/store'
import type { VerifiedAlbum } from '../../src/albums/verify'
import { albumPicks, albums, djSessions, listenLater, sessionEvents, user } from '../../src/db/schema'

let counter = 0

function verified(over: Partial<VerifiedAlbum> = {}): VerifiedAlbum {
  counter += 1
  return {
    appleId: String(5000 + counter),
    upc: null,
    title: `Record ${counter}`,
    artist: 'Artist',
    releaseYear: 1990,
    trackCount: 10,
    durationMs: null,
    type: 'album',
    artwork: null,
    genre: null,
    why: 'because',
    fromShelf: false,
    modelOrder: 0,
    storefront: 'us',
    ...over,
  }
}

async function seedUser(db: TestDb, id = 'u1') {
  await db.insert(user).values({ id, name: id, email: `${id}@example.com`, emailVerified: false, createdAt: new Date(), updatedAt: new Date() })
}

async function seedSession(db: TestDb, userId = 'u1', kind: 'mix' | 'album' = 'album') {
  const [s] = await db.insert(djSessions).values({ userId, title: 's', kind }).returning()
  return s
}

async function threeAlbums(db: TestDb) {
  const rows = await upsertAlbums(db, [verified(), verified(), verified()])
  return [...rows.values()].map((r) => r.id)
}

function picks(ids: string[]) {
  return ids.map((albumId, i) => ({ albumId, reason: `reason ${i}`, newToThem: i === 0 }))
}

async function passedEvents(db: TestDb, sessionId: string) {
  return db.select().from(sessionEvents).where(and(eq(sessionEvents.sessionId, sessionId), eq(sessionEvents.type, 'album_passed')))
}

describe('upsertAlbums', () => {
  it('keeps one row per apple id and refreshes its fields', async () => {
    const db = await createTestDb()
    const first = verified({ appleId: '777', durationMs: null, upc: '012345678905' })
    const a = await upsertAlbums(db, [first])
    const b = await upsertAlbums(db, [{
      ...first, title: 'Renamed', durationMs: 3_000_000, upc: null,
      artwork: { url: 'https://a/{w}x{h}.jpg', width: 600, height: 600, bgColor: 'aabbcc' },
    }])
    expect(b.get('777')!.id).toBe(a.get('777')!.id)
    const rows = await db.select().from(albums).where(eq(albums.appleId, '777'))
    expect(rows).toHaveLength(1)
    expect(rows[0]).toMatchObject({
      title: 'Renamed', durationMs: 3_000_000, upc: '012345678905', appleCatalogStorefront: 'us',
      artworkUrlTemplate: 'https://a/{w}x{h}.jpg', artworkBgColor: 'aabbcc',
    })
    expect(rows[0].artworkFetchedAt).not.toBeNull()
  })

  it('returns an empty map for nothing', async () => {
    const db = await createTestDb()
    expect((await upsertAlbums(db, [])).size).toBe(0)
  })
})

describe('writePickVersion', () => {
  it('bumps the session version and writes ranks from zero', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const s = await seedSession(db)
    const ids = await threeAlbums(db)
    const { version } = await writePickVersion(db, { sessionId: s.id, userId: 'u1', picks: picks(ids) })
    expect(version).toBe(1)
    const [session] = await db.select().from(djSessions).where(eq(djSessions.id, s.id))
    expect(session.queueVersion).toBe(1)
    const rows = await db.select().from(albumPicks).where(eq(albumPicks.sessionId, s.id))
    expect(rows.map((r) => [r.rank, r.albumId])).toEqual(ids.map((id, i) => [i, id]))
    expect(rows.every((r) => r.version === 1)).toBe(true)
  })

  it('records album_passed only when the new version replaces the previous pick', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const s = await seedSession(db)
    const [a, b, c] = await threeAlbums(db)
    await writePickVersion(db, { sessionId: s.id, userId: 'u1', picks: picks([a, b]) })
    expect(await passedEvents(db, s.id)).toHaveLength(0)
    // Same pick, new runners-up: nothing passed over.
    await writePickVersion(db, { sessionId: s.id, userId: 'u1', picks: picks([a, c]) })
    expect(await passedEvents(db, s.id)).toHaveLength(0)
    await writePickVersion(db, { sessionId: s.id, userId: 'u1', picks: picks([c, a]) })
    expect(await passedEvents(db, s.id)).toHaveLength(1)
  })

  it('refuses a stale expectedVersion', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const s = await seedSession(db)
    const ids = await threeAlbums(db)
    await writePickVersion(db, { sessionId: s.id, userId: 'u1', picks: picks(ids) })
    const err = await writePickVersion(db, { sessionId: s.id, userId: 'u1', picks: picks(ids), expectedVersion: 0 }).catch((e) => e)
    expect(err).toBeInstanceOf(AlbumStoreError)
    expect(err.kind).toBe('conflict')
  })

  it('refuses a mix session and a session the user does not own', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedUser(db, 'u2')
    const mix = await seedSession(db, 'u1', 'mix')
    const other = await seedSession(db, 'u2')
    const ids = await threeAlbums(db)
    const wrong = await writePickVersion(db, { sessionId: mix.id, userId: 'u1', picks: picks(ids) }).catch((e) => e)
    expect(wrong.kind).toBe('wrong_kind')
    const missing = await writePickVersion(db, { sessionId: other.id, userId: 'u1', picks: picks(ids) }).catch((e) => e)
    expect(missing.kind).toBe('not_found')
  })
})

describe('readPickState', () => {
  it('returns the pick, runners-up and passed-over picks across versions', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const s = await seedSession(db)
    const [a, b, c] = await threeAlbums(db)
    const [d] = [...(await upsertAlbums(db, [verified()])).values()].map((r) => r.id)
    await writePickVersion(db, { sessionId: s.id, userId: 'u1', picks: picks([a, b]) })
    await writePickVersion(db, { sessionId: s.id, userId: 'u1', picks: picks([c, d, b]) })
    const state = await readPickState(db, s.id, 'u1')
    expect(state.version).toBe(2)
    expect(state.pick!.id).toBe(c)
    expect(state.pick!.version).toBe(2)
    expect(state.pick!.reason).toBe('reason 0')
    expect(state.pick!.newToThem).toBe(true)
    expect(state.runnersUp.map((r) => r.id)).toEqual([d, b])
    expect(state.passed.map((p) => [p.id, p.version])).toEqual([[a, 1]])
    expect(state.pick).toMatchObject({ appleId: expect.any(String), type: 'album', artwork: null, savedForLater: false })
  })

  it('lists a passed-over album that is a runner-up again only as a runner-up', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const s = await seedSession(db)
    const [a, b, c] = await threeAlbums(db)
    await writePickVersion(db, { sessionId: s.id, userId: 'u1', picks: picks([a]) })
    await writePickVersion(db, { sessionId: s.id, userId: 'u1', picks: picks([b]) })
    await writePickVersion(db, { sessionId: s.id, userId: 'u1', picks: picks([c, a]) })
    const state = await readPickState(db, s.id, 'u1')
    expect(state.runnersUp.map((r) => r.id)).toEqual([a])
    expect(state.passed.map((p) => p.id)).toEqual([b])
  })

  it('is empty for a session with no picks', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const s = await seedSession(db)
    expect(await readPickState(db, s.id, 'u1')).toEqual({ version: 0, pick: null, runnersUp: [], passed: [] })
  })

  it('marks savedForLater only for a live listen_later row', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const s = await seedSession(db)
    const [a, b] = await threeAlbums(db)
    await writePickVersion(db, { sessionId: s.id, userId: 'u1', picks: picks([a, b]) })
    await db.insert(listenLater).values([
      { userId: 'u1', albumId: a, sessionId: s.id },
      { userId: 'u1', albumId: b, sessionId: s.id, removedAt: new Date() },
    ])
    const state = await readPickState(db, s.id, 'u1')
    expect(state.pick!.savedForLater).toBe(true)
    expect(state.runnersUp[0].savedForLater).toBe(false)
  })
})

describe('choosePick and goBack', () => {
  it('choosePick moves a runner-up to the pick in a new version and records the pass', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const s = await seedSession(db)
    const [a, b, c] = await threeAlbums(db)
    await writePickVersion(db, { sessionId: s.id, userId: 'u1', picks: picks([a, b, c]) })
    const state = await choosePick(db, { sessionId: s.id, userId: 'u1', albumId: c, expectedVersion: 1 })
    expect(state.version).toBe(2)
    expect(state.pick!.id).toBe(c)
    expect(state.pick!.reason).toBe('reason 2')
    expect(state.runnersUp.map((r) => r.id)).toEqual([a, b])
    // a was passed over but is a runner-up now: listed once, as a runner-up.
    expect(state.passed).toEqual([])
    expect(await passedEvents(db, s.id)).toHaveLength(1)
  })

  it('choosePick refuses an album outside the latest version, and a stale version', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const s = await seedSession(db)
    const [a, b, c] = await threeAlbums(db)
    await writePickVersion(db, { sessionId: s.id, userId: 'u1', picks: picks([a, b]) })
    expect((await choosePick(db, { sessionId: s.id, userId: 'u1', albumId: c }).catch((e) => e)).kind).toBe('not_found')
    expect((await choosePick(db, { sessionId: s.id, userId: 'u1', albumId: b, expectedVersion: 7 }).catch((e) => e)).kind).toBe('conflict')
  })

  it('goBack copies an earlier version as a new one and records the pass', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const s = await seedSession(db)
    const [a, b, c] = await threeAlbums(db)
    await writePickVersion(db, { sessionId: s.id, userId: 'u1', picks: picks([a, b]) })
    await writePickVersion(db, { sessionId: s.id, userId: 'u1', picks: picks([c]) })
    const state = await goBack(db, { sessionId: s.id, userId: 'u1', version: 1 })
    expect(state.version).toBe(3)
    expect(state.pick!.id).toBe(a)
    expect(state.runnersUp.map((r) => r.id)).toEqual([b])
    expect(state.passed.map((p) => p.id)).toEqual([c])
    // One pass for v2 replacing a with c, one for goBack replacing c with a.
    expect(await passedEvents(db, s.id)).toHaveLength(2)
    expect((await goBack(db, { sessionId: s.id, userId: 'u1', version: 9 }).catch((e) => e)).kind).toBe('not_found')
  })

  it('choosePick on the current pick and goBack to the current version are no-ops', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const s = await seedSession(db)
    const [a, b] = await threeAlbums(db)
    await writePickVersion(db, { sessionId: s.id, userId: 'u1', picks: picks([a, b]) })
    const chose = await choosePick(db, { sessionId: s.id, userId: 'u1', albumId: a, expectedVersion: 1 })
    expect(chose.version).toBe(1)
    expect(chose.pick!.id).toBe(a)
    const back = await goBack(db, { sessionId: s.id, userId: 'u1', version: 1, expectedVersion: 1 })
    expect(back.version).toBe(1)
    const rows = await db.select().from(albumPicks).where(eq(albumPicks.sessionId, s.id))
    expect(rows.every((r) => r.version === 1)).toBe(true)
    expect(await passedEvents(db, s.id)).toHaveLength(0)
  })

  it('goBack to a version with the same pick writes a version but records no pass', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const s = await seedSession(db)
    const [a, b, c] = await threeAlbums(db)
    await writePickVersion(db, { sessionId: s.id, userId: 'u1', picks: picks([a, b]) })
    await writePickVersion(db, { sessionId: s.id, userId: 'u1', picks: picks([a, c]) })
    const state = await goBack(db, { sessionId: s.id, userId: 'u1', version: 1 })
    expect(state.version).toBe(3)
    expect(state.runnersUp.map((r) => r.id)).toEqual([b])
    expect(await passedEvents(db, s.id)).toHaveLength(0)
  })
})
