import { randomUUID } from 'node:crypto'
import { and, eq, gt, inArray, isNotNull, isNull, or, sql } from 'drizzle-orm'
import type { Db } from '../db/types'
import { djMessages, djSessions, queueTracks } from '../db/schema'
import { restoreMixVersion } from './mix-history'

// Stopping a mix turn (spec 2026-11-15 stop-a-turn). A turn claims its
// session while it runs; POST /sessions/:id/turn/stop raises a flag on that
// claim; the turn sees the flag at its next model call (or within a second
// of it, mid call) and undoes what it wrote. Whether the turn finished or
// was stopped is decided by two conditional UPDATEs on the session row,
// which Postgres orders: exactly one of them wins.

// Thrown out of runDjTurn once a stopped turn has been undone.
export class TurnStopped extends Error {
  constructor() {
    super('turn stopped')
    this.name = 'TurnStopped'
  }
}

// A claim older than this belongs to a turn that died without clearing it
// (an isolate that went away mid turn). A turn never runs this long.
export const STALE_TURN_MS = 5 * 60_000

// How often a stop request looks for the turn to have let go, and for how
// long, and how often a turn looks for the flag during a model call.
export type TurnStopTiming = { pollMs?: number; timeoutMs?: number; guardPollMs?: number }
const DEFAULT_POLL_MS = 250
const DEFAULT_TIMEOUT_MS = 30_000
const DEFAULT_GUARD_POLL_MS = 1_000

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms))

// What a turn found when it claimed the session, to put back if stopped.
export type TurnClaim = { turnId: string; title: string; notPersonal: boolean }

// Claims the session for a new turn. A turn whose stop is still being
// undone is waited out first (bounded), so the next turn never races the
// rollback of the last one.
export async function claimTurn(db: Db, sessionId: string, timing: TurnStopTiming = {}): Promise<TurnClaim> {
  const pollMs = timing.pollMs ?? DEFAULT_POLL_MS
  const deadline = Date.now() + (timing.timeoutMs ?? DEFAULT_TIMEOUT_MS)
  for (;;) {
    const [row] = await db
      .select({ activeTurnId: djSessions.activeTurnId, activeTurnAt: djSessions.activeTurnAt, stop: djSessions.turnStopRequested })
      .from(djSessions)
      .where(eq(djSessions.id, sessionId))
    const undoing = row?.activeTurnId != null && row.stop && row.activeTurnAt != null && row.activeTurnAt.getTime() > Date.now() - STALE_TURN_MS
    if (!undoing || Date.now() >= deadline) break
    await sleep(pollMs)
  }
  const turnId = randomUUID()
  const [row] = await db
    .update(djSessions)
    .set({ activeTurnId: turnId, activeTurnAt: sql`now()`, turnStopRequested: false, updatedAt: sql`${djSessions.updatedAt}` })
    .where(eq(djSessions.id, sessionId))
    .returning({ title: djSessions.title, notPersonal: djSessions.notPersonal })
  return { turnId, title: row?.title ?? '', notPersonal: row?.notPersonal ?? false }
}

// True when this turn finished and let go; false when a stop got in first
// (the turn must then be undone). The claim stays in place on false, so a
// waiting stop request keeps waiting until the rollback lets go.
export async function finishTurn(db: Db, sessionId: string, turnId: string): Promise<boolean> {
  const rows = await db
    .update(djSessions)
    .set({ activeTurnId: null, activeTurnAt: null, updatedAt: sql`${djSessions.updatedAt}` })
    .where(and(eq(djSessions.id, sessionId), eq(djSessions.activeTurnId, turnId), eq(djSessions.turnStopRequested, false)))
    .returning({ id: djSessions.id })
  if (rows.length > 0) return true
  // No row: either a stop is on this claim, or the claim is no longer ours
  // (a later turn took it, or the session is gone). Only the first is a
  // stop seen here; a stop the turn's guard already saw is the caller's.
  const [row] = await db
    .select({ activeTurnId: djSessions.activeTurnId, stop: djSessions.turnStopRequested })
    .from(djSessions)
    .where(eq(djSessions.id, sessionId))
  return !(row?.activeTurnId === turnId && row.stop)
}

// Asks the running turn to stop, then waits until it has been undone.
// False when no turn was running (it finished first).
export async function requestStop(db: Db, sessionId: string, timing: TurnStopTiming = {}): Promise<boolean> {
  const pollMs = timing.pollMs ?? DEFAULT_POLL_MS
  const deadline = Date.now() + (timing.timeoutMs ?? DEFAULT_TIMEOUT_MS)
  const rows = await db
    .update(djSessions)
    .set({ turnStopRequested: true, updatedAt: sql`${djSessions.updatedAt}` })
    .where(and(
      eq(djSessions.id, sessionId),
      isNotNull(djSessions.activeTurnId),
      gt(djSessions.activeTurnAt, new Date(Date.now() - STALE_TURN_MS)),
    ))
    .returning({ turnId: djSessions.activeTurnId })
  if (rows.length === 0) return false
  const turnId = rows[0].turnId
  while (Date.now() < deadline) {
    const [row] = await db.select({ activeTurnId: djSessions.activeTurnId }).from(djSessions).where(eq(djSessions.id, sessionId))
    // Gone (a stopped first turn deletes its session) or let go: undone.
    if (!row || row.activeTurnId !== turnId) return true
    await sleep(pollMs)
  }
  // The turn will still see the flag and undo itself; the answer stays
  // "stopped", and the next turn's claim waits for that rollback.
  return true
}

// Watches one turn's claim for a stop. Once it has seen one it says so
// without asking again.
export class TurnGuard {
  stopped = false
  private readonly guardPollMs: number

  constructor(private readonly db: Db, private readonly sessionId: string, private readonly turnId: string, timing: TurnStopTiming = {}) {
    this.guardPollMs = timing.guardPollMs ?? DEFAULT_GUARD_POLL_MS
  }

  private async stopRequested(): Promise<boolean> {
    if (this.stopped) return true
    const [row] = await this.db
      .select({ activeTurnId: djSessions.activeTurnId, stop: djSessions.turnStopRequested })
      .from(djSessions)
      .where(eq(djSessions.id, this.sessionId))
    if (!row || (row.activeTurnId === this.turnId && row.stop)) this.stopped = true
    return this.stopped
  }

  // A failed look is not a stop: the finish check still decides.
  async check(): Promise<void> {
    let stop = false
    try {
      stop = await this.stopRequested()
    } catch {
      stop = false
    }
    if (stop) throw new TurnStopped()
  }

  // [run], abandoned with TurnStopped as soon as a stop is seen. The call
  // itself is left to finish on its own; nothing reads its answer.
  race<T>(run: Promise<T>): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      let settled = false
      let timer: ReturnType<typeof setTimeout> | undefined
      const poll = () => {
        timer = setTimeout(async () => {
          if (settled) return
          let stop = false
          try {
            stop = await this.stopRequested()
          } catch {
            // A failed look is not a stop; the finish check still decides.
          }
          if (settled) return
          if (stop) {
            settled = true
            reject(new TurnStopped())
            return
          }
          poll()
        }, this.guardPollMs)
      }
      poll()
      run.then(
        (value) => {
          if (settled) return
          settled = true
          clearTimeout(timer)
          resolve(value)
        },
        (error: unknown) => {
          if (settled) return
          settled = true
          clearTimeout(timer)
          reject(error)
        },
      )
    })
  }

  // [fn] with a stop check before each call and a watch during it.
  wrap<A extends unknown[], R>(fn: (...args: A) => Promise<R>): (...args: A) => Promise<R> {
    return async (...args: A) => {
      await this.check()
      return this.race(fn(...args))
    }
  }
}

// What a turn wrote, for its rollback: the seqs of its own messages (the
// listener's first, then the DJ's), and whether it renamed the session or
// offered the music pill.
export type TurnWrites = { messageSeqs: number[]; renamed: boolean; historyOffered: boolean }

// TurnWrites plus what a rollback puts back, flattened so it can be stored
// (dj_turns.writes, spec 2026-11-21 durable-mix-turns "Retries without a
// second mix") and handed to rollbackTurn by a later attempt that never saw
// the in-memory objects. The claim fields are null for a turn that ran
// without a claim (claimTurn failed): nothing of the title or the claim is
// then put back, only messages and the queue. claimTurnId says whose claim
// to let go of, and whether a later turn has taken the session since.
export type PersistedTurnWrites = {
  messageSeqs: number[]
  renamed: boolean
  historyOffered: boolean
  startingVersion: number
  claimTitle: string | null
  claimNotPersonal: boolean | null
  claimTurnId: string | null
}

// A snapshot, never a view: messageSeqs is copied, so a turn that writes on
// after handing it out cannot change what was handed out.
export function persistTurnWrites(claim: TurnClaim | null, startingVersion: number, writes: TurnWrites): PersistedTurnWrites {
  return {
    messageSeqs: [...writes.messageSeqs],
    renamed: writes.renamed,
    historyOffered: writes.historyOffered,
    startingVersion,
    claimTitle: claim?.title ?? null,
    claimNotPersonal: claim?.notPersonal ?? null,
    claimTurnId: claim?.turnId ?? null,
  }
}

// 'stop': the listener stopped the turn; everything it wrote goes, the
// listener's own message included, and a first turn takes its session with
// it. 'rerun': an attempt died mid turn and the turn runs again; the
// listener's message (the first seq) stays, since the re-run answers it,
// and the session always stays.
export type RollbackMode = { mode: 'stop'; firstTurn?: boolean } | { mode: 'rerun' }

// Undoes a turn's writes and lets go of its claim. When a later turn already
// holds the claim, only this turn's own messages go: the queue and title are
// that turn's now.
export async function rollbackTurn(
  db: Db,
  session: { id: string; userId: string },
  writes: PersistedTurnWrites,
  options: RollbackMode,
): Promise<void> {
  if (options.mode === 'stop' && options.firstTurn) {
    await db.delete(djSessions).where(eq(djSessions.id, session.id))
    return
  }
  const [row] = await db
    .select({ activeTurnId: djSessions.activeTurnId, queueVersion: djSessions.queueVersion })
    .from(djSessions)
    .where(eq(djSessions.id, session.id))
  if (!row) return
  const doomedSeqs = options.mode === 'rerun' ? writes.messageSeqs.slice(1) : writes.messageSeqs
  if (doomedSeqs.length > 0) {
    await db.delete(djMessages).where(and(eq(djMessages.sessionId, session.id), inArray(djMessages.seq, doomedSeqs)))
  }
  const superseded = row.activeTurnId !== null && row.activeTurnId !== writes.claimTurnId
  if (superseded) return

  const { startingVersion } = writes
  if (row.queueVersion !== startingVersion) {
    if (startingVersion >= 1) {
      // A restore, so the version still only moves forward: a client that
      // saw the undone version reads the old songs as a newer one.
      await restoreMixVersion(db, session.id, session.userId, {
        version: startingVersion,
        expectedVersion: row.queueVersion,
        requestId: randomUUID(),
      })
    } else {
      // The mix was empty before this turn: empty again, one version on.
      await db.transaction(async (tx) => {
        await tx.delete(queueTracks).where(and(eq(queueTracks.sessionId, session.id), eq(queueTracks.state, 'active')))
        await tx
          .update(djSessions)
          .set({
            queueVersion: sql`${djSessions.queueVersion} + 1`,
            ...(writes.claimNotPersonal !== null ? { notPersonal: writes.claimNotPersonal } : {}),
          })
          .where(eq(djSessions.id, session.id))
      })
    }
  }
  await db
    .update(djSessions)
    .set({
      activeTurnId: null,
      activeTurnAt: null,
      turnStopRequested: false,
      ...(writes.renamed && writes.claimTitle !== null ? { title: writes.claimTitle } : {}),
      ...(writes.historyOffered ? { musicChipAt: null } : {}),
      updatedAt: sql`${djSessions.updatedAt}`,
    })
    .where(and(eq(djSessions.id, session.id), claimHeldBy(writes.claimTurnId, options.mode)))
}

// Whose claim the closing UPDATE lets go of. A stop only ever undoes the
// turn still holding its claim (finishTurn left it in place). A re-run also
// accepts a session nobody holds: no later turn has taken it (the
// superseded check), so the dead attempt's title and pill are still its own
// to put back.
function claimHeldBy(turnId: string | null, mode: RollbackMode['mode']) {
  const free = isNull(djSessions.activeTurnId)
  if (turnId === null) return free
  const ours = eq(djSessions.activeTurnId, turnId)
  return mode === 'rerun' ? or(ours, free) : ours
}
