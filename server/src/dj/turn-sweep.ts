import { and, eq, gt, inArray, lt, sql } from 'drizzle-orm'
import type { Db } from '../db/types'
import { djMessages, djSessions, djTurns } from '../db/schema'
import type { PersistedTurnWrites } from './loop'
import { rollbackTurn } from './turn-stop'
import { abandonTurn, TURN_LOST_MS } from './turn-job'

// Lost durable turns (spec 2026-11-21 durable-mix-turns, "Status rules"): a
// turn queued or running whose heartbeat (or created_at, while queued) is
// older than 90 s will not finish by itself. The hourly maintenance cron
// fails it ('lost'), undoes what its dead attempt wrote (best effort, the
// listener's message kept), and tells the listener.

// What notify is told about a turn that ended. S6 sends the push; until
// then this is a no-op seam, called wherever a turn ends off a watcher.
export type EndedTurn = { turnId: string; sessionId: string; userId: string; status: 'done' | 'failed' | 'stopped'; errorKind: string | null }
export type NotifyTurn = (db: Db, turn: EndedTurn) => Promise<void>

export const notifyTurn: NotifyTurn = async () => {}

// At most this many per run: a backlog drains over a few hours rather than
// one invocation's budget.
export const LOST_TURN_SWEEP_LIMIT = 100

export type LostTurnSweepDeps = { now?: () => Date; notify?: NotifyTurn }

/** Fails every lost turn; answers how many it failed (the cron line's count). */
export async function sweepLostTurns(db: Db, deps: LostTurnSweepDeps = {}): Promise<number> {
  const now = (deps.now ?? (() => new Date()))()
  const notify = deps.notify ?? notifyTurn
  const cutoff = new Date(now.getTime() - TURN_LOST_MS)
  const lost = await db
    .select({ id: djTurns.id, sessionId: djTurns.sessionId, userId: djTurns.userId, writes: djTurns.writes })
    .from(djTurns)
    .where(and(inArray(djTurns.status, ['queued', 'running']), lt(sql`coalesce(${djTurns.heartbeatAt}, ${djTurns.createdAt})`, cutoff)))
    .orderBy(djTurns.createdAt)
    .limit(LOST_TURN_SWEEP_LIMIT)

  let count = 0
  for (const turn of lost) {
    // Failed first, fenced on still being live: a turn that finished since
    // the read is left alone, and no attempt can finish over this one.
    if (!(await abandonTurn(db, turn.id, 'lost', now))) continue
    count += 1
    if (turn.writes) {
      try {
        const writes = turn.writes as PersistedTurnWrites
        // Only while nothing has happened in the session since: a turn whose
        // object let go of it (its finish write failed) leaves the session
        // free for later turns, and their mix is not this turn's to undo.
        if (!(await movedOn(db, turn.id, turn.sessionId, writes))) {
          await rollbackTurn(db, { id: turn.sessionId, userId: turn.userId }, writes, { mode: 'rerun' })
        }
      } catch {
        // Its writes stand; the turn reads as failed with the message intact.
        console.error('lost turn rollback failed')
      }
    }
    try {
      await notify(db, { turnId: turn.id, sessionId: turn.sessionId, userId: turn.userId, status: 'failed', errorKind: 'lost' })
    } catch {
      console.error('lost turn notify failed')
    }
  }
  return count
}


// True when the session has gone on past this turn: another turn is its
// current one, or a message was written after the last of this turn's.
async function movedOn(db: Db, turnId: string, sessionId: string, writes: PersistedTurnWrites): Promise<boolean> {
  const [session] = await db.select({ currentTurnId: djSessions.currentTurnId }).from(djSessions).where(eq(djSessions.id, sessionId))
  if (!session || session.currentTurnId !== turnId) return true
  const last = Math.max(...writes.messageSeqs, 0)
  const [later] = await db
    .select({ seq: djMessages.seq })
    .from(djMessages)
    .where(and(eq(djMessages.sessionId, sessionId), gt(djMessages.seq, last)))
    .limit(1)
  return later !== undefined
}
