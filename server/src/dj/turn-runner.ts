import type { Db } from '../db/types'
import type { DjDeps } from './loop'
import type { TurnStepEvent } from './turn-steps'
import type { TurnStopTiming } from './turn-stop'
import { abandonTurn, runTurnJob, type TurnJob, type TurnJobResult } from './turn-job'
import { INTERNAL_TURN_REPLY, TurnStreamWriter, turnStreamResponse, type TurnReply } from '../routes/turn-stream'

// The Durable Object that runs a mix turn off the request (spec 2026-11-21
// durable-mix-turns, "Run (object side)"), one per session. The class the
// platform instantiates (TurnRunner in src/index.ts) is a few-line adapter
// over TurnRunnerCore, which takes its storage, alarm and wiring as plain
// values so Node tests drive it with fakes (founder answer 5: no second
// test runner). What a turn does to the database is runTurnJob's
// (dj/turn-job.ts); this holds the job until it ends and fans its steps and
// last event out to the streams watching it.

// The slice of the object's storage this uses.
export type TurnRunnerStorage = {
  get<T = unknown>(key: string): Promise<T | undefined>
  put<T>(key: string, value: T): Promise<void>
  delete(key: string): Promise<boolean>
}

export type TurnRunnerShell = {
  storage: TurnRunnerStorage
  setAlarm(scheduledTime: number): Promise<void>
  // A Neon pool per alarm invocation, ended in a finally (spec, "Cloudflare
  // facts": a pool lives within one handler). Production passes buildDb.
  openDb(): { db: Db; pool: { end(): Promise<void> } }
  // buildTurnDeps in production; undefined when the DJ is not configured.
  buildDeps(db: Db): DjDeps | undefined
  now?: () => number
  // For tests: the stream keepalive, and how long a watcher may take to
  // read the last event before it counts as not seen.
  keepaliveMs?: number
  endTimeoutMs?: number
  // For tests: how fast the turn's stop guard polls.
  stopTiming?: TurnStopTiming
}

// What the Worker gets back from start: `busy` while another turn of this
// session is unfinished (the route answers today's 409 conflict).
export type TurnStartAnswer = 'started' | 'busy'

// The Worker's view of the binding (routes/turns.ts goes through these).
export type TurnRunnerStub = {
  start(job: TurnJob): Promise<TurnStartAnswer>
  fetch(input: Request | string): Promise<Response>
}
export type TurnRunnerNamespace = {
  idFromName(name: string): unknown
  get(id: unknown): TurnRunnerStub
}

const JOB_KEY = 'job'
const FINAL_KEY = 'final'
// The last event is kept this long after the end, for a watch that asks to
// replay it (the Worker's own watch racing a very fast turn). After that only
// the turn's id is kept, so a late attach still reads as finished (204).
export const FINAL_REPLAY_MS = 60_000
const END_TIMEOUT_MS = 2_000

// A finished turn, for watches that come after it. `reply` (the only part
// that carries the listener's words) goes once FINAL_REPLAY_MS has passed;
// the id stays until the next turn's end replaces it.
type FinalRecord = { turnId: string; at: number; reply?: TurnReply; push?: boolean }

// The reply as it went down the wire (JSON), so a replay sends the same
// bytes and storage never holds anything its clone could refuse. A body
// that cannot be serialized went down as INTERNAL_TURN_REPLY (endOne).
function finalRecord(job: TurnJob, reply: TurnReply, at: number): FinalRecord {
  let wire: TurnReply
  try {
    wire = JSON.parse(JSON.stringify(reply)) as TurnReply
  } catch {
    wire = INTERNAL_TURN_REPLY
  }
  return {
    turnId: job.turnId,
    at,
    reply: wire,
    push: job.push === true,
  }
}

// The turn this instance is running or about to run, with its watchers.
type Live = {
  job: TurnJob
  latestStep?: TurnStepEvent
  ended?: TurnReply
  watchers: Set<TurnStreamWriter>
}

export class TurnRunnerCore {
  private live: Live | null = null
  private running = false

  constructor(private readonly shell: TurnRunnerShell) {}

  private now(): number {
    return (this.shell.now ?? Date.now)()
  }

  /**
   * Holds the job and sets the alarm for now. A second start of the same
   * turn (a retried RPC) is the same start; another turn while one is
   * unfinished is `busy`, as two turns on one session race today.
   */
  async start(job: TurnJob): Promise<TurnStartAnswer> {
    const held = await this.shell.storage.get<TurnJob>(JOB_KEY)
    if (held) return held.turnId === job.turnId ? 'started' : 'busy'
    await this.shell.storage.put(JOB_KEY, job)
    await this.shell.setAlarm(this.now())
    return 'started'
  }

  /**
   * Runs the held job, then forgets it whatever the outcome. Never throws:
   * the platform retries an alarm that throws, and only a dead attempt
   * should be retried (runTurnJob's claim then decides). An alarm with no
   * job is the cleanup one, which drops an expired last event.
   */
  async alarm(): Promise<TurnJobResult | undefined> {
    let job: TurnJob | undefined
    try {
      job = await this.shell.storage.get<TurnJob>(JOB_KEY)
    } catch {
      return undefined
    }
    if (!job) {
      await this.expireFinal()
      return undefined
    }
    if (this.running) return undefined
    this.running = true
    const live = this.liveFor(job)

    let result: TurnJobResult | undefined
    let pool: { end(): Promise<void> } | undefined
    try {
      const opened = this.shell.openDb()
      pool = opened.pool
      const deps = this.shell.buildDeps(opened.db)
      if (deps) {
        result = await runTurnJob(job, {
          db: opened.db,
          deps,
          watchers: { onStep: (event) => this.step(live, event), onEnd: (reply) => this.end(live, reply) },
          ...(this.shell.stopTiming ? { stopTiming: this.shell.stopTiming } : {}),
        })
      } else {
        // Nothing to run the turn with: an answer, not a retry.
        await abandonTurn(opened.db, job.turnId, 'internal').catch(() => false)
        result = await this.failed(live)
      }
    } catch {
      console.error('turn runner failed')
      result = await this.failed(live)
    } finally {
      await pool?.end().catch(() => {})
    }

    // A duplicate had no answer to send: its watchers just close.
    for (const watcher of live.watchers) watcher.close()
    live.watchers.clear()
    // The job goes first: a job left held would answer every later start
    // `busy`. Should the delete fail, the cleanup alarm below finds the job
    // again, and its claim answers duplicate, which deletes it then.
    try {
      await this.shell.storage.delete(JOB_KEY)
    } catch {
      console.error('turn runner storage failed')
    }
    try {
      if (live.ended) await this.shell.storage.put<FinalRecord>(FINAL_KEY, finalRecord(job, live.ended, this.now()))
    } catch {
      console.error('turn runner storage failed')
    }
    try {
      await this.shell.setAlarm(this.now() + FINAL_REPLAY_MS)
    } catch {
      console.error('turn runner storage failed')
    }
    if (this.live === live) this.live = null
    this.running = false
    return result
  }

  /**
   * GET /watch?turn=<id>: the turn's stream while it is held (queued or
   * running), starting from its latest step; 204 once it has finished; 404
   * for a turn this object never held. `replay=1` on a turn that finished
   * within FINAL_REPLAY_MS answers its last event instead of 204.
   */
  async fetch(req: Request): Promise<Response> {
    const url = new URL(req.url)
    const turnId = url.searchParams.get('turn')
    if (url.pathname !== '/watch' || !turnId) return new Response(null, { status: 404 })

    const live = this.live?.job.turnId === turnId ? this.live : null
    if (live && !live.ended) return this.attach(live)
    if (!live) {
      const held = await this.shell.storage.get<TurnJob>(JOB_KEY)
      if (held?.turnId === turnId) return this.attach(this.liveFor(held))
    }
    const final = live?.ended ? finalRecord(live.job, live.ended, this.now()) : await this.shell.storage.get<FinalRecord>(FINAL_KEY)
    if (final?.turnId !== turnId) return new Response(null, { status: 404 })
    if (url.searchParams.get('replay') === '1' && final.reply && this.now() - final.at < FINAL_REPLAY_MS) {
      const writer = this.writer()
      writer.turn({ turnId, push: final.push === true })
      void this.endOne(writer, final.reply)
      return turnStreamResponse(writer.readable)
    }
    return new Response(null, { status: 204 })
  }

  private liveFor(job: TurnJob): Live {
    if (this.live?.job.turnId !== job.turnId) this.live = { job, watchers: new Set() }
    return this.live
  }

  private writer(onGone?: () => void): TurnStreamWriter {
    return new TurnStreamWriter({ keepaliveMs: this.shell.keepaliveMs, onGone })
  }

  // turn, then the latest step so a late attacher's caption resumes, then
  // live. A create's `session` event comes before all of it, from the Worker
  // (routes/turns.ts): the job holds no list row. A write that fails drops
  // the watcher (gate 0: about a second after the client goes).
  private attach(live: Live): Response {
    const { job } = live
    const writer: TurnStreamWriter = this.writer(() => live.watchers.delete(writer))
    writer.turn({ turnId: job.turnId, push: job.push === true })
    if (live.latestStep) writer.step(live.latestStep)
    live.watchers.add(writer)
    return turnStreamResponse(writer.readable)
  }

  private step(live: Live, event: TurnStepEvent): void {
    live.latestStep = event
    for (const watcher of live.watchers) watcher.step(event)
  }

  // True when at least one watcher read the last event in time.
  private async end(live: Live, reply: TurnReply): Promise<boolean> {
    live.ended = reply
    const watchers = [...live.watchers]
    live.watchers.clear()
    const taken = await Promise.all(watchers.map((watcher) => this.endOne(watcher, reply)))
    return taken.some(Boolean)
  }

  private async endOne(watcher: TurnStreamWriter, reply: TurnReply): Promise<boolean> {
    let written: Promise<boolean>
    try {
      written = watcher.end(reply)
    } catch {
      // A body that cannot be serialized, as streamTurn handles it.
      written = watcher.end(INTERNAL_TURN_REPLY)
    }
    let timer: ReturnType<typeof setTimeout> | undefined
    const late = new Promise<boolean>((resolve) => {
      timer = setTimeout(() => resolve(false), this.shell.endTimeoutMs ?? END_TIMEOUT_MS)
    })
    try {
      return await Promise.race([written, late])
    } finally {
      clearTimeout(timer)
    }
  }

  // The answer when the job could not run at all.
  private async failed(live: Live): Promise<TurnJobResult> {
    const watchedResult = live.ended ? false : await this.end(live, INTERNAL_TURN_REPLY)
    return { outcome: 'failed', status: INTERNAL_TURN_REPLY.status, body: INTERNAL_TURN_REPLY.body, errorKind: 'internal', title: null, watchedResult }
  }

  // The cleanup alarm: the last event's body (the listener's words) goes;
  // its turn id stays, so a late attach still answers 204. The job itself
  // holds only ids, so nothing else needs stripping.
  private async expireFinal(): Promise<void> {
    try {
      const final = await this.shell.storage.get<FinalRecord>(FINAL_KEY)
      if (final?.reply && this.now() - final.at >= FINAL_REPLAY_MS) {
        await this.shell.storage.put<FinalRecord>(FINAL_KEY, { turnId: final.turnId, at: final.at })
      }
    } catch {
      // Overwritten by the next turn's end anyway.
    }
  }
}
