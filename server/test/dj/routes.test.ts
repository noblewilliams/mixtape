import { describe, it, expect } from 'vitest'
import { createTestDb, type TestDb } from '../helpers/db'
import { createApp, type AuthLike } from '../../src/app'
import type { DjDeps } from '../../src/dj/loop'
import type { LlmClient, LlmRequest, LlmTurn, LlmAssistantBlock, LlmToolCall } from '../../src/dj/llm'
import { LlmError } from '../../src/dj/llm'
import type { Embedder } from '../../src/enrich/embedder'
import { tracks, trackMeanings, userTracks, user, djSessions, djMessages } from '../../src/db/schema'
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
      const body = (await res.json()) as { error: string }
      expect(body.error).toBe('llm')

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
})
