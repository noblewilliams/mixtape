import { describe, it, expect } from 'vitest'
import { asc, eq } from 'drizzle-orm'
import { createTestDb, type TestDb } from '../helpers/db'
import { runDjTurn, type DjDeps, type DjSessionRef } from '../../src/dj/loop'
import { requestStop, TurnStopped } from '../../src/dj/turn-stop'
import type { LlmClient, LlmRequest, LlmTurn } from '../../src/dj/llm'
import { getActiveQueue } from '../../src/dj/queue-store'
import { djMessages, djSessions, trackMeanings, tracks, user, userTracks } from '../../src/db/schema'
import type { Embedder } from '../../src/enrich/embedder'
import { createApp, type AuthLike } from '../../src/app'

const DIMS = 1024
const DIRECTION = (() => {
  const v = new Array(DIMS).fill(0)
  v[0] = 1
  return v
})()
const embed: Embedder = async () => DIRECTION
const FAST = { pollMs: 5, timeoutMs: 5_000, guardPollMs: 10 }

let counter = 0

async function seed(db: TestDb, userId = 'u1', libraryTracks = 8) {
  await db.insert(user).values({ id: userId, name: userId, email: `${userId}@example.com`, emailVerified: false, createdAt: new Date(), updatedAt: new Date() })
  const [session] = await db.insert(djSessions).values({ userId, title: 'Original title' }).returning()
  for (let i = 0; i < libraryTracks; i++) {
    counter += 1
    const [t] = await db.insert(tracks).values({ appleId: `stop-${counter}`, title: `Track ${counter}`, artist: `Artist ${counter}`, durationMs: 200_000 }).returning()
    await db.insert(trackMeanings).values({ trackId: t.id, embedding: DIRECTION, lyricsSource: 'lrclib' })
    await db.insert(userTracks).values({ userId, trackId: t.id, playCount: i, inLibrary: true })
  }
  return { session, ref: { id: session.id, userId } satisfies DjSessionRef }
}

function curate(req: LlmRequest): LlmTurn {
  const message = req.messages[0]
  const blocks = typeof message.content === 'string' ? [] : (message.content as Array<{ text?: string }>)
  const ids = Array.from((blocks[0]?.text ?? '').matchAll(/^([0-9a-f-]{36}) \|/gm)).map((m) => m[1])
  const count = Number((blocks[1]?.text ?? '').match(/Pick up to (\d+) tracks/)?.[1] ?? ids.length)
  // Reversed, so a second generate lands a different order than the first.
  const picks = ids.reverse().slice(0, count).map((id) => ({ id, reason: 'fits' }))
  return { text: JSON.stringify(picks), toolCalls: [], raw: [{ type: 'text', text: JSON.stringify(picks) }], stopReason: 'end_turn', usage: { inputTokens: 1, outputTokens: 1, cacheReadInputTokens: null } }
}

function reply(turn: Partial<LlmTurn>): LlmTurn {
  const raw: LlmTurn['raw'] = []
  if (turn.text) raw.push({ type: 'text', text: turn.text })
  for (const tc of turn.toolCalls ?? []) raw.push({ type: 'tool_use', id: tc.id, name: tc.name, input: tc.input })
  return { text: turn.text ?? '', toolCalls: turn.toolCalls ?? [], raw, stopReason: 'end_turn', usage: { inputTokens: 1, outputTokens: 1, cacheReadInputTokens: null } }
}

// A conversation that generates a queue, then answers with [last] (a turn,
// or a function standing in for the model's second round).
function generateThen(last: () => Promise<LlmTurn>, toolInput: Record<string, unknown> = { themes: 'moody', targetCount: 4 }): LlmClient {
  let round = 0
  return async (req) => {
    if (req.tools.length === 0) return curate(req)
    round += 1
    if (round === 1) return reply({ toolCalls: [{ id: `g${counter}`, name: 'generate_queue', input: toolInput }] })
    return last()
  }
}

// The turn's promise with its rejection already handled, so a stop that
// lands before the test awaits it is not an unhandled rejection.
function running<T>(turn: Promise<T>): Promise<T> {
  turn.catch(() => {})
  return turn
}

const said = (text: string) => async () => reply({ text })
const never = () => new Promise<LlmTurn>(() => {})

async function messages(db: TestDb, sessionId: string) {
  return db.select().from(djMessages).where(eq(djMessages.sessionId, sessionId)).orderBy(asc(djMessages.seq))
}

async function sessionRow(db: TestDb, sessionId: string) {
  const [row] = await db.select().from(djSessions).where(eq(djSessions.id, sessionId))
  return row
}

// Resolves once the turn holds its claim, so a stop has something to stop.
async function claimed(db: TestDb, sessionId: string) {
  for (let i = 0; i < 500; i++) {
    if ((await sessionRow(db, sessionId))?.activeTurnId) return
    await new Promise((r) => setTimeout(r, 2))
  }
  throw new Error('turn never claimed')
}

describe('stopping a mix turn', () => {
  it('a stop mid model call undoes the turn: messages gone, the mix back as it was, claim released', async () => {
    const db = await createTestDb()
    const { session, ref } = await seed(db)
    const first = await runDjTurn(db, { embed, llm: generateThen(said('first mix')) }, ref, 'something moody', { stopTiming: FAST })
    const before = (await getActiveQueue(db, session.id)).map((t) => t.trackId)
    const messagesBefore = await messages(db, session.id)

    // The second turn writes a new queue, then hangs in its next model call.
    let wrote!: () => void
    const written = new Promise<void>((r) => (wrote = r))
    const turn = running(runDjTurn(db, { embed, llm: generateThen(() => (wrote(), never()), { themes: 'other', targetCount: 3 }) }, ref, 'change it', { stopTiming: FAST }))
    await written
    expect((await sessionRow(db, session.id)).queueVersion).toBeGreaterThan(first.queueVersion)

    const stopped = await requestStop(db, session.id, FAST)

    expect(stopped).toBe(true)
    await expect(turn).rejects.toBeInstanceOf(TurnStopped)
    expect((await messages(db, session.id)).map((m) => m.content)).toEqual(messagesBefore.map((m) => m.content))
    expect((await getActiveQueue(db, session.id)).map((t) => t.trackId)).toEqual(before)
    const row = await sessionRow(db, session.id)
    // A restore: the version moved on, the songs are the old ones.
    expect(row.queueVersion).toBeGreaterThan(first.queueVersion)
    expect(row.activeTurnId).toBeNull()
    expect(row.turnStopRequested).toBe(false)
  })

  it('a stop that lands after the last model call but before the finish still undoes the turn', async () => {
    const db = await createTestDb()
    const { session, ref } = await seed(db)
    // The model's last round raises the flag itself, as a stop arriving
    // right then would; the guard's checks have all passed by now.
    const llm = generateThen(async () => {
      await db.update(djSessions).set({ turnStopRequested: true }).where(eq(djSessions.id, session.id))
      return reply({ text: 'done' })
    })

    await expect(runDjTurn(db, { embed, llm }, ref, 'make me a mix', { stopTiming: FAST })).rejects.toBeInstanceOf(TurnStopped)

    expect(await messages(db, session.id)).toEqual([])
    expect(await getActiveQueue(db, session.id)).toEqual([])
    expect((await sessionRow(db, session.id)).activeTurnId).toBeNull()
  })

  it('a turn that finished first is not stopped: the stop answers false and nothing is undone', async () => {
    const db = await createTestDb()
    const { session, ref } = await seed(db)
    await runDjTurn(db, { embed, llm: generateThen(said('here')) }, ref, 'a mix', { stopTiming: FAST })

    expect(await requestStop(db, session.id, FAST)).toBe(false)
    expect((await messages(db, session.id)).map((m) => m.content)).toEqual(['a mix', 'here'])
    expect((await sessionRow(db, session.id)).turnStopRequested).toBe(false)
  })

  it('a rename this turn made is taken back', async () => {
    const db = await createTestDb()
    const { session, ref } = await seed(db)
    let round = 0
    const llm: LlmClient = async (req) => {
      if (req.tools.length === 0) return curate(req)
      round += 1
      if (round === 1) return reply({ toolCalls: [{ id: 'r1', name: 'rename_session', input: { title: 'Lagos Nights' } }] })
      return never()
    }
    const turn = running(runDjTurn(db, { embed, llm }, ref, 'call it Lagos Nights', { stopTiming: FAST }))
    for (let i = 0; i < 500 && (await sessionRow(db, session.id)).title !== 'Lagos Nights'; i++) await new Promise((r) => setTimeout(r, 2))
    expect((await sessionRow(db, session.id)).title).toBe('Lagos Nights')

    expect(await requestStop(db, session.id, FAST)).toBe(true)
    await expect(turn).rejects.toBeInstanceOf(TurnStopped)
    expect((await sessionRow(db, session.id)).title).toBe('Original title')
  })

  it('a stopped first turn deletes its session', async () => {
    const db = await createTestDb()
    const { session, ref } = await seed(db)
    const turn = running(runDjTurn(db, { embed, llm: generateThen(never) }, ref, 'first prompt', { stopTiming: FAST, firstTurn: true }))
    await claimed(db, session.id)

    expect(await requestStop(db, session.id, FAST)).toBe(true)
    await expect(turn).rejects.toBeInstanceOf(TurnStopped)
    expect(await sessionRow(db, session.id)).toBeUndefined()
  })

  it('a turn right after a stop runs normally', async () => {
    const db = await createTestDb()
    const { session, ref } = await seed(db)
    const stoppedTurn = running(runDjTurn(db, { embed, llm: generateThen(never) }, ref, 'first', { stopTiming: FAST }))
    await claimed(db, session.id)
    await requestStop(db, session.id, FAST)
    await expect(stoppedTurn).rejects.toBeInstanceOf(TurnStopped)

    const next = await runDjTurn(db, { embed, llm: generateThen(said('second answer')) }, ref, 'second', { stopTiming: FAST })

    expect(next.djMessage.content).toBe('second answer')
    expect((await messages(db, session.id)).map((m) => m.content)).toEqual(['second', 'second answer'])
  })
})

describe('POST /sessions/:id/turn/stop', () => {
  const authedAs = (id: string): AuthLike => ({ handler: () => new Response('ok'), api: { getSession: async () => ({ user: { id } }) } })
  const deps: DjDeps = { embed, llm: generateThen(said('hi')) }

  it('answers stopped:false when no turn is running', async () => {
    const db = await createTestDb()
    const { session } = await seed(db)
    const app = createApp({ auth: authedAs('u1'), db, dj: { deps } })

    const res = await app.request(`http://x/sessions/${session.id}/turn/stop`, { method: 'POST' })

    expect(res.status).toBe(200)
    expect(await res.json()).toEqual({ stopped: false })
  })

  it("is 404 for someone else's session", async () => {
    const db = await createTestDb()
    const { session } = await seed(db)
    await db.insert(user).values({ id: 'u2', name: 'u2', email: 'u2@example.com', emailVerified: false, createdAt: new Date(), updatedAt: new Date() })
    const app = createApp({ auth: authedAs('u2'), db, dj: { deps } })

    const res = await app.request(`http://x/sessions/${session.id}/turn/stop`, { method: 'POST' })

    expect(res.status).toBe(404)
  })
})
