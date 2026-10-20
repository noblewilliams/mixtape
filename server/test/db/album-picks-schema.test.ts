import { describe, it, expect } from 'vitest'
import { eq } from 'drizzle-orm'
import { createTestDb, type TestDb } from '../helpers/db'
import {
  albums,
  albumPicks,
  listenLater,
  djSessions,
  sessionEvents,
  user,
} from '../../src/db/schema'

// Postgres puts the violated constraint (or index) name on the driver error;
// drizzle wraps that error as `cause`.
async function expectViolation(promise: Promise<unknown>, constraint: string) {
  const err = await promise.then(
    () => undefined,
    (e: unknown) => e,
  )
  expect(err, `expected ${constraint} to be violated`).toBeDefined()
  const e = err as { constraint?: string; cause?: { constraint?: string } }
  expect(e.cause?.constraint ?? e.constraint).toBe(constraint)
}

async function seedUser(db: TestDb, id = 'u1') {
  await db.insert(user).values({
    id,
    name: 'T',
    email: `${id}@example.com`,
    emailVerified: false,
    createdAt: new Date(),
    updatedAt: new Date(),
  })
  return id
}

async function seedSession(db: TestDb, kind?: 'mix' | 'album') {
  const userId = await seedUser(db)
  const [session] = await db
    .insert(djSessions)
    .values({ userId, title: 'Sunday', ...(kind ? { kind } : {}) })
    .returning()
  return session
}

async function seedAlbum(db: TestDb, appleId: string | null = 'a1') {
  const [album] = await db
    .insert(albums)
    .values({ appleId, title: 'Blue', artist: 'Joni Mitchell', type: 'album' })
    .returning()
  return album
}

describe('albums', () => {
  it('round-trips every column', async () => {
    const db = await createTestDb()
    const fetchedAt = new Date('2026-10-20T10:00:00.000Z')
    await db.insert(albums).values({
      upc: '075992742926',
      appleId: '1440815640',
      appleCatalogStorefront: 'us',
      title: 'Blue',
      artist: 'Joni Mitchell',
      releaseYear: 1971,
      trackCount: 10,
      durationMs: 2_160_000,
      type: 'album',
      artworkUrlTemplate: 'https://is1-ssl.mzstatic.com/image/thumb/{w}x{h}bb.{f}',
      artworkWidth: 3000,
      artworkHeight: 3000,
      artworkBgColor: 'a1b2c3',
      artworkFetchedAt: fetchedAt,
    })
    const [row] = await db.select().from(albums)
    expect(row).toMatchObject({
      upc: '075992742926',
      appleId: '1440815640',
      appleCatalogStorefront: 'us',
      title: 'Blue',
      artist: 'Joni Mitchell',
      releaseYear: 1971,
      trackCount: 10,
      durationMs: 2_160_000,
      type: 'album',
      artworkUrlTemplate: 'https://is1-ssl.mzstatic.com/image/thumb/{w}x{h}bb.{f}',
      artworkWidth: 3000,
      artworkHeight: 3000,
      artworkBgColor: 'a1b2c3',
    })
    expect(row.id).toMatch(/^[0-9a-f-]{36}$/)
    expect(row.artworkFetchedAt?.toISOString()).toBe(fetchedAt.toISOString())
    expect(row.createdAt).toBeInstanceOf(Date)
  })

  it('rejects a duplicate apple_id but allows two null apple_ids', async () => {
    const db = await createTestDb()
    await seedAlbum(db, 'a1')
    await expectViolation(seedAlbum(db, 'a1'), 'albums_apple_id_idx')
    await seedAlbum(db, null)
    await seedAlbum(db, null)
    expect(await db.select().from(albums)).toHaveLength(3)
  })

  it('rejects a type outside the allowed list', async () => {
    const db = await createTestDb()
    await expectViolation(
      db.execute(`INSERT INTO albums (title, artist, type) VALUES ('X', 'Y', 'boxset')`),
      'albums_type_check',
    )
  })

  it('rejects a bad storefront and non-positive counts', async () => {
    const db = await createTestDb()
    await expectViolation(
      db.insert(albums).values({ title: 'X', artist: 'Y', type: 'ep', appleCatalogStorefront: 'USA' }),
      'albums_apple_catalog_storefront_check',
    )
    await expectViolation(
      db.insert(albums).values({ title: 'X', artist: 'Y', type: 'ep', trackCount: 0 }),
      'albums_track_count_positive_check',
    )
    await expectViolation(
      db.insert(albums).values({ title: 'X', artist: 'Y', type: 'ep', durationMs: 0 }),
      'albums_duration_ms_positive_check',
    )
  })
})

describe('dj_sessions.kind', () => {
  it("defaults to 'mix' and accepts 'album'", async () => {
    const db = await createTestDb()
    const session = await seedSession(db)
    expect(session.kind).toBe('mix')
    const [album] = await db
      .insert(djSessions)
      .values({ userId: session.userId, title: 'Albums', kind: 'album' })
      .returning()
    expect(album.kind).toBe('album')
  })

  it("rejects 'queue'", async () => {
    const db = await createTestDb()
    const session = await seedSession(db)
    await expectViolation(
      db.execute(`UPDATE dj_sessions SET kind = 'queue' WHERE id = '${session.id}'`),
      'dj_sessions_kind_check',
    )
  })
})

describe('album_picks', () => {
  async function setup() {
    const db = await createTestDb()
    const session = await seedSession(db, 'album')
    const album = await seedAlbum(db)
    const pick = (version: number, rank: number) =>
      db.insert(albumPicks).values({
        sessionId: session.id,
        version,
        rank,
        albumId: album.id,
        reason: 'Because Sunday',
      })
    return { db, session, album, pick }
  }

  it('round-trips with defaults', async () => {
    const { db, pick } = await setup()
    await pick(1, 0)
    const [row] = await db.select().from(albumPicks)
    expect(row.newToThem).toBe(false)
    expect(row.createdAt).toBeInstanceOf(Date)
  })

  it('rejects version 0 and rank -1', async () => {
    const { pick } = await setup()
    await expectViolation(pick(0, 0), 'album_picks_version_positive_check')
    await expectViolation(pick(1, -1), 'album_picks_rank_nonnegative_check')
  })

  it('rejects a duplicate (session_id, version, rank)', async () => {
    const { pick } = await setup()
    await pick(1, 0)
    await pick(1, 1)
    await pick(2, 0)
    await expectViolation(pick(1, 0), 'album_picks_session_version_rank_idx')
  })

  it('cascades when the session is deleted', async () => {
    const { db, session, pick } = await setup()
    await pick(1, 0)
    await db.delete(djSessions).where(eq(djSessions.id, session.id))
    expect(await db.select().from(albumPicks)).toHaveLength(0)
  })
})

describe('listen_later', () => {
  it('is keyed by (user_id, album_id) and nulls session_id when the session goes', async () => {
    const db = await createTestDb()
    const session = await seedSession(db, 'album')
    const album = await seedAlbum(db)
    await db.insert(listenLater).values({
      userId: session.userId,
      albumId: album.id,
      sessionId: session.id,
    })
    await expectViolation(
      db.insert(listenLater).values({ userId: session.userId, albumId: album.id }),
      'listen_later_user_id_album_id_pk',
    )

    await db.delete(djSessions).where(eq(djSessions.id, session.id))
    const [row] = await db.select().from(listenLater)
    expect(row.sessionId).toBeNull()
    expect(row.savedAt).toBeInstanceOf(Date)
    expect(row.listenedAt).toBeNull()
    expect(row.removedAt).toBeNull()
  })

  it('cascades when the user is deleted', async () => {
    const db = await createTestDb()
    const session = await seedSession(db, 'album')
    const album = await seedAlbum(db)
    await db.insert(listenLater).values({ userId: session.userId, albumId: album.id })
    await db.delete(user).where(eq(user.id, session.userId))
    expect(await db.select().from(listenLater)).toHaveLength(0)
  })
})

describe('albums foreign keys', () => {
  it('rejects deleting an album still referenced by album_picks or listen_later', async () => {
    const db = await createTestDb()
    const session = await seedSession(db, 'album')
    const picked = await seedAlbum(db, 'a1')
    const saved = await seedAlbum(db, 'a2')
    await db.insert(albumPicks).values({
      sessionId: session.id,
      version: 1,
      rank: 0,
      albumId: picked.id,
      reason: 'Because Sunday',
    })
    await db.insert(listenLater).values({ userId: session.userId, albumId: saved.id })

    await expectViolation(
      db.delete(albums).where(eq(albums.id, picked.id)),
      'album_picks_album_id_albums_id_fk',
    )
    await expectViolation(
      db.delete(albums).where(eq(albums.id, saved.id)),
      'listen_later_album_id_albums_id_fk',
    )
    expect(await db.select().from(albums)).toHaveLength(2)
  })
})

describe('session_events.type', () => {
  it('accepts the album events and rejects an unknown type', async () => {
    const db = await createTestDb()
    const session = await seedSession(db, 'album')
    for (const type of ['album_saved', 'album_unsaved', 'album_passed', 'album_listened'] as const) {
      await db.insert(sessionEvents).values({ sessionId: session.id, type })
    }
    expect(await db.select().from(sessionEvents)).toHaveLength(4)
    await expectViolation(
      db.execute(
        `INSERT INTO session_events (session_id, type) VALUES ('${session.id}', 'album_loved')`,
      ),
      'session_events_type_check',
    )
  })
})
