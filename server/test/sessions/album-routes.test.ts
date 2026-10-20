import { describe, it, expect, vi } from 'vitest'
import { eq } from 'drizzle-orm'
import { createTestDb, type TestDb } from '../helpers/db'
import { createApp, type AuthLike } from '../../src/app'
import type { DjDeps } from '../../src/dj/loop'
import type { AlbumDeps } from '../../src/albums/loop'
import { LlmError, type LlmClient, type LlmComplete, type LlmToolCall, type LlmTurn } from '../../src/dj/llm'
import { AppleCatalogError, type AppleCatalogAlbumClient, type CatalogAlbum } from '../../src/musickit/catalog'
import type { Embedder } from '../../src/enrich/embedder'
import { albums, djSessions, sessionEvents, user, userMusicProfiles } from '../../src/db/schema'
import { upsertAlbums, writePickVersion } from '../../src/albums/store'

const fakeEmbed: Embedder = async () => {
  const v = new Array(1024).fill(0)
  v[0] = 1
  return v
}

type Scripted = { text?: string; toolCalls?: LlmToolCall[] }

// One scripted conversation shared by the mix and album loops; counts calls.
function scriptedLlm(script: Scripted[]) {
  const state = { calls: 0 }
  const llm: LlmClient = async () => {
    const s = script[Math.min(state.calls, script.length - 1)]
    state.calls += 1
    const raw: LlmTurn['raw'] = []
    if (s.text) raw.push({ type: 'text', text: s.text })
    for (const tc of s.toolCalls ?? []) raw.push({ type: 'tool_use', id: tc.id, name: tc.name, input: tc.input })
    return { text: s.text ?? '', toolCalls: s.toolCalls ?? [], raw, stopReason: 'end_turn', usage: null }
  }
  return { llm, state }
}

let appleCounter = 7000
function catalogAlbum(artist: string, title: string): CatalogAlbum {
  appleCounter += 1
  return {
    appleId: String(appleCounter), upc: null, title, artist, releaseYear: 1971, trackCount: 10, durationMs: null,
    isSingle: false, isCompilation: false, genre: null, artwork: { url: 'https://img/{w}x{h}.jpg', width: 600, height: 600, bgColor: null },
  }
}

function fakeCatalog(known: CatalogAlbum[]): AppleCatalogAlbumClient {
  const byTerm = new Map(known.map((a) => [`${a.artist} ${a.title}`, a]))
  return {
    searchAlbums: vi.fn(async (_m: string, term: string) => {
      const hit = byTerm.get(term)
      return hit ? [hit] : []
    }),
    getAlbums: vi.fn(async (_m: string, ids: readonly string[]) =>
      new Map(known.filter((a) => ids.includes(a.appleId)).map((a) => [a.appleId, { ...a, durationMs: 2_400_000 }]))),
  }
}

function recommendBlue(): Scripted[] {
  return [
    { toolCalls: [{ id: 'r1', name: 'recommend_album', input: { familiarity: 'mix', candidates: [{ artist: 'Joni Mitchell', title: 'Blue', type: 'album', why: 'grey morning' }] } }] },
    { text: 'Blue, start to finish.' },
  ]
}

async function seedUser(db: TestDb, id: string, isAnonymous = false) {
  await db.insert(user).values({ id, name: id, email: `${id}@example.com`, emailVerified: false, isAnonymous, createdAt: new Date(), updatedAt: new Date() })
  await db.insert(userMusicProfiles).values({ userId: id, appleStorefront: 'us' })
}

function authedAs(id: string, isAnonymous = false): AuthLike {
  return { handler: () => new Response('ok'), api: { getSession: async () => ({ user: { id, isAnonymous } }) } }
}

function build(db: TestDb, opts: {
  userId?: string; anonymous?: boolean; albums?: boolean; script?: Scripted[]; known?: CatalogAlbum[]
  llm?: LlmClient; catalog?: AppleCatalogAlbumClient; titleComplete?: LlmComplete
} = {}) {
  const scripted = scriptedLlm(opts.script ?? [{ text: 'ready.' }])
  const llm = opts.llm ?? scripted.llm
  const state = scripted.state
  const dj: DjDeps = { llm, embed: fakeEmbed }
  const albumDeps: AlbumDeps = {
    llm, embed: fakeEmbed, catalog: opts.catalog ?? fakeCatalog(opts.known ?? []), defaultStorefront: 'us',
    ...(opts.titleComplete ? { titleComplete: opts.titleComplete } : {}),
  }
  const app = createApp({
    auth: authedAs(opts.userId ?? 'u1', opts.anonymous ?? false),
    db,
    dj: { deps: dj },
    albums: opts.albums === false ? undefined : { deps: albumDeps },
  })
  return { app, state }
}

function send(app: ReturnType<typeof createApp>, method: string, path: string, body?: unknown) {
  return app.request(`http://x${path}`, {
    method,
    headers: { 'content-type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  })
}

// An album session with versions already written: v1 [a, b], so b is a runner-up.
async function seedAlbumSession(db: TestDb, userId = 'u1') {
  const [s] = await db.insert(djSessions).values({ userId, title: 'records', kind: 'album' }).returning()
  const a = catalogAlbum('Sade', 'Love Deluxe')
  const b = catalogAlbum('Joni Mitchell', 'Blue')
  const rows = await upsertAlbums(db, [a, b].map((x, i) => ({
    appleId: x.appleId, upc: null, storefront: 'us', title: x.title, artist: x.artist, releaseYear: 1990, trackCount: 10,
    durationMs: 2_400_000, type: 'album' as const, artwork: null, genre: null, why: `why ${i}`, fromShelf: false, modelOrder: i,
  })))
  const idA = rows.get(a.appleId)!.id
  const idB = rows.get(b.appleId)!.id
  await writePickVersion(db, { sessionId: s.id, userId, picks: [
    { albumId: idA, reason: 'why a', newToThem: true },
    { albumId: idB, reason: 'why b', newToThem: false },
  ] })
  return { id: s.id, idA, idB }
}

describe('album session routes', () => {
  it('POST /sessions defaults kind to mix', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const { app } = build(db)
    const res = await send(app, 'POST', '/sessions', { prompt: 'a mix' })
    expect(res.status).toBe(200)
    const body = (await res.json()) as { session: { id: string; kind: string }; queue: unknown }
    expect(body.session.kind).toBe('mix')
    expect(body.queue).toBeDefined()
  })

  it('kind album with the flag off is 404 album_picks_off and writes nothing', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const { app, state } = build(db, { albums: false })
    const res = await send(app, 'POST', '/sessions', { prompt: 'one record', kind: 'album' })
    expect(res.status).toBe(404)
    expect(await res.json()).toEqual({ error: 'album_picks_off' })
    expect(await db.select().from(djSessions)).toHaveLength(0)
    expect(state.calls).toBe(0)
  })

  it('anonymous listeners cannot start an album session', async () => {
    const db = await createTestDb()
    await seedUser(db, 'anon', true)
    const { app, state } = build(db, { userId: 'anon', anonymous: true })
    const res = await send(app, 'POST', '/sessions', { prompt: 'one record', kind: 'album' })
    expect(res.status).toBe(403)
    expect(await res.json()).toEqual({ error: 'anonymous_albums' })
    expect(await db.select().from(djSessions)).toHaveLength(0)
    expect(state.calls).toBe(0)
  })

  it('creates an album session and returns the pick shape', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const blue = catalogAlbum('Joni Mitchell', 'Blue')
    const { app } = build(db, { script: recommendBlue(), known: [blue] })
    const res = await send(app, 'POST', '/sessions', { prompt: 'a grey morning', kind: 'album', energyArc: 'steady' })
    expect(res.status).toBe(200)
    const body = (await res.json()) as Record<string, any>
    expect(body.session.kind).toBe('album')
    expect(body.pick.title).toBe('Blue')
    expect(body.pick.appleId).toBe(blue.appleId)
    expect(body.runnersUp).toEqual([])
    expect(body.passed).toEqual([])
    expect(body.version).toBe(1)
    expect(body.queue).toBeUndefined()
    expect(body.messages.map((m: { role: string }) => m.role)).toEqual(['user', 'dj'])
    const [row] = await db.select().from(djSessions)
    expect(row.kind).toBe('album')
  })

  it('GET /sessions/:id for an album session has no queue', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const { id } = await seedAlbumSession(db)
    const { app } = build(db)
    const res = await send(app, 'GET', `/sessions/${id}`)
    expect(res.status).toBe(200)
    const body = (await res.json()) as Record<string, any>
    expect(body.queue).toBeUndefined()
    expect(body.supportsInsert).toBeUndefined()
    expect(body.pick.title).toBe('Love Deluxe')
    expect(body.runnersUp.map((a: { title: string }) => a.title)).toEqual(['Blue'])
    expect(body.version).toBe(1)
    expect(body.session.kind).toBe('album')
    expect(body).toHaveProperty('playlistSeed')
  })

  it('GET /sessions rows carry kind, and album rows the pick', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const { id } = await seedAlbumSession(db)
    await db.insert(djSessions).values({ userId: 'u1', title: 'a mix' })
    await db.insert(djSessions).values({ userId: 'u1', title: 'empty records', kind: 'album' })
    const { app } = build(db)
    const res = await send(app, 'GET', '/sessions')
    const { sessions } = (await res.json()) as { sessions: Array<Record<string, any>> }
    expect(sessions).toHaveLength(3)
    const album = sessions.find((s) => s.id === id)!
    expect(album.kind).toBe('album')
    expect(album.pick).toEqual({ title: 'Love Deluxe', artist: 'Sade', artwork: null })
    const mix = sessions.find((s) => s.title === 'a mix')!
    expect(mix.kind).toBe('mix')
    expect(mix.pick).toBeUndefined()
    expect(mix.trackCount).toBe(0)
    expect(sessions.find((s) => s.title === 'empty records')!.pick).toBeNull()
  })

  it('POST /sessions/:id/messages dispatches by kind', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const blue = catalogAlbum('Joni Mitchell', 'Blue')
    const [albumSession] = await db.insert(djSessions).values({ userId: 'u1', title: 'records', kind: 'album' }).returning()
    const [mixSession] = await db.insert(djSessions).values({ userId: 'u1', title: 'mix' }).returning()
    const { app } = build(db, { script: recommendBlue(), known: [blue] })
    const res = await send(app, 'POST', `/sessions/${albumSession.id}/messages`, { text: 'a grey morning' })
    expect(res.status).toBe(200)
    const body = (await res.json()) as Record<string, any>
    expect(body.pick.title).toBe('Blue')
    expect(body.djMessage.content).toBe('Blue, start to finish.')
    expect(body.version).toBe(1)
    expect(body.queue).toBeUndefined()

    const { app: mixApp } = build(db, { script: [{ text: 'mix reply' }] })
    const mixRes = await send(mixApp, 'POST', `/sessions/${mixSession.id}/messages`, { text: 'more' })
    expect(mixRes.status).toBe(200)
    const mixBody = (await mixRes.json()) as Record<string, any>
    expect(mixBody.queue).toBeDefined()
    expect(mixBody.pick).toBeUndefined()
  })

  it('an album session message with the flag off is 404 album_picks_off', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const { id } = await seedAlbumSession(db)
    const { app, state } = build(db, { albums: false })
    const res = await send(app, 'POST', `/sessions/${id}/messages`, { text: 'another' })
    expect(res.status).toBe(404)
    expect(await res.json()).toEqual({ error: 'album_picks_off' })
    expect(state.calls).toBe(0)
  })

  it('queue-ops on an album session is 409 wrong_session_kind', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const { id } = await seedAlbumSession(db)
    const { app } = build(db)
    const res = await send(app, 'POST', `/sessions/${id}/queue-ops`, { ops: [{ op: 'remove', position: 0 }] })
    expect(res.status).toBe(409)
    expect(await res.json()).toEqual({ error: 'wrong_session_kind' })
  })

  it('mix history versions on an album session is 409 wrong_session_kind', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const { id } = await seedAlbumSession(db)
    const { app } = build(db)
    for (const path of [`/sessions/${id}/versions`, `/sessions/${id}/versions/1`]) {
      const res = await send(app, 'GET', path)
      expect(res.status).toBe(409)
      expect(await res.json()).toEqual({ error: 'wrong_session_kind' })
    }
    const restore = await send(app, 'POST', `/sessions/${id}/versions/restore`, { version: 1, expectedVersion: 1, requestId: 'r' })
    expect(restore.status).toBe(409)
  })

  it('POST /sessions/:id/pick with albumId swaps the pick and records album_passed', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const { id, idB } = await seedAlbumSession(db)
    const { app } = build(db)
    const res = await send(app, 'POST', `/sessions/${id}/pick`, { albumId: idB, expectedVersion: 1 })
    expect(res.status).toBe(200)
    const body = (await res.json()) as Record<string, any>
    expect(body.pick.title).toBe('Blue')
    expect(body.version).toBe(2)
    expect(body.runnersUp.map((a: { title: string }) => a.title)).toEqual(['Love Deluxe'])
    expect(Object.keys(body).sort()).toEqual(['passed', 'pick', 'runnersUp', 'version'])
    const events = await db.select().from(sessionEvents).where(eq(sessionEvents.sessionId, id))
    expect(events.map((e) => e.type)).toEqual(['album_passed'])
  })

  it('POST /sessions/:id/pick with version goes back', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const { id, idB } = await seedAlbumSession(db)
    const { app } = build(db)
    await send(app, 'POST', `/sessions/${id}/pick`, { albumId: idB })
    const res = await send(app, 'POST', `/sessions/${id}/pick`, { version: 1, expectedVersion: 2 })
    expect(res.status).toBe(200)
    const body = (await res.json()) as Record<string, any>
    expect(body.version).toBe(3)
    expect(body.pick.title).toBe('Love Deluxe')
  })

  it('POST /sessions/:id/pick rejects a stale expectedVersion, bad bodies, unknown albums and mix sessions', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const { id, idB } = await seedAlbumSession(db)
    const [mix] = await db.insert(djSessions).values({ userId: 'u1', title: 'mix' }).returning()
    const { app } = build(db)

    const stale = await send(app, 'POST', `/sessions/${id}/pick`, { albumId: idB, expectedVersion: 0 })
    expect(stale.status).toBe(409)
    expect(await stale.json()).toEqual({ error: 'stale', version: 1 })

    expect((await send(app, 'POST', `/sessions/${id}/pick`, { albumId: idB, version: 1 })).status).toBe(400)
    expect((await send(app, 'POST', `/sessions/${id}/pick`, {})).status).toBe(400)
    expect((await send(app, 'POST', `/sessions/${id}/pick`, { version: 0 })).status).toBe(400)

    const unknown = await send(app, 'POST', `/sessions/${id}/pick`, { albumId: '00000000-0000-4000-8000-000000000000' })
    expect(unknown.status).toBe(404)

    const onMix = await send(app, 'POST', `/sessions/${mix.id}/pick`, { albumId: idB })
    expect(onMix.status).toBe(409)
    expect(await onMix.json()).toEqual({ error: 'wrong_session_kind' })

    expect((await send(app, 'POST', '/sessions/not-a-uuid/pick', { albumId: idB })).status).toBe(404)
  })

  it('POST /sessions/:id/pick is 404 album_picks_off with the flag off', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const { id, idB } = await seedAlbumSession(db)
    const { app } = build(db, { albums: false })
    const res = await send(app, 'POST', `/sessions/${id}/pick`, { albumId: idB })
    expect(res.status).toBe(404)
    expect(await res.json()).toEqual({ error: 'album_picks_off' })
    // The flag answers before the body is validated.
    const badBody = await send(app, 'POST', `/sessions/${id}/pick`, {})
    expect(badBody.status).toBe(404)
    expect(await badBody.json()).toEqual({ error: 'album_picks_off' })
    expect((await db.select().from(albums))).toHaveLength(2)
  })

  it('a catalogue failure on create is 502 catalogue with a step and the session id, no detail', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const catalog: AppleCatalogAlbumClient = {
      searchAlbums: vi.fn(async () => { throw new AppleCatalogError('upstream', 503) }),
      getAlbums: vi.fn(async () => new Map()),
    }
    const { app } = build(db, { script: recommendBlue(), catalog })
    const res = await send(app, 'POST', '/sessions', { prompt: 'a grey morning', kind: 'album' })
    expect(res.status).toBe(502)
    const body = (await res.json()) as Record<string, unknown>
    expect(body.error).toBe('catalogue')
    expect(typeof body.step).toBe('string')
    const [row] = await db.select().from(djSessions)
    expect(body.sessionId).toBe(row.id)
    expect(body).not.toHaveProperty('detail')
  })

  it('a model failure on an album message is 502 upstream', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const { id } = await seedAlbumSession(db)
    const llm: LlmClient = async () => { throw new LlmError('overloaded', 529) }
    const { app } = build(db, { llm })
    const res = await send(app, 'POST', `/sessions/${id}/messages`, { text: 'another' })
    expect(res.status).toBe(502)
    const body = (await res.json()) as Record<string, unknown>
    expect(body.error).toBe('upstream')
    expect(body).not.toHaveProperty('detail')
  })

  it('album create takes the generated title, and an explicit rename beats it', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const blue = catalogAlbum('Joni Mitchell', 'Blue')
    const titleComplete: LlmComplete = async () => 'Grey Morning Records'
    const { app } = build(db, { script: recommendBlue(), known: [blue], titleComplete })
    const res = await send(app, 'POST', '/sessions', { prompt: 'a grey morning', kind: 'album' })
    expect(res.status).toBe(200)
    expect(((await res.json()) as { session: { title: string } }).session.title).toBe('Grey Morning Records')

    const blue2 = catalogAlbum('Joni Mitchell', 'Blue')
    const renaming: Scripted[] = [
      { toolCalls: [{ id: 'n1', name: 'rename_session', input: { title: 'Joni Hours' } }] },
      ...recommendBlue(),
    ]
    const { app: renameApp } = build(db, { script: renaming, known: [blue2], titleComplete })
    const renamed = await send(renameApp, 'POST', '/sessions', { prompt: 'a grey morning', kind: 'album' })
    expect(renamed.status).toBe(200)
    const body = (await renamed.json()) as { session: { id: string; title: string }; sessionTitle?: string }
    expect(body.session.title).toBe('Joni Hours')
    const [row] = await db.select().from(djSessions).where(eq(djSessions.id, body.session.id))
    expect(row.title).toBe('Joni Hours')
  })

  it('an album message turn moves the session to the top of GET /sessions', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const blue = catalogAlbum('Joni Mitchell', 'Blue')
    const old = new Date(Date.UTC(2026, 0, 1))
    const [albumSession] = await db.insert(djSessions).values({ userId: 'u1', title: 'records', kind: 'album', updatedAt: old }).returning()
    await db.insert(djSessions).values({ userId: 'u1', title: 'a mix', updatedAt: new Date(Date.UTC(2026, 5, 1)) })
    const { app } = build(db, { script: recommendBlue(), known: [blue] })
    const before = (await (await send(app, 'GET', '/sessions')).json()) as { sessions: Array<{ id: string }> }
    expect(before.sessions[0].id).not.toBe(albumSession.id)
    expect((await send(app, 'POST', `/sessions/${albumSession.id}/messages`, { text: 'a grey morning' })).status).toBe(200)
    const after = (await (await send(app, 'GET', '/sessions')).json()) as { sessions: Array<{ id: string; updatedAt: string }> }
    expect(after.sessions[0].id).toBe(albumSession.id)
    expect(new Date(after.sessions[0].updatedAt).getTime()).toBeGreaterThan(old.getTime())
  })

  it('another listener cannot read or pick on an album session', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedUser(db, 'u2')
    const { id, idB } = await seedAlbumSession(db)
    const { app } = build(db, { userId: 'u2' })
    expect((await send(app, 'GET', `/sessions/${id}`)).status).toBe(404)
    expect((await send(app, 'POST', `/sessions/${id}/pick`, { albumId: idB })).status).toBe(404)
  })
})
