import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { Hono } from 'hono'
import { createTestDb, type TestDb } from '../helpers/db'
import { embed, generate, mixSession, queueCreateTurn, queueMessageTurn, scriptedLlm, seedLibrary, seedUser, turnRow } from '../helpers/turn-job'
import { eventsOnly, parseSse, readEvents } from '../helpers/sse'
import { FINAL_REPLAY_MS, TurnRunnerCore, type TurnRunnerShell, type TurnRunnerStorage } from '../../src/dj/turn-runner'
import type { DjDeps } from '../../src/dj/loop'
import type { TurnStepEvent } from '../../src/dj/turn-steps'
import { streamTurn, TurnStreamWriter } from '../../src/routes/turn-stream'
import { buildDurableTurns, durableTurnsEnabled } from '../../src/index'

// The Durable Object's own surface (spec 2026-11-21 durable-mix-turns, "Run
// (object side)"), through TurnRunnerCore over a fake storage and alarm: no
// workers pool (founder answer 5). The turn itself is runTurnJob's, covered
// in turn-job.test.ts.

beforeEach(() => {
  vi.spyOn(console, 'log').mockImplementation(() => {})
})
afterEach(() => {
  vi.useRealTimers()
  vi.restoreAllMocks()
})

// A Map with the object storage's async face. Values are cloned, as the
// platform's storage keeps a copy rather than the caller's object.
function fakeStorage(): TurnRunnerStorage & { map: Map<string, unknown> } {
  const map = new Map<string, unknown>()
  return {
    map,
    get: async <T>(key: string) => (map.has(key) ? structuredClone(map.get(key)) as T : undefined),
    put: async <T>(key: string, value: T) => void map.set(key, structuredClone(value)),
    delete: async (key: string) => map.delete(key),
  }
}

type Fake = {
  core: TurnRunnerCore
  storage: ReturnType<typeof fakeStorage>
  alarms: number[]
  poolEnds: number
  clock: { now: number }
}

function fakeRunner(db: TestDb, deps: DjDeps | undefined, overrides: Partial<TurnRunnerShell> = {}): Fake {
  const storage = fakeStorage()
  const fake: Fake = { core: undefined as unknown as TurnRunnerCore, storage, alarms: [], poolEnds: 0, clock: { now: 1_000_000 } }
  fake.core = new TurnRunnerCore({
    storage,
    setAlarm: async (at) => void fake.alarms.push(at),
    openDb: () => ({ db, pool: { end: async () => void (fake.poolEnds += 1) } }),
    buildDeps: () => deps,
    now: () => fake.clock.now,
    ...overrides,
  })
  return fake
}

const watch = (core: TurnRunnerCore, turnId: string, extra = '') => core.fetch(new Request(`http://turn/watch?turn=${turnId}${extra}`))

async function listenerWithMix(): Promise<{ db: TestDb; sessionId: string }> {
  const db = await createTestDb()
  await seedUser(db)
  await seedLibrary(db, 'u1', 4)
  return { db, sessionId: await mixSession(db) }
}

function deferred<T = void>() {
  let resolve!: (value: T) => void
  const promise = new Promise<T>((r) => (resolve = r))
  return { promise, resolve }
}

describe('TurnRunnerCore', () => {
  it('start, then the alarm runs the turn: two watchers each get turn, the steps, then the result', async () => {
    const { db, sessionId } = await listenerWithMix()
    const job = await queueMessageTurn(db, sessionId, 'a rainy drive')
    const runner = fakeRunner(db, { embed, llm: scriptedLlm(generate(3)) })

    expect(await runner.core.start({ ...job, push: true })).toBe('started')
    expect(runner.alarms).toEqual([runner.clock.now])
    const [one, two] = [await watch(runner.core, job.turnId), await watch(runner.core, job.turnId)]
    expect(one.headers.get('content-type')).toBe('text/event-stream; charset=utf-8')
    const texts = Promise.all([one.text(), two.text()])
    const result = await runner.core.alarm()

    expect(result).toMatchObject({ outcome: 'done', status: 200, watchedResult: true })
    const [a, b] = await texts
    expect(a).toBe(b)
    const events = eventsOnly(parseSse(a))
    expect(events.map((e) => e.event)).toEqual(['turn', 'step', 'step', 'step', 'step', 'result'])
    expect(events[0].raw).toBe(JSON.stringify({ turnId: job.turnId, push: true }))
    expect(events[events.length - 1].raw).toBe(JSON.stringify(result && 'body' in result ? result.body : null))
    // The job is forgotten, the pool ended, and a cleanup alarm set.
    expect(runner.storage.map.has('job')).toBe(false)
    expect(runner.poolEnds).toBe(1)
    expect(runner.alarms).toEqual([1_000_000, 1_000_000 + FINAL_REPLAY_MS])
    expect((await turnRow(db, job.turnId)).status).toBe('done')
  })

  it('a create turn streams turn first (the Worker sends session), and the object holds no words', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedLibrary(db, 'u1', 4)
    const job = await queueCreateTurn(db, 'a rainy drive')
    const runner = fakeRunner(db, { embed, llm: scriptedLlm(generate(3)) })

    await runner.core.start(job)
    // Ids and switches only: the prompt is read from its message row.
    expect(JSON.stringify(runner.storage.map.get('job'))).not.toMatch(/rainy/)
    const res = await watch(runner.core, job.turnId)
    const text = res.text()
    const result = await runner.core.alarm()

    const events = eventsOnly(parseSse(await text))
    expect(events[0]).toMatchObject({ event: 'turn', data: { turnId: job.turnId, push: false } })
    expect(events.some((e) => e.event === 'session')).toBe(false)
    expect(events[events.length - 1].event).toBe('result')
    expect(result).toMatchObject({ outcome: 'done', status: 200 })
    // The fallback title came from the stored prompt.
    expect((result as { body: { messages: Array<{ content: string }> } }).body.messages[0].content).toBe('a rainy drive')
  })

  it('answers busy while another turn is held, and started again for the same turn', async () => {
    const { db, sessionId } = await listenerWithMix()
    const first = await queueMessageTurn(db, sessionId, 'one')
    const second = await queueMessageTurn(db, sessionId, 'two')
    const runner = fakeRunner(db, { embed, llm: scriptedLlm([{ text: 'ok.' }]) })

    expect(await runner.core.start(first)).toBe('started')
    expect(await runner.core.start(second)).toBe('busy')
    expect(await runner.core.start(first)).toBe('started')
    // Every start that finds the job held and not running sets its alarm
    // for now again, so a held job can never sit with no alarm.
    expect(runner.alarms).toEqual([runner.clock.now, runner.clock.now, runner.clock.now])

    await runner.core.alarm()
    expect(await runner.core.start(second)).toBe('started')
  })

  it('a held job whose alarm was lost is run again by the next start, so the session is not busy for ever', async () => {
    const { db, sessionId } = await listenerWithMix()
    const first = await queueMessageTurn(db, sessionId, 'one')
    const second = await queueMessageTurn(db, sessionId, 'two')
    // The first start's setAlarm failed after the job was put.
    let failAlarm = true
    const runner = fakeRunner(db, { embed, llm: scriptedLlm([{ text: 'ok.' }]) }, {
      setAlarm: async (at) => {
        if (failAlarm) throw new Error('alarm write failed')
        runner.alarms.push(at)
      },
    })
    await expect(runner.core.start(first)).rejects.toThrow()
    failAlarm = false
    expect(runner.alarms).toEqual([])

    expect(await runner.core.start(second)).toBe('busy')
    expect(runner.alarms).toEqual([runner.clock.now])
    expect(await runner.core.alarm()).toMatchObject({ outcome: 'done' })
    expect(await runner.core.start(second)).toBe('started')
  })

  it('a cleanup alarm that wakes early sets itself again rather than keep the body for good', async () => {
    const { db, sessionId } = await listenerWithMix()
    const job = await queueMessageTurn(db, sessionId, 'one')
    const runner = fakeRunner(db, { embed, llm: scriptedLlm([{ text: 'ok.' }]) })
    await runner.core.start(job)
    await runner.core.alarm()
    const endedAt = runner.clock.now
    runner.alarms.length = 0

    runner.clock.now += FINAL_REPLAY_MS - 1
    await runner.core.alarm()
    expect((runner.storage.map.get('final') as { reply?: unknown }).reply).toBeDefined()
    expect(runner.alarms).toEqual([endedAt + FINAL_REPLAY_MS])

    runner.clock.now = endedAt + FINAL_REPLAY_MS
    await runner.core.alarm()
    expect(runner.storage.map.get('final')).toEqual({ turnId: job.turnId, at: endedAt })
  })

  it('a watcher that drops mid turn is let go, and the turn runs on for the other', async () => {
    const { db, sessionId } = await listenerWithMix()
    const job = await queueMessageTurn(db, sessionId, 'a rainy drive')
    const gate = deferred()
    const dropped = deferred()
    const runner = fakeRunner(db, {
      embed,
      llm: scriptedLlm(generate(3), async (n) => {
        if (n === 1) {
          gate.resolve()
          await dropped.promise
        }
      }),
    })
    await runner.core.start(job)
    const leaving = (await watch(runner.core, job.turnId)).body!.getReader()
    const staying = (await watch(runner.core, job.turnId)).text()

    const alarm = runner.core.alarm()
    await readEvents(leaving, 1)
    await gate.promise
    await leaving.cancel()
    dropped.resolve()
    const result = await alarm

    expect(result).toMatchObject({ outcome: 'done', watchedResult: true })
    expect(eventsOnly(parseSse(await staying)).at(-1)?.event).toBe('result')
    expect((await turnRow(db, job.turnId)).status).toBe('done')
  })

  it('when every watcher has gone, the turn still finishes, and watchedResult is false', async () => {
    const { db, sessionId } = await listenerWithMix()
    const job = await queueMessageTurn(db, sessionId, 'hello')
    const runner = fakeRunner(db, { embed, llm: scriptedLlm([{ text: 'hi.' }]) }, { endTimeoutMs: 50 })
    await runner.core.start(job)
    const reader = (await watch(runner.core, job.turnId)).body!.getReader()
    await readEvents(reader, 1)
    await reader.cancel()

    const result = await runner.core.alarm()

    expect(result).toMatchObject({ outcome: 'done', watchedResult: false })
  })

  it('a watch that attaches mid turn gets the latest step first, then the rest live', async () => {
    const { db, sessionId } = await listenerWithMix()
    const job = await queueMessageTurn(db, sessionId, 'a rainy drive')
    let late: Promise<Response> | undefined
    const runner = fakeRunner(db, {
      embed,
      // Attaches as the turn's second model call starts: some steps are past.
      llm: scriptedLlm(generate(3), (n) => void (n === 1 && (late = watch(runner.core, job.turnId)))),
    })
    await runner.core.start(job)
    const early = (await watch(runner.core, job.turnId)).text()
    const alarm = runner.core.alarm()
    await vi.waitFor(() => expect(late).toBeDefined())
    const lateText = (await late!).text()
    await alarm

    const all = eventsOnly(parseSse(await early)).filter((e) => e.event === 'step').map((e) => e.data as TurnStepEvent)
    const lateEvents = eventsOnly(parseSse(await lateText))
    expect(lateEvents[0].event).toBe('turn')
    expect(lateEvents.at(-1)?.event).toBe('result')
    const lateSteps = lateEvents.filter((e) => e.event === 'step').map((e) => e.data as TurnStepEvent)
    // A suffix of the whole turn's steps, starting from one already past.
    expect(lateSteps.length).toBeGreaterThan(0)
    expect(lateSteps.length).toBeLessThan(all.length)
    expect(all.slice(all.length - lateSteps.length)).toEqual(lateSteps)
  })

  it('after the end a watch answers 204, replays the last event on request for a while, and 404 for a turn it never held', async () => {
    const { db, sessionId } = await listenerWithMix()
    const job = await queueMessageTurn(db, sessionId, 'hello')
    const runner = fakeRunner(db, { embed, llm: scriptedLlm([{ text: 'hi.' }]) })
    await runner.core.start(job)
    const result = await runner.core.alarm()

    expect((await watch(runner.core, job.turnId)).status).toBe(204)
    expect((await watch(runner.core, '00000000-0000-4000-8000-000000000000')).status).toBe(404)
    const replay = await watch(runner.core, job.turnId, '&replay=1')
    expect(eventsOnly(parseSse(await replay.text())).map((e) => [e.event, e.raw])).toEqual([
      ['turn', JSON.stringify({ turnId: job.turnId, push: false })],
      ['result', JSON.stringify(result && 'body' in result ? result.body : null)],
    ])

    // The cleanup alarm drops the body once its time is up; the end stays.
    runner.clock.now += FINAL_REPLAY_MS
    expect(await runner.core.alarm()).toBeUndefined()
    expect(JSON.stringify(runner.storage.map.get('final'))).not.toMatch(/hi\./)
    expect((await watch(runner.core, job.turnId, '&replay=1')).status).toBe(204)
    expect((await watch(runner.core, job.turnId)).status).toBe(204)
  })

  it('a duplicate alarm for a finished turn sends its watchers nothing and closes them', async () => {
    const { db, sessionId } = await listenerWithMix()
    const job = await queueMessageTurn(db, sessionId, 'hello')
    const runner = fakeRunner(db, { embed, llm: scriptedLlm([{ text: 'hi.' }]) })
    await runner.core.start(job)
    await runner.core.alarm()
    // The platform delivers the alarm again with the job still held.
    await runner.storage.put('job', job)
    const res = await watch(runner.core, job.turnId)
    const text = res.text()

    expect(await runner.core.alarm()).toEqual({ outcome: 'duplicate' })
    expect(eventsOnly(parseSse(await text)).map((e) => e.event)).toEqual(['turn'])
    expect(runner.storage.map.has('job')).toBe(false)
  })

  it('never throws: no database, or no DJ to run with, is a failed turn with a 500 to watchers', async () => {
    const { db, sessionId } = await listenerWithMix()
    vi.spyOn(console, 'error').mockImplementation(() => {})
    const job = await queueMessageTurn(db, sessionId, 'hello')
    const noDj = fakeRunner(db, undefined)
    await noDj.core.start(job)
    const text = (await watch(noDj.core, job.turnId)).text()

    expect(await noDj.core.alarm()).toMatchObject({ outcome: 'failed', status: 500, errorKind: 'internal' })
    expect(eventsOnly(parseSse(await text)).at(-1)?.data).toEqual({ status: 500, body: { error: 'internal' } })
    expect(await turnRow(db, job.turnId)).toMatchObject({ status: 'failed', errorKind: 'internal' })
    expect(noDj.storage.map.has('job')).toBe(false)

    const other = await queueMessageTurn(db, sessionId, 'again')
    const noDb = fakeRunner(db, undefined, { openDb: () => { throw new Error('DATABASE_URL is required') } })
    await noDb.core.start(other)
    await expect(noDb.core.alarm()).resolves.toMatchObject({ outcome: 'failed', status: 500 })
    expect(noDb.storage.map.has('job')).toBe(false)
  })
})

describe('TurnStreamWriter', () => {
  it('frames the same bytes streamTurn sends for the same turn', async () => {
    const steps: TurnStepEvent[] = [{ step: 'digging', scope: 'library', artists: ['Tems'] }, { step: 'pressing', count: 3 }]
    const body = { djMessage: { content: 'here.' }, queue: [] }
    const app = new Hono()
    app.post('/turn', (c) =>
      streamTurn(c, async (onStep) => {
        for (const step of steps) onStep(step)
        return { status: 200, body }
      }, { session: { id: 's1' } }),
    )
    const fromRoute = await (await app.request('http://x/turn', { method: 'POST' })).text()

    const writer = new TurnStreamWriter()
    const fromWriter = new Response(writer.readable).text()
    writer.session({ id: 's1' })
    for (const step of steps) writer.step(step)
    void writer.end({ status: 200, body })

    expect(await fromWriter).toBe(fromRoute)
  })

  it('frames the turn event and an error reply as the wire contract says', async () => {
    const writer = new TurnStreamWriter()
    const text = new Response(writer.readable).text()
    writer.turn({ turnId: 't1', push: true })
    void writer.end({ status: 409, body: { error: 'conflict' } })

    expect(await text).toBe('event: turn\ndata: {"turnId":"t1","push":true}\n\nevent: error\ndata: {"status":409,"body":{"error":"conflict"}}\n\n')
  })

  it('sends a keepalive after a quiet interval, and none after the end', async () => {
    vi.useFakeTimers()
    const writer = new TurnStreamWriter({ keepaliveMs: 1_000 })
    const reader = writer.readable.getReader()
    writer.turn({ turnId: 't1', push: false })
    await vi.advanceTimersByTimeAsync(1_000)
    expect((await readEvents(reader, 2)).map((e) => ('comment' in e ? e.comment : e.event))).toEqual(['turn', 'keepalive'])
    void writer.end({ status: 200, body: {} })
    await vi.advanceTimersByTimeAsync(5_000)
    const rest = await readEvents(reader, 1)
    expect(rest.map((e) => ('comment' in e ? e.comment : e.event))).toEqual(['result'])
    expect((await reader.read()).done).toBe(true)
  })
})

describe('DURABLE_TURNS wiring', () => {
  const namespace = { idFromName: () => 'id', get: () => ({ start: async () => 'started' as const, fetch: async () => new Response() }) }

  it('is on only for the exact string "on"', () => {
    expect(durableTurnsEnabled({ DURABLE_TURNS: 'on' })).toBe(true)
    expect(durableTurnsEnabled({ DURABLE_TURNS: 'ON' })).toBe(false)
    expect(durableTurnsEnabled({ DURABLE_TURNS: 'off' })).toBe(false)
    expect(durableTurnsEnabled({})).toBe(false)
  })

  it('wires nothing when off, the runner when on, and refuses on without the binding', () => {
    expect(buildDurableTurns({ DURABLE_TURNS: 'off' })).toBeUndefined()
    expect(buildDurableTurns({ TURN_RUNNER: namespace })).toBeUndefined()
    expect(buildDurableTurns({ DURABLE_TURNS: 'on', TURN_RUNNER: namespace })).toEqual({ runner: namespace })
    expect(() => buildDurableTurns({ DURABLE_TURNS: 'on' })).toThrow('TURN_RUNNER durable object binding is required when DURABLE_TURNS is on')
  })
})
