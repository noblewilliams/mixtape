import { and, eq, inArray, lt, sql } from 'drizzle-orm'
import type { Db } from '../db/types'
import { djSessions, djTurns } from '../db/schema'
import type { DjDeps, DjTurnOptions, PersistedTurnWrites } from './loop'
import { rollbackTurn, type TurnStopTiming } from './turn-stop'
import type { TurnStepEvent } from './turn-steps'
import { createMixTurn, mixMessageTurn, type MixTurnEnd } from '../routes/turn-bodies'
import { INTERNAL_TURN_REPLY, type TurnReply } from '../routes/turn-stream'

// The durable mix turn, apart from any platform (spec 2026-11-21
// durable-mix-turns, "Run (object side)" and "Retries without a second
// mix"). The Durable Object (dj/turn-runner.ts) is a thin shell over this:
// it holds the job, runs it on its alarm, and fans the job's steps and last
// event out to whoever is watching. Everything that decides what a turn
// does to the database lives here, so Node tests cover it whole.

// One automatic re-run (founder answer 4): a second death is `lost`.
export const MAX_ATTEMPTS = 2
// While running, the row's heartbeat is bumped this often; a turn whose
// heartbeat is older than 90 s reads as lost (spec, "Status rules").
export const TURN_HEARTBEAT_MS = 15_000

// What the object holds until the turn ends. The listener's message row is
// already written (persist-first, by the Worker), so a re-run answers the
// same row. `session` is the create's list row, the stream's first event.
// `push` says whether the server will push this turn's end (the stream's
// `turn` event); S6 computes it, absent is false.
type TurnJobBase = {
  turnId: string
  sessionId: string
  userId: string
  userMessageSeq: number
  text: string
  options: { energyArc?: DjTurnOptions['energyArc']; surface?: DjTurnOptions['surface']; remake?: boolean }
  push?: boolean
}
export type TurnJob =
  | (TurnJobBase & { kind: 'create'; fallbackTitle: string; session?: unknown })
  | (TurnJobBase & { kind: 'message' | 'remake' })

// Who is watching the turn. onEnd resolves true when at least one watcher
// took the last event (what notify reads as "the client saw it").
export type TurnWatchers = {
  onStep(event: TurnStepEvent): void
  onEnd(reply: TurnReply): Promise<boolean> | boolean
}

type IntervalHandle = unknown
export type TurnJobIo = {
  db: Db
  deps: DjDeps
  watchers: TurnWatchers
  now?: () => Date
  setInterval?: (run: () => void, ms: number) => IntervalHandle
  clearInterval?: (handle: IntervalHandle) => void
  // For tests: how fast the turn's stop guard polls.
  stopTiming?: TurnStopTiming
}

// done/failed/stopped: this attempt ran and finished the row. duplicate: the
// row was already terminal (or gone before the claim), nothing was done.
// lost: the attempts were spent, the row is failed('lost'). gone: the
// session was deleted under the turn; nothing to tell anyone.
export type TurnJobOutcome = 'done' | 'failed' | 'stopped' | 'lost' | 'gone'
export type TurnJobResult =
  | { outcome: 'duplicate' }
  | {
      outcome: TurnJobOutcome
      status: TurnReply['status']
      body: unknown
      // The row's code: a DjError kind, 'internal' or 'lost'; null when done
      // or stopped.
      errorKind: string | null
      // The session's title once the turn is over, for the push; null when
      // the session is gone.
      title: string | null
      watchedResult: boolean
    }

type Finish = { status: 'done' | 'failed' | 'stopped'; errorKind: string | null }

function finishFor(end: MixTurnEnd): Finish {
  if (end.kind === 'done') return { status: 'done', errorKind: null }
  if (end.kind === 'stopped') return { status: 'stopped', errorKind: null }
  return { status: 'failed', errorKind: end.errorKind }
}

const LIVE = ['queued', 'running'] as const

// Claims the next attempt: one conditional UPDATE, so two alarms for one
// turn cannot both run it. Null when the row is terminal, spent or gone.
async function claimAttempt(db: Db, turnId: string, now: Date) {
  const [row] = await db
    .update(djTurns)
    .set({
      status: 'running',
      attempt: sql`${djTurns.attempt} + 1`,
      startedAt: sql`coalesce(${djTurns.startedAt}, ${now.toISOString()}::timestamptz)`,
      heartbeatAt: now,
    })
    .where(and(eq(djTurns.id, turnId), inArray(djTurns.status, [...LIVE]), lt(djTurns.attempt, MAX_ATTEMPTS)))
    .returning({ attempt: djTurns.attempt, writes: djTurns.writes })
  return row ?? null
}

// Marks a turn that will not run (its attempts are spent, or the object
// could not wire one) failed with a code. False when the row was already
// terminal or is gone.
export async function abandonTurn(db: Db, turnId: string, errorKind: 'lost' | 'internal', now: Date = new Date()): Promise<boolean> {
  const rows = await db
    .update(djTurns)
    .set({ status: 'failed', errorKind, finishedAt: now })
    .where(and(eq(djTurns.id, turnId), inArray(djTurns.status, [...LIVE])))
    .returning({ id: djTurns.id })
  return rows.length > 0
}

/**
 * Runs one attempt of a durable mix turn and finishes its dj_turns row
 * exactly once. Never throws: an alarm that throws is retried by the
 * platform, and a turn error is an answer, not a reason to run it again
 * (spec, "Retries without a second mix", 3). Nothing here is logged but
 * fixed lines: steps and bodies carry the listener's names and words.
 */
export async function runTurnJob(job: TurnJob, io: TurnJobIo): Promise<TurnJobResult> {
  const now = io.now ?? (() => new Date())
  const setTimer = io.setInterval ?? ((run, ms) => setInterval(run, ms))
  const clearTimer = io.clearInterval ?? ((handle) => clearInterval(handle as ReturnType<typeof setInterval>))
  const { db } = io
  const session = { id: job.sessionId, userId: job.userId }

  let attempt: number | null = null
  let reply: TurnReply = INTERNAL_TURN_REPLY
  let finish: Finish = { status: 'failed', errorKind: 'internal' }
  let outcome: TurnJobOutcome | null = null
  // Step stamps still in flight, settled before the finish so none lands
  // on a pool that is about to end.
  const pending: Promise<unknown>[] = []
  let heartbeat: IntervalHandle | undefined

  // Every write below is fenced on this attempt still running: a late write
  // from a dead attempt's isolate can never touch the next one's row.
  const thisAttempt = () => and(eq(djTurns.id, job.turnId), eq(djTurns.attempt, attempt ?? -1), eq(djTurns.status, 'running'))

  try {
    const claim = await claimAttempt(db, job.turnId, now())
    if (!claim) {
      const [row] = await db
        .select({ status: djTurns.status, writes: djTurns.writes })
        .from(djTurns)
        .where(eq(djTurns.id, job.turnId))
      // Terminal already, or gone with its session: a duplicate alarm.
      if (!row || !(LIVE as readonly string[]).includes(row.status)) return { outcome: 'duplicate' }
      // Still live with its attempts spent: the last one died mid turn.
      // Its writes are undone (the listener's message kept) so the mix is
      // left as it was before the turn, then the row is failed('lost').
      if (row.writes) {
        try {
          await rollbackTurn(db, session, row.writes as PersistedTurnWrites, { mode: 'rerun' })
        } catch {
          console.error('turn job rollback failed')
        }
      }
      if (!(await abandonTurn(db, job.turnId, 'lost', now()))) return { outcome: 'duplicate' }
      outcome = 'lost'
      finish = { status: 'failed', errorKind: 'lost' }
    } else {
      attempt = claim.attempt
      // A previous attempt died mid turn: undo what it wrote before running
      // again, keeping the listener's message. A rollback that fails leaves
      // those writes standing, so the turn fails rather than run on top.
      let clean = true
      if (attempt > 1 && claim.writes) {
        try {
          await rollbackTurn(db, session, claim.writes as PersistedTurnWrites, { mode: 'rerun' })
        } catch {
          console.error('turn job rollback failed')
          clean = false
        }
      }
      if (clean) {
        heartbeat = setTimer(() => {
          pending.push(db.update(djTurns).set({ heartbeatAt: now() }).where(thisAttempt()).catch(() => {}))
        }, TURN_HEARTBEAT_MS)
        const answer = await runTurn(job, io, {
          onStep: stepper(io.watchers, (step) => {
            // The step's name only, never its artists, genres or title.
            pending.push(db.update(djTurns).set({ step, stepAt: now() }).where(thisAttempt()).catch(() => {}))
          }),
          recordWrites: async (snapshot) => {
            await db.update(djTurns).set({ writes: snapshot }).where(thisAttempt())
          },
        })
        reply = { status: answer.status, body: answer.body }
        finish = finishFor(answer.end)
      }
    }
  } catch {
    console.error('turn job failed')
    reply = INTERNAL_TURN_REPLY
    finish = { status: 'failed', errorKind: 'internal' }
  } finally {
    if (heartbeat !== undefined) clearTimer(heartbeat)
  }
  await Promise.allSettled(pending)

  // Finish exactly once. A row the cascade removed (a stopped first turn
  // deletes its session, or the mix was deleted under the turn) finishes
  // nothing, and that is fine.
  if (outcome === null) {
    outcome = finish.status
    if (attempt !== null) {
      try {
        const finished = await db
          .update(djTurns)
          .set({ status: finish.status, errorKind: finish.errorKind, finishedAt: now() })
          .where(thisAttempt())
          .returning({ id: djTurns.id })
        if (finished.length === 0 && finish.status !== 'stopped' && !(await sessionExists(db, job.sessionId))) outcome = 'gone'
      } catch {
        console.error('turn job finish failed')
      }
    }
  }

  let title: string | null = null
  try {
    const [row] = await db.select({ title: djSessions.title }).from(djSessions).where(eq(djSessions.id, job.sessionId))
    title = row?.title ?? null
  } catch {
    title = null
  }

  // Sent after the finish, so a client that re-reads the session on its
  // last event sees the turn over.
  let watchedResult = false
  try {
    watchedResult = await io.watchers.onEnd(reply)
  } catch {
    watchedResult = false
  }
  if (watchedResult) {
    try {
      await db.update(djTurns).set({ watchedResult: true }).where(eq(djTurns.id, job.turnId))
    } catch {
      // notify reads the returned value; the column is a record.
    }
  }

  return { outcome, status: reply.status, body: reply.body, errorKind: finish.errorKind, title, watchedResult }
}

// Fans each step out to the watchers and stamps the row once per change of
// step: a caption never fails the turn, and its names never reach the row.
function stepper(watchers: TurnWatchers, stamp: (step: TurnStepEvent['step']) => void): (event: TurnStepEvent) => void {
  let stamped: TurnStepEvent['step'] | undefined
  return (event) => {
    try {
      watchers.onStep(event)
    } catch {
      // A caption never fails the turn.
    }
    if (event.step === stamped) return
    stamped = event.step
    stamp(event.step)
  }
}

async function sessionExists(db: Db, sessionId: string): Promise<boolean> {
  const [row] = await db.select({ id: djSessions.id }).from(djSessions).where(eq(djSessions.id, sessionId))
  return row !== undefined
}

// The turn exactly as the routes run it (routes/sessions.ts), through the
// same builders, so the job's result and error bodies are the routes'.
function runTurn(
  job: TurnJob,
  io: TurnJobIo,
  hooks: Pick<DjTurnOptions, 'onStep' | 'recordWrites'>,
) {
  const options: DjTurnOptions = {
    energyArc: job.options.energyArc,
    surface: job.options.surface,
    ...(job.options.remake === true ? { remake: true } : {}),
    userMessageSeq: job.userMessageSeq,
    ...hooks,
    ...(io.stopTiming ? { stopTiming: io.stopTiming } : {}),
  }
  if (job.kind === 'create') {
    return createMixTurn(io.db, io.deps, { id: job.sessionId }, job.userId, job.text, job.fallbackTitle, options)
  }
  return mixMessageTurn(io.db, io.deps, { id: job.sessionId, userId: job.userId }, job.text, options)
}
