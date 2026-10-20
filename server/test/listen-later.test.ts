import { describe, it, expect } from 'vitest'
import { eq } from 'drizzle-orm'
import { createTestDb, type TestDb } from './helpers/db'
import { createApp, type AuthLike } from '../src/app'
import type { AlbumDeps } from '../src/albums/loop'
import type { DjDeps } from '../src/dj/loop'
import type { LlmClient } from '../src/dj/llm'
import { albumPicks, albums, djSessions, listenLater, sessionEvents, user } from '../src/db/schema'

const llm: LlmClient = async () => ({ text: 'ok', toolCalls: [], raw: [{ type: 'text', text: 'ok' }], stopReason: 'end_turn', usage: null })
const embed = async () => new Array(1024).fill(0)
const djDeps: DjDeps = { llm, embed }
const albumDeps: AlbumDeps = {
  llm,
  embed,
  catalog: { searchAlbums: async () => [], getAlbums: async () => new Map() },
  defaultStorefront: 'us',
}

async function seedUser(db: TestDb, id: string) {
  await db.insert(user).values({ id, name: id, email: `${id}@example.com`, emailVerified: false, createdAt: new Date(), updatedAt: new Date() })
}

let counter = 0
async function seedAlbum(db: TestDb, title = `Record ${++counter}`) {
  const [a] = await db.insert(albums).values({ appleId: `al-${title}`, title, artist: 'Artist', type: 'album', trackCount: 9, durationMs: 2_000_000 }).returning()
  return a
}

function authedAs(id: string): AuthLike {
  return { handler: () => new Response('ok'), api: { getSession: async () => ({ user: { id } }) } }
}

function build(db: TestDb, userId = 'u1', withAlbums = true) {
  return createApp({ auth: authedAs(userId), db, dj: { deps: djDeps }, albums: withAlbums ? { deps: albumDeps } : undefined })
}

function send(app: ReturnType<typeof createApp>, method: string, path: string, body?: unknown) {
  return app.request(`http://x${path}`, {
    method,
    headers: { 'content-type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  })
}

async function eventTypes(db: TestDb, sessionId: string) {
  return (await db.select().from(sessionEvents).where(eq(sessionEvents.sessionId, sessionId))).map((e) => e.type).sort()
}

type Entry = { id: string; title: string; sessionId: string | null; savedAt: string; listenedAt: string | null; reason: string | null }

describe('GET /me albumPicks', () => {
  it('reports the flag', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const on = await (await send(build(db), 'GET', '/me')).json() as { albumPicks: boolean; merged: unknown }
    expect(on.albumPicks).toBe(true)
    expect(on.merged).toBeNull()
    const off = await (await send(build(db, 'u1', false), 'GET', '/me')).json() as { albumPicks: boolean }
    expect(off.albumPicks).toBe(false)
  })
})

describe('/me/listen-later', () => {
  it('is 404 everywhere with the flag off', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const album = await seedAlbum(db)
    const app = build(db, 'u1', false)
    expect((await send(app, 'GET', '/me/listen-later')).status).toBe(404)
    expect((await send(app, 'PUT', `/me/listen-later/${album.id}`, {})).status).toBe(404)
    expect((await send(app, 'DELETE', `/me/listen-later/${album.id}`)).status).toBe(404)
    expect((await send(app, 'POST', `/me/listen-later/${album.id}/listened`)).status).toBe(404)
    expect(await db.select().from(listenLater)).toHaveLength(0)
  })

  it('requires a session', async () => {
    const db = await createTestDb()
    const app = createApp({
      auth: { handler: () => new Response('ok'), api: { getSession: async () => null } },
      db, dj: { deps: djDeps }, albums: { deps: albumDeps },
    })
    expect((await send(app, 'GET', '/me/listen-later')).status).toBe(401)
  })

  it('saves, unsaves, re-saves and marks listened idempotently, recording events', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const album = await seedAlbum(db, 'Blue')
    const [session] = await db.insert(djSessions).values({ userId: 'u1', title: 'records', kind: 'album' }).returning()
    await db.insert(albumPicks).values([
      { sessionId: session.id, version: 1, rank: 0, albumId: album.id, reason: 'older reason' },
      { sessionId: session.id, version: 2, rank: 1, albumId: album.id, reason: 'grey mornings' },
    ])
    const app = build(db)

    const save = await send(app, 'PUT', `/me/listen-later/${album.id}`, { sessionId: session.id })
    expect(save.status).toBe(200)
    const { entry } = (await save.json()) as { entry: Entry }
    expect(entry).toMatchObject({ id: album.id, title: 'Blue', sessionId: session.id, listenedAt: null, reason: 'grey mornings' })
    expect((await send(app, 'PUT', `/me/listen-later/${album.id}`, {})).status).toBe(200)
    expect(await db.select().from(listenLater)).toHaveLength(1)
    // The second save without a session keeps the original session.
    expect((await db.select().from(listenLater))[0].sessionId).toBe(session.id)
    // A repeat save on a live row from another session that also offered it
    // keeps the saved date and the original source.
    const [other] = await db.insert(djSessions).values({ userId: 'u1', title: 'more records', kind: 'album' }).returning()
    await db.insert(albumPicks).values({ sessionId: other.id, version: 1, rank: 0, albumId: album.id, reason: 'later' })
    const repeat = await send(app, 'PUT', `/me/listen-later/${album.id}`, { sessionId: other.id })
    expect(repeat.status).toBe(200)
    const repeated = ((await repeat.json()) as { entry: Entry }).entry
    expect(repeated.savedAt).toBe(entry.savedAt)
    expect(repeated.sessionId).toBe(session.id)
    expect(await eventTypes(db, other.id)).toEqual([])

    let list = (await (await send(app, 'GET', '/me/listen-later')).json()) as { entries: Entry[] }
    expect(list.entries.map((e) => e.title)).toEqual(['Blue'])

    expect((await send(app, 'DELETE', `/me/listen-later/${album.id}`)).status).toBe(200)
    const again = await send(app, 'DELETE', `/me/listen-later/${album.id}`)
    expect(again.status).toBe(200)
    expect(await again.json()).toEqual({ ok: true })
    list = (await (await send(app, 'GET', '/me/listen-later')).json()) as { entries: Entry[] }
    expect(list.entries).toEqual([])
    // Listened needs a live row.
    expect((await send(app, 'POST', `/me/listen-later/${album.id}/listened`)).status).toBe(404)

    // Re-saving revives the same row.
    expect((await send(app, 'PUT', `/me/listen-later/${album.id}`, {})).status).toBe(200)
    const rows = await db.select().from(listenLater)
    expect(rows).toHaveLength(1)
    expect(rows[0].removedAt).toBeNull()

    const first = await send(app, 'POST', `/me/listen-later/${album.id}/listened`)
    expect(first.status).toBe(200)
    const firstAt = ((await first.json()) as { entry: Entry }).entry.listenedAt
    expect(firstAt).not.toBeNull()
    const second = await send(app, 'POST', `/me/listen-later/${album.id}/listened`)
    expect(((await second.json()) as { entry: Entry }).entry.listenedAt).toBe(firstAt)

    // One event per state change: repeats change nothing and record nothing.
    expect(await eventTypes(db, session.id)).toEqual(['album_listened', 'album_saved', 'album_saved', 'album_unsaved'])
  })

  it('records no event without a session', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const album = await seedAlbum(db)
    const app = build(db)
    const res = await send(app, 'PUT', `/me/listen-later/${album.id}`, {})
    expect(res.status).toBe(200)
    expect(((await res.json()) as { entry: Entry }).entry).toMatchObject({ sessionId: null, reason: null })
    await send(app, 'POST', `/me/listen-later/${album.id}/listened`)
    await send(app, 'DELETE', `/me/listen-later/${album.id}`)
    expect(await db.select().from(sessionEvents)).toHaveLength(0)
  })

  it('404s an unknown album, a malformed id and another listener\'s session', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedUser(db, 'u2')
    const album = await seedAlbum(db)
    const [foreign] = await db.insert(djSessions).values({ userId: 'u2', title: 'theirs', kind: 'album' }).returning()
    const app = build(db)
    const missing = '00000000-0000-4000-8000-000000000000'
    expect((await send(app, 'PUT', `/me/listen-later/${missing}`, {})).status).toBe(404)
    expect((await send(app, 'DELETE', `/me/listen-later/${missing}`)).status).toBe(404)
    expect((await send(app, 'POST', `/me/listen-later/${missing}/listened`)).status).toBe(404)
    expect((await send(app, 'PUT', '/me/listen-later/not-a-uuid', {})).status).toBe(404)
    expect((await send(app, 'DELETE', '/me/listen-later/not-a-uuid')).status).toBe(404)
    expect((await send(app, 'PUT', `/me/listen-later/${album.id}`, { sessionId: foreign.id })).status).toBe(404)
    expect((await send(app, 'PUT', `/me/listen-later/${album.id}`, { sessionId: 'nope' })).status).toBe(400)
    expect(await db.select().from(listenLater)).toHaveLength(0)
  })

  it('404s a session that is a mix or never offered the album, recording nothing', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const album = await seedAlbum(db)
    const elsewhere = await seedAlbum(db)
    const [mix] = await db.insert(djSessions).values({ userId: 'u1', title: 'a mix' }).returning()
    const [records] = await db.insert(djSessions).values({ userId: 'u1', title: 'records', kind: 'album' }).returning()
    await db.insert(albumPicks).values({ sessionId: records.id, version: 1, rank: 0, albumId: elsewhere.id, reason: 'not this one' })
    const app = build(db)
    const onMix = await send(app, 'PUT', `/me/listen-later/${album.id}`, { sessionId: mix.id })
    expect(onMix.status).toBe(404)
    expect(await onMix.json()).toEqual({ error: 'not_found' })
    expect((await send(app, 'PUT', `/me/listen-later/${album.id}`, { sessionId: records.id })).status).toBe(404)
    expect(await db.select().from(listenLater)).toHaveLength(0)
    expect(await db.select().from(sessionEvents)).toHaveLength(0)
  })

  it('is keyed by user', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedUser(db, 'u2')
    const album = await seedAlbum(db)
    const a = build(db, 'u1')
    const b = build(db, 'u2')
    await send(a, 'PUT', `/me/listen-later/${album.id}`, {})
    expect(((await (await send(b, 'GET', '/me/listen-later')).json()) as { entries: Entry[] }).entries).toEqual([])
    expect((await send(b, 'POST', `/me/listen-later/${album.id}/listened`)).status).toBe(404)
    // B's delete touches nothing of A's.
    expect((await send(b, 'DELETE', `/me/listen-later/${album.id}`)).status).toBe(200)
    const [row] = await db.select().from(listenLater)
    expect(row.userId).toBe('u1')
    expect(row.removedAt).toBeNull()
    expect(((await (await send(a, 'GET', '/me/listen-later')).json()) as { entries: Entry[] }).entries).toHaveLength(1)
  })

  it('orders unlistened (newest saved first) then listened (newest listened first)', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const [w, x, y, z, gone] = [await seedAlbum(db, 'W'), await seedAlbum(db, 'X'), await seedAlbum(db, 'Y'), await seedAlbum(db, 'Z'), await seedAlbum(db, 'Gone')]
    const t = (m: number) => new Date(Date.UTC(2026, 9, 1, 0, m))
    await db.insert(listenLater).values([
      { userId: 'u1', albumId: w.id, savedAt: t(1) },
      { userId: 'u1', albumId: x.id, savedAt: t(2) },
      { userId: 'u1', albumId: y.id, savedAt: t(3), listenedAt: t(10) },
      { userId: 'u1', albumId: z.id, savedAt: t(4), listenedAt: t(5) },
      { userId: 'u1', albumId: gone.id, savedAt: t(9), removedAt: t(11) },
    ])
    const res = await send(build(db), 'GET', '/me/listen-later')
    const { entries } = (await res.json()) as { entries: Array<Entry & Record<string, unknown>> }
    expect(entries.map((e) => e.title)).toEqual(['X', 'W', 'Y', 'Z'])
    expect(Object.keys(entries[0]).sort()).toEqual([
      'appleId', 'artist', 'artwork', 'durationMs', 'id', 'listenedAt', 'reason', 'releaseYear', 'savedAt',
      'sessionId', 'title', 'trackCount', 'type', 'upc',
    ])
  })
})
