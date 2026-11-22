import type { TestDb } from './db'
import { createApp, type AuthLike } from '../../src/app'
import type { DjDeps } from '../../src/dj/loop'
import type { TurnJobResult } from '../../src/dj/turn-job'
import { TurnRunnerCore, type TurnRunnerNamespace, type TurnRunnerShell, type TurnRunnerStorage, type TurnRunnerStub } from '../../src/dj/turn-runner'
import type { TurnStopTiming } from '../../src/dj/turn-stop'

// A TURN_RUNNER namespace for route tests: one TurnRunnerCore per session
// name, in process, over the routes' own database (spec 2026-11-21
// durable-mix-turns; founder answer 5, no workers pool). Jobs cross the stub
// as structured clones, as RPC arguments do.
//
// auto: an alarm set for "now" runs on the next macrotask, as the platform
// runs it soon after start; later ones (the cleanup alarm) are recorded
// only. manual: every alarm is recorded, and the test runs it with
// runAlarm, so a turn can be held queued.

function fakeStorage(): TurnRunnerStorage & { map: Map<string, unknown> } {
  const map = new Map<string, unknown>()
  return {
    map,
    get: async <T>(key: string) => (map.has(key) ? (structuredClone(map.get(key)) as T) : undefined),
    put: async <T>(key: string, value: T) => void map.set(key, structuredClone(value)),
    delete: async (key: string) => map.delete(key),
  }
}

export type FakeRunner = { core: TurnRunnerCore; storage: ReturnType<typeof fakeStorage>; alarms: number[]; starts: number }

export type FakeRunners = {
  namespace: TurnRunnerNamespace
  runners: Map<string, FakeRunner>
  // Runs the object's alarm for this session, as the platform would.
  runAlarm(sessionId: string): Promise<TurnJobResult | undefined>
  // Every alarm the auto mode started, settled.
  settled(): Promise<void>
}

export type FakeRunnersOptions = {
  mode?: 'auto' | 'manual'
  stopTiming?: TurnStopTiming
  endTimeoutMs?: number
  shell?: Partial<TurnRunnerShell>
}

export function fakeTurnRunners(db: TestDb, deps: DjDeps, options: FakeRunnersOptions = {}): FakeRunners {
  const runners = new Map<string, FakeRunner>()
  const running: Promise<unknown>[] = []
  const mode = options.mode ?? 'auto'

  const runnerFor = (name: string): FakeRunner => {
    const existing = runners.get(name)
    if (existing) return existing
    const storage = fakeStorage()
    const fake: FakeRunner = { core: undefined as unknown as TurnRunnerCore, storage, alarms: [], starts: 0 }
    fake.core = new TurnRunnerCore({
      storage,
      setAlarm: async (at) => {
        fake.alarms.push(at)
        if (mode === 'auto' && at <= Date.now() + 1_000) {
          running.push(new Promise((resolve) => setTimeout(() => resolve(fake.core.alarm()), 0)))
        }
      },
      openDb: () => ({ db, pool: { end: async () => {} } }),
      buildDeps: () => deps,
      ...(options.stopTiming ? { stopTiming: options.stopTiming } : {}),
      ...(options.endTimeoutMs !== undefined ? { endTimeoutMs: options.endTimeoutMs } : {}),
      ...options.shell,
    })
    runners.set(name, fake)
    return fake
  }

  const namespace: TurnRunnerNamespace = {
    idFromName: (name) => name,
    get: (id): TurnRunnerStub => {
      const fake = runnerFor(id as string)
      return {
        start: async (job) => {
          fake.starts += 1
          return fake.core.start(structuredClone(job))
        },
        fetch: async (input) => fake.core.fetch(typeof input === 'string' ? new Request(input) : input),
      }
    },
  }

  return {
    namespace,
    runners,
    runAlarm: (sessionId) => runnerFor(sessionId).core.alarm(),
    settled: async () => {
      while (running.length > 0) await Promise.allSettled(running.splice(0))
    },
  }
}

export function authedAs(id: string, isAnonymous = false): AuthLike {
  return { handler: () => new Response('ok'), api: { getSession: async () => ({ user: { id, isAnonymous } }) } }
}

export type DurableAppOptions = { userId?: string; anonymous?: boolean; aiConsent?: 'off' | 'enforce'; allowedOrigins?: string[] }

// The app as production wires it with DURABLE_TURNS on, over the fakes.
export function durableApp(db: TestDb, deps: DjDeps, runners: FakeRunners, opts: DurableAppOptions = {}) {
  return createApp({
    auth: authedAs(opts.userId ?? 'u1', opts.anonymous ?? false),
    db,
    dj: { deps },
    durableTurns: { runner: runners.namespace },
    ...(opts.aiConsent ? { aiConsent: opts.aiConsent } : {}),
    ...(opts.allowedOrigins ? { allowedOrigins: opts.allowedOrigins } : {}),
  })
}
