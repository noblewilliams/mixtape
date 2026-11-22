import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { eq } from 'drizzle-orm'
import { createTestDb, forkTestDb, type TestDb } from '../helpers/db'
import { embed, FAST, generate, messages, mixSession, normalized, post, queueCreateTurn, queueMessageTurn, scriptedLlm, seedLibrary, seedUser, turnRow, curateReply } from '../helpers/turn-job'
import { LlmError, type LlmClient, type LlmComplete, type LlmRequest } from '../../src/dj/llm'
import { djMessages, djSessions, djTurns } from '../../src/db/schema'
import { getActiveQueue } from '../../src/dj/queue-store'
import { MAX_ATTEMPTS, runTurnJob, TURN_HEARTBEAT_MS, type TurnJobIo } from '../../src/dj/turn-job'
import type { TurnStepEvent } from '../../src/dj/turn-steps'
import type { TurnReply } from '../../src/routes/turn-stream'
import type { Db } from '../../src/db/types'

// The durable turn job (spec 2026-11-21 durable-mix-turns, "Run (object
// side)" and "Retries without a second mix"), over pglite and a scripted
// model, with in-memory watchers and an injected clock.

const TURN_STEPS = ['playlists', 'digging', 'picking', 'checking', 'editing', 'pressing', 'labelling', 'noting', 'writing']

beforeEach(() => {
  // The turn log (counts and codes) is not under test here.
  vi.spyOn(console, 'log').mockImplementation(() => {})
})
afterEach(() => {
  vi.restoreAllMocks()
})

type Watched = { steps: TurnStepEvent[]; ends: TurnReply[]; accept: boolean }

function watchers(accept = true): Watched & TurnJobIo['watchers'] {
  const w: Watched = { steps: [], ends: [], accept }
  return Object.assign(w, {
    onStep: (event: TurnStepEvent) => void w.steps.push(event),
    onEnd: (reply: TurnReply) => {
      w.ends.push(reply)
      return w.accept
    },
  })
}

// A database that stops answering once cut, as Neon does under an isolate
// that died: every query started after the cut throws.
function cuttable(db: TestDb): { db: Db; cut: () => void } {
  let dead = false
  const proxy = new Proxy(db, {
    get(target, prop) {
      const value: unknown = Reflect.get(target, prop, target)
      if (typeof value !== 'function') return value
      if (dead && ['select', 'insert', 'update', 'delete', 'transaction', 'execute'].includes(String(prop))) {
        return () => {
          throw new Error('connection gone')
        }
      }
      return value.bind(target)
    },
  })
  return { db: proxy as unknown as Db, cut: () => (dead = true) }
}

// Every value the job sets on dj_turns, in order.
function recordingTurnSets(db: TestDb): { db: Db; sets: Array<Record<string, unknown>> } {
  const sets: Array<Record<string, unknown>> = []
  const proxy = new Proxy(db, {
    get(target, prop) {
      const value: unknown = Reflect.get(target, prop, target)
      if (prop === 'update') {
        return (table: unknown) => {
          const builder = target.update(table as typeof djTurns)
          if (table !== djTurns) return builder
          return new Proxy(builder, {
            get(b, bp) {
              if (bp === 'set') {
                return (values: Record<string, unknown>) => {
                  sets.push(values)
                  return b.set(values)
                }
              }
              const v: unknown = Reflect.get(b, bp, b)
              return typeof v === 'function' ? v.bind(b) : v
            },
          })
        }
      }
      return typeof value === 'function' ? value.bind(target) : value
    },
  })
  return { db: proxy as unknown as Db, sets }
}

describe('runTurnJob', () => {
  it('a message turn finishes done with the same body the route answers for the same turn', async () => {
    const base = await createTestDb()
    await seedUser(base)
    await seedLibrary(base, 'u1', 4)
    const sessionId = await mixSession(base)
    const [a, b] = [await forkTestDb(base), await forkTestDb(base)]

    const route = await post(a, { embed, llm: scriptedLlm(generate(3)) }, `/sessions/${sessionId}/messages`, { text: 'a rainy drive' })
    const job = await queueMessageTurn(b, sessionId, 'a rainy drive')
    const w = watchers()
    const result = await runTurnJob(job, { db: b, deps: { embed, llm: scriptedLlm(generate(3)) }, watchers: w })

    expect(route.status).toBe(200)
    expect(result).toMatchObject({ outcome: 'done', status: 200, errorKind: null, title: 'start', watchedResult: true })
    if (result.outcome === 'duplicate') throw new Error('unreachable')
    expect(normalized(JSON.stringify(result.body))).toBe(normalized(await route.text()))
    // The watchers saw every step, then exactly the result.
    expect(w.steps.map((s) => s.step)).toEqual(['digging', 'picking', 'pressing', 'writing'])
    expect(w.ends).toEqual([{ status: 200, body: result.body }])

    const row = await turnRow(b, job.turnId)
    expect(row).toMatchObject({ status: 'done', attempt: 1, errorKind: null, step: 'writing', watchedResult: true })
    expect(row.startedAt).toBeInstanceOf(Date)
    expect(row.heartbeatAt).toBeInstanceOf(Date)
    expect(row.finishedAt).toBeInstanceOf(Date)
    // What a re-run would have undone: the listener's message first.
    expect((row.writes as { messageSeqs: number[] }).messageSeqs[0]).toBe(job.userMessageSeq)
  })

  it('a create turn finishes done with the same body POST /sessions answers', async () => {
    const base = await createTestDb()
    await seedUser(base)
    await seedLibrary(base, 'u1', 4)
    const [a, b] = [await forkTestDb(base), await forkTestDb(base)]
    const titleComplete: LlmComplete = async () => 'Rainy Drive'

    const route = await post(a, { embed, llm: scriptedLlm(generate(3)), titleComplete }, '/sessions', { prompt: 'a rainy drive' })
    const job = await queueCreateTurn(b, 'a rainy drive')
    const result = await runTurnJob(job, { db: b, deps: { embed, llm: scriptedLlm(generate(3)), titleComplete }, watchers: watchers() })

    expect(route.status).toBe(200)
    if (result.outcome === 'duplicate') throw new Error('unexpected duplicate')
    expect(result).toMatchObject({ outcome: 'done', status: 200, title: 'Rainy Drive' })
    expect(normalized(JSON.stringify(result.body))).toBe(normalized(await route.text()))
    expect((await turnRow(b, job.turnId)).status).toBe('done')
  })

  it('a DjError finishes failed with its kind, and the same status and body as the route', async () => {
    const base = await createTestDb()
    await seedUser(base)
    await seedLibrary(base, 'u1', 4)
    const sessionId = await mixSession(base)
    const [a, b] = [await forkTestDb(base), await forkTestDb(base)]
    const failing: LlmClient = async () => {
      throw new LlmError('boom', 500)
    }

    const route = await post(a, { embed, llm: failing }, `/sessions/${sessionId}/messages`, { text: 'more' })
    const job = await queueMessageTurn(b, sessionId, 'more')
    const w = watchers()
    const result = await runTurnJob(job, { db: b, deps: { embed, llm: failing }, watchers: w })

    expect(route.status).toBe(502)
    if (result.outcome === 'duplicate') throw new Error('unexpected duplicate')
    expect(result).toMatchObject({ outcome: 'failed', status: 502, errorKind: 'llm' })
    expect(JSON.stringify(result.body)).toBe(await route.text())
    expect(w.ends).toEqual([{ status: 502, body: result.body }])
    expect(await turnRow(b, job.turnId)).toMatchObject({ status: 'failed', errorKind: 'llm' })
  })

  it('an unforeseen throw is caught: failed internal, a 500 internal to watchers, a fixed log line, never rethrown', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedLibrary(db, 'u1', 4)
    const sessionId = await mixSession(db)
    const job = await queueMessageTurn(db, sessionId, 'listener words: rainy lagos night')
    const logged = vi.spyOn(console, 'error').mockImplementation(() => {})
    // The message turn's closing updatedAt bump throws, outside the turn's
    // own error handling, as a dropped connection would.
    const throwing = new Proxy(db, {
      get(target, prop) {
        const value: unknown = Reflect.get(target, prop, target)
        if (prop === 'update') {
          return (table: typeof djSessions) => {
            const builder = target.update(table)
            if (table !== djSessions) return builder
            return new Proxy(builder, {
              get(b, bp) {
                if (bp === 'set') {
                  return (values: Record<string, unknown>) => {
                    if (Object.keys(values).join() === 'updatedAt' && values.updatedAt instanceof Date) throw new Error('listener words: rainy lagos night')
                    return b.set(values as never)
                  }
                }
                const v: unknown = Reflect.get(b, bp, b)
                return typeof v === 'function' ? v.bind(b) : v
              },
            })
          }
        }
        return typeof value === 'function' ? value.bind(target) : value
      },
    }) as unknown as Db
    const w = watchers()

    const result = await runTurnJob(job, { db: throwing, deps: { embed, llm: scriptedLlm([{ text: 'sure.' }]) }, watchers: w })

    expect(result).toMatchObject({ outcome: 'failed', status: 500, body: { error: 'internal' }, errorKind: 'internal' })
    expect(w.ends).toEqual([{ status: 500, body: { error: 'internal' } }])
    expect(await turnRow(db, job.turnId)).toMatchObject({ status: 'failed', errorKind: 'internal' })
    expect(logged.mock.calls.flat().join(' ')).not.toMatch(/lagos/)
  })

  it('a duplicate run after the finish does nothing', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedLibrary(db, 'u1', 4)
    const sessionId = await mixSession(db)
    const job = await queueMessageTurn(db, sessionId, 'a rainy drive')
    await runTurnJob(job, { db, deps: { embed, llm: scriptedLlm(generate(3)) }, watchers: watchers() })
    const rowBefore = await turnRow(db, job.turnId)
    const messagesBefore = await messages(db, sessionId)
    const queueBefore = await getActiveQueue(db, sessionId)
    let called = false
    const w = watchers()

    const again = await runTurnJob(job, { db, deps: { embed, llm: async () => ((called = true), curateReply({} as LlmRequest)) }, watchers: w })

    expect(again).toEqual({ outcome: 'duplicate' })
    expect(called).toBe(false)
    expect(w.ends).toEqual([])
    expect(await turnRow(db, job.turnId)).toEqual(rowBefore)
    expect(await messages(db, sessionId)).toEqual(messagesBefore)
    expect(await getActiveQueue(db, sessionId)).toEqual(queueBefore)
  })

  it("attempt 2 undoes attempt 1's persisted writes, then runs clean: the listener's message kept, one DJ reply", async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedLibrary(db, 'u1', 8)
    // A mix with songs before the turn, so attempt 1's new version is
    // something to undo.
    const sessionId = await mixSession(db)
    await runTurnJob(await queueMessageTurn(db, sessionId, 'first mix'), { db, deps: { embed, llm: scriptedLlm(generate(3, 'first')) }, watchers: watchers() })
    const songsBefore = (await getActiveQueue(db, sessionId)).map((t) => t.trackId)
    const job = await queueMessageTurn(db, sessionId, 'change it')
    vi.spyOn(console, 'error').mockImplementation(() => {})

    // Attempt 1 writes a new queue, then its isolate dies: the database
    // stops answering before the DJ's reply is written.
    const dying = cuttable(db)
    await runTurnJob(job, { db: dying.db, deps: { embed, llm: scriptedLlm(generate(5, 'other'), (n) => void (n === 1 && dying.cut())) }, watchers: watchers(), stopTiming: FAST })
    const dead = await turnRow(db, job.turnId)
    expect(dead).toMatchObject({ status: 'running', attempt: 1 })
    expect((await getActiveQueue(db, sessionId)).length).toBe(5)
    expect((await db.select().from(djSessions).where(eq(djSessions.id, sessionId)))[0].activeTurnId).not.toBeNull()

    // The platform re-runs the alarm.
    const seen: string[][] = []
    const result = await runTurnJob(job, {
      db,
      deps: { embed, llm: scriptedLlm(generate(3, 'other'), (n) => void (n === 0 && getActiveQueue(db, sessionId).then((q) => seen.push(q.map((t) => t.trackId))))) },
      watchers: watchers(),
      stopTiming: FAST,
    })

    expect(result).toMatchObject({ outcome: 'done', status: 200 })
    // Undone before the re-run's first model call: the songs from before.
    expect(seen[0]).toEqual(songsBefore)
    const transcript = (await messages(db, sessionId)).map((m) => [m.role, m.content])
    expect(transcript.filter(([, content]) => content === 'change it')).toHaveLength(1)
    expect(transcript.slice(-2)).toEqual([['user', 'change it'], ['dj', 'here you go.']])
    expect((await getActiveQueue(db, sessionId)).length).toBe(3)
    expect(await turnRow(db, job.turnId)).toMatchObject({ status: 'done', attempt: 2 })
  })

  it("attempt 2 also undoes a DJ reply attempt 1 wrote but died before recording", async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedLibrary(db, 'u1', 4)
    const sessionId = await mixSession(db)
    const job = await queueMessageTurn(db, sessionId, 'change it')
    // Attempt 1 recorded only the listener's message, then its reply landed
    // and the isolate died before the record that names it.
    await db.insert(djMessages).values({ sessionId, role: 'dj', content: 'orphan reply' })
    await db.update(djTurns).set({
      status: 'running',
      attempt: 1,
      writes: { messageSeqs: [job.userMessageSeq], renamed: false, historyOffered: false, startingVersion: 0, claimTitle: 'start', claimNotPersonal: false, claimTurnId: null },
    }).where(eq(djTurns.id, job.turnId))

    const result = await runTurnJob(job, { db, deps: { embed, llm: scriptedLlm([{ text: 'fresh reply.' }]) }, watchers: watchers(), stopTiming: FAST })

    expect(result).toMatchObject({ outcome: 'done' })
    const transcript = (await messages(db, sessionId)).map((m) => [m.role, m.content])
    expect(transcript).toEqual([['user', 'start'], ['dj', 'ready.'], ['user', 'change it'], ['dj', 'fresh reply.']])
  })

  it('a stop raised while attempt 1 held the claim is honoured: attempt 2 undoes it as a stop, never re-runs', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedLibrary(db, 'u1', 4)
    const sessionId = await mixSession(db)
    const job = await queueMessageTurn(db, sessionId, 'change it')
    const deadClaim = '11111111-2222-4333-8444-555555555555'
    await db.update(djSessions).set({ activeTurnId: deadClaim, activeTurnAt: new Date(), turnStopRequested: true, title: 'Renamed' }).where(eq(djSessions.id, sessionId))
    await db.update(djTurns).set({
      status: 'running',
      attempt: 1,
      writes: { messageSeqs: [job.userMessageSeq], renamed: true, historyOffered: false, startingVersion: 0, claimTitle: 'start', claimNotPersonal: false, claimTurnId: deadClaim },
    }).where(eq(djTurns.id, job.turnId))
    let called = false

    const w = watchers()
    const result = await runTurnJob(job, { db, deps: { embed, llm: async () => ((called = true), curateReply({} as LlmRequest)) }, watchers: w, stopTiming: FAST })

    expect(called).toBe(false)
    expect(result).toMatchObject({ outcome: 'stopped', status: 409, body: { error: 'turn_stopped' }, errorKind: null })
    expect(w.ends).toEqual([{ status: 409, body: { error: 'turn_stopped' } }])
    expect(await turnRow(db, job.turnId)).toMatchObject({ status: 'stopped', attempt: 2 })
    const [row] = await db.select().from(djSessions).where(eq(djSessions.id, sessionId))
    expect(row).toMatchObject({ title: 'start', activeTurnId: null, turnStopRequested: false })
    expect((await messages(db, sessionId)).map((m) => m.content)).toEqual(['start', 'ready.'])
  })

  it('a stop raised while a dead first turn held the claim takes its session, as a live stop does', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedLibrary(db, 'u1', 4)
    const job = await queueCreateTurn(db, 'a rainy drive')
    const deadClaim = '11111111-2222-4333-8444-555555555556'
    await db.update(djSessions).set({ activeTurnId: deadClaim, activeTurnAt: new Date(), turnStopRequested: true }).where(eq(djSessions.id, job.sessionId))
    await db.update(djTurns).set({
      status: 'running',
      attempt: 1,
      writes: { messageSeqs: [job.userMessageSeq], renamed: false, historyOffered: false, startingVersion: 0, claimTitle: 'a rainy drive', claimNotPersonal: false, claimTurnId: deadClaim },
    }).where(eq(djTurns.id, job.turnId))

    const result = await runTurnJob(job, { db, deps: { embed, llm: scriptedLlm(generate(3)) }, watchers: watchers(), stopTiming: FAST })

    expect(result).toMatchObject({ outcome: 'stopped', status: 409 })
    expect((await db.select().from(djSessions).where(eq(djSessions.id, job.sessionId))).length).toBe(0)
    expect(await turnRow(db, job.turnId)).toBeUndefined()
  })

  it('a rollback that fails leaves the writes standing and fails the turn rather than run on top', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedLibrary(db, 'u1', 4)
    const sessionId = await mixSession(db)
    const job = await queueMessageTurn(db, sessionId, 'change it')
    vi.spyOn(console, 'error').mockImplementation(() => {})
    // A dead first attempt whose recorded writes point at a version the
    // restore cannot find.
    await db.update(djTurns).set({
      status: 'running',
      attempt: 1,
      writes: { messageSeqs: [job.userMessageSeq], renamed: false, historyOffered: false, startingVersion: 99, claimTitle: 'start', claimNotPersonal: false, claimTurnId: null },
    }).where(eq(djTurns.id, job.turnId))
    let called = false

    const result = await runTurnJob(job, { db, deps: { embed, llm: async () => ((called = true), curateReply({} as LlmRequest)) }, watchers: watchers() })

    expect(called).toBe(false)
    expect(result).toMatchObject({ outcome: 'failed', status: 500, errorKind: 'internal' })
    expect(await turnRow(db, job.turnId)).toMatchObject({ status: 'failed', attempt: 2, errorKind: 'internal' })
  })

  it(`a turn whose ${MAX_ATTEMPTS} attempts are spent is lost: failed('lost'), nothing run`, async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedLibrary(db, 'u1', 4)
    const sessionId = await mixSession(db)
    const job = await queueMessageTurn(db, sessionId, 'change it')
    await db.update(djTurns).set({ status: 'running', attempt: MAX_ATTEMPTS }).where(eq(djTurns.id, job.turnId))
    let called = false
    const w = watchers()

    const result = await runTurnJob(job, { db, deps: { embed, llm: async () => ((called = true), curateReply({} as LlmRequest)) }, watchers: w })

    expect(called).toBe(false)
    expect(result).toMatchObject({ outcome: 'lost', status: 500, errorKind: 'lost' })
    expect(w.ends).toEqual([{ status: 500, body: { error: 'internal' } }])
    expect(await turnRow(db, job.turnId)).toMatchObject({ status: 'failed', attempt: MAX_ATTEMPTS, errorKind: 'lost' })
    expect((await messages(db, sessionId)).map((m) => m.content)).toContain('change it')
  })

  it('a stopped message turn finishes stopped with the route\'s turn_stopped answer', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedLibrary(db, 'u1', 4)
    const sessionId = await mixSession(db)
    const job = await queueMessageTurn(db, sessionId, 'change it')
    // The model's last round raises the flag, as a stop arriving then would.
    const llm = scriptedLlm(generate(3), async (n) => {
      if (n === 1) await db.update(djSessions).set({ turnStopRequested: true }).where(eq(djSessions.id, sessionId))
    })

    const result = await runTurnJob(job, { db, deps: { embed, llm }, watchers: watchers(), stopTiming: FAST })

    expect(result).toMatchObject({ outcome: 'stopped', status: 409, body: { error: 'turn_stopped' }, errorKind: null })
    expect((await turnRow(db, job.turnId)).status).toBe('stopped')
  })

  it('a stopped first turn takes its session and row with it, and ends quietly as stopped', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedLibrary(db, 'u1', 4)
    const job = await queueCreateTurn(db, 'a rainy drive')
    const llm = scriptedLlm(generate(3), async (n) => {
      if (n === 1) await db.update(djSessions).set({ turnStopRequested: true }).where(eq(djSessions.id, job.sessionId))
    })

    const result = await runTurnJob(job, { db, deps: { embed, llm }, watchers: watchers(), stopTiming: FAST })

    expect(result).toMatchObject({ outcome: 'stopped', status: 409, title: null })
    expect(await turnRow(db, job.turnId)).toBeUndefined()
  })

  it('bumps the heartbeat on each tick while running, and clears it at the end', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedLibrary(db, 'u1', 4)
    const sessionId = await mixSession(db)
    const job = await queueMessageTurn(db, sessionId, 'a rainy drive')
    let clock = new Date('2026-11-22T10:00:00Z')
    const timers: Array<{ run: () => void; ms: number }> = []
    const cleared: unknown[] = []
    const heartbeats: Array<Date | null> = []
    // Mid turn, the clock moves on and the interval fires twice.
    const llm = scriptedLlm(generate(3), async (n) => {
      if (n !== 1) return
      for (const minutes of [1, 2]) {
        clock = new Date(clock.getTime() + 15_000 * minutes)
        timers[0].run()
        await new Promise((r) => setTimeout(r, 20))
        heartbeats.push((await turnRow(db, job.turnId)).heartbeatAt)
      }
    })

    await runTurnJob(job, {
      db,
      deps: { embed, llm },
      watchers: watchers(),
      now: () => clock,
      setInterval: (run, ms) => (timers.push({ run, ms }), 'handle-1'),
      clearInterval: (handle) => void cleared.push(handle),
    })

    expect(timers.map((t) => t.ms)).toEqual([TURN_HEARTBEAT_MS])
    expect(heartbeats.map((d) => d?.toISOString())).toEqual(['2026-11-22T10:00:15.000Z', '2026-11-22T10:00:45.000Z'])
    expect(cleared).toEqual(['handle-1'])
    const row = await turnRow(db, job.turnId)
    expect(row.startedAt?.toISOString()).toBe('2026-11-22T10:00:00.000Z')
    expect(row.finishedAt?.toISOString()).toBe('2026-11-22T10:00:45.000Z')
  })

  it('stamps the step name only, once per change of step, never its names', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedLibrary(db, 'u1', 4)
    const sessionId = await mixSession(db)
    const job = await queueMessageTurn(db, sessionId, 'a rainy drive')
    const recording = recordingTurnSets(db)
    const w = watchers()

    await runTurnJob(job, { db: recording.db, deps: { embed, llm: scriptedLlm(generate(3)) }, watchers: w })

    const stamps = recording.sets.filter((s) => 'step' in s)
    for (const stamp of stamps) {
      expect(Object.keys(stamp).sort()).toEqual(['step', 'stepAt'])
      expect(TURN_STEPS).toContain(stamp.step)
    }
    // The watchers got the full events (a count rides pressing); the row
    // got one name per change.
    expect(w.steps).toContainEqual({ step: 'pressing', count: 3 })
    expect(stamps.map((s) => s.step)).toEqual(['digging', 'picking', 'pressing', 'writing'])
    expect(JSON.stringify(await turnRow(db, job.turnId))).not.toMatch(/"count"/)
  })

  it('a session deleted mid turn ends quietly as gone', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedLibrary(db, 'u1', 4)
    const sessionId = await mixSession(db)
    const job = await queueMessageTurn(db, sessionId, 'a rainy drive')
    vi.spyOn(console, 'error').mockImplementation(() => {})
    const llm = scriptedLlm(generate(3), async (n) => {
      if (n === 1) await db.delete(djSessions).where(eq(djSessions.id, sessionId))
    })

    const result = await runTurnJob(job, { db, deps: { embed, llm }, watchers: watchers(), stopTiming: FAST })

    expect(result).toMatchObject({ outcome: 'gone', title: null })
    expect(await turnRow(db, job.turnId)).toBeUndefined()
  })

  it('reads the listener\'s words from their message row by seq, never from the job', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedLibrary(db, 'u1', 4)
    const sessionId = await mixSession(db)
    const job = await queueMessageTurn(db, sessionId, 'a rainy drive')
    expect(JSON.stringify(job)).not.toMatch(/rainy/)
    const seen: string[] = []
    const llm: LlmClient = async (req) => {
      if (req.tools.length > 0) seen.push(JSON.stringify(req.messages))
      return scriptedLlm([{ text: 'on it.' }])(req)
    }

    const result = await runTurnJob(job, { db, deps: { embed, llm }, watchers: watchers() })

    expect(result).toMatchObject({ outcome: 'done' })
    expect(seen[0]).toMatch(/a rainy drive/)
  })

  it('a job whose message row is missing fails internal, without running', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const sessionId = await mixSession(db)
    const job = await queueMessageTurn(db, sessionId, 'hello')
    vi.spyOn(console, 'error').mockImplementation(() => {})
    let calls = 0
    const llm: LlmClient = async () => {
      calls += 1
      throw new Error('never')
    }

    const result = await runTurnJob({ ...job, userMessageSeq: job.userMessageSeq + 50 }, { db, deps: { embed, llm }, watchers: watchers() })

    expect(result).toMatchObject({ outcome: 'failed', status: 500, errorKind: 'internal' })
    expect(calls).toBe(0)
    expect(await turnRow(db, job.turnId)).toMatchObject({ status: 'failed', errorKind: 'internal' })
  })

  it('watchedResult is false when no watcher took the last event', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedLibrary(db, 'u1', 4)
    const sessionId = await mixSession(db)
    const job = await queueMessageTurn(db, sessionId, 'hello')

    const result = await runTurnJob(job, { db, deps: { embed, llm: scriptedLlm([{ text: 'hi.' }]) }, watchers: watchers(false) })

    expect(result).toMatchObject({ outcome: 'done', watchedResult: false })
    expect((await turnRow(db, job.turnId)).watchedResult).toBe(false)
  })
})
