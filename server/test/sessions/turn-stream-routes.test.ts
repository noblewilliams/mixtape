import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { eq } from 'drizzle-orm'
import { createTestDb, forkTestDb, type TestDb } from '../helpers/db'
import { createApp, type AuthLike } from '../../src/app'
import type { DjDeps } from '../../src/dj/loop'
import type { AlbumDeps } from '../../src/albums/loop'
import { LlmError, type LlmClient, type LlmComplete, type LlmRequest, type LlmToolCall, type LlmTurn } from '../../src/dj/llm'
import type { AppleCatalogAlbumClient, CatalogAlbum } from '../../src/musickit/catalog'
import type { Embedder } from '../../src/enrich/embedder'
import { djMessages, djSessions, trackFeatures, trackMeanings, tracks, user, userArtistSeeds, userMusicProfiles, userTracks } from '../../src/db/schema'
import { applyOps, replaceQueue } from '../../src/dj/queue-store'
import { eventsOnly, readEvents, readSse } from '../helpers/sse'

// Spec 2026-11-13 dj-turn-steps, "Wire contract": POST /sessions and POST
// /sessions/:id/messages stream a mix turn on Accept: text/event-stream, and
// answer today's JSON for everything else (the existing route tests stand
// for the no-header path).

const UNIT = Array.from({ length: 1024 }, (_, i) => (i === 0 ? 1 : 0))
const embed: Embedder = async () => UNIT
const STREAM = { accept: 'text/event-stream' }
let counter = 0

beforeEach(() => {
  // The turn log (counts and codes) is not under test here.
  vi.spyOn(console, 'log').mockImplementation(() => {})
})
afterEach(() => {
  vi.restoreAllMocks()
})

async function seedUser(db: TestDb, id: string, isAnonymous = false) {
  await db.insert(user).values({ id, name: id, email: `${id}@example.com`, emailVerified: false, isAnonymous, createdAt: new Date(), updatedAt: new Date() })
}

async function seedLibrary(db: TestDb, userId: string, n: number) {
  for (let i = 0; i < n; i++) {
    counter += 1
    const [t] = await db.insert(tracks).values({ appleId: `stream-${counter}`, title: `Track ${counter}`, artist: 'Artist', durationMs: 200_000 }).returning()
    await db.insert(trackMeanings).values({ trackId: t.id, embedding: UNIT, lyricsSource: 'lrclib' })
    await db.insert(userTracks).values({ userId, trackId: t.id, playCount: 0, inLibrary: true })
  }
}

// No library, three interview seed artists with enriched catalogue rows: a
// first generate makes a catalogue mix (notPersonal), as in routes.test.ts.
async function seedCorpusListener(db: TestDb, userId: string) {
  for (const artist of ['SeedA', 'SeedB', 'SeedC']) {
    await db.insert(userArtistSeeds).values({ userId, name: artist, source: 'interview' })
    for (let i = 0; i < 9; i++) {
      counter += 1
      const [t] = await db.insert(tracks).values({ appleId: `corpus-${counter}`, title: `Corpus ${counter}`, artist, durationMs: 200_000 }).returning()
      await db.insert(trackFeatures).values({ trackId: t.id, tempo: 120, source: 'reccobeats' })
      await db.insert(trackMeanings).values({ trackId: t.id, embedding: UNIT, lyricsSource: 'lrclib' })
    }
  }
}

type Scripted = { text?: string; toolCalls?: LlmToolCall[] }

function toolCall(id: string, name: string, input: unknown): LlmToolCall {
  return { id, name, input }
}

// curate() shares the LlmClient (told apart by `tools: []`): it picks the
// first `count` pool ids, as in routes.test.ts.
function curateReply(req: LlmRequest): LlmTurn {
  const message = req.messages[0]
  const blocks = typeof message.content === 'string' ? [] : (message.content as Array<{ text?: string }>)
  const ids = Array.from((blocks[0]?.text ?? '').matchAll(/^([0-9a-f-]{36}) \|/gm)).map((m) => m[1])
  const countMatch = (blocks[1]?.text ?? '').match(/Pick up to (\d+) tracks/)
  const picks = ids.slice(0, countMatch ? Number(countMatch[1]) : ids.length).map((id) => ({ id, reason: 'fits the vibe' }))
  const text = JSON.stringify(picks)
  return { text, toolCalls: [], raw: [{ type: 'text', text }], stopReason: 'end_turn', usage: { inputTokens: 50, outputTokens: 20, cacheReadInputTokens: null } }
}

// A conversation script; `before(n)` runs ahead of the nth conversation call.
function scriptedLlm(script: Scripted[], before?: (call: number) => void | Promise<void>): LlmClient {
  let call = 0
  return async (req) => {
    if (req.tools.length === 0) return curateReply(req)
    const n = call
    call += 1
    await before?.(n)
    const s = script[Math.min(n, script.length - 1)]
    const raw: LlmTurn['raw'] = []
    if (s.text) raw.push({ type: 'text', text: s.text })
    for (const tc of s.toolCalls ?? []) raw.push({ type: 'tool_use', id: tc.id, name: tc.name, input: tc.input })
    return { text: s.text ?? '', toolCalls: s.toolCalls ?? [], raw, stopReason: s.toolCalls?.length ? 'tool_use' : 'end_turn', usage: { inputTokens: 10, outputTokens: 5, cacheReadInputTokens: null } }
  }
}

const generate = (targetCount: number): Scripted[] => [
  { toolCalls: [toolCall('c1', 'generate_queue', { themes: 'rainy drive', targetCount })] },
  { text: 'here you go.' },
]

function authedAs(id: string, isAnonymous = false): AuthLike {
  return { handler: () => new Response('ok'), api: { getSession: async () => ({ user: { id, isAnonymous } }) } }
}

type BuildOpts = { userId?: string; anonymous?: boolean; albums?: AlbumDeps; aiConsent?: 'off' | 'enforce'; allowedOrigins?: string[] }

function buildApp(db: TestDb, deps: DjDeps, opts: BuildOpts = {}) {
  return createApp({
    auth: authedAs(opts.userId ?? 'u1', opts.anonymous ?? false),
    db,
    dj: { deps },
    ...(opts.albums ? { albums: { deps: opts.albums } } : {}),
    ...(opts.aiConsent ? { aiConsent: opts.aiConsent } : {}),
    ...(opts.allowedOrigins ? { allowedOrigins: opts.allowedOrigins } : {}),
  })
}

type App = ReturnType<typeof buildApp>

function fakeCtx() {
  const waited: Promise<unknown>[] = []
  return { waited, ctx: { waitUntil: (p: Promise<unknown>) => void waited.push(p), passThroughOnException: () => {}, props: {} } }
}

function post(app: App, path: string, body: unknown, headers: Record<string, string> = {}, ctx?: ReturnType<typeof fakeCtx>['ctx']) {
  return app.request(`http://x${path}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...headers },
    body: JSON.stringify(body),
  }, undefined, ctx)
}

// Two forks of one database run the same turn, so their bodies differ only
// in what each fork mints: ids, times, and a new session's tape colour (a
// random column default). Ids are numbered by first appearance, so a body
// that points at the wrong row still differs.
function normalized(text: string): string {
  const ids = new Map<string, number>()
  return text
    .replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi, (id) => {
      if (!ids.has(id)) ids.set(id, ids.size)
      return `<id${ids.get(id)}>`
    })
    .replace(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z/g, '<time>')
    .replace(/"caseColor":"#[0-9a-f]{6}"/gi, '"caseColor":"<color>"')
}

function isStream(res: Response) {
  return res.headers.get('content-type') === 'text/event-stream; charset=utf-8'
}

// The same request with and without the stream header: same status, JSON
// both times, the same body.
async function expectSameJson(app: App, path: string, body: unknown, status: number) {
  const plain = await post(app, path, body)
  const asked = await post(app, path, body, STREAM)
  expect(plain.status).toBe(status)
  expect(asked.status).toBe(status)
  expect(asked.headers.get('content-type')).toMatch(/^application\/json/)
  expect(await asked.text()).toBe(await plain.text())
}

// Persist-first: a session that already ran one text-only turn.
async function mixSession(db: TestDb, userId = 'u1') {
  const res = await post(buildApp(db, { embed, llm: scriptedLlm([{ text: 'ready.' }]) }, { userId }), '/sessions', { prompt: 'start' })
  return ((await res.json()) as { session: { id: string } }).session.id
}

describe('streamed mix turns', () => {
  describe('POST /sessions', () => {
    it('sends session first, then the steps, then result: the JSON body byte for byte for the same turn', async () => {
      const base = await createTestDb()
      await seedUser(base, 'u1')
      await seedLibrary(base, 'u1', 4)
      const [a, b] = [await forkTestDb(base), await forkTestDb(base)]
      const titleComplete: LlmComplete = async () => 'Rainy Drive'

      const json = await post(buildApp(a, { embed, llm: scriptedLlm(generate(3)), titleComplete }), '/sessions', { prompt: 'a rainy drive' })
      const stream = await post(buildApp(b, { embed, llm: scriptedLlm(generate(3)), titleComplete }), '/sessions', { prompt: 'a rainy drive' }, STREAM)

      expect(json.status).toBe(200)
      expect(stream.status).toBe(200)
      expect(isStream(stream)).toBe(true)
      expect(stream.headers.get('cache-control')).toBe('no-cache, no-transform')
      const jsonText = await json.text()
      const events = eventsOnly(await readSse(stream))
      expect(events.map((e) => e.event)).toEqual(['session', 'step', 'step', 'step', 'step', 'result'])
      expect(events.slice(1, -1).map((e) => e.data)).toEqual([
        { step: 'digging', scope: 'library' },
        { step: 'picking' },
        { step: 'pressing', count: 3 },
        { step: 'writing' },
      ])
      const result = events[events.length - 1]
      expect(normalized(result.raw)).toBe(normalized(jsonText))

      // The session event is the list-row shape of the row the turn runs
      // on, before the closing UPDATE named it.
      const first = events[0].data as { session: Record<string, unknown> }
      const final = result.data as { session: Record<string, unknown>; queue: unknown[] }
      expect(first.session.id).toBe(final.session.id)
      expect(Object.keys(first.session)).toEqual(Object.keys(final.session))
      expect(first.session.title).toBe('a rainy drive')
      expect(final.session.title).toBe('Rainy Drive')
      expect(final.queue).toHaveLength(3)
    })

    it('a first turn that fails sends error with the JSON status and body, sessionId included', async () => {
      const base = await createTestDb()
      await seedUser(base, 'u1')
      const [a, b] = [await forkTestDb(base), await forkTestDb(base)]
      const llm: LlmClient = async () => {
        throw new LlmError('boom', 500)
      }

      const json = await post(buildApp(a, { embed, llm }), '/sessions', { prompt: 'play me something' })
      const stream = await post(buildApp(b, { embed, llm }), '/sessions', { prompt: 'play me something' }, STREAM)

      expect(json.status).toBe(502)
      expect(stream.status).toBe(200)
      const events = eventsOnly(await readSse(stream))
      expect(events.map((e) => e.event)).toEqual(['session', 'error'])
      const error = events[1].data as { status: number; body: { error: string; sessionId: string } }
      expect(error.status).toBe(502)
      expect(error.body.error).toBe('llm')
      expect(error.body.sessionId).toBe((events[0].data as { session: { id: string } }).session.id)
      expect(normalized(JSON.stringify(error.body))).toBe(normalized(await json.text()))
      // Persist-first, as on the JSON path: the session and the prompt stand.
      const [row] = await b.select().from(djSessions).where(eq(djSessions.id, error.body.sessionId))
      expect(row).toBeDefined()
    })

    it('an unforeseen failure sends error 500 internal, as the JSON path answers 500, logging no content', async () => {
      const errors = vi.spyOn(console, 'error').mockImplementation(() => {})
      const base = await createTestDb()
      await seedUser(base, 'u1')
      const forks = [await forkTestDb(base), await forkTestDb(base)].map(failingClosingUpdate)
      const app = (i: number) => buildApp(forks[i].db, { embed, llm: scriptedLlm([{ text: 'ready.' }], () => void (forks[i].state.armed = true)) })

      const json = await post(app(0), '/sessions', { prompt: 'rainy lagos night' })
      expect(json.status).toBe(500)
      expect(await json.json()).toEqual({ error: 'internal' })
      errors.mockClear()

      const stream = await post(app(1), '/sessions', { prompt: 'rainy lagos night' }, STREAM)
      const events = eventsOnly(await readSse(stream))
      expect(events.map((e) => e.event)).toEqual(['session', 'error'])
      expect(events[1].data).toEqual({ status: 500, body: { error: 'internal' } })
      expect(errors.mock.calls).toEqual([['turn stream failed']])
    })

    it('a client that stops reading does not stop the turn: its reply, title and queue still land', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      await seedLibrary(db, 'u1', 4)
      let open!: () => void
      const gate = new Promise<void>((r) => (open = r))
      const llm = scriptedLlm(generate(3), (n) => (n === 1 ? gate : undefined))
      const titleComplete: LlmComplete = async () => 'Kept Title'
      const { ctx, waited } = fakeCtx()

      const res = await post(buildApp(db, { embed, llm, titleComplete }), '/sessions', { prompt: 'a rainy drive' }, STREAM, ctx)
      const reader = res.body!.getReader()
      const first = eventsOnly(await readEvents(reader, 1))
      expect(first.map((e) => e.event)).toEqual(['session'])
      const sessionId = (first[0].data as { session: { id: string } }).session.id
      await reader.cancel()
      open()
      expect(waited).toHaveLength(1)
      await Promise.all(waited)

      const messages = await db.select().from(djMessages).where(eq(djMessages.sessionId, sessionId))
      expect(messages.map((m) => [m.role, m.content])).toEqual([['user', 'a rainy drive'], ['dj', 'here you go.']])
      const [row] = await db.select().from(djSessions).where(eq(djSessions.id, sessionId))
      expect(row.title).toBe('Kept Title')
      expect(row.queueVersion).toBe(1)
    })

    it('carries the same CORS headers as the JSON answer', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const origin = 'https://mixtape.example.com'
      const app = buildApp(db, { embed, llm: scriptedLlm([{ text: 'ready.' }]) }, { allowedOrigins: [origin] })

      const json = await post(app, '/sessions', { prompt: 'hello' }, { origin })
      const stream = await post(app, '/sessions', { prompt: 'hello' }, { origin, ...STREAM })

      expect(isStream(stream)).toBe(true)
      for (const res of [json, stream]) {
        expect(res.headers.get('access-control-allow-origin')).toBe(origin)
        expect(res.headers.get('access-control-allow-credentials')).toBe('true')
        expect(res.headers.get('vary')).toMatch(/Origin/)
      }
      expect(eventsOnly(await readSse(stream)).map((e) => e.event)).toEqual(['session', 'result'])
    })

    it("answers JSON to the web's current Accept: application/json", async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const res = await post(buildApp(db, { embed, llm: scriptedLlm([{ text: 'ready.' }]) }), '/sessions', { prompt: 'hello' }, { accept: 'application/json' })
      expect(res.status).toBe(200)
      expect(res.headers.get('content-type')).toMatch(/^application\/json/)
      expect(((await res.json()) as { messages: unknown[] }).messages).toHaveLength(2)
    })
  })

  describe('POST /sessions/:id/messages', () => {
    it('sends the steps, then result: the JSON body byte for byte for the same turn, with no session event', async () => {
      const base = await createTestDb()
      await seedUser(base, 'u1')
      await seedLibrary(base, 'u1', 3)
      const sessionId = await mixSession(base)
      const [a, b] = [await forkTestDb(base), await forkTestDb(base)]

      const json = await post(buildApp(a, { embed, llm: scriptedLlm(generate(3)) }), `/sessions/${sessionId}/messages`, { text: 'play something' })
      const stream = await post(buildApp(b, { embed, llm: scriptedLlm(generate(3)) }), `/sessions/${sessionId}/messages`, { text: 'play something' }, STREAM)

      expect(json.status).toBe(200)
      expect(isStream(stream)).toBe(true)
      const jsonText = await json.text()
      const events = eventsOnly(await readSse(stream))
      expect(events.map((e) => e.event)).toEqual(['step', 'step', 'step', 'step', 'result'])
      expect(normalized(events[4].raw)).toBe(normalized(jsonText))
      expect((events[4].data as { djMessage: { content: string } }).djMessage.content).toBe('here you go.')
    })

    it('a remake streams to the same result as its JSON answer', async () => {
      const base = await createTestDb()
      await seedUser(base, 'u1')
      await seedCorpusListener(base, 'u1')
      const created = await post(buildApp(base, { embed, llm: scriptedLlm([
        { toolCalls: [toolCall('c1', 'generate_queue', { themes: 'late night', targetCount: 4 })] },
        { text: 'a first guess.' },
      ]) }), '/sessions', { prompt: 'something for late night' })
      const sessionId = ((await created.json()) as { session: { id: string; notPersonal: boolean } }).session.id
      await seedLibrary(base, 'u1', 6)
      const [a, b] = [await forkTestDb(base), await forkTestDb(base)]
      const remake = () => scriptedLlm([
        { toolCalls: [toolCall('c1', 'generate_queue', { themes: 'late night', targetCount: 4 })] },
        { text: 'remade from your music.' },
      ])
      const body = { text: 'Remake this with my music', remake: true }

      const json = await post(buildApp(a, { embed, llm: remake() }), `/sessions/${sessionId}/messages`, body)
      const stream = await post(buildApp(b, { embed, llm: remake() }), `/sessions/${sessionId}/messages`, body, STREAM)

      expect(json.status).toBe(200)
      const jsonText = await json.text()
      const events = eventsOnly(await readSse(stream))
      const result = events[events.length - 1]
      expect(result.event).toBe('result')
      expect(events.slice(0, -1).every((e) => e.event === 'step')).toBe(true)
      expect(normalized(result.raw)).toBe(normalized(jsonText))
      expect((result.data as { queueVersion: number }).queueVersion).toBe(2)
    })

    it('a persistent queue-version race sends error 409 with the fresh queue, as the JSON path answers', async () => {
      const base = await createTestDb()
      await seedUser(base, 'u1')
      await seedLibrary(base, 'u1', 3)
      const sessionId = await mixSession(base)
      const queued = await base.select({ trackId: userTracks.trackId }).from(userTracks).limit(2)
      await replaceQueue(base, sessionId, queued.map((t) => ({ trackId: t.trackId, reason: '' })), 'dj')
      const [a, b] = [await forkTestDb(base), await forkTestDb(base)]
      // Every curate call writes concurrently, so the turn's retry never
      // gets past the version check (routes.test.ts's manufactured race).
      const racing = (db: TestDb): LlmClient => async (req) => {
        if (req.tools.length === 0) {
          await applyOps(db, sessionId, [{ op: 'move', from: 0, to: 1 }], 'user')
          return curateReply(req)
        }
        const input = { ops: [{ op: 'extend', count: 1 }] }
        return { text: '', toolCalls: [toolCall('c1', 'edit_queue', input)], raw: [{ type: 'tool_use', id: 'c1', name: 'edit_queue', input }], stopReason: 'tool_use', usage: null }
      }

      const json = await post(buildApp(a, { embed, llm: racing(a) }), `/sessions/${sessionId}/messages`, { text: 'stretch this out' })
      const stream = await post(buildApp(b, { embed, llm: racing(b) }), `/sessions/${sessionId}/messages`, { text: 'stretch this out' }, STREAM)

      expect(json.status).toBe(409)
      const events = eventsOnly(await readSse(stream))
      const error = events[events.length - 1]
      expect(error.event).toBe('error')
      const data = error.data as { status: number; body: { error: string; queue: unknown[] } }
      expect(data.status).toBe(409)
      expect(data.body.error).toBe('conflict')
      expect(data.body.queue.length).toBeGreaterThan(0)
      expect(normalized(JSON.stringify(data.body))).toBe(normalized(await json.text()))
    })

    it('an unforeseen failure after the turn sends error 500 internal', async () => {
      vi.spyOn(console, 'error').mockImplementation(() => {})
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const sessionId = await mixSession(db)
      const failing = failingClosingUpdate(db)
      const app = buildApp(failing.db, { embed, llm: scriptedLlm([{ text: 'noted.' }], () => void (failing.state.armed = true)) })

      const events = eventsOnly(await readSse(await post(app, `/sessions/${sessionId}/messages`, { text: 'hi' }, STREAM)))

      expect(events.map((e) => [e.event, e.data])).toEqual([['error', { status: 500, body: { error: 'internal' } }]])
    })
  })

  describe('refusals before the turn keep their status and JSON body', () => {
    it('validation 400 on both routes', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const sessionId = await mixSession(db)
      const app = buildApp(db, { embed, llm: scriptedLlm([{ text: 'never.' }]) })
      await expectSameJson(app, '/sessions', { prompt: '' }, 400)
      await expectSameJson(app, `/sessions/${sessionId}/messages`, { text: '' }, 400)
    })

    it('the AI consent 403 on both routes', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const sessionId = await mixSession(db)
      const app = buildApp(db, { embed, llm: scriptedLlm([{ text: 'never.' }]) }, { aiConsent: 'enforce' })
      await expectSameJson(app, '/sessions', { prompt: 'hello' }, 403)
      await expectSameJson(app, `/sessions/${sessionId}/messages`, { text: 'hello' }, 403)
    })

    it('anonymous_cap 403, writing nothing', async () => {
      const db = await createTestDb()
      await seedUser(db, 'anon', true)
      await db.insert(djSessions).values([1, 2, 3].map((i) => ({ userId: 'anon', title: `s${i}` })))
      const app = buildApp(db, { embed, llm: scriptedLlm([{ text: 'never.' }]) }, { userId: 'anon', anonymous: true })
      await expectSameJson(app, '/sessions', { prompt: 'one more' }, 403)
      expect(await db.select().from(djSessions)).toHaveLength(3)
    })

    it("404 for a missing or another listener's session", async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      await seedUser(db, 'u2')
      const sessionId = await mixSession(db)
      const app = buildApp(db, { embed, llm: scriptedLlm([{ text: 'never.' }]) }, { userId: 'u2' })
      await expectSameJson(app, `/sessions/${sessionId}/messages`, { text: 'hijack' }, 404)
      await expectSameJson(app, '/sessions/00000000-0000-4000-8000-000000000000/messages', { text: 'hi' }, 404)
    })

    it('a playlist-seed refusal', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const app = buildApp(db, { embed, llm: scriptedLlm([{ text: 'never.' }]) })
      await expectSameJson(app, '/sessions', { prompt: 'hello', playlistSeed: { playlistId: '00000000-0000-4000-8000-000000000000' } }, 404)
      expect(await db.select().from(djSessions)).toHaveLength(0)
    })

    it('album_picks_off on create and on an album message, wrong_session_kind on an album remake', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const [album] = await db.insert(djSessions).values({ userId: 'u1', title: 'records', kind: 'album' }).returning()
      const app = buildApp(db, { embed, llm: scriptedLlm([{ text: 'never.' }]) })
      await expectSameJson(app, '/sessions', { prompt: 'one record', kind: 'album' }, 404)
      await expectSameJson(app, `/sessions/${album.id}/messages`, { text: 'another' }, 404)
      await expectSameJson(app, `/sessions/${album.id}/messages`, { text: 'Remake this with my music', remake: true }, 409)
    })
  })

  describe('album sessions answer JSON even when asked for a stream', () => {
    it('album create and album message', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      await db.insert(userMusicProfiles).values({ userId: 'u1', appleStorefront: 'us' })
      const blue = catalogAlbum('Joni Mitchell', 'Blue')
      const script: Scripted[] = [
        { toolCalls: [toolCall('r1', 'recommend_album', { familiarity: 'mix', candidates: [{ artist: 'Joni Mitchell', title: 'Blue', type: 'album', why: 'grey morning' }] })] },
        { text: 'Blue, start to finish.' },
      ]
      const albumApp = () => {
        const llm = plainScript(script)
        return buildApp(db, { embed, llm }, { albums: { llm, embed, catalog: fakeCatalog([blue]), defaultStorefront: 'us' } })
      }

      const created = await post(albumApp(), '/sessions', { prompt: 'a grey morning', kind: 'album' }, STREAM)
      expect(created.status).toBe(200)
      expect(created.headers.get('content-type')).toMatch(/^application\/json/)
      const body = (await created.json()) as { session: { id: string; kind: string }; pick: { title: string } }
      expect(body.session.kind).toBe('album')
      expect(body.pick.title).toBe('Blue')

      const message = await post(albumApp(), `/sessions/${body.session.id}/messages`, { text: 'another grey one' }, STREAM)
      expect(message.headers.get('content-type')).toMatch(/^application\/json/)
      expect(((await message.json()) as { djMessage: { content: string } }).djMessage.content).toBe('Blue, start to finish.')
    })
  })
})

// The album loop's conversation has no curate call of its own: a plain
// script, call by call.
function plainScript(script: Scripted[]): LlmClient {
  let call = 0
  return async () => {
    const s = script[Math.min(call, script.length - 1)]
    call += 1
    const raw: LlmTurn['raw'] = []
    if (s.text) raw.push({ type: 'text', text: s.text })
    for (const tc of s.toolCalls ?? []) raw.push({ type: 'tool_use', id: tc.id, name: tc.name, input: tc.input })
    return { text: s.text ?? '', toolCalls: s.toolCalls ?? [], raw, stopReason: 'end_turn', usage: null }
  }
}

let appleCounter = 9000
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
    searchAlbums: async (_m: string, term: string) => {
      const hit = byTerm.get(term)
      return hit ? [hit] : []
    },
    getAlbums: async (_m: string, ids: readonly string[]) =>
      new Map(known.filter((a) => ids.includes(a.appleId)).map((a) => [a.appleId, { ...a, durationMs: 2_400_000 }])),
  }
}

// The database fails the route's own closing UPDATE (the one that sets
// updatedAt) once armed: an error no turn code turns into a DjError.
function failingClosingUpdate(db: TestDb) {
  const state = { armed: false }
  const bind = <T extends object>(target: T, prop: string | symbol) => {
    const value = Reflect.get(target, prop, target)
    return typeof value === 'function' ? value.bind(target) : value
  }
  const wrapped = new Proxy(db, {
    get(target, prop) {
      if (prop !== 'update') return bind(target, prop)
      return (table: typeof djSessions) => {
        const builder = target.update(table)
        if (!state.armed || table !== djSessions) return builder
        return new Proxy(builder, {
          get(b, p) {
            if (p !== 'set') return bind(b, p)
            return (values: Record<string, unknown>) => {
              if ('updatedAt' in values) throw new Error('connection reset')
              return b.set(values as never)
            }
          },
        })
      }
    },
  })
  return { db: wrapped, state }
}
