import { describe, it, expect } from 'vitest'
import { asc, eq } from 'drizzle-orm'
import { createTestDb, type TestDb } from '../helpers/db'
import { runDjTurn, DjError, FALLBACK_TEXT, type DjDeps, type DjSessionRef } from '../../src/dj/loop'
import { LlmError, type LlmClient, type LlmRequest, type LlmTurn, type LlmAssistantBlock, type LlmToolCall } from '../../src/dj/llm'
import { replaceQueue, applyOps } from '../../src/dj/queue-store'
import { djMessages, djSessions, tracks, trackMeanings, userTracks, user } from '../../src/db/schema'
import type { Embedder } from '../../src/enrich/embedder'

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

async function seedSession(db: TestDb, userId: string, title = 'session') {
  const [s] = await db.insert(djSessions).values({ userId, title }).returning()
  return s
}

let trackCounter = 0

async function seedLibraryTrack(db: TestDb, userId: string, opts: { title?: string; embedding?: number[]; playCount?: number } = {}) {
  trackCounter += 1
  const label = opts.title ?? `Track ${trackCounter}`
  const [t] = await db
    .insert(tracks)
    .values({ appleId: `apple-${trackCounter}`, title: label, artist: 'Artist', durationMs: 200_000 })
    .returning()
  if (opts.embedding) {
    await db.insert(trackMeanings).values({ trackId: t.id, embedding: opts.embedding, lyricsSource: 'lrclib' })
  }
  await db.insert(userTracks).values({ userId, trackId: t.id, playCount: opts.playCount ?? 0, inLibrary: true })
  return t
}

async function seedLibrary(db: TestDb, userId: string, n: number) {
  const out = []
  for (let i = 0; i < n; i++) out.push(await seedLibraryTrack(db, userId, { embedding: MATCHING_DIRECTION }))
  return out
}

async function readMessages(db: TestDb, sessionId: string) {
  return db.select().from(djMessages).where(eq(djMessages.sessionId, sessionId)).orderBy(asc(djMessages.seq))
}

type ScriptedTurn = Partial<LlmTurn>

function defaultRaw(scripted: ScriptedTurn): LlmAssistantBlock[] {
  const blocks: LlmAssistantBlock[] = []
  if (scripted.text) blocks.push({ type: 'text', text: scripted.text })
  for (const tc of scripted.toolCalls ?? []) blocks.push({ type: 'tool_use', id: tc.id, name: tc.name, input: tc.input })
  return blocks
}

// Synthesizes a plausible curate() response by reading the pool ids and the
// requested count straight out of curate's own prompt text — curate always
// calls the SAME LlmClient the conversation loop uses (tools: [] is how a
// curate call is told apart from a conversation round), so any test that
// exercises a real generate/swap/extend needs this to keep those calls from
// falling through to the (conversation-shaped) script below.
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
function makeFakeLlm(conversationScript: ScriptedTurn[]): { llm: LlmClient; requests: LlmRequest[] } {
  const requests: LlmRequest[] = []
  let convCall = 0
  const llm: LlmClient = async (req) => {
    requests.push(req)
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
  return { llm, requests }
}

// Conversation-only requests — i.e. NOT one of curate's tools:[] calls —
// in the order they were sent. Useful for asserting round-by-round shape
// without hardcoding indices that a curate call could shift.
function conversationRequests(requests: LlmRequest[]): LlmRequest[] {
  return requests.filter((r) => r.tools.length > 0)
}

function toolCall(id: string, name: string, input: unknown): LlmToolCall {
  return { id, name, input }
}

describe('runDjTurn', () => {
  it('generate flow: tool_use generate_queue then text — queue persisted, messages persisted in order, dj message carries the new queueVersion', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const session = await seedSession(db, 'u1')
    await seedLibrary(db, 'u1', 5)
    const sessionRef: DjSessionRef = { id: session.id, userId: 'u1' }
    const deps: DjDeps = {
      embed: fakeEmbed,
      llm: makeFakeLlm([
        { toolCalls: [toolCall('c1', 'generate_queue', { themes: 'rainy drive', targetCount: 3 })] },
        { text: 'here you go, a moody little set.' },
      ]).llm,
    }

    const result = await runDjTurn(db, deps, sessionRef, 'play me something moody')

    expect(result.queue).toHaveLength(3)
    expect(result.djMessage.content).toBe('here you go, a moody little set.')
    expect(result.djMessage.queueVersion).toBe(result.queueVersion)
    expect(result.djMessage.queueVersion).not.toBeNull()

    const messages = await readMessages(db, session.id)
    expect(messages).toHaveLength(2)
    expect(messages[0].role).toBe('user')
    expect(messages[0].content).toBe('play me something moody')
    expect(messages[0].queueVersion).toBeNull()
    expect(messages[1].role).toBe('dj')
    expect(messages[1].content).toBe('here you go, a moody little set.')
    expect(messages[1].queueVersion).toBe(result.queueVersion)
  })

  it('edit flow: edit_queue remove bumps the version and feeds an honest accounting tool_result back to the model', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const session = await seedSession(db, 'u1')
    const trackList = await seedLibrary(db, 'u1', 3)
    await replaceQueue(
      db,
      session.id,
      trackList.map((t) => ({ trackId: t.id, reason: '' })),
      'dj',
    )
    const sessionRef: DjSessionRef = { id: session.id, userId: 'u1' }
    const { llm, requests } = makeFakeLlm([
      { toolCalls: [toolCall('c1', 'edit_queue', { ops: [{ op: 'remove', position: 0 }] })] },
      { text: 'done, dropped the first one.' },
    ])
    const deps: DjDeps = { embed: fakeEmbed, llm }

    const result = await runDjTurn(db, deps, sessionRef, 'take off the first track')

    expect(result.queue).toHaveLength(2)
    expect(result.djMessage.queueVersion).toBe(result.queueVersion)

    const convo = conversationRequests(requests)
    expect(convo).toHaveLength(2)
    const secondRequestMessages = convo[1].messages
    const toolResultMessage = secondRequestMessages.find(
      (m) => m.role === 'user' && Array.isArray(m.content) && (m.content[0] as { type?: string })?.type === 'tool_result',
    )
    expect(toolResultMessage).toBeDefined()
    const content = (toolResultMessage!.content as Array<{ content: string }>)[0].content
    expect(content).toContain('removed 1')
    expect(content).toContain('requested 0')
    expect(content).toContain('added 0')
  })

  it('replays an assistant turn (including a thinking block) verbatim via turn.raw on the next request', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const session = await seedSession(db, 'u1')
    const trackList = await seedLibrary(db, 'u1', 2)
    await replaceQueue(
      db,
      session.id,
      trackList.map((t) => ({ trackId: t.id, reason: '' })),
      'dj',
    )
    const sessionRef: DjSessionRef = { id: session.id, userId: 'u1' }
    const thinkingBlock: LlmAssistantBlock = { type: 'thinking', thinking: 'weighing which track to drop', signature: 'sig-1' }
    const toolUseBlock: LlmAssistantBlock = { type: 'tool_use', id: 'c1', name: 'edit_queue', input: { ops: [{ op: 'remove', position: 0 }] } }
    const { llm, requests } = makeFakeLlm([
      { raw: [thinkingBlock, toolUseBlock], toolCalls: [toolCall('c1', 'edit_queue', { ops: [{ op: 'remove', position: 0 }] })] },
      { text: 'ok, done.' },
    ])
    const deps: DjDeps = { embed: fakeEmbed, llm }

    await runDjTurn(db, deps, sessionRef, 'drop the first track')

    const convo = conversationRequests(requests)
    expect(convo).toHaveLength(2) // a plain remove needs no replacementsProvider — no curate call in between
    const replayed = convo[1].messages.find((m) => m.role === 'assistant')
    expect(replayed).toEqual({ role: 'assistant', content: [thinkingBlock, toolUseBlock] })
  })

  it('text-only reply: no queue change, queueVersion stays null on the message', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const session = await seedSession(db, 'u1')
    const sessionRef: DjSessionRef = { id: session.id, userId: 'u1' }
    const deps: DjDeps = { embed: fakeEmbed, llm: makeFakeLlm([{ text: 'just chatting, no queue changes.' }]).llm }

    const result = await runDjTurn(db, deps, sessionRef, 'hey, how are you?')

    expect(result.queue).toHaveLength(0)
    expect(result.djMessage.content).toBe('just chatting, no queue changes.')
    expect(result.djMessage.queueVersion).toBeNull()
  })

  it('MAX_TURNS bound: a model that always returns tool_use gets a fallback reply, never an infinite loop', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const session = await seedSession(db, 'u1')
    const trackList = await seedLibrary(db, 'u1', 6)
    await replaceQueue(
      db,
      session.id,
      trackList.map((t) => ({ trackId: t.id, reason: '' })),
      'dj',
    )
    const sessionRef: DjSessionRef = { id: session.id, userId: 'u1' }
    const { llm, requests } = makeFakeLlm([{ toolCalls: [toolCall('c1', 'edit_queue', { ops: [{ op: 'remove', position: 0 }] })] }])
    const deps: DjDeps = { embed: fakeEmbed, llm }

    const result = await runDjTurn(db, deps, sessionRef, 'keep trimming it down')

    expect(result.djMessage.content).toBe(FALLBACK_TEXT)
    expect(conversationRequests(requests)).toHaveLength(4) // MAX_TURNS, no 5th call
    expect(result.queue).toHaveLength(2) // 4 successful removes from 6
  })

  it('an LlmError aborts the turn as DjError kind "llm" — user message persisted, no dj message', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const session = await seedSession(db, 'u1')
    const sessionRef: DjSessionRef = { id: session.id, userId: 'u1' }
    const llm: LlmClient = async () => {
      throw new LlmError('boom', 500)
    }
    const deps: DjDeps = { embed: fakeEmbed, llm }

    let error: unknown
    try {
      await runDjTurn(db, deps, sessionRef, 'hello')
      throw new Error('expected runDjTurn to reject')
    } catch (e) {
      error = e
    }
    expect(error).toBeInstanceOf(DjError)
    expect((error as DjError).kind).toBe('llm')

    const messages = await readMessages(db, session.id)
    expect(messages).toHaveLength(1)
    expect(messages[0].role).toBe('user')
  })

  it('a curation parse failure surfaces as DjError kind "curation" — no dj message persisted', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const session = await seedSession(db, 'u1')
    await seedLibrary(db, 'u1', 3)
    const sessionRef: DjSessionRef = { id: session.id, userId: 'u1' }
    const llm: LlmClient = async (req) => {
      if (req.tools.length === 0) {
        // Garbage curation output — no parseable picks array anywhere.
        return { text: 'sorry, I cannot comply with that today!', toolCalls: [], raw: [], stopReason: 'end_turn', usage: null }
      }
      return {
        text: '',
        toolCalls: [toolCall('c1', 'generate_queue', { themes: 'x', targetCount: 3 })],
        raw: [{ type: 'tool_use', id: 'c1', name: 'generate_queue', input: { themes: 'x', targetCount: 3 } }],
        stopReason: 'tool_use',
        usage: null,
      }
    }
    const deps: DjDeps = { embed: fakeEmbed, llm }

    let error: unknown
    try {
      await runDjTurn(db, deps, sessionRef, 'give me something')
      throw new Error('expected runDjTurn to reject')
    } catch (e) {
      error = e
    }
    expect(error).toBeInstanceOf(DjError)
    expect((error as DjError).kind).toBe('curation')

    const messages = await readMessages(db, session.id)
    expect(messages).toHaveLength(1)
  })

  it('invalid tool input (missing required field) feeds validation text back; the model corrects and the second call succeeds', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const session = await seedSession(db, 'u1')
    await seedLibrary(db, 'u1', 4)
    const sessionRef: DjSessionRef = { id: session.id, userId: 'u1' }
    const { llm, requests } = makeFakeLlm([
      { toolCalls: [toolCall('c1', 'generate_queue', { targetCount: 3 })] }, // missing required `themes`
      { toolCalls: [toolCall('c2', 'generate_queue', { themes: 'now with themes', targetCount: 3 })] },
      { text: 'fixed it, here you go.' },
    ])
    const deps: DjDeps = { embed: fakeEmbed, llm }

    const result = await runDjTurn(db, deps, sessionRef, 'play something')

    expect(result.queue).toHaveLength(3)
    expect(result.djMessage.content).toBe('fixed it, here you go.')
    expect(result.djMessage.queueVersion).not.toBeNull()

    const convo = conversationRequests(requests)
    const secondRequestMessages = convo[1].messages
    const toolResultMessage = secondRequestMessages.find(
      (m) => m.role === 'user' && Array.isArray(m.content) && (m.content[0] as { type?: string })?.type === 'tool_result',
    )
    const content = (toolResultMessage!.content as Array<{ content: string }>)[0].content
    expect(content).toContain('invalid generate_queue input')
    expect(content).toContain('themes')
  })

  it('an empty pool gets an honest no-match tool_result, and the dj still finishes normally', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const session = await seedSession(db, 'u1')
    // No library tracks at all for this user — buildPool must come back empty.
    const sessionRef: DjSessionRef = { id: session.id, userId: 'u1' }
    const { llm, requests } = makeFakeLlm([
      { toolCalls: [toolCall('c1', 'generate_queue', { themes: 'nonexistent genre', targetCount: 5 })] },
      { text: "sorry, nothing quite fits that in your library yet." },
    ])
    const deps: DjDeps = { embed: fakeEmbed, llm }

    const result = await runDjTurn(db, deps, sessionRef, 'play me some nonexistent genre')

    expect(result.queue).toHaveLength(0)
    expect(result.djMessage.content).toBe("sorry, nothing quite fits that in your library yet.")
    expect(result.djMessage.queueVersion).toBeNull()

    const convo = conversationRequests(requests)
    const toolResultMessage = convo[1].messages.find(
      (m) => m.role === 'user' && Array.isArray(m.content) && (m.content[0] as { type?: string })?.type === 'tool_result',
    )
    const content = (toolResultMessage!.content as Array<{ content: string }>)[0].content
    expect(content).toBe('no tracks in the library match those constraints')
  })

  it("includes an acknowledgment of the listener's own manual removal (since the dj's last message) in the next turn's context", async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const session = await seedSession(db, 'u1')
    const distinctive = await seedLibraryTrack(db, 'u1', { title: 'Distinctive Song Title Zzyzx' })
    const other = await seedLibraryTrack(db, 'u1')
    await replaceQueue(
      db,
      session.id,
      [distinctive, other].map((t) => ({ trackId: t.id, reason: '' })),
      'dj',
    )
    // An earlier dj turn, deliberately timestamped well in the past.
    await db.insert(djMessages).values({
      sessionId: session.id,
      role: 'dj',
      content: 'earlier dj turn',
      queueVersion: 1,
      createdAt: new Date(Date.now() - 60_000),
    })
    // The listener removes the distinctive track AFTER that dj turn.
    await applyOps(db, session.id, [{ op: 'remove', position: 0 }], 'user')

    const sessionRef: DjSessionRef = { id: session.id, userId: 'u1' }
    const { llm, requests } = makeFakeLlm([{ text: 'noticed you trimmed the queue — updating the vibe.' }])
    const deps: DjDeps = { embed: fakeEmbed, llm }

    await runDjTurn(db, deps, sessionRef, 'keep going with the same mood')

    const convo = conversationRequests(requests)
    expect(convo[0].system).toContain('Distinctive Song Title Zzyzx')
    expect(convo[0].system).toContain('manually removed')
  })

  // These two exercise "QueueVersionConflict -> retry the turn ONCE from a
  // fresh snapshot, then 'conflict'". The race is manufactured through
  // curate's own LLM call (the only outside hook a replacementsProvider's
  // curation step has): while resolving an extend op's replacement track,
  // the fake performs a SECOND write to the same session (as if another
  // request landed concurrently), which is exactly the phase 1 -> phase 2
  // window queue-store's applyOps guards with QueueVersionConflict.
  describe('QueueVersionConflict retry contract', () => {
    async function seedExtendScenario(db: TestDb) {
      await seedUser(db, 'u1')
      const session = await seedSession(db, 'u1')
      const trackList = await seedLibrary(db, 'u1', 2)
      // A high play count makes `extra` score strictly highest among the
      // three (identical embedding direction and tempo otherwise tie the
      // rest) — the fake curate responder picks pool order top-down, so this
      // is what makes it deterministically the extend's pick rather than a
      // duplicate of a track already active in the queue.
      const extra = await seedLibraryTrack(db, 'u1', { embedding: MATCHING_DIRECTION, playCount: 200 })
      await replaceQueue(
        db,
        session.id,
        trackList.map((t) => ({ trackId: t.id, reason: '' })),
        'dj',
      )
      return { session, trackList, extra }
    }

    it('resolves via a single retry when the interloping write happens only once', async () => {
      const db = await createTestDb()
      const { session, trackList, extra } = await seedExtendScenario(db)
      const sessionRef: DjSessionRef = { id: session.id, userId: 'u1' }
      let interloperFired = false
      // Branches on whether THIS round's request already carries an
      // assistant (tool_use) turn — true from the second round of any given
      // attemptTurn call onward — rather than a raw call counter, because a
      // conflict-triggered retry starts attemptTurn fresh (round 0 again,
      // empty liveMessages): a call-count-based script would never re-issue
      // the extend on retry, since the interrupted first attempt already
      // consumed round 1 of a shared counter.
      const llm: LlmClient = async (req) => {
        if (req.tools.length === 0) {
          if (!interloperFired) {
            interloperFired = true
            // A concurrent write lands while curation is "in flight" — bumps
            // the session's queueVersion out from under this call's phase 1
            // snapshot, exactly like the queue-store race test.
            await applyOps(db, session.id, [{ op: 'move', from: 0, to: 1 }], 'user')
          }
          return curateFakeResponseFromRequest(req)
        }
        const alreadyUsedATool = req.messages.some((m) => m.role === 'assistant')
        if (!alreadyUsedATool) {
          return {
            text: '',
            toolCalls: [toolCall('c1', 'edit_queue', { ops: [{ op: 'extend', count: 1 }] })],
            raw: [{ type: 'tool_use', id: 'c1', name: 'edit_queue', input: { ops: [{ op: 'extend', count: 1 }] } }],
            stopReason: 'tool_use',
            usage: null,
          }
        }
        return { text: 'stretched it out for you.', toolCalls: [], raw: [{ type: 'text', text: 'stretched it out for you.' }], stopReason: 'end_turn', usage: null }
      }
      const deps: DjDeps = { embed: fakeEmbed, llm }

      const result = await runDjTurn(db, deps, sessionRef, 'stretch this out a bit')

      expect(result.djMessage.content).toBe('stretched it out for you.')
      // Both the interloping move (version 2) and the eventual successful
      // extend (version 3, on retry) took effect — 3 tracks active, in the
      // order the interloping move+extend actually produced.
      expect(result.queue.map((q) => q.trackId)).toEqual([trackList[1].id, trackList[0].id, extra.id])
      expect(result.queue).toHaveLength(3)
    })

    it('surfaces DjError kind "conflict" when the race persists through the retry — no dj message persisted', async () => {
      const db = await createTestDb()
      const { session } = await seedExtendScenario(db)
      const sessionRef: DjSessionRef = { id: session.id, userId: 'u1' }
      const llm: LlmClient = async (req) => {
        if (req.tools.length === 0) {
          // Fires on EVERY curate call — both the original attempt and the retry race.
          await applyOps(db, session.id, [{ op: 'move', from: 0, to: 1 }], 'user')
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
      const deps: DjDeps = { embed: fakeEmbed, llm }

      let error: unknown
      try {
        await runDjTurn(db, deps, sessionRef, 'stretch this out a bit')
        throw new Error('expected runDjTurn to reject')
      } catch (e) {
        error = e
      }
      expect(error).toBeInstanceOf(DjError)
      expect((error as DjError).kind).toBe('conflict')

      const messages = await readMessages(db, session.id)
      expect(messages).toHaveLength(1) // user message only
      expect(messages[0].role).toBe('user')
    })
  })
})
