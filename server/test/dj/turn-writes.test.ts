import { describe, it, expect } from 'vitest'
import { asc, eq } from 'drizzle-orm'
import { createTestDb, type TestDb } from '../helpers/db'
import { type DjDeps, type DjSessionRef, type DjTurnOptions, type PersistedTurnWrites } from '../../src/dj/loop'
import { runDjTurn } from '../helpers/turn'
import { rollbackTurn } from '../../src/dj/turn-stop'
import type { LlmClient, LlmRequest, LlmTurn } from '../../src/dj/llm'
import { getActiveQueue } from '../../src/dj/queue-store'
import { djMessages, djSessions, trackMeanings, tracks, user, userTracks } from '../../src/db/schema'
import type { Embedder } from '../../src/enrich/embedder'

// What a turn records for a later attempt's rollback (spec 2026-11-21
// durable-mix-turns, "Retries without a second mix"): the recordWrites hook
// on DjTurnOptions, and rollbackTurn run from a stored snapshot.

const DIMS = 1024
const DIRECTION = (() => {
  const v = new Array(DIMS).fill(0)
  v[0] = 1
  return v
})()
const embed: Embedder = async () => DIRECTION
const FAST = { pollMs: 5, timeoutMs: 5_000, guardPollMs: 10 }
const IOS = { surface: 'ios', stopTiming: FAST } as const
// A brief for the listener's own favourites: what offers the history pill
// to a listener the app sees no plays for.
const COMFORT = { themes: 'my favourites', targetCount: 5, familiarity: 'comfort' }
const MIX = { themes: 'late night', targetCount: 3, familiarity: 'mix' }

let counter = 0

// A listener with a library and no plays (every play count zero), so an
// own-music generate claims the history pill.
async function seed(db: TestDb, userId = 'u1', libraryTracks = 8) {
  await db.insert(user).values({ id: userId, name: userId, email: `${userId}@example.com`, emailVerified: false, createdAt: new Date(), updatedAt: new Date() })
  const [session] = await db.insert(djSessions).values({ userId, title: 'Original title' }).returning()
  for (let i = 0; i < libraryTracks; i++) {
    counter += 1
    const [t] = await db.insert(tracks).values({ appleId: `writes-${counter}`, title: `Track ${counter}`, artist: `Artist ${counter}`, durationMs: 200_000 }).returning()
    await db.insert(trackMeanings).values({ trackId: t.id, embedding: DIRECTION, lyricsSource: 'lrclib' })
    await db.insert(userTracks).values({ userId, trackId: t.id, playCount: 0, inLibrary: true })
  }
  return { session, ref: { id: session.id, userId } satisfies DjSessionRef }
}

function curate(req: LlmRequest): LlmTurn {
  const message = req.messages[0]
  const blocks = typeof message.content === 'string' ? [] : (message.content as Array<{ text?: string }>)
  const ids = Array.from((blocks[0]?.text ?? '').matchAll(/^([0-9a-f-]{36}) \|/gm)).map((m) => m[1])
  const count = Number((blocks[1]?.text ?? '').match(/Pick up to (\d+) tracks/)?.[1] ?? ids.length)
  const picks = ids.reverse().slice(0, count).map((id) => ({ id, reason: 'fits' }))
  return { text: JSON.stringify(picks), toolCalls: [], raw: [{ type: 'text', text: JSON.stringify(picks) }], stopReason: 'end_turn', usage: { inputTokens: 1, outputTokens: 1, cacheReadInputTokens: null } }
}

function reply(turn: Partial<LlmTurn>): LlmTurn {
  const raw: LlmTurn['raw'] = []
  if (turn.text) raw.push({ type: 'text', text: turn.text })
  for (const tc of turn.toolCalls ?? []) raw.push({ type: 'tool_use', id: tc.id, name: tc.name, input: tc.input })
  return { text: turn.text ?? '', toolCalls: turn.toolCalls ?? [], raw, stopReason: 'end_turn', usage: { inputTokens: 1, outputTokens: 1, cacheReadInputTokens: null } }
}

type Call = { name: string; input: Record<string, unknown> }

// The model's conversation rounds: each call in turn, one per round, then
// [text]. Curation calls (no tools offered) are answered by curate.
function scripted(calls: Call[], text: string): LlmClient {
  let round = 0
  return async (req) => {
    if (req.tools.length === 0) return curate(req)
    const call = calls[round]
    round += 1
    if (call) return reply({ toolCalls: [{ id: `c${counter}-${round}`, name: call.name, input: call.input }] })
    return reply({ text })
  }
}

const generate = (input: Record<string, unknown>): Call => ({ name: 'generate_queue', input })
const rename = (title: string): Call => ({ name: 'rename_session', input: { title } })

async function messages(db: TestDb, sessionId: string) {
  return db.select().from(djMessages).where(eq(djMessages.sessionId, sessionId)).orderBy(asc(djMessages.seq))
}

async function sessionRow(db: TestDb, sessionId: string) {
  const [row] = await db.select().from(djSessions).where(eq(djSessions.id, sessionId))
  return row
}

// Runs a turn recording every snapshot, with what the session looked like
// at the moment each one was handed over.
async function recordedTurn(db: TestDb, deps: DjDeps, ref: DjSessionRef, text: string, options: Omit<DjTurnOptions, 'userMessageSeq' | 'recordWrites'> = {}) {
  const snapshots: Array<{ writes: PersistedTurnWrites; title: string; chip: boolean }> = []
  const result = await runDjTurn(db, deps, ref, text, {
    ...options,
    recordWrites: async (writes) => {
      const row = await sessionRow(db, ref.id)
      snapshots.push({ writes, title: row.title, chip: row.musicChipAt !== null })
    },
  })
  return { result, snapshots, last: snapshots.at(-1)!.writes }
}

describe('recordWrites', () => {
  it('records at the start: the listener message seq, the starting version and the claim', async () => {
    const db = await createTestDb()
    const { session, ref } = await seed(db)
    const { result, snapshots } = await recordedTurn(db, { embed, llm: scripted([generate(MIX)], 'here') }, ref, 'a mix', IOS)

    const [user] = await messages(db, session.id)
    const first = snapshots[0].writes
    expect(first).toEqual({
      messageSeqs: [user.seq],
      renamed: false,
      historyOffered: false,
      startingVersion: 0,
      claimTitle: 'Original title',
      claimNotPersonal: false,
      claimTurnId: expect.any(String),
    })
    // Then once more for the DJ's reply, and nothing else changed.
    expect(snapshots.map((s) => s.writes.messageSeqs)).toEqual([[user.seq], [user.seq, result.djMessage.seq]])
    // Stored as JSON: it survives the round trip whole.
    for (const { writes } of snapshots) expect(JSON.parse(JSON.stringify(writes))).toEqual(writes)
  })

  it('records a rename the moment its write lands, before the reply', async () => {
    const db = await createTestDb()
    const { session, ref } = await seed(db)
    const { snapshots, last } = await recordedTurn(db, { embed, llm: scripted([rename('Lagos Nights')], 'renamed') }, ref, 'call it Lagos Nights', IOS)

    const [user] = await messages(db, session.id)
    expect(snapshots).toHaveLength(3)
    expect(snapshots[1]).toMatchObject({ writes: { messageSeqs: [user.seq], renamed: true, historyOffered: false }, title: 'Lagos Nights' })
    expect(last.renamed).toBe(true)
    expect(last.messageSeqs).toHaveLength(2)
  })

  it('records a pill claim the moment its write lands, before the reply', async () => {
    const db = await createTestDb()
    const { session, ref } = await seed(db)
    const { result, snapshots, last } = await recordedTurn(db, { embed, llm: scripted([generate(COMFORT)], 'your favourites') }, ref, 'play my favourites', IOS)

    expect(result.addMusic).toBe('history')
    const [user] = await messages(db, session.id)
    const claimed = snapshots.find((s) => s.writes.historyOffered)!
    expect(claimed).toMatchObject({ writes: { messageSeqs: [user.seq], renamed: false }, chip: true })
    expect(last).toMatchObject({ historyOffered: true, messageSeqs: [user.seq, result.djMessage.seq] })
  })

  it('a hook that throws or rejects leaves the turn as it would have been', async () => {
    const plain = await createTestDb()
    const { ref: plainRef } = await seed(plain)
    const expected = await runDjTurn(plain, { embed, llm: scripted([rename('Lagos Nights'), generate(COMFORT)], 'here') }, plainRef, 'a mix', IOS)

    for (const recordWrites of [() => { throw new Error('store down') }, async () => { throw new Error('store down') }]) {
      const db = await createTestDb()
      const { session, ref } = await seed(db)
      const result = await runDjTurn(db, { embed, llm: scripted([rename('Lagos Nights'), generate(COMFORT)], 'here') }, ref, 'a mix', { ...IOS, recordWrites })

      expect(result.djMessage.content).toBe(expected.djMessage.content)
      expect(result.queue).toHaveLength(expected.queue.length)
      expect(result.queueVersion).toBe(expected.queueVersion)
      expect(result.sessionTitle).toBe(expected.sessionTitle)
      expect(result.addMusic).toBe(expected.addMusic)
      expect((await messages(db, session.id)).map((m) => m.content)).toEqual(['a mix', 'here'])
      expect((await sessionRow(db, session.id)).activeTurnId).toBeNull()
    }
  })
})

describe('rollbackTurn from a stored snapshot', () => {
  // A first turn that sets a mix, then a second that renames, regenerates
  // and claims the pill, recorded as it goes. The second turn's claim is put
  // back on the session afterwards, as an attempt that died mid turn would
  // have left it.
  async function deadSecondTurn() {
    const db = await createTestDb()
    const { session, ref } = await seed(db)
    const first = await runDjTurn(db, { embed, llm: scripted([generate(MIX)], 'first mix') }, ref, 'something for late night', IOS)
    const firstQueue = (await getActiveQueue(db, session.id)).map((t) => t.trackId)

    const { result, last } = await recordedTurn(db, { embed, llm: scripted([rename('Lagos Nights'), generate(COMFORT)], 'your favourites') }, ref, 'my favourites, call it Lagos Nights', IOS)
    expect(result.queueVersion).toBeGreaterThan(first.queueVersion)
    expect(result.addMusic).toBe('history')
    expect((await sessionRow(db, session.id)).title).toBe('Lagos Nights')
    await db.update(djSessions).set({ activeTurnId: last.claimTurnId, activeTurnAt: new Date() }).where(eq(djSessions.id, session.id))

    // Stored, then loaded: the rollback sees only what JSON kept.
    const stored = JSON.parse(JSON.stringify(last)) as PersistedTurnWrites
    return { db, session, ref, first, firstQueue, secondVersion: result.queueVersion, stored }
  }

  it("'rerun' undoes the rename, the queue version and the pill claim, and keeps the listener's message", async () => {
    const { db, session, ref, firstQueue, secondVersion, stored } = await deadSecondTurn()

    await rollbackTurn(db, ref, stored, { mode: 'rerun' })

    const row = await sessionRow(db, session.id)
    expect(row.title).toBe('Original title')
    expect(row.musicChipAt).toBeNull()
    expect((await getActiveQueue(db, session.id)).map((t) => t.trackId)).toEqual(firstQueue)
    // A restore: the version moves on, the songs are the first turn's.
    expect(row.queueVersion).toBeGreaterThan(secondVersion)
    expect(row.activeTurnId).toBeNull()
    expect(row.turnStopRequested).toBe(false)
    expect((await messages(db, session.id)).map((m) => m.content)).toEqual([
      'something for late night',
      'first mix',
      'my favourites, call it Lagos Nights',
    ])
  })

  it("'rerun' never deletes the session, even for a first turn", async () => {
    const db = await createTestDb()
    const { session, ref } = await seed(db)
    const { last } = await recordedTurn(db, { embed, llm: scripted([generate(MIX)], 'first mix') }, ref, 'first prompt', { ...IOS, firstTurn: true })

    await rollbackTurn(db, ref, last, { mode: 'rerun' })

    expect(await sessionRow(db, session.id)).toBeDefined()
    expect((await messages(db, session.id)).map((m) => m.content)).toEqual(['first prompt'])
    expect(await getActiveQueue(db, session.id)).toEqual([])
  })

  it("'stop' from the same snapshot takes the listener's message too", async () => {
    const { db, session, ref, firstQueue, stored } = await deadSecondTurn()

    await rollbackTurn(db, ref, stored, { mode: 'stop' })

    const row = await sessionRow(db, session.id)
    expect(row.title).toBe('Original title')
    expect(row.musicChipAt).toBeNull()
    expect((await getActiveQueue(db, session.id)).map((t) => t.trackId)).toEqual(firstQueue)
    expect(row.activeTurnId).toBeNull()
    expect((await messages(db, session.id)).map((m) => m.content)).toEqual(['something for late night', 'first mix'])
  })

  it('leaves the queue and title to a later turn that holds the claim, deleting only its own replies', async () => {
    const { db, session, ref, stored } = await deadSecondTurn()
    await db.update(djSessions).set({ activeTurnId: crypto.randomUUID(), activeTurnAt: new Date() }).where(eq(djSessions.id, session.id))
    const before = (await getActiveQueue(db, session.id)).map((t) => t.trackId)

    await rollbackTurn(db, ref, stored, { mode: 'rerun' })

    expect((await sessionRow(db, session.id)).title).toBe('Lagos Nights')
    expect((await getActiveQueue(db, session.id)).map((t) => t.trackId)).toEqual(before)
    expect((await messages(db, session.id)).map((m) => m.content)).toEqual([
      'something for late night',
      'first mix',
      'my favourites, call it Lagos Nights',
    ])
  })
})
