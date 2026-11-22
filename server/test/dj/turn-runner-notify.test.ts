import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { eq } from 'drizzle-orm'
import { createTestDb, type TestDb } from '../helpers/db'
import { embed, mixSession, queueMessageTurn, scriptedLlm, seedLibrary, seedUser, turnRow } from '../helpers/turn-job'
import { FINAL_REPLAY_MS, TurnRunnerCore, type TurnRunnerShell, type TurnRunnerStorage } from '../../src/dj/turn-runner'
import type { DjDeps } from '../../src/dj/loop'
import { djTurns, pushDevices } from '../../src/db/schema'
import { sweepLostTurns } from '../../src/dj/turn-sweep'
import { notifyTurn, NOTIFY_RECHECK_MS, type PushConfig } from '../../src/push/notify'
import type { Db } from '../../src/db/types'

// The TurnRunner object's half of notify (spec 2026-11-21 durable-mix-turns,
// "Who notifies"): it calls notify once the job is over, keeps an 8 s recheck
// for a watched result by turn id only, and shares its one alarm between the
// recheck and the last event's cleanup. And the cron's half: a lost turn.

beforeEach(() => {
  vi.spyOn(console, 'log').mockImplementation(() => {})
})
afterEach(() => {
  vi.restoreAllMocks()
})

function fakeStorage(): TurnRunnerStorage & { map: Map<string, unknown> } {
  const map = new Map<string, unknown>()
  return {
    map,
    get: async <T>(key: string) => (map.has(key) ? (structuredClone(map.get(key)) as T) : undefined),
    put: async <T>(key: string, value: T) => void map.set(key, structuredClone(value)),
    delete: async (key: string) => map.delete(key),
  }
}

type Notify = NonNullable<TurnRunnerShell['notify']>

function fakeRunner(db: TestDb, deps: DjDeps, notify: Notify) {
  const storage = fakeStorage()
  const fake = { core: undefined as unknown as TurnRunnerCore, storage, alarms: [] as number[], clock: { now: 1_000_000 } }
  fake.core = new TurnRunnerCore({
    storage,
    setAlarm: async (at) => void fake.alarms.push(at),
    openDb: () => ({ db, pool: { end: async () => {} } }),
    buildDeps: () => deps,
    now: () => fake.clock.now,
    notify,
  })
  return fake
}

const watch = (core: TurnRunnerCore, turnId: string) => core.fetch(new Request(`http://turn/watch?turn=${turnId}`))
const dj = (): DjDeps => ({ embed, llm: scriptedLlm([{ text: 'ok.' }]) })

async function listener() {
  const db = await createTestDb()
  await seedUser(db)
  await seedLibrary(db, 'u1', 4)
  return { db, sessionId: await mixSession(db) }
}

describe('TurnRunnerCore: notify', () => {
  it('notifies a finished turn once, after the job is let go', async () => {
    const { db, sessionId } = await listener()
    const job = await queueMessageTurn(db, sessionId, 'one')
    const calls: Array<{ turnId: string; recheck: boolean; jobHeld: boolean }> = []
    const runner = fakeRunner(db, dj(), async (_db, turnId, { recheck }) => {
      calls.push({ turnId, recheck, jobHeld: runner.storage.map.has('job') })
    })
    await runner.core.start(job)
    expect(await runner.core.alarm()).toMatchObject({ outcome: 'done' })
    expect(calls).toEqual([{ turnId: job.turnId, recheck: false, jobHeld: false }])
    // Nothing deferred: the one alarm is the cleanup's.
    expect(runner.alarms).toEqual([1_000_000, 1_000_000 + FINAL_REPLAY_MS])
  })

  it('a duplicate alarm notifies nothing (whoever finished the turn did)', async () => {
    const { db, sessionId } = await listener()
    const job = await queueMessageTurn(db, sessionId, 'one')
    const notify = vi.fn<Notify>(async () => {})
    const runner = fakeRunner(db, dj(), notify)
    await runner.core.start(job)
    await runner.core.alarm()
    await runner.storage.put('job', job)
    expect(await runner.core.alarm()).toEqual({ outcome: 'duplicate' })
    expect(notify).toHaveBeenCalledTimes(1)
  })

  it('a notify that throws does not fail the alarm', async () => {
    const { db, sessionId } = await listener()
    vi.spyOn(console, 'error').mockImplementation(() => {})
    const job = await queueMessageTurn(db, sessionId, 'one')
    const runner = fakeRunner(db, dj(), async () => {
      throw new Error('apns down')
    })
    await runner.core.start(job)
    expect(await runner.core.alarm()).toMatchObject({ outcome: 'done' })
    expect(runner.storage.map.has('job')).toBe(false)
    expect(runner.alarms.at(-1)).toBe(1_000_000 + FINAL_REPLAY_MS)
  })

  it('a deferred notify sets the recheck as the next alarm, ahead of the cleanup, and runs it once', async () => {
    const { db, sessionId } = await listener()
    const job = await queueMessageTurn(db, sessionId, 'one')
    const calls: Array<{ turnId: string; recheck: boolean }> = []
    const runner = fakeRunner(db, dj(), async (_db, turnId, { recheck, scheduleRecheck }) => {
      calls.push({ turnId, recheck })
      if (!recheck) scheduleRecheck(NOTIFY_RECHECK_MS)
    })
    await runner.core.start(job)
    await runner.core.alarm()
    const endedAt = runner.clock.now

    // By turn id only: nothing the listener said.
    expect(runner.storage.map.get('rechecks')).toEqual([{ turnId: job.turnId, at: endedAt + NOTIFY_RECHECK_MS }])
    expect(runner.alarms.at(-1)).toBe(endedAt + NOTIFY_RECHECK_MS)

    // Woken early by the platform: nothing is due, and the alarm stays.
    runner.clock.now = endedAt + 1_000
    await runner.core.alarm()
    expect(calls).toHaveLength(1)
    expect(runner.alarms.at(-1)).toBe(endedAt + NOTIFY_RECHECK_MS)

    // The recheck: notify again with recheck, then the alarm is the cleanup.
    runner.clock.now = endedAt + NOTIFY_RECHECK_MS
    await runner.core.alarm()
    expect(calls).toEqual([
      { turnId: job.turnId, recheck: false },
      { turnId: job.turnId, recheck: true },
    ])
    expect(runner.storage.map.get('rechecks')).toEqual([])
    expect((runner.storage.map.get('final') as { reply?: unknown }).reply).toBeDefined()
    expect(runner.alarms.at(-1)).toBe(endedAt + FINAL_REPLAY_MS)

    // The cleanup still runs on its own time, and nothing is left to wake for.
    const before = runner.alarms.length
    runner.clock.now = endedAt + FINAL_REPLAY_MS
    await runner.core.alarm()
    expect(runner.storage.map.get('final')).toEqual({ turnId: job.turnId, at: endedAt })
    expect(runner.alarms).toHaveLength(before)
    expect(calls).toHaveLength(2)
  })

  it('a recheck pending when the next turn starts runs after that turn, and is not lost', async () => {
    const { db, sessionId } = await listener()
    const first = await queueMessageTurn(db, sessionId, 'one')
    const calls: Array<{ turnId: string; recheck: boolean }> = []
    const runner = fakeRunner(db, dj(), async (_db, turnId, { recheck, scheduleRecheck }) => {
      calls.push({ turnId, recheck })
      if (!recheck && turnId === first.turnId) scheduleRecheck(NOTIFY_RECHECK_MS)
    })
    await runner.core.start(first)
    await runner.core.alarm()
    const endedAt = runner.clock.now

    // The next message, 9 s later: its start sets the alarm for now.
    runner.clock.now = endedAt + 9_000
    const second = await queueMessageTurn(db, sessionId, 'two')
    await runner.core.start(second)
    expect(runner.alarms.at(-1)).toBe(runner.clock.now)
    await runner.core.alarm()

    expect(calls).toEqual([
      { turnId: first.turnId, recheck: false },
      { turnId: second.turnId, recheck: false },
      { turnId: first.turnId, recheck: true },
    ])
    expect(runner.storage.map.get('rechecks')).toEqual([])
    expect(runner.alarms.at(-1)).toBe(runner.clock.now + FINAL_REPLAY_MS)
  })

  it('end to end: a watched result, not seen, pushes on the 8 s recheck; a seen one does not', async () => {
    const { db, sessionId } = await listener()
    await db.insert(pushDevices).values({ userId: 'u1', provider: 'apns', platform: 'ios', token: 'ab'.repeat(32), environment: 'sandbox' })
    const sent: string[] = []
    const fetch = async (url: string) => {
      sent.push(url)
      return new Response(null, { status: 200 })
    }
    const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign'])
    const pkcs8 = Buffer.from(await crypto.subtle.exportKey('pkcs8', pair.privateKey)).toString('base64')
    const config: PushConfig = {
      enabled: true,
      apns: { teamId: 'TEAM', keyId: 'KEY', privateKey: `-----BEGIN PRIVATE KEY-----\n${pkcs8}\n-----END PRIVATE KEY-----`, topic: 'com.example' },
    }
    const notify: Notify = (turnDb: Db, turnId, opts) => notifyTurn({ db: turnDb, config, fetch, scheduleRecheck: opts.scheduleRecheck }, turnId, { recheck: opts.recheck }).then(() => {})

    for (const seen of [false, true]) {
      const job = await queueMessageTurn(db, sessionId, seen ? 'seen one' : 'unseen one')
      const runner = fakeRunner(db, dj(), notify)
      await runner.core.start(job)
      const text = (await watch(runner.core, job.turnId)).text()
      await runner.core.alarm()
      await text
      expect((await turnRow(db, job.turnId)).watchedResult).toBe(true)
      expect(sent).toHaveLength(seen ? 1 : 0)

      if (seen) await db.update(djTurns).set({ seenAt: new Date() }).where(eq(djTurns.id, job.turnId))
      runner.clock.now += NOTIFY_RECHECK_MS
      await runner.core.alarm()
      expect(sent).toHaveLength(1)
      expect((await turnRow(db, job.turnId)).notifyOutcome).toBe(seen ? 'seen' : 'sent')
    }
  })
})

describe('the lost-turn sweep notifies', () => {
  it('pushes a lost turn at once with the failed copy', async () => {
    const { db, sessionId } = await listener()
    await db.insert(pushDevices).values({ userId: 'u1', provider: 'apns', platform: 'ios', token: 'ab'.repeat(32), environment: 'production' })
    const job = await queueMessageTurn(db, sessionId, 'never ran')
    await db.update(djTurns).set({ createdAt: new Date(Date.now() - 91_000) }).where(eq(djTurns.id, job.turnId))
    const bodies: string[] = []
    const fetch = async (_url: string, init: RequestInit) => {
      bodies.push(String(init.body))
      return new Response(null, { status: 200 })
    }
    const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign'])
    const pkcs8 = Buffer.from(await crypto.subtle.exportKey('pkcs8', pair.privateKey)).toString('base64')
    const config: PushConfig = {
      enabled: true,
      apns: { teamId: 'TEAM', keyId: 'KEY', privateKey: `-----BEGIN PRIVATE KEY-----\n${pkcs8}\n-----END PRIVATE KEY-----`, topic: 'com.example' },
    }

    expect(await sweepLostTurns(db, { notify: async (turnDb, turn) => void (await notifyTurn({ db: turnDb, config, fetch }, turn.turnId)) })).toBe(1)
    expect(bodies).toHaveLength(1)
    expect(JSON.parse(bodies[0]!)).toMatchObject({ kind: 'failed', turnId: job.turnId, aps: { alert: { title: expect.stringMatching(/^Oops/) } } })
    expect(await turnRow(db, job.turnId)).toMatchObject({ status: 'failed', errorKind: 'lost', notifyOutcome: 'sent' })
  })
})
