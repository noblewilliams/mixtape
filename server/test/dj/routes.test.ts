import { describe, it, expect } from 'vitest'
import { createTestDb, type TestDb } from '../helpers/db'
import { createApp, type AuthLike } from '../../src/app'
import type { DjDeps } from '../../src/dj/loop'
import type { LlmClient, LlmComplete, LlmRequest, LlmTurn, LlmAssistantBlock, LlmToolCall } from '../../src/dj/llm'
import { LlmError } from '../../src/dj/llm'
import type { Embedder } from '../../src/enrich/embedder'
import {
  tracks,
  trackFeatures,
  trackMeanings,
  userTracks,
  userArtistSeeds,
  user,
  djSessions,
  djMessages,
  sessionEvents,
  djMemories,
} from '../../src/db/schema'
import { eq } from 'drizzle-orm'
import { replaceQueue, applyOps } from '../../src/dj/queue-store'

const DIMS = 1024

function vec(pattern: Record<number, number>): number[] {
  const v = new Array(DIMS).fill(0)
  for (const [i, val] of Object.entries(pattern)) v[Number(i)] = val
  return v
}

const MATCHING_DIRECTION = vec({ 0: 1 })
const fakeEmbed: Embedder = async () => MATCHING_DIRECTION

async function seedUser(db: TestDb, id: string) {
  await db.insert(user).values({ id, name: id, email: `${id}@example.com`, emailVerified: false, createdAt: new Date(), updatedAt: new Date() })
}

let trackCounter = 0

async function seedLibraryTrack(db: TestDb, userId: string, opts: { title?: string; embedding?: number[] } = {}) {
  trackCounter += 1
  const label = opts.title ?? `Track ${trackCounter}`
  const [t] = await db
    .insert(tracks)
    .values({ appleId: `apple-${trackCounter}-${userId}`, title: label, artist: 'Artist', durationMs: 200_000 })
    .returning()
  if (opts.embedding) {
    await db.insert(trackMeanings).values({ trackId: t.id, embedding: opts.embedding, lyricsSource: 'lrclib' })
  }
  await db.insert(userTracks).values({ userId, trackId: t.id, playCount: 0, inLibrary: true })
  return t
}

async function seedLibrary(db: TestDb, userId: string, n: number) {
  const out = []
  for (let i = 0; i < n; i++) out.push(await seedLibraryTrack(db, userId, { embedding: MATCHING_DIRECTION }))
  return out
}

// A listener with no library and no ledger but enough interview seeds to
// unlock corpus mode (Task 5): 3 seed artists, 9 enriched corpus tracks
// each, none owned by anyone.
async function seedCorpusListener(db: TestDb, userId: string) {
  for (const artist of ['SeedA', 'SeedB', 'SeedC']) {
    await db.insert(userArtistSeeds).values({ userId, name: artist, source: 'interview' })
    for (let i = 0; i < 9; i++) {
      trackCounter += 1
      const [t] = await db
        .insert(tracks)
        .values({ appleId: `corpus-${trackCounter}`, title: `Corpus ${trackCounter}`, artist, durationMs: 200_000 })
        .returning()
      await db.insert(trackFeatures).values({ trackId: t.id, tempo: 120, source: 'reccobeats' })
      await db.insert(trackMeanings).values({ trackId: t.id, embedding: MATCHING_DIRECTION, lyricsSource: 'lrclib' })
    }
  }
}

type ScriptedTurn = Partial<LlmTurn>

function defaultRaw(scripted: ScriptedTurn): LlmAssistantBlock[] {
  const blocks: LlmAssistantBlock[] = []
  if (scripted.text) blocks.push({ type: 'text', text: scripted.text })
  for (const tc of scripted.toolCalls ?? []) blocks.push({ type: 'tool_use', id: tc.id, name: tc.name, input: tc.input })
  return blocks
}

// Synthesizes a plausible curate() response straight from its own prompt —
// see test/dj/loop.test.ts for the fuller explanation. Needed here whenever
// a scripted conversation turn calls generate_queue/edit_queue(swap|extend),
// since curate() shares the same LlmClient (told apart by `tools: []`).
function curateFakeResponseFromRequest(req: LlmRequest): LlmTurn {
  const message = req.messages[0]
  const blocks = typeof message.content === 'string' ? [] : (message.content as Array<{ text?: string }>)
  const poolText = blocks[0]?.text ?? ''
  const intentText = blocks[1]?.text ?? ''
  const ids = Array.from(poolText.matchAll(/^([0-9a-f-]{36}) \|/gm)).map((m) => m[1])
  const countMatch = intentText.match(/Pick exactly (\d+) tracks/)
  const count = countMatch ? Number(countMatch[1]) : ids.length
  const picks = ids.slice(0, count).map((id) => ({ id, reason: 'fits the vibe' }))
  return {
    text: JSON.stringify(picks),
    toolCalls: [],
    raw: [{ type: 'text', text: JSON.stringify(picks) }],
    stopReason: 'end_turn',
    usage: { inputTokens: 50, outputTokens: 20, cacheReadInputTokens: null },
  }
}

function toolCall(id: string, name: string, input: unknown): LlmToolCall {
  return { id, name, input }
}

function makeFakeLlm(conversationScript: ScriptedTurn[]): { llm: LlmClient; requests: LlmRequest[]; calls: number } {
  const requests: LlmRequest[] = []
  let convCall = 0
  const state = { calls: 0 }
  const llm: LlmClient = async (req) => {
    requests.push(req)
    state.calls += 1
    if (req.tools.length === 0) return curateFakeResponseFromRequest(req)
    const scripted = conversationScript[Math.min(convCall, conversationScript.length - 1)]
    convCall += 1
    return {
      text: scripted.text ?? '',
      toolCalls: scripted.toolCalls ?? [],
      raw: scripted.raw ?? defaultRaw(scripted),
      stopReason: scripted.stopReason ?? 'end_turn',
      usage: scripted.usage ?? { inputTokens: 10, outputTokens: 5, cacheReadInputTokens: null },
    }
  }
  return { llm, requests, get calls() { return state.calls } }
}

function authedAs(userId: string): AuthLike {
  return {
    handler: () => new Response('ok'),
    api: { getSession: async () => ({ user: { id: userId } }) },
  }
}

const unauthed: AuthLike = {
  handler: () => new Response('ok'),
  api: { getSession: async () => null },
}

function buildApp(db: TestDb, deps: DjDeps, auth: AuthLike) {
  return createApp({ auth, db, dj: { deps } })
}

function postJson(app: ReturnType<typeof buildApp>, path: string, body: unknown) {
  return app.request(`http://x${path}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  })
}

function getJson(app: ReturnType<typeof buildApp>, path: string) {
  return app.request(`http://x${path}`)
}

function patchJson(app: ReturnType<typeof buildApp>, path: string, body: unknown) {
  return app.request(`http://x${path}`, {
    method: 'PATCH',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  })
}

describe('session routes', () => {
  describe('POST /sessions', () => {
    it('creates a session, runs the first turn, and returns session/messages/queue with a truncated sanitized title', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      await seedLibrary(db, 'u1', 4)
      const longPrompt =
        'give me a long, moody, rainy-day driving playlist that stretches well past sixty characters for sure'
      const { llm } = makeFakeLlm([
        { toolCalls: [toolCall('c1', 'generate_queue', { themes: 'rainy drive', targetCount: 3 })] },
        { text: 'here you go.' },
      ])
      const app = buildApp(db, { embed: fakeEmbed, llm }, authedAs('u1'))

      const res = await postJson(app, '/sessions', { prompt: longPrompt })
      expect(res.status).toBe(200)
      const body = (await res.json()) as {
        session: { id: string; title: string; queueVersion: number }
        messages: Array<{ role: string; content: string }>
        queue: unknown[]
      }

      expect(body.session.title.length).toBeLessThanOrEqual(60)
      expect(longPrompt.startsWith(body.session.title.replace(/\s+$/, ''))).toBe(true)
      expect(body.session.queueVersion).toBe(1)
      expect(body.messages).toHaveLength(2)
      expect(body.messages[0].role).toBe('user')
      expect(body.messages[0].content).toBe(longPrompt)
      expect(body.messages[1].role).toBe('dj')
      expect(body.messages[1].content).toBe('here you go.')
      expect(body.queue).toHaveLength(3)

      const [row] = await db.select().from(djSessions).where(eq(djSessions.id, body.session.id))
      expect(row).toBeDefined()
    })

    it('rejects an empty prompt with 400', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const { llm } = makeFakeLlm([{ text: 'n/a' }])
      const app = buildApp(db, { embed: fakeEmbed, llm }, authedAs('u1'))

      const res = await postJson(app, '/sessions', { prompt: '' })
      expect(res.status).toBe(400)
    })

    it('persists the session and user message even when the first turn throws a DjError, returning 502 with sessionId', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const llm: LlmClient = async () => {
        throw new LlmError('boom', 500)
      }
      const app = buildApp(db, { embed: fakeEmbed, llm }, authedAs('u1'))

      const res = await postJson(app, '/sessions', { prompt: 'play me something' })
      expect(res.status).toBe(502)
      const body = (await res.json()) as { error: string; sessionId: string }
      expect(body.error).toBe('llm')
      expect(body.sessionId).toBeTruthy()

      // Session + user message exist by design (persist-first) so the client
      // can open the session and retry.
      const getRes = await getJson(app, `/sessions/${body.sessionId}`)
      expect(getRes.status).toBe(200)
      const getBody = (await getRes.json()) as { messages: Array<{ role: string; content: string }> }
      expect(getBody.messages).toHaveLength(1)
      expect(getBody.messages[0].role).toBe('user')
      expect(getBody.messages[0].content).toBe('play me something')
    })

    it('401s without a session', async () => {
      const db = await createTestDb()
      const { llm } = makeFakeLlm([{ text: 'n/a' }])
      const app = buildApp(db, { embed: fakeEmbed, llm }, unauthed)

      const res = await postJson(app, '/sessions', { prompt: 'hello' })
      expect(res.status).toBe(401)
    })

    it('names the session from a concurrently-run Haiku title call, landing in both the response and the row', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const { llm } = makeFakeLlm([{ text: 'here you go.' }])
      const titleComplete: LlmComplete = async () => 'Rainy Night Drive'
      const app = buildApp(db, { embed: fakeEmbed, llm, titleComplete }, authedAs('u1'))

      const res = await postJson(app, '/sessions', { prompt: 'rainy night drive — moody, keep it flowing' })
      expect(res.status).toBe(200)
      const body = (await res.json()) as { session: { id: string; title: string } }
      expect(body.session.title).toBe('Rainy Night Drive')

      const [row] = await db.select().from(djSessions).where(eq(djSessions.id, body.session.id))
      expect(row.title).toBe('Rainy Night Drive')
    })

    it('sanitizes a quoted/multi-line Haiku title before it ever reaches the row', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const { llm } = makeFakeLlm([{ text: 'here you go.' }])
      const titleComplete: LlmComplete = async () => '"Rainy\nNight Drive"  '
      const app = buildApp(db, { embed: fakeEmbed, llm, titleComplete }, authedAs('u1'))

      const res = await postJson(app, '/sessions', { prompt: 'rainy night drive' })
      const body = (await res.json()) as { session: { title: string } }
      expect(body.session.title).toBe('Rainy Night Drive')
    })

    it('falls back to the truncated-prompt title — and the session still succeeds — when the title call throws', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const longPrompt = 'a moody rainy-day driving playlist that keeps things flowing for about ten songs please'
      const { llm } = makeFakeLlm([{ text: 'here you go.' }])
      const titleComplete: LlmComplete = async () => {
        throw new LlmError('boom', 500)
      }
      const app = buildApp(db, { embed: fakeEmbed, llm, titleComplete }, authedAs('u1'))

      const res = await postJson(app, '/sessions', { prompt: longPrompt })
      expect(res.status).toBe(200)
      const body = (await res.json()) as { session: { id: string; title: string } }
      expect(longPrompt.startsWith(body.session.title.replace(/\s+$/, ''))).toBe(true)

      const [row] = await db.select().from(djSessions).where(eq(djSessions.id, body.session.id))
      expect(row.title).toBe(body.session.title)
    })

    it('falls back to the truncated-prompt title when the title call resolves empty/garbage', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const longPrompt = 'a moody rainy-day driving playlist that keeps things flowing for about ten songs please'
      const { llm } = makeFakeLlm([{ text: 'here you go.' }])
      const titleComplete: LlmComplete = async () => '   ""   '
      const app = buildApp(db, { embed: fakeEmbed, llm, titleComplete }, authedAs('u1'))

      const res = await postJson(app, '/sessions', { prompt: longPrompt })
      expect(res.status).toBe(200)
      const body = (await res.json()) as { session: { title: string } }
      expect(longPrompt.startsWith(body.session.title.replace(/\s+$/, ''))).toBe(true)
    })

    it('lands the generated title on the row even when the DJ turn itself fails', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const llm: LlmClient = async () => {
        throw new LlmError('boom', 500)
      }
      const titleComplete: LlmComplete = async () => 'Rainy Night Drive'
      const app = buildApp(db, { embed: fakeEmbed, llm, titleComplete }, authedAs('u1'))

      const res = await postJson(app, '/sessions', { prompt: 'play me something' })
      expect(res.status).toBe(502)
      const body = (await res.json()) as { error: string; message: string; sessionId: string }
      expect(body.error).toBe('llm')
      expect(body.sessionId).toBeTruthy()

      const [row] = await db.select().from(djSessions).where(eq(djSessions.id, body.sessionId))
      expect(row.title).toBe('Rainy Night Drive')
    })

    it('with no titleComplete wired at all, behaves exactly as before (truncated-prompt title)', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const { llm } = makeFakeLlm([{ text: 'here you go.' }])
      const app = buildApp(db, { embed: fakeEmbed, llm }, authedAs('u1'))

      const res = await postJson(app, '/sessions', { prompt: 'no title llm configured' })
      expect(res.status).toBe(200)
      const body = (await res.json()) as { session: { title: string } }
      expect(body.session.title).toBe('no title llm configured')
    })
  })

  describe('GET /sessions', () => {
    it('lists only the caller’s own sessions, newest first', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      await seedUser(db, 'u2')
      const { llm: llm1 } = makeFakeLlm([{ text: 'first' }])
      const { llm: llm2 } = makeFakeLlm([{ text: 'second' }])
      const { llm: llmOther } = makeFakeLlm([{ text: 'other user' }])

      const appU1 = buildApp(db, { embed: fakeEmbed, llm: llm1 }, authedAs('u1'))
      await postJson(appU1, '/sessions', { prompt: 'first session' })
      const appU1b = buildApp(db, { embed: fakeEmbed, llm: llm2 }, authedAs('u1'))
      await postJson(appU1b, '/sessions', { prompt: 'second session' })
      const appU2 = buildApp(db, { embed: fakeEmbed, llm: llmOther }, authedAs('u2'))
      await postJson(appU2, '/sessions', { prompt: 'a session for u2' })

      const res = await getJson(appU1, '/sessions')
      expect(res.status).toBe(200)
      const body = (await res.json()) as { sessions: Array<{ title: string }> }
      expect(body.sessions).toHaveLength(2)
      expect(body.sessions.every((s) => !s.title.includes('u2'))).toBe(true)
      // newest first
      expect(body.sessions[0].title).toContain('second session')
      expect(body.sessions[1].title).toContain('first session')
    })

    it('401s without a session', async () => {
      const db = await createTestDb()
      const { llm } = makeFakeLlm([{ text: 'n/a' }])
      const app = buildApp(db, { embed: fakeEmbed, llm }, unauthed)
      const res = await getJson(app, '/sessions')
      expect(res.status).toBe(401)
    })

    it('includes active track count and duration for collection views', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      await seedLibrary(db, 'u1', 3)
      const { llm } = makeFakeLlm([
        { toolCalls: [toolCall('c1', 'generate_queue', { themes: 'evening', targetCount: 3 })] },
        { text: 'ready.' },
      ])
      const app = buildApp(db, { embed: fakeEmbed, llm }, authedAs('u1'))
      const created = await postJson(app, '/sessions', { prompt: 'an easy evening tape' })
      const createdBody = (await created.json()) as { session: { id: string } }

      const res = await getJson(app, '/sessions')
      const body = (await res.json()) as {
        sessions: Array<{ id: string; trackCount: number; durationMs: number }>
      }
      const row = body.sessions.find((session) => session.id === createdBody.session.id)

      expect(row).toMatchObject({ trackCount: 3, durationMs: 600_000 })
    })
  })

  describe('GET /sessions/:id', () => {
    it('404s for another user’s session id (no existence leak)', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      await seedUser(db, 'u2')
      const { llm } = makeFakeLlm([{ text: 'hi' }])
      const appU1 = buildApp(db, { embed: fakeEmbed, llm }, authedAs('u1'))
      const createRes = await postJson(appU1, '/sessions', { prompt: 'mine' })
      const { session } = (await createRes.json()) as { session: { id: string } }

      const appU2 = buildApp(db, { embed: fakeEmbed, llm }, authedAs('u2'))
      const res = await getJson(appU2, `/sessions/${session.id}`)
      expect(res.status).toBe(404)
    })

    it('404s for a malformed uuid instead of 500', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const { llm } = makeFakeLlm([{ text: 'hi' }])
      const app = buildApp(db, { embed: fakeEmbed, llm }, authedAs('u1'))
      const res = await getJson(app, '/sessions/not-a-uuid')
      expect(res.status).toBe(404)
    })

    it('404s for a well-formed but missing uuid', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const { llm } = makeFakeLlm([{ text: 'hi' }])
      const app = buildApp(db, { embed: fakeEmbed, llm }, authedAs('u1'))
      const res = await getJson(app, '/sessions/00000000-0000-0000-0000-000000000000')
      expect(res.status).toBe(404)
    })

    it('returns session, messages, and active queue for the owner', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      await seedLibrary(db, 'u1', 3)
      const { llm } = makeFakeLlm([
        { toolCalls: [toolCall('c1', 'generate_queue', { themes: 'x', targetCount: 3 })] },
        { text: 'set.' },
      ])
      const app = buildApp(db, { embed: fakeEmbed, llm }, authedAs('u1'))
      const createRes = await postJson(app, '/sessions', { prompt: 'give me a set' })
      const { session } = (await createRes.json()) as { session: { id: string } }

      const res = await getJson(app, `/sessions/${session.id}`)
      expect(res.status).toBe(200)
      const body = (await res.json()) as { session: { id: string }; messages: unknown[]; queue: unknown[] }
      expect(body.session.id).toBe(session.id)
      expect(body.messages).toHaveLength(2)
      expect(body.queue).toHaveLength(3)
    })

    it('returns the LAST 200 messages (newest window), in ascending order — not the first 200', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const { llm } = makeFakeLlm([{ text: 'hi' }])
      const app = buildApp(db, { embed: fakeEmbed, llm }, authedAs('u1'))
      const createRes = await postJson(app, '/sessions', { prompt: 'start' })
      const { session } = (await createRes.json()) as { session: { id: string } }

      // Bulk-insert well past the 200 cap directly (cheap — no LLM turns
      // needed to pad the transcript).
      const rows = Array.from({ length: 250 }, (_, i) => ({
        sessionId: session.id,
        role: (i % 2 === 0 ? 'user' : 'dj') as 'user' | 'dj',
        content: `padding ${i}`,
      }))
      await db.insert(djMessages).values(rows)
      await db.insert(djMessages).values({ sessionId: session.id, role: 'user', content: 'the newest message' })

      const res = await getJson(app, `/sessions/${session.id}`)
      expect(res.status).toBe(200)
      const body = (await res.json()) as { messages: Array<{ content: string; seq: number }> }
      expect(body.messages).toHaveLength(200)
      // The very newest message is present...
      expect(body.messages[body.messages.length - 1].content).toBe('the newest message')
      // ...and the window is in ascending (chronological) order, not reversed.
      const seqs = body.messages.map((m) => m.seq)
      expect(seqs).toEqual([...seqs].sort((a, b) => a - b))
    })
  })

  describe('POST /sessions/:id/messages', () => {
    async function createSession(db: TestDb, auth: AuthLike, deps: DjDeps, prompt = 'start') {
      const app = buildApp(db, deps, auth)
      const res = await postJson(app, '/sessions', { prompt })
      const body = (await res.json()) as { session: { id: string } }
      return body.session.id
    }

    it('runs a message turn and returns djMessage/queue/queueVersion', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const trackList = await seedLibrary(db, 'u1', 3)
      const { llm: setupLlm } = makeFakeLlm([{ text: 'ready.' }])
      const sessionId = await createSession(db, authedAs('u1'), { embed: fakeEmbed, llm: setupLlm })

      const { llm } = makeFakeLlm([
        { toolCalls: [toolCall('c1', 'generate_queue', { themes: 'x', targetCount: 3 })] },
        { text: 'here is a set.' },
      ])
      const app = buildApp(db, { embed: fakeEmbed, llm }, authedAs('u1'))

      const res = await postJson(app, `/sessions/${sessionId}/messages`, { text: 'play something' })
      expect(res.status).toBe(200)
      const body = (await res.json()) as { djMessage: { content: string }; queue: unknown[]; queueVersion: number }
      expect(body.djMessage.content).toBe('here is a set.')
      expect(body.queue).toHaveLength(3)
      expect(body.queueVersion).toBe(1)
      expect(trackList).toHaveLength(3)
    })

    it('bumps dj_sessions.updatedAt on a text-only turn (no queue write to ride $onUpdate otherwise)', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const { llm: setupLlm } = makeFakeLlm([{ text: 'ready.' }])
      const sessionId = await createSession(db, authedAs('u1'), { embed: fakeEmbed, llm: setupLlm })

      const stale = new Date(Date.now() - 60_000)
      await db.update(djSessions).set({ updatedAt: stale }).where(eq(djSessions.id, sessionId))

      const { llm } = makeFakeLlm([{ text: 'just chatting, no queue changes.' }])
      const app = buildApp(db, { embed: fakeEmbed, llm }, authedAs('u1'))
      const res = await postJson(app, `/sessions/${sessionId}/messages`, { text: 'how are you' })
      expect(res.status).toBe(200)

      const [row] = await db.select({ updatedAt: djSessions.updatedAt }).from(djSessions).where(eq(djSessions.id, sessionId))
      expect(row.updatedAt.getTime()).toBeGreaterThan(stale.getTime())
    })

    it('rejects empty text with 400', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const { llm: setupLlm } = makeFakeLlm([{ text: 'ready.' }])
      const sessionId = await createSession(db, authedAs('u1'), { embed: fakeEmbed, llm: setupLlm })
      const app = buildApp(db, { embed: fakeEmbed, llm: setupLlm }, authedAs('u1'))

      const res = await postJson(app, `/sessions/${sessionId}/messages`, { text: '' })
      expect(res.status).toBe(400)
    })

    it('404s when the session belongs to another user', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      await seedUser(db, 'u2')
      const { llm } = makeFakeLlm([{ text: 'ready.' }])
      const sessionId = await createSession(db, authedAs('u1'), { embed: fakeEmbed, llm })

      const appU2 = buildApp(db, { embed: fakeEmbed, llm }, authedAs('u2'))
      const res = await postJson(appU2, `/sessions/${sessionId}/messages`, { text: 'hijack' })
      expect(res.status).toBe(404)
    })

    it('a throwing LLM surfaces as 502 with the DjError kind, and the user message is persisted', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const { llm: setupLlm } = makeFakeLlm([{ text: 'ready.' }])
      const sessionId = await createSession(db, authedAs('u1'), { embed: fakeEmbed, llm: setupLlm })

      const failingLlm: LlmClient = async () => {
        throw new LlmError('boom', 503)
      }
      const app = buildApp(db, { embed: fakeEmbed, llm: failingLlm }, authedAs('u1'))
      const res = await postJson(app, `/sessions/${sessionId}/messages`, { text: 'try again' })
      expect(res.status).toBe(502)
      const body = (await res.json()) as { error: string; message: string }
      expect(body.error).toBe('llm')
      // The message is listener-ready — a P3b chat bubble renders it as-is,
      // so it must never carry the dev-facing "dj:" prefix or a raw status
      // code (e.g. from LlmError('boom', 503) above), only the apology copy.
      expect(body.message).not.toMatch(/dj:/)
      expect(body.message).not.toMatch(/503/)
      expect(body.message).toBe('the line to the booth dropped — try that again?')
      // DjError.detail (the upstream status/error name, for server-side
      // observability only) is never in djErrorBody's whitelist — confirm
      // it can't leak into the client-facing body.
      expect(body).not.toHaveProperty('detail')

      const getRes = await getJson(app, `/sessions/${sessionId}`)
      const getBody = (await getRes.json()) as { messages: Array<{ role: string; content: string }> }
      // 2 messages from the setup turn (user 'start' + dj 'ready.') plus this
      // turn's user message — and, since the turn failed, NO dj message for it.
      expect(getBody.messages).toHaveLength(3)
      expect(getBody.messages[2]).toMatchObject({ role: 'user', content: 'try again' })
    })

    it('a persistent queue-version race (DjError kind "conflict") surfaces as 409 with the fresh queue state — same status as queue-ops staleness', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      // 2 tracks go in the queue; a 3rd stays OUTSIDE it so the extend op's
      // replacementsProvider (buildPool, excluding the active queue) has a
      // real candidate to hand back — otherwise buildPool comes back empty
      // and the provider short-circuits to [] before ever calling curate(),
      // and the manufactured race below would never get a chance to fire.
      const trackList = await seedLibrary(db, 'u1', 2)
      await seedLibraryTrack(db, 'u1', { embedding: MATCHING_DIRECTION })
      const { llm: setupLlm } = makeFakeLlm([{ text: 'ready.' }])
      const sessionId = await createSession(db, authedAs('u1'), { embed: fakeEmbed, llm: setupLlm })
      await replaceQueue(
        db,
        sessionId,
        trackList.map((t) => ({ trackId: t.id, reason: '' })),
        'dj',
      )

      // Same manufactured race as test/dj/loop.test.ts's "QueueVersionConflict
      // retry contract": every curate call (tools: []) performs a concurrent
      // write, so the phase-1/phase-2 version check in applyOps never lines
      // up — even across the loop's one retry — and runDjTurn's own retry
      // logic gives up as DjError kind 'conflict'.
      const llm: LlmClient = async (req) => {
        if (req.tools.length === 0) {
          await applyOps(db, sessionId, [{ op: 'move', from: 0, to: 1 }], 'user')
          return curateFakeResponseFromRequest(req)
        }
        return {
          text: '',
          toolCalls: [toolCall('c1', 'edit_queue', { ops: [{ op: 'extend', count: 1 }] })],
          raw: [{ type: 'tool_use', id: 'c1', name: 'edit_queue', input: { ops: [{ op: 'extend', count: 1 }] } }],
          stopReason: 'tool_use',
          usage: null,
        }
      }
      const app = buildApp(db, { embed: fakeEmbed, llm }, authedAs('u1'))

      const res = await postJson(app, `/sessions/${sessionId}/messages`, { text: 'stretch this out' })
      expect(res.status).toBe(409)
      const body = (await res.json()) as { error: string; message: string; queue: unknown[]; queueVersion: number }
      expect(body.error).toBe('conflict')
      expect(typeof body.message).toBe('string')
      expect(body.queue.length).toBeGreaterThan(0)
    })

    it('401s without a session', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const { llm } = makeFakeLlm([{ text: 'ready.' }])
      const sessionId = await createSession(db, authedAs('u1'), { embed: fakeEmbed, llm })
      const app = buildApp(db, { embed: fakeEmbed, llm }, unauthed)
      const res = await postJson(app, `/sessions/${sessionId}/messages`, { text: 'hi' })
      expect(res.status).toBe(401)
    })

    it('a rename followed by a LATER failure this same turn still carries sessionTitle in the DjError body — self-healing but must not show a stale AppBar first', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const { llm: setupLlm } = makeFakeLlm([{ text: 'ready.' }])
      const sessionId = await createSession(db, authedAs('u1'), { embed: fakeEmbed, llm: setupLlm })

      // Round 1 renames (the write lands immediately); round 2 — the SAME
      // turn — then throws, ending it. The rename must still ride the
      // resulting DjError body, not just the DB row.
      let call = 0
      const llm: LlmClient = async () => {
        call += 1
        if (call === 1) {
          return {
            text: '',
            toolCalls: [toolCall('c1', 'rename_session', { title: 'Lagos Nights' })],
            raw: [{ type: 'tool_use', id: 'c1', name: 'rename_session', input: { title: 'Lagos Nights' } }],
            stopReason: 'tool_use',
            usage: null,
          }
        }
        throw new LlmError('boom', 503)
      }
      const app = buildApp(db, { embed: fakeEmbed, llm }, authedAs('u1'))

      const res = await postJson(app, `/sessions/${sessionId}/messages`, { text: 'call this tape Lagos Nights then break' })
      expect(res.status).toBe(502)
      const body = (await res.json()) as { error: string; sessionTitle?: string }
      expect(body.error).toBe('llm')
      expect(body.sessionTitle).toBe('Lagos Nights')

      const [row] = await db.select().from(djSessions).where(eq(djSessions.id, sessionId))
      expect(row.title).toBe('Lagos Nights')
    })
  })

  describe('POST /sessions/:id/queue-ops', () => {
    async function createSessionWithQueue(db: TestDb, userId: string, count = 3) {
      const trackList = await seedLibrary(db, userId, count)
      const { llm } = makeFakeLlm([
        { toolCalls: [toolCall('c1', 'generate_queue', { themes: 'x', targetCount: count })] },
        { text: 'here you go.' },
      ])
      const app = buildApp(db, { embed: fakeEmbed, llm }, authedAs(userId))
      const res = await postJson(app, '/sessions', { prompt: 'give me a set' })
      const body = (await res.json()) as { session: { id: string; queueVersion: number } }
      return { sessionId: body.session.id, queueVersion: body.session.queueVersion, trackList }
    }

    it('applies a remove op WITHOUT calling the LLM, returns the updated queue/version, and marks removedBy user', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const { sessionId, queueVersion } = await createSessionWithQueue(db, 'u1', 3)

      const { llm, calls } = makeFakeLlm([{ text: 'should never be called' }])
      const app = buildApp(db, { embed: fakeEmbed, llm }, authedAs('u1'))

      const res = await postJson(app, `/sessions/${sessionId}/queue-ops`, {
        ops: [{ op: 'remove', position: 0 }],
        expectedVersion: queueVersion,
      })
      expect(res.status).toBe(200)
      const body = (await res.json()) as { queueVersion: number; requested: number; added: number; removed: number; queue: unknown[] }
      expect(body.queueVersion).toBe(queueVersion + 1)
      expect(body.removed).toBe(1)
      expect(body.requested).toBe(0)
      expect(body.added).toBe(0)
      expect(body.queue).toHaveLength(2)
      expect(calls).toBe(0)
    })

    it('rejects a swap op with 400 and the dj-message hint', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const { sessionId } = await createSessionWithQueue(db, 'u1', 3)

      const { llm, calls } = makeFakeLlm([{ text: 'should never be called' }])
      const app = buildApp(db, { embed: fakeEmbed, llm }, authedAs('u1'))

      const res = await postJson(app, `/sessions/${sessionId}/queue-ops`, { ops: [{ op: 'swap', position: 0 }] })
      expect(res.status).toBe(400)
      const body = (await res.json()) as { error: string; message: string }
      expect(body.error).toBe('dj_required')
      expect(body.message).toContain('swap/extend require the DJ')
      expect(calls).toBe(0)
    })

    it('rejects an extend op with 400 and the dj-message hint', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const { sessionId } = await createSessionWithQueue(db, 'u1', 3)
      const { llm } = makeFakeLlm([{ text: 'should never be called' }])
      const app = buildApp(db, { embed: fakeEmbed, llm }, authedAs('u1'))

      const res = await postJson(app, `/sessions/${sessionId}/queue-ops`, { ops: [{ op: 'extend', count: 1 }] })
      expect(res.status).toBe(400)
      const body = (await res.json()) as { error: string; message: string }
      expect(body.error).toBe('dj_required')
      expect(body.message).toContain('swap/extend require the DJ')
    })

    it('a stale expectedVersion returns 409 with the fresh queue/version', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const { sessionId, queueVersion } = await createSessionWithQueue(db, 'u1', 3)

      const { llm } = makeFakeLlm([{ text: 'n/a' }])
      const app = buildApp(db, { embed: fakeEmbed, llm }, authedAs('u1'))

      const res = await postJson(app, `/sessions/${sessionId}/queue-ops`, {
        ops: [{ op: 'remove', position: 0 }],
        expectedVersion: queueVersion + 5,
      })
      expect(res.status).toBe(409)
      const body = (await res.json()) as { error: string; queue: unknown[]; queueVersion: number }
      expect(body.error).toBe('stale')
      expect(body.queueVersion).toBe(queueVersion)
      expect(body.queue).toHaveLength(3)
    })

    it('rejects an empty ops array with 400', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const { sessionId } = await createSessionWithQueue(db, 'u1', 3)
      const { llm } = makeFakeLlm([{ text: 'n/a' }])
      const app = buildApp(db, { embed: fakeEmbed, llm }, authedAs('u1'))

      const res = await postJson(app, `/sessions/${sessionId}/queue-ops`, { ops: [] })
      expect(res.status).toBe(400)
    })

    it('404s when the session belongs to another user', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      await seedUser(db, 'u2')
      const { sessionId } = await createSessionWithQueue(db, 'u1', 3)
      const { llm } = makeFakeLlm([{ text: 'n/a' }])
      const appU2 = buildApp(db, { embed: fakeEmbed, llm }, authedAs('u2'))

      const res = await postJson(appU2, `/sessions/${sessionId}/queue-ops`, { ops: [{ op: 'remove', position: 0 }] })
      expect(res.status).toBe(404)
    })

    it('401s without a session', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const { sessionId } = await createSessionWithQueue(db, 'u1', 3)
      const { llm } = makeFakeLlm([{ text: 'n/a' }])
      const app = buildApp(db, { embed: fakeEmbed, llm }, unauthed)

      const res = await postJson(app, `/sessions/${sessionId}/queue-ops`, { ops: [{ op: 'remove', position: 0 }] })
      expect(res.status).toBe(401)
    })
  })

  describe('POST /sessions/:id/events', () => {
    async function createPlainSession(db: TestDb, userId: string) {
      const { llm } = makeFakeLlm([{ text: 'hi' }])
      const app = buildApp(db, { embed: fakeEmbed, llm }, authedAs(userId))
      const res = await postJson(app, '/sessions', { prompt: 'a session' })
      const body = (await res.json()) as { session: { id: string } }
      return body.session.id
    }

    it.each(['played', 'saved_playlist'] as const)('persists a %s event row and responds {ok: true}', async (type) => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const sessionId = await createPlainSession(db, 'u1')
      const { llm } = makeFakeLlm([{ text: 'n/a' }])
      const app = buildApp(db, { embed: fakeEmbed, llm }, authedAs('u1'))

      const res = await postJson(app, `/sessions/${sessionId}/events`, { type })
      expect(res.status).toBe(200)
      expect(await res.json()).toEqual({ ok: true })

      const rows = await db.select().from(sessionEvents).where(eq(sessionEvents.sessionId, sessionId))
      expect(rows).toHaveLength(1)
      expect(rows[0].type).toBe(type)
    })

    it('allows multiple play events for the same session — no dedupe', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const sessionId = await createPlainSession(db, 'u1')
      const { llm } = makeFakeLlm([{ text: 'n/a' }])
      const app = buildApp(db, { embed: fakeEmbed, llm }, authedAs('u1'))

      await postJson(app, `/sessions/${sessionId}/events`, { type: 'played' })
      await postJson(app, `/sessions/${sessionId}/events`, { type: 'played' })

      const rows = await db.select().from(sessionEvents).where(eq(sessionEvents.sessionId, sessionId))
      expect(rows).toHaveLength(2)
    })

    it('404s when the session belongs to another user, and writes no row', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      await seedUser(db, 'u2')
      const sessionId = await createPlainSession(db, 'u1')
      const { llm } = makeFakeLlm([{ text: 'n/a' }])
      const appU2 = buildApp(db, { embed: fakeEmbed, llm }, authedAs('u2'))

      const res = await postJson(appU2, `/sessions/${sessionId}/events`, { type: 'played' })
      expect(res.status).toBe(404)

      const rows = await db.select().from(sessionEvents).where(eq(sessionEvents.sessionId, sessionId))
      expect(rows).toHaveLength(0)
    })

    it('404s for a well-formed but missing/unknown session id', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const { llm } = makeFakeLlm([{ text: 'n/a' }])
      const app = buildApp(db, { embed: fakeEmbed, llm }, authedAs('u1'))

      const res = await postJson(app, '/sessions/00000000-0000-0000-0000-000000000000/events', { type: 'played' })
      expect(res.status).toBe(404)
    })

    it('rejects an invalid type with 400 in the established zod-validator shape', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const sessionId = await createPlainSession(db, 'u1')
      const { llm } = makeFakeLlm([{ text: 'n/a' }])
      const app = buildApp(db, { embed: fakeEmbed, llm }, authedAs('u1'))

      const res = await postJson(app, `/sessions/${sessionId}/events`, { type: 'liked' })
      expect(res.status).toBe(400)
      const body = (await res.json()) as { success: boolean; error: unknown }
      expect(body.success).toBe(false)
      expect(body.error).toBeTruthy()

      const rows = await db.select().from(sessionEvents).where(eq(sessionEvents.sessionId, sessionId))
      expect(rows).toHaveLength(0)
    })

    it('401s without a session', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const sessionId = await createPlainSession(db, 'u1')
      const { llm } = makeFakeLlm([{ text: 'n/a' }])
      const app = buildApp(db, { embed: fakeEmbed, llm }, unauthed)

      const res = await postJson(app, `/sessions/${sessionId}/events`, { type: 'played' })
      expect(res.status).toBe(401)
    })

    it('cascades on session delete — removing a session removes its events', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const sessionId = await createPlainSession(db, 'u1')
      const { llm } = makeFakeLlm([{ text: 'n/a' }])
      const app = buildApp(db, { embed: fakeEmbed, llm }, authedAs('u1'))
      await postJson(app, `/sessions/${sessionId}/events`, { type: 'played' })
      await postJson(app, `/sessions/${sessionId}/events`, { type: 'saved_playlist' })

      await db.delete(djSessions).where(eq(djSessions.id, sessionId))

      const rows = await db.select().from(sessionEvents).where(eq(sessionEvents.sessionId, sessionId))
      expect(rows).toHaveLength(0)
    })
  })

  describe('remember_preference tool — works in both the first turn and a later reply turn', () => {
    it('persists a note from POST /sessions\'s own first turn', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const { llm } = makeFakeLlm([
        { toolCalls: [toolCall('c1', 'remember_preference', { note: 'never play explicit tracks' })] },
        { text: 'got it, noted for next time.' },
      ])
      const app = buildApp(db, { embed: fakeEmbed, llm }, authedAs('u1'))

      const res = await postJson(app, '/sessions', { prompt: 'i never want explicit tracks, ever' })
      expect(res.status).toBe(200)

      const rows = await db.select().from(djMemories).where(eq(djMemories.userId, 'u1'))
      expect(rows).toHaveLength(1)
      expect(rows[0].note).toBe('never play explicit tracks')
    })

    it('persists a second note from a later POST /sessions/:id/messages reply turn', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const { llm: firstLlm } = makeFakeLlm([{ text: 'hi there.' }])
      const app = buildApp(db, { embed: fakeEmbed, llm: firstLlm }, authedAs('u1'))
      const createRes = await postJson(app, '/sessions', { prompt: 'hey' })
      const { session } = (await createRes.json()) as { session: { id: string } }

      const { llm: replyLlm } = makeFakeLlm([
        { toolCalls: [toolCall('c1', 'remember_preference', { note: 'always keep the energy up' })] },
        { text: 'noted, will do.' },
      ])
      const replyApp = buildApp(db, { embed: fakeEmbed, llm: replyLlm }, authedAs('u1'))

      const res = await postJson(replyApp, `/sessions/${session.id}/messages`, { text: 'always keep the energy up, ok?' })
      expect(res.status).toBe(200)

      const rows = await db.select().from(djMemories).where(eq(djMemories.userId, 'u1'))
      expect(rows).toHaveLength(1)
      expect(rows[0].note).toBe('always keep the energy up')
    })
  })

  describe('rename_session tool — turn responses carry sessionTitle', () => {
    it('POST /sessions/:id/messages includes sessionTitle only when rename_session fired this turn', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const { llm: setupLlm } = makeFakeLlm([{ text: 'hi there.' }])
      const app = buildApp(db, { embed: fakeEmbed, llm: setupLlm }, authedAs('u1'))
      const createRes = await postJson(app, '/sessions', { prompt: 'hey' })
      const { session } = (await createRes.json()) as { session: { id: string } }

      const { llm: renameLlm } = makeFakeLlm([
        { toolCalls: [toolCall('c1', 'rename_session', { title: 'Lagos Nights' })] },
        { text: 'there you go.' },
      ])
      const renameApp = buildApp(db, { embed: fakeEmbed, llm: renameLlm }, authedAs('u1'))
      const renameRes = await postJson(renameApp, `/sessions/${session.id}/messages`, { text: 'call this tape Lagos Nights' })
      expect(renameRes.status).toBe(200)
      const renameBody = (await renameRes.json()) as { sessionTitle?: string }
      expect(renameBody.sessionTitle).toBe('Lagos Nights')

      // A later, unrelated turn on the SAME session omits the field entirely.
      const { llm: plainLlm } = makeFakeLlm([{ text: 'sure thing.' }])
      const plainApp = buildApp(db, { embed: fakeEmbed, llm: plainLlm }, authedAs('u1'))
      const plainRes = await postJson(plainApp, `/sessions/${session.id}/messages`, { text: 'play something else' })
      const plainBody = (await plainRes.json()) as { sessionTitle?: string }
      expect(plainBody).not.toHaveProperty('sessionTitle')
    })

    it('POST /sessions includes sessionTitle when the very first turn renames — and it wins over the concurrently-generated title', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const { llm } = makeFakeLlm([
        { toolCalls: [toolCall('c1', 'rename_session', { title: 'Lagos Nights' })] },
        { text: 'there you go.' },
      ])
      const titleComplete: LlmComplete = async () => 'Some Auto Title'
      const app = buildApp(db, { embed: fakeEmbed, llm, titleComplete }, authedAs('u1'))

      const res = await postJson(app, '/sessions', { prompt: 'call this tape Lagos Nights' })
      expect(res.status).toBe(200)
      const body = (await res.json()) as { session: { id: string; title: string }; sessionTitle?: string }
      expect(body.sessionTitle).toBe('Lagos Nights')
      expect(body.session.title).toBe('Lagos Nights')

      const [row] = await db.select().from(djSessions).where(eq(djSessions.id, body.session.id))
      expect(row.title).toBe('Lagos Nights')
    })

    it('POST /sessions: a rename that survives a QueueVersionConflict retry still carries sessionTitle in the response and wins the row over the Haiku title', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      // A small library so the extend op below has a real replacement
      // candidate to pick (buildPool must come back non-empty for
      // executeEditQueue's provider to ever call curate()).
      await seedLibrary(db, 'u1', 2)

      let convCall = 0
      let curateCall = 0
      const llm: LlmClient = async (req) => {
        if (req.tools.length === 0) {
          curateCall += 1
          if (curateCall === 1) {
            // Simulates a concurrent write landing between applyOps' phase-1
            // snapshot and its phase-2 locked re-check (same race as
            // test/dj/loop.test.ts's "QueueVersionConflict retry contract")
            // by bumping queueVersion directly — there's no existing queue
            // row to move via a queue op, since this is the session's very
            // first turn and the queue starts empty.
            const [s] = await db.select({ id: djSessions.id, queueVersion: djSessions.queueVersion }).from(djSessions)
            await db.update(djSessions).set({ queueVersion: s.queueVersion + 1 }).where(eq(djSessions.id, s.id))
          }
          return curateFakeResponseFromRequest(req)
        }
        convCall += 1
        if (convCall === 1) {
          // Attempt 1's only round: renames AND kicks off the extend that's
          // about to conflict — both land in the SAME round, same as the
          // real listener bundling a rename with another request.
          return {
            text: '',
            toolCalls: [
              toolCall('c1', 'rename_session', { title: 'Lagos Nights' }),
              toolCall('c2', 'edit_queue', { ops: [{ op: 'extend', count: 1 }] }),
            ],
            raw: [
              { type: 'tool_use', id: 'c1', name: 'rename_session', input: { title: 'Lagos Nights' } },
              { type: 'tool_use', id: 'c2', name: 'edit_queue', input: { ops: [{ op: 'extend', count: 1 }] } },
            ],
            stopReason: 'tool_use',
            usage: null,
          }
        }
        if (convCall === 2) {
          // The retry's round 1 — does NOT rename again, only finishes the
          // extend (the interloper fired only once, so this one succeeds).
          return {
            text: '',
            toolCalls: [toolCall('c3', 'edit_queue', { ops: [{ op: 'extend', count: 1 }] })],
            raw: [{ type: 'tool_use', id: 'c3', name: 'edit_queue', input: { ops: [{ op: 'extend', count: 1 }] } }],
            stopReason: 'tool_use',
            usage: null,
          }
        }
        return {
          text: 'stretched it out and renamed it.',
          toolCalls: [],
          raw: [{ type: 'text', text: 'stretched it out and renamed it.' }],
          stopReason: 'end_turn',
          usage: null,
        }
      }
      const titleComplete: LlmComplete = async () => 'Some Auto Title'
      const app = buildApp(db, { embed: fakeEmbed, llm, titleComplete }, authedAs('u1'))

      const res = await postJson(app, '/sessions', { prompt: 'call this tape Lagos Nights and stretch it out' })
      expect(res.status).toBe(200)
      const body = (await res.json()) as { session: { id: string; title: string }; sessionTitle?: string }
      expect(body.sessionTitle).toBe('Lagos Nights')
      expect(body.session.title).toBe('Lagos Nights')

      const [row] = await db.select().from(djSessions).where(eq(djSessions.id, body.session.id))
      expect(row.title).toBe('Lagos Nights') // NOT 'Some Auto Title'
    })

    it('POST /sessions: a rename on a first turn that ultimately FAILS still keeps the rename on the row, not the Haiku title', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')

      // Round 1 renames; round 2 — the SAME turn — throws, ending it with no
      // retry (LlmError isn't a QueueVersionConflict). The rename's DB write
      // already landed in round 1, and must survive the write below.
      let call = 0
      const llm: LlmClient = async () => {
        call += 1
        if (call === 1) {
          return {
            text: '',
            toolCalls: [toolCall('c1', 'rename_session', { title: 'Lagos Nights' })],
            raw: [{ type: 'tool_use', id: 'c1', name: 'rename_session', input: { title: 'Lagos Nights' } }],
            stopReason: 'tool_use',
            usage: null,
          }
        }
        throw new LlmError('boom', 503)
      }
      const titleComplete: LlmComplete = async () => 'Some Auto Title'
      const app = buildApp(db, { embed: fakeEmbed, llm, titleComplete }, authedAs('u1'))

      const res = await postJson(app, '/sessions', { prompt: 'call this tape Lagos Nights then break' })
      expect(res.status).toBe(502)
      const body = (await res.json()) as { error: string; sessionId: string; sessionTitle?: string }
      expect(body.error).toBe('llm')
      expect(body.sessionTitle).toBe('Lagos Nights')

      const [row] = await db.select().from(djSessions).where(eq(djSessions.id, body.sessionId))
      expect(row.title).toBe('Lagos Nights') // NOT 'Some Auto Title'
    })

    it('POST /sessions omits sessionTitle on an ordinary (no-rename) first turn', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const { llm } = makeFakeLlm([{ text: 'here you go.' }])
      const app = buildApp(db, { embed: fakeEmbed, llm }, authedAs('u1'))

      const res = await postJson(app, '/sessions', { prompt: 'play something chill' })
      expect(res.status).toBe(200)
      const body = (await res.json()) as { sessionTitle?: string }
      expect(body).not.toHaveProperty('sessionTitle')
    })
  })

  describe('PATCH /sessions/:id', () => {
    async function createPlainSession(db: TestDb, userId: string) {
      const { llm } = makeFakeLlm([{ text: 'hi' }])
      const app = buildApp(db, { embed: fakeEmbed, llm }, authedAs(userId))
      const res = await postJson(app, '/sessions', { prompt: 'a session' })
      const body = (await res.json()) as { session: { id: string } }
      return body.session.id
    }

    it('archives then reactivates a session — round trip, returning the list-row shape', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const sessionId = await createPlainSession(db, 'u1')
      const { llm } = makeFakeLlm([{ text: 'n/a' }])
      const app = buildApp(db, { embed: fakeEmbed, llm }, authedAs('u1'))

      const archiveRes = await patchJson(app, `/sessions/${sessionId}`, { status: 'archived' })
      expect(archiveRes.status).toBe(200)
      const archiveBody = (await archiveRes.json()) as {
        session: { id: string; title: string; status: string; queueVersion: number; updatedAt: string }
      }
      expect(archiveBody.session.id).toBe(sessionId)
      expect(archiveBody.session.status).toBe('archived')
      expect(archiveBody.session.queueVersion).toBe(0)
      expect(archiveBody.session.title).toBeTruthy()
      expect(archiveBody.session.updatedAt).toBeTruthy()

      const reactivateRes = await patchJson(app, `/sessions/${sessionId}`, { status: 'active' })
      expect(reactivateRes.status).toBe(200)
      const reactivateBody = (await reactivateRes.json()) as { session: { status: string } }
      expect(reactivateBody.session.status).toBe('active')
    })

    it('404s for another user’s session id (no existence leak)', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      await seedUser(db, 'u2')
      const sessionId = await createPlainSession(db, 'u1')
      const { llm } = makeFakeLlm([{ text: 'n/a' }])
      const appU2 = buildApp(db, { embed: fakeEmbed, llm }, authedAs('u2'))

      const res = await patchJson(appU2, `/sessions/${sessionId}`, { status: 'archived' })
      expect(res.status).toBe(404)
    })

    it('GET /sessions still returns an archived session — the client filters it out, not the server', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const sessionId = await createPlainSession(db, 'u1')
      const { llm } = makeFakeLlm([{ text: 'n/a' }])
      const app = buildApp(db, { embed: fakeEmbed, llm }, authedAs('u1'))
      await patchJson(app, `/sessions/${sessionId}`, { status: 'archived' })

      const res = await getJson(app, '/sessions')
      expect(res.status).toBe(200)
      const body = (await res.json()) as { sessions: Array<{ id: string; status: string }> }
      const row = body.sessions.find((s) => s.id === sessionId)
      expect(row).toBeDefined()
      expect(row!.status).toBe('archived')
    })

    it('renames a session — persists the sanitized title and returns it in the list-row shape', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const sessionId = await createPlainSession(db, 'u1')
      const { llm } = makeFakeLlm([{ text: 'n/a' }])
      const app = buildApp(db, { embed: fakeEmbed, llm }, authedAs('u1'))

      const res = await patchJson(app, `/sessions/${sessionId}`, { title: 'Lagos Nights' })
      expect(res.status).toBe(200)
      const body = (await res.json()) as { session: { id: string; title: string } }
      expect(body.session.id).toBe(sessionId)
      expect(body.session.title).toBe('Lagos Nights')

      const [row] = await db.select().from(djSessions).where(eq(djSessions.id, sessionId))
      expect(row.title).toBe('Lagos Nights')
    })

    it('rejects an empty or whitespace-only title with 400', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const sessionId = await createPlainSession(db, 'u1')
      const { llm } = makeFakeLlm([{ text: 'n/a' }])
      const app = buildApp(db, { embed: fakeEmbed, llm }, authedAs('u1'))

      // '' fails the raw zod min(1) bound...
      const emptyRes = await patchJson(app, `/sessions/${sessionId}`, { title: '' })
      expect(emptyRes.status).toBe(400)

      // ...while a whitespace-only string passes that raw bound but sanitizes
      // down to nothing, so the HANDLER's own rejection has to catch it.
      const wsRes = await patchJson(app, `/sessions/${sessionId}`, { title: '   ' })
      expect(wsRes.status).toBe(400)
      const wsBody = (await wsRes.json()) as { error: string }
      expect(wsBody.error).toBe('invalid_title')
    })

    it('caps an over-60-char title at 60 (display cap), matching titleFromPrompt\'s discipline', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const sessionId = await createPlainSession(db, 'u1')
      const { llm } = makeFakeLlm([{ text: 'n/a' }])
      const app = buildApp(db, { embed: fakeEmbed, llm }, authedAs('u1'))
      const longTitle = 'a'.repeat(90)

      const res = await patchJson(app, `/sessions/${sessionId}`, { title: longTitle })
      expect(res.status).toBe(200)
      const body = (await res.json()) as { session: { title: string } }
      expect(body.session.title).toBe('a'.repeat(60))
    })

    it('rejects a title over the raw 120-char zod bound with 400, before it ever reaches sanitize', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const sessionId = await createPlainSession(db, 'u1')
      const { llm } = makeFakeLlm([{ text: 'n/a' }])
      const app = buildApp(db, { embed: fakeEmbed, llm }, authedAs('u1'))

      const res = await patchJson(app, `/sessions/${sessionId}`, { title: 'a'.repeat(121) })
      expect(res.status).toBe(400)
    })

    it('404s a rename for another user\'s session id (no existence leak)', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      await seedUser(db, 'u2')
      const sessionId = await createPlainSession(db, 'u1')
      const { llm } = makeFakeLlm([{ text: 'n/a' }])
      const appU2 = buildApp(db, { embed: fakeEmbed, llm }, authedAs('u2'))

      const res = await patchJson(appU2, `/sessions/${sessionId}`, { title: 'hijacked' })
      expect(res.status).toBe(404)
    })

    it('accepts status and title together in one PATCH', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const sessionId = await createPlainSession(db, 'u1')
      const { llm } = makeFakeLlm([{ text: 'n/a' }])
      const app = buildApp(db, { embed: fakeEmbed, llm }, authedAs('u1'))

      const res = await patchJson(app, `/sessions/${sessionId}`, { status: 'archived', title: 'Lagos Nights' })
      expect(res.status).toBe(200)
      const body = (await res.json()) as { session: { title: string; status: string } }
      expect(body.session.status).toBe('archived')
      expect(body.session.title).toBe('Lagos Nights')
    })

    it('rejects a body with neither status nor title', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const sessionId = await createPlainSession(db, 'u1')
      const { llm } = makeFakeLlm([{ text: 'n/a' }])
      const app = buildApp(db, { embed: fakeEmbed, llm }, authedAs('u1'))

      const res = await patchJson(app, `/sessions/${sessionId}`, {})
      expect(res.status).toBe(400)
    })
  })
})

// --- Task 5: notPersonal rides every session summary --------------------

describe('notPersonal on session routes', () => {
  async function createPlainSession(db: TestDb, userId: string) {
    const { llm } = makeFakeLlm([{ text: 'hi' }])
    const app = buildApp(db, { embed: fakeEmbed, llm }, authedAs(userId))
    const res = await postJson(app, '/sessions', { prompt: 'a session' })
    const body = (await res.json()) as { session: { id: string; notPersonal: boolean } }
    return body
  }

  it('POST /sessions echoes notPersonal (false for a text-only first turn)', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const body = await createPlainSession(db, 'u1')
    expect(body.session.notPersonal).toBe(false)
  })

  it('GET /sessions, GET /sessions/:id, and PATCH /sessions/:id all carry the flag', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const { session } = await createPlainSession(db, 'u1')
    await db.update(djSessions).set({ notPersonal: true }).where(eq(djSessions.id, session.id))
    const { llm } = makeFakeLlm([{ text: 'n/a' }])
    const app = buildApp(db, { embed: fakeEmbed, llm }, authedAs('u1'))

    const listRes = await getJson(app, '/sessions')
    const list = (await listRes.json()) as { sessions: Array<{ id: string; notPersonal: boolean }> }
    expect(list.sessions.find((s) => s.id === session.id)?.notPersonal).toBe(true)

    const detailRes = await getJson(app, `/sessions/${session.id}`)
    const detail = (await detailRes.json()) as { session: { notPersonal: boolean } }
    expect(detail.session.notPersonal).toBe(true)

    const patchRes = await patchJson(app, `/sessions/${session.id}`, { title: 'Renamed' })
    const patched = (await patchRes.json()) as { session: { notPersonal: boolean; title: string } }
    expect(patched.session.notPersonal).toBe(true)
    expect(patched.session.title).toBe('Renamed')
  })

  it('a corpus-mode first turn creates the session already flagged, end to end', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedCorpusListener(db, 'u1')
    const { llm } = makeFakeLlm([
      { toolCalls: [toolCall('c1', 'generate_queue', { themes: 'late night', targetCount: 4 })] },
      { text: 'a first guess, not from your history yet.' },
    ])
    const app = buildApp(db, { embed: fakeEmbed, llm }, authedAs('u1'))

    const res = await postJson(app, '/sessions', { prompt: 'something for late night' })
    expect(res.status).toBe(200)
    const body = (await res.json()) as { session: { id: string; notPersonal: boolean }; queue: unknown[] }
    expect(body.queue).toHaveLength(4)
    expect(body.session.notPersonal).toBe(true)

    const listRes = await getJson(app, '/sessions')
    const list = (await listRes.json()) as { sessions: Array<{ id: string; notPersonal: boolean }> }
    expect(list.sessions.find((s) => s.id === body.session.id)?.notPersonal).toBe(true)
  })
})
