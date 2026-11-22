import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { and, eq } from 'drizzle-orm'
import { createTestDb, forkTestDb, type TestDb } from '../helpers/db'
import { createApp } from '../../src/app'
import { CONFLICT_APOLOGY, type DjDeps } from '../../src/dj/loop'
import { LlmError, type LlmClient, type LlmComplete } from '../../src/dj/llm'
import { djMessages, djSessions, djTurns, user } from '../../src/db/schema'
import { eventsOnly, readEvents, readSse } from '../helpers/sse'
import { embed, FAST, generate, mixSession, normalized, queueMessageTurn, scriptedLlm, seedLibrary, seedUser, turnRow } from '../helpers/turn-job'
import { authedAs, durableApp, fakeTurnRunners, type FakeRunners } from '../helpers/turn-runners'

// S5 of plan 2026-11-22 durable-mix-turns: with DURABLE_TURNS on, the mix
// routes write the persist-first rows and answer from the session's
// TurnRunner object (a TurnRunnerCore in process). With it off, every path is
// the in-request one, which the rest of the suite covers untouched.

const STREAM = { accept: 'text/event-stream' }

beforeEach(() => {
  vi.spyOn(console, 'log').mockImplementation(() => {})
})
afterEach(() => {
  vi.restoreAllMocks()
})

type App = { request: ReturnType<typeof createApp>['request'] }

function plainApp(db: TestDb, deps: DjDeps, userId = 'u1', extra: { aiConsent?: 'enforce'; anonymous?: boolean } = {}) {
  return createApp({ auth: authedAs(userId, extra.anonymous ?? false), db, dj: { deps }, ...(extra.aiConsent ? { aiConsent: extra.aiConsent } : {}) })
}

function post(app: App, path: string, body: unknown, headers: Record<string, string> = {}) {
  return app.request(`http://x${path}`, { method: 'POST', headers: { 'content-type': 'application/json', ...headers }, body: JSON.stringify(body) })
}

function get(app: App, path: string) {
  return app.request(`http://x${path}`)
}

// The durable stream less its `turn` event: what streamTurn sends today.
function withoutTurnEvent(text: string): string {
  return text.replace(/event: turn\ndata: [^\n]*\n\n/, '')
}

async function listener(libraryTracks = 4): Promise<TestDb> {
  const db = await createTestDb()
  await seedUser(db)
  await seedLibrary(db, 'u1', libraryTracks)
  return db
}

const count = async (db: TestDb, table: typeof djTurns | typeof djSessions) => (await db.select().from(table)).length

function deferred() {
  let resolve!: () => void
  const promise = new Promise<void>((r) => (resolve = r))
  return { promise, resolve }
}

describe('DURABLE_TURNS on: the answer is today\'s', () => {
  it('POST /sessions streams session, turn, the steps, then result: today\'s bytes plus turn', async () => {
    const base = await listener()
    const [a, b] = [await forkTestDb(base), await forkTestDb(base)]
    const titleComplete: LlmComplete = async () => 'Rainy Drive'
    const runners = fakeTurnRunners(b, { embed, llm: scriptedLlm(generate(3)), titleComplete })

    const today = await post(plainApp(a, { embed, llm: scriptedLlm(generate(3)), titleComplete }), '/sessions', { prompt: 'a rainy drive' }, STREAM)
    const durable = await post(durableApp(b, { embed, llm: scriptedLlm(generate(3)), titleComplete }, runners), '/sessions', { prompt: 'a rainy drive' }, STREAM)

    expect(durable.status).toBe(200)
    expect(durable.headers.get('content-type')).toBe('text/event-stream; charset=utf-8')
    expect(durable.headers.get('cache-control')).toBe('no-cache, no-transform')
    const text = await durable.text()
    await runners.settled()
    const events = eventsOnly(await readSse(new Response(text)))
    expect(events.map((e) => e.event)).toEqual(['session', 'turn', 'step', 'step', 'step', 'step', 'result'])
    const sessionId = (events[0].data as { session: { id: string } }).session.id
    const { turnId, push } = events[1].data as { turnId: string; push: boolean }
    expect(push).toBe(false)
    expect(normalized(withoutTurnEvent(text))).toBe(normalized(await today.text()))

    // One turn row, done, and the session points at it.
    expect(await turnRow(b, turnId)).toMatchObject({ sessionId, userId: 'u1', kind: 'create', status: 'done', attempt: 1 })
    const [row] = await b.select().from(djSessions).where(eq(djSessions.id, sessionId))
    expect(row.currentTurnId).toBe(turnId)
    expect(row.title).toBe('Rainy Drive')
  })

  it('POST /sessions as JSON answers today\'s body', async () => {
    const base = await listener()
    const [a, b] = [await forkTestDb(base), await forkTestDb(base)]
    const titleComplete: LlmComplete = async () => 'Rainy Drive'
    const runners = fakeTurnRunners(b, { embed, llm: scriptedLlm(generate(3)), titleComplete })

    const today = await post(plainApp(a, { embed, llm: scriptedLlm(generate(3)), titleComplete }), '/sessions', { prompt: 'a rainy drive' })
    const durable = await post(durableApp(b, { embed, llm: scriptedLlm(generate(3)), titleComplete }, runners), '/sessions', { prompt: 'a rainy drive' })

    expect(durable.status).toBe(200)
    expect(durable.headers.get('content-type')).toMatch(/^application\/json/)
    expect(normalized(await durable.text())).toBe(normalized(await today.text()))
    await runners.settled()
  })

  it('POST /sessions/:id/messages, stream and JSON, and a remake flag reach the job', async () => {
    const base = await listener(3)
    const sessionId = await mixSession(base)
    const [a, b, c] = [await forkTestDb(base), await forkTestDb(base), await forkTestDb(base)]
    const path = `/sessions/${sessionId}/messages`

    const todayJson = await post(plainApp(a, { embed, llm: scriptedLlm(generate(3)) }), path, { text: 'play something' })
    const todayJsonText = await todayJson.text()
    const streamRunners = fakeTurnRunners(b, { embed, llm: scriptedLlm(generate(3)) })
    const stream = await post(durableApp(b, { embed, llm: scriptedLlm(generate(3)) }, streamRunners), path, { text: 'play something' }, STREAM)
    const jsonRunners = fakeTurnRunners(c, { embed, llm: scriptedLlm(generate(3)) })
    const json = await post(durableApp(c, { embed, llm: scriptedLlm(generate(3)) }, jsonRunners), path, { text: 'play something' })

    const events = eventsOnly(await readSse(stream))
    expect(events.map((e) => e.event)).toEqual(['turn', 'step', 'step', 'step', 'step', 'result'])
    expect(normalized(events[5].raw)).toBe(normalized(todayJsonText))
    expect(json.status).toBe(200)
    expect(normalized(await json.text())).toBe(normalized(todayJsonText))
    await Promise.all([streamRunners.settled(), jsonRunners.settled()])
    const turns = await c.select().from(djTurns)
    expect(turns.map((t) => [t.kind, t.status])).toEqual([['message', 'done']])
  })

  it('a failed turn answers the same status and body as today, on both paths', async () => {
    const base = await listener(3)
    const sessionId = await mixSession(base)
    const [a, b, c] = [await forkTestDb(base), await forkTestDb(base), await forkTestDb(base)]
    const llm: LlmClient = async () => {
      throw new LlmError('boom', 500)
    }
    const path = `/sessions/${sessionId}/messages`

    const today = await post(plainApp(a, { embed, llm }), path, { text: 'more' })
    const json = await post(durableApp(b, { embed, llm }, fakeTurnRunners(b, { embed, llm })), path, { text: 'more' })
    const stream = await post(durableApp(c, { embed, llm }, fakeTurnRunners(c, { embed, llm })), path, { text: 'more' }, STREAM)

    expect(today.status).toBe(502)
    expect(json.status).toBe(502)
    const todayText = await today.text()
    expect(await json.text()).toBe(todayText)
    const error = eventsOnly(await readSse(stream)).at(-1)!
    expect(error.event).toBe('error')
    expect(error.data).toEqual({ status: 502, body: JSON.parse(todayText) })
    const [turn] = await b.select().from(djTurns)
    expect(turn).toMatchObject({ status: 'failed', errorKind: 'llm' })
  })

  it('carries the CORS headers on the object\'s stream', async () => {
    const db = await listener()
    const origin = 'https://mixtape.example.com'
    const deps = { embed, llm: scriptedLlm([{ text: 'ready.' }]) }
    const runners = fakeTurnRunners(db, deps)
    const res = await post(durableApp(db, deps, runners, { allowedOrigins: [origin] }), '/sessions', { prompt: 'hello' }, { origin, ...STREAM })
    expect(res.headers.get('access-control-allow-origin')).toBe(origin)
    expect(eventsOnly(await readSse(res)).map((e) => e.event)).toEqual(['session', 'turn', 'result'])
    await runners.settled()
  })
})

describe('DURABLE_TURNS on: refusals before the turn keep their status and body', () => {
  // The same request to the in-request app and the durable one, plain and
  // asking for a stream: same status, same JSON. Nothing is started.
  async function sameRefusal(db: TestDb, path: string, body: unknown, status: number, opts: { userId?: string; aiConsent?: 'enforce'; anonymous?: boolean } = {}) {
    const deps = { embed, llm: scriptedLlm([{ text: 'never.' }]) }
    const runners = fakeTurnRunners(db, deps)
    const userId = opts.userId ?? 'u1'
    const today = await post(plainApp(db, deps, userId, opts), path, body)
    const todayText = await today.text()
    for (const headers of [{}, STREAM]) {
      const res = await post(durableApp(db, deps, runners, { userId, ...opts }), path, body, headers)
      expect(res.status).toBe(status)
      expect(res.headers.get('content-type')).toMatch(/^application\/json/)
      expect(await res.text()).toBe(todayText)
    }
    expect(today.status).toBe(status)
    expect(runners.runners.size).toBe(0)
  }

  it('validation, consent, 404, playlist seed, album and remake refusals', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedUser(db, 'u2')
    const sessionId = await mixSession(db)
    const [album] = await db.insert(djSessions).values({ userId: 'u1', title: 'records', kind: 'album' }).returning()
    await sameRefusal(db, '/sessions', { prompt: '' }, 400)
    await sameRefusal(db, `/sessions/${sessionId}/messages`, { text: '' }, 400)
    await sameRefusal(db, '/sessions', { prompt: 'hello' }, 403, { aiConsent: 'enforce' })
    await sameRefusal(db, `/sessions/${sessionId}/messages`, { text: 'hello' }, 403, { aiConsent: 'enforce' })
    await sameRefusal(db, `/sessions/${sessionId}/messages`, { text: 'hijack' }, 404, { userId: 'u2' })
    await sameRefusal(db, '/sessions/00000000-0000-4000-8000-000000000000/messages', { text: 'hi' }, 404)
    await sameRefusal(db, '/sessions', { prompt: 'hello', playlistSeed: { playlistId: '00000000-0000-4000-8000-000000000000' } }, 404)
    await sameRefusal(db, '/sessions', { prompt: 'one record', kind: 'album' }, 404)
    await sameRefusal(db, `/sessions/${album.id}/messages`, { text: 'another' }, 404)
    await sameRefusal(db, `/sessions/${album.id}/messages`, { text: 'Remake this with my music', remake: true }, 409)
    expect(await count(db, djTurns)).toBe(0)
    // The seed refusal rolled its whole transaction back.
    expect(await count(db, djSessions)).toBe(2)
  })

  it('anonymous_cap, writing nothing', async () => {
    const db = await createTestDb()
    await db.insert(user).values({ id: 'anon', name: 'anon', email: 'anon@example.com', emailVerified: false, isAnonymous: true, createdAt: new Date(), updatedAt: new Date() })
    await db.insert(djSessions).values([1, 2, 3].map((i) => ({ userId: 'anon', title: `s${i}` })))
    await sameRefusal(db, '/sessions', { prompt: 'one more' }, 403, { userId: 'anon', anonymous: true })
    expect(await count(db, djSessions)).toBe(3)
    expect(await count(db, djTurns)).toBe(0)
  })
})

describe('Idempotency-Key', () => {
  const KEY = '6f1c2d3e-4b5a-4c6d-8e7f-0a1b2c3d4e5f'

  it('a replayed create attaches to its turn: no second mix, message or start', async () => {
    const db = await listener()
    const deps = { embed, llm: scriptedLlm(generate(3)) }
    const runners = fakeTurnRunners(db, deps)
    const app = durableApp(db, deps, runners)

    const first = await post(app, '/sessions', { prompt: 'a rainy drive' }, { ...STREAM, 'idempotency-key': KEY })
    const firstEvents = eventsOnly(await readSse(first))
    await runners.settled()
    expect(firstEvents[1].data).toEqual({ turnId: KEY, push: false })

    const json = await post(app, '/sessions', { prompt: 'a rainy drive' }, { 'idempotency-key': KEY.toUpperCase() })
    expect(json.status).toBe(200)
    expect(await json.text()).toBe(firstEvents.at(-1)!.raw)

    const stream = await post(app, '/sessions', { prompt: 'a rainy drive' }, { ...STREAM, 'idempotency-key': KEY })
    const replay = eventsOnly(await readSse(stream))
    expect(replay.map((e) => e.event)).toEqual(['session', 'turn', 'result'])
    expect((replay[0].data as { session: { id: string } }).session.id).toBe((firstEvents[0].data as { session: { id: string } }).session.id)
    expect(replay[2].raw).toBe(firstEvents.at(-1)!.raw)

    expect(await count(db, djSessions)).toBe(1)
    expect(await count(db, djTurns)).toBe(1)
    expect((await db.select().from(djMessages).where(eq(djMessages.role, 'user'))).length).toBe(1)
    expect([...runners.runners.values()].reduce((n, r) => n + r.starts, 0)).toBe(1)
  })

  it('a replayed message attaches while the turn is still running', async () => {
    const db = await listener(3)
    const sessionId = await mixSession(db)
    const deps = { embed, llm: scriptedLlm(generate(3)) }
    const runners = fakeTurnRunners(db, deps, { mode: 'manual' })
    const app = durableApp(db, deps, runners)
    const path = `/sessions/${sessionId}/messages`

    const first = post(app, path, { text: 'play something' }, { 'idempotency-key': KEY })
    const again = post(app, path, { text: 'play something' }, { 'idempotency-key': KEY })
    await vi.waitFor(async () => expect(await count(db, djTurns)).toBe(1))
    await runners.runAlarm(sessionId)
    const [a, b] = await Promise.all([first, again])

    expect(a.status).toBe(200)
    expect(await b.text()).toBe(await a.text())
    expect(await count(db, djTurns)).toBe(1)
    const userMessages = await db.select().from(djMessages).where(and(eq(djMessages.sessionId, sessionId), eq(djMessages.role, 'user')))
    expect(userMessages.map((m) => m.content)).toEqual(['start', 'play something'])
  })

  it('an invalid key, another listener\'s key, or another session\'s key is a 400', async () => {
    const db = await listener(3)
    await seedUser(db, 'u2')
    const sessionId = await mixSession(db)
    const otherSession = await mixSession(db)
    const deps = { embed, llm: scriptedLlm([{ text: 'ok.' }]) }
    const runners = fakeTurnRunners(db, deps)
    const u1 = durableApp(db, deps, runners)
    const u2 = durableApp(db, deps, runners, { userId: 'u2' })

    for (const key of ['not-a-uuid', '', '6f1c2d3e4b5a4c6d8e7f0a1b2c3d4e5f']) {
      const create = await post(u1, '/sessions', { prompt: 'hello' }, { 'idempotency-key': key })
      expect(create.status).toBe(400)
      expect(await create.json()).toEqual({ error: 'invalid_idempotency_key' })
      expect((await post(u1, `/sessions/${sessionId}/messages`, { text: 'hi' }, { 'idempotency-key': key })).status).toBe(400)
    }

    expect((await post(u2, '/sessions', { prompt: 'mine' }, { 'idempotency-key': KEY })).status).toBe(200)
    await runners.settled()
    const foreign = await post(u1, '/sessions', { prompt: 'hello' }, { 'idempotency-key': KEY })
    expect(foreign.status).toBe(400)
    expect(await foreign.json()).toEqual({ error: 'invalid_idempotency_key' })
    expect((await post(u1, `/sessions/${sessionId}/messages`, { text: 'hi' }, { 'idempotency-key': KEY })).status).toBe(400)

    const own = '7a1c2d3e-4b5a-4c6d-8e7f-0a1b2c3d4e5f'
    expect((await post(u1, `/sessions/${otherSession}/messages`, { text: 'hi' }, { 'idempotency-key': own })).status).toBe(200)
    await runners.settled()
    expect((await post(u1, `/sessions/${sessionId}/messages`, { text: 'hi' }, { 'idempotency-key': own })).status).toBe(400)
    // Refused keys wrote nothing.
    expect(await count(db, djTurns)).toBe(2)
  })
})

describe('the object refusing and attaching', () => {
  it('a busy object answers today\'s 409 conflict, fails the queued row and keeps the current pointer', async () => {
    const db = await listener(3)
    const sessionId = await mixSession(db)
    const deps = { embed, llm: scriptedLlm([{ text: 'ok.' }]) }
    const runners = fakeTurnRunners(db, deps, { mode: 'manual' })
    const held = await queueMessageTurn(db, sessionId, 'first')
    expect(await runners.namespace.get(runners.namespace.idFromName(sessionId)).start(held)).toBe('started')

    const res = await post(durableApp(db, deps, runners), `/sessions/${sessionId}/messages`, { text: 'second' })

    expect(res.status).toBe(409)
    expect(await res.json()).toEqual({ error: 'conflict', message: CONFLICT_APOLOGY })
    const turns = await db.select().from(djTurns).where(eq(djTurns.sessionId, sessionId))
    const fresh = turns.find((t) => t.id !== held.turnId)!
    expect(fresh).toMatchObject({ status: 'failed', errorKind: 'internal' })
    const [row] = await db.select().from(djSessions).where(eq(djSessions.id, sessionId))
    expect(row.currentTurnId).toBe(held.turnId)
    // Persist-first: the listener's words stand.
    const words = await db.select().from(djMessages).where(eq(djMessages.sessionId, sessionId))
    expect(words.map((m) => m.content)).toContain('second')
  })

  it('GET /sessions/:id/turn/stream attaches mid turn, then answers 204 once it is over; owner only', async () => {
    const db = await listener(3)
    await seedUser(db, 'u2')
    const sessionId = await mixSession(db)
    const deps = { embed, llm: scriptedLlm(generate(3)) }
    const runners = fakeTurnRunners(db, deps, { mode: 'manual' })
    const app = durableApp(db, deps, runners)

    expect((await get(app, `/sessions/${sessionId}/turn/stream`)).status).toBe(204)
    const started = await post(app, `/sessions/${sessionId}/messages`, { text: 'play something' }, STREAM)
    const startedReader = started.body!.getReader()
    const [turnEvent] = eventsOnly(await readEvents(startedReader, 1))
    const { turnId } = turnEvent.data as { turnId: string }

    // The connection dropped; the app comes back and attaches.
    await startedReader.cancel()
    const attached = await get(app, `/sessions/${sessionId}/turn/stream`)
    expect(attached.status).toBe(200)
    expect(attached.headers.get('content-type')).toBe('text/event-stream; charset=utf-8')
    expect((await get(durableApp(db, deps, runners, { userId: 'u2' }), `/sessions/${sessionId}/turn/stream`)).status).toBe(404)
    const text = attached.text()
    await runners.runAlarm(sessionId)
    const events = eventsOnly(await readSse(new Response(await text)))
    expect(events[0]).toMatchObject({ event: 'turn', data: { turnId, push: false } })
    expect(events.at(-1)?.event).toBe('result')
    expect((await turnRow(db, turnId)).watchedResult).toBe(true)

    expect((await get(app, `/sessions/${sessionId}/turn/stream`)).status).toBe(204)
  })

  it('POST /sessions/:id/turn/:turnId/seen stamps seen_at once, 204 every time; 404 otherwise', async () => {
    const db = await listener(3)
    await seedUser(db, 'u2')
    const sessionId = await mixSession(db)
    const otherSession = await mixSession(db)
    const deps = { embed, llm: scriptedLlm([{ text: 'ok.' }]) }
    const runners = fakeTurnRunners(db, deps)
    const app = durableApp(db, deps, runners)
    const res = await post(app, `/sessions/${sessionId}/messages`, { text: 'hi' }, STREAM)
    const turnId = (eventsOnly(await readSse(res))[0].data as { turnId: string }).turnId
    await runners.settled()

    expect((await post(app, `/sessions/${sessionId}/turn/${turnId}/seen`, {})).status).toBe(204)
    const seenAt = (await turnRow(db, turnId)).seenAt
    expect(seenAt).toBeInstanceOf(Date)
    expect((await post(app, `/sessions/${sessionId}/turn/${turnId}/seen`, {})).status).toBe(204)
    expect((await turnRow(db, turnId)).seenAt).toEqual(seenAt)

    expect((await post(app, `/sessions/${otherSession}/turn/${turnId}/seen`, {})).status).toBe(404)
    expect((await post(app, `/sessions/${sessionId}/turn/00000000-0000-4000-8000-000000000000/seen`, {})).status).toBe(404)
    expect((await post(app, `/sessions/${sessionId}/turn/nope/seen`, {})).status).toBe(404)
    expect((await post(durableApp(db, deps, runners, { userId: 'u2' }), `/sessions/${sessionId}/turn/${turnId}/seen`, {})).status).toBe(404)
  })

  it('a stop mid turn reaches the object\'s run: the turn ends stopped and the request answers turn_stopped', async () => {
    const db = await listener(3)
    const sessionId = await mixSession(db)
    const inCall = deferred()
    const never = new Promise<void>(() => {})
    // The turn's second model call hangs until the stop abandons it.
    const deps = { embed, llm: scriptedLlm(generate(3), (n) => (n === 1 ? (inCall.resolve(), never) : undefined)) }
    const runners = fakeTurnRunners(db, deps, { mode: 'manual', stopTiming: FAST })
    const app = durableApp(db, deps, runners)

    const pending = post(app, `/sessions/${sessionId}/messages`, { text: 'play something' })
    await vi.waitFor(async () => expect(await count(db, djTurns)).toBe(1))
    const alarm = runners.runAlarm(sessionId)
    await inCall.promise
    const stop = await post(app, `/sessions/${sessionId}/turn/stop`, {})
    expect(await stop.json()).toEqual({ stopped: true })

    const res = await pending
    expect(res.status).toBe(409)
    expect(await res.json()).toEqual({ error: 'turn_stopped' })
    expect(await alarm).toMatchObject({ outcome: 'stopped' })
    const [turn] = await db.select().from(djTurns)
    expect(turn.status).toBe('stopped')
    const words = await db.select().from(djMessages).where(eq(djMessages.sessionId, sessionId))
    expect(words.map((m) => m.content)).toEqual(['start', 'ready.'])
  })
})

describe('session reads', () => {
  async function turnsShown(app: App, sessionId: string) {
    const list = (await (await get(app, '/sessions')).json()) as { sessions: Array<{ id: string; turn?: unknown }> }
    const detail = (await (await get(app, `/sessions/${sessionId}`)).json()) as { session: { turn?: unknown } }
    const row = list.sessions.find((s) => s.id === sessionId)!
    return { list: 'turn' in row ? row.turn : 'absent', detail: 'turn' in detail.session ? detail.session.turn : 'absent' }
  }

  it('show the current turn while it runs, and omit it when done, when lost, and with the flag off', async () => {
    const db = await listener(3)
    const sessionId = await mixSession(db)
    const deps = { embed, llm: scriptedLlm([{ text: 'ok.' }]) }
    const runners: FakeRunners = fakeTurnRunners(db, deps, { mode: 'manual' })
    const app = durableApp(db, deps, runners)
    expect(await turnsShown(app, sessionId)).toEqual({ list: 'absent', detail: 'absent' })

    const pending = post(app, `/sessions/${sessionId}/messages`, { text: 'hi' })
    await vi.waitFor(async () => expect(await count(db, djTurns)).toBe(1))
    const [queued] = await db.select().from(djTurns)
    const live = { id: queued.id, status: 'queued', step: null }
    expect(await turnsShown(app, sessionId)).toEqual({ list: live, detail: live })
    expect(await turnsShown(plainApp(db, deps), sessionId)).toEqual({ list: 'absent', detail: 'absent' })

    // Queued for over 90 s with no heartbeat: lost, so omitted.
    await db.update(djTurns).set({ createdAt: new Date(Date.now() - 91_000) }).where(eq(djTurns.id, queued.id))
    expect(await turnsShown(app, sessionId)).toEqual({ list: 'absent', detail: 'absent' })
    // A heartbeat inside 90 s keeps a running turn shown.
    await db.update(djTurns).set({ status: 'running', heartbeatAt: new Date(), step: 'picking' }).where(eq(djTurns.id, queued.id))
    expect(await turnsShown(app, sessionId)).toEqual({ list: { id: queued.id, status: 'running', step: 'picking' }, detail: { id: queued.id, status: 'running', step: 'picking' } })
    await db.update(djTurns).set({ status: 'queued', heartbeatAt: null, createdAt: new Date() }).where(eq(djTurns.id, queued.id))

    await runners.runAlarm(sessionId)
    expect((await pending).status).toBe(200)
    expect(await turnsShown(app, sessionId)).toEqual({ list: 'absent', detail: 'absent' })
  })
})
