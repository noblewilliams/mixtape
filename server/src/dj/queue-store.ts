import { and, asc, eq, inArray, sql } from 'drizzle-orm'
import type { Db } from '../db/types'
import { djSessions, queueTracks, tracks } from '../db/schema'
import type { OpIntent, QueueOp } from './contracts'

export type QueueTrackView = {
  position: number
  trackId: string
  appleId: string | null
  title: string
  artist: string
  reason: string | null
  durationMs: number | null
}

// Thrown when an op batch fails validation against the CURRENT queue state
// (an out-of-range position/from/to, or a batch that needs a
// replacementsProvider — a swap/extend whose placeholder survives to the
// final plan — and none was given). All-or-nothing: nothing in the batch is
// applied. Message is deliberately content-free (never echoes op fields or
// ids).
export class QueueOpError extends Error {
  constructor() {
    super('queue-store: invalid queue operation')
    this.name = 'QueueOpError'
  }
}

// Thrown when the session's queueVersion moved between this call's initial,
// UNLOCKED read (phase 1, where the replacementsProvider runs — see
// applyOps) and its locked re-read moments later (phase 2) — something else
// wrote to this queue in that window. Also thrown up front when the caller
// passes `expectedVersion` and it's already stale at the start of the call.
// Either way the caller (the agent loop / the manual queue-ops route) should
// re-read the queue and retry, not blindly resubmit. Message is
// deliberately content-free.
export class QueueVersionConflict extends Error {
  constructor() {
    super('queue-store: queue changed since it was last read')
    this.name = 'QueueVersionConflict'
  }
}

export type ReplacementPick = { trackId: string; reason: string }

// The engine (Task 7), not the store, decides what a swap/extend actually
// plays — the store only knows how to splice picks into position order.
export type ReplacementsProvider = (count: number, intent?: OpIntent) => Promise<ReplacementPick[]>

export type ApplyOpsResult = {
  version: number
  requested: number // total tracks asked of the provider across this batch
  added: number // tracks actually inserted (requested minus shortfall/duplicates)
  removed: number // rows marked removed (unconditional `remove`s + resolved swaps)
}

/**
 * Replaces a session's entire queue: hard-deletes every existing queue_tracks
 * row (active AND removed — history for a discarded queue lives in
 * dj_messages, not queue rows) and inserts `picks` at positions 0..n-1.
 * Bumps queueVersion once. Returns the new version.
 *
 * Unlike applyOps below, this never calls out to a replacementsProvider —
 * there's nothing here that can run long enough to make holding the session
 * lock across it a problem, so it stays a single short transaction.
 */
export async function replaceQueue(
  db: Db,
  sessionId: string,
  picks: ReplacementPick[],
  addedBy: 'dj' | 'user',
): Promise<number> {
  return db.transaction(async (tx) => {
    const [session] = await tx.select().from(djSessions).where(eq(djSessions.id, sessionId)).for('update')
    if (!session) throw new Error('queue-store: session not found')

    await tx.delete(queueTracks).where(eq(queueTracks.sessionId, sessionId))

    if (picks.length > 0) {
      await tx.insert(queueTracks).values(
        picks.map((p, i) => ({
          sessionId,
          position: i,
          trackId: p.trackId,
          reason: p.reason,
          addedBy,
        })),
      )
    }

    const newVersion = session.queueVersion + 1
    await tx.update(djSessions).set({ queueVersion: newVersion }).where(eq(djSessions.id, sessionId))
    return newVersion
  })
}

export async function getActiveQueue(db: Db, sessionId: string): Promise<QueueTrackView[]> {
  return db
    .select({
      position: queueTracks.position,
      trackId: queueTracks.trackId,
      appleId: tracks.appleId,
      title: tracks.title,
      artist: tracks.artist,
      reason: queueTracks.reason,
      durationMs: tracks.durationMs,
    })
    .from(queueTracks)
    .innerJoin(tracks, eq(tracks.id, queueTracks.trackId))
    .where(and(eq(queueTracks.sessionId, sessionId), eq(queueTracks.state, 'active')))
    .orderBy(asc(queueTracks.position))
}

// A slot in the working queue, tracked through an op batch so later ops see
// the list as it would stand after earlier ones (remove closes a gap, move
// reorders — a later position/from/to is relative to THAT list, not the
// original snapshot). 'keep' references an existing DB row untouched by this
// batch, optionally flagged with a PENDING swap (the row stays exactly what
// it is — id/trackId/reason/originalPosition unchanged — until a real
// replacement resolves at materialize time; see the swap-shortfall note
// there). 'pendingExtend' is a placeholder for an appended track the
// replacementsProvider hasn't been asked for yet.
type WorkingSlot =
  | {
      kind: 'keep'
      id: string
      trackId: string
      reason: string | null
      originalPosition: number
      pendingSwap?: { opIndex: number }
    }
  | { kind: 'pendingExtend'; opIndex: number }

export type PlanRequest = {
  opIndex: number
  kind: 'swap' | 'extend'
  count: number
  intent?: OpIntent
}

export type Plan = {
  working: WorkingSlot[]
  removedIds: string[]
  requests: PlanRequest[]
}

// Scans the FINAL working list (after every op has run) for which
// swap/extend placeholders actually survived to the end of the batch, and
// asks the provider for exactly that many — never for a placeholder a later
// op in the same batch went on to remove or overwrite. This is what makes a
// batch like [swap(0), remove(0)] cost zero provider calls instead of one:
// the swap's placeholder never makes it into the final working list, so no
// request is ever generated for it.
function computeRequests(working: WorkingSlot[], ops: QueueOp[]): PlanRequest[] {
  const seenSwapOpIndexes = new Set<number>()
  const extendCounts = new Map<number, number>()
  for (const slot of working) {
    if (slot.kind === 'keep' && slot.pendingSwap) {
      seenSwapOpIndexes.add(slot.pendingSwap.opIndex)
    } else if (slot.kind === 'pendingExtend') {
      extendCounts.set(slot.opIndex, (extendCounts.get(slot.opIndex) ?? 0) + 1)
    }
  }
  const requests: PlanRequest[] = []
  for (const opIndex of seenSwapOpIndexes) {
    const op = ops[opIndex] as Extract<QueueOp, { op: 'swap' }>
    requests.push({ opIndex, kind: 'swap', count: 1, intent: op.intent })
  }
  for (const [opIndex, count] of extendCounts) {
    const op = ops[opIndex] as Extract<QueueOp, { op: 'extend' }>
    requests.push({ opIndex, kind: 'extend', count, intent: op.intent })
  }
  // Deterministic order (the order the ops themselves were issued in) —
  // matters for tests asserting call order / intent forwarding, and makes
  // provider call order predictable for callers in general.
  requests.sort((a, b) => a.opIndex - b.opIndex)
  return requests
}

/**
 * Pure planning step, shared by both phases of applyOps (see below): given
 * the queue's current active rows (ordered by position) and an op batch,
 * validates every op against that state — a single forward pass, because an
 * out-of-range position/from/to can only be judged against the list AS IT
 * WOULD STAND after the ops before it (remove closes a gap, move reorders).
 * Throws QueueOpError on the first invalid op; nothing is mutated by a throw
 * (this function touches nothing outside its own local `working` array — no
 * DB, no provider).
 *
 * swap/extend never resolve a real track here — they only leave a
 * placeholder (`pendingSwap` / `pendingExtend`) in `working` — and a swap
 * NEVER removes its target row here either, no matter how the op reads;
 * removal only happens once a real replacement has actually been resolved
 * (see materialize). `requests` reports exactly what a replacementsProvider
 * would need to be called with to resolve every placeholder that survived
 * to the end of the batch.
 */
export function planOps(
  currentRows: Array<{ id: string; trackId: string; reason: string | null }>,
  ops: QueueOp[],
): Plan {
  let working: WorkingSlot[] = currentRows.map((r, i) => ({
    kind: 'keep',
    id: r.id,
    trackId: r.trackId,
    reason: r.reason,
    originalPosition: i,
  }))
  const removedIds: string[] = []

  for (let opIndex = 0; opIndex < ops.length; opIndex++) {
    const op = ops[opIndex]
    if (op.op === 'remove') {
      if (op.position < 0 || op.position >= working.length) throw new QueueOpError()
      const [removed] = working.splice(op.position, 1)
      // A 'pendingExtend' placeholder removed here was never persisted —
      // nothing to mark removed in the DB for it.
      if (removed.kind === 'keep') removedIds.push(removed.id)
    } else if (op.op === 'move') {
      if (op.from < 0 || op.from >= working.length || op.to < 0 || op.to >= working.length) throw new QueueOpError()
      const [item] = working.splice(op.from, 1)
      working.splice(op.to, 0, item)
    } else if (op.op === 'swap') {
      if (op.position < 0 || op.position >= working.length) throw new QueueOpError()
      const target = working[op.position]
      // Swapping a still-pending extend placeholder from earlier in this
      // same batch isn't a meaningful operation (there's no established row
      // there to replace yet) — treated as a silent no-op rather than an
      // error, since the position itself is legitimately in range.
      if (target.kind === 'keep') {
        // Overwrites any earlier pendingSwap on this same slot (a double
        // swap on one position) — only the LAST swap in the batch ever
        // generates a request; the discarded one costs nothing.
        working[op.position] = { ...target, pendingSwap: { opIndex } }
      }
    } else if (op.op === 'extend') {
      for (let i = 0; i < op.count; i++) working.push({ kind: 'pendingExtend', opIndex })
    }
  }

  return { working, removedIds, requests: computeRequests(working, ops) }
}

type MaterializeResult = {
  finalRemovedIds: string[]
  toInsert: Array<{ position: number; trackId: string; reason: string }>
  positionUpdates: Array<{ id: string; position: number }>
  added: number
}

/**
 * Turns a Plan plus already-fetched provider picks into concrete writes.
 * Pure and synchronous — no provider calls here, only ones already resolved
 * into `picksByOpIndex` (keyed by the op's index in the original ops array).
 *
 * Shortfall and duplicate handling live here, not in planOps, because both
 * depend on what the provider actually returned:
 *  - A swap with no usable pick (provider returned nothing, or its one pick
 *    duplicates a track already active elsewhere in the queue) leaves the
 *    ORIGINAL row exactly where it was — never delete a track on the
 *    strength of a replacement that doesn't exist.
 *  - An extend that under-returns just appends whatever arrived; unresolved
 *    placeholders are dropped without shifting the position counter, so the
 *    final list stays gap-free (0..len-1).
 *  - Any pick — swap or extend — whose trackId is already active elsewhere
 *    in the (surviving) queue is skipped the same way, counted as a
 *    shortfall rather than silently inserted: the store is the one place
 *    that holds the "no duplicate active track in a queue" invariant, since
 *    neither the schema nor the caller can enforce it.
 */
function materialize(
  working: WorkingSlot[],
  removedIds: string[],
  picksByOpIndex: Map<number, ReplacementPick[]>,
): MaterializeResult {
  const finalRemovedIds = [...removedIds]
  const toInsert: Array<{ position: number; trackId: string; reason: string }> = []
  const positionUpdates: Array<{ id: string; position: number }> = []
  const active = new Set(
    working.filter((s): s is Extract<WorkingSlot, { kind: 'keep' }> => s.kind === 'keep').map((s) => s.trackId),
  )
  const extendCursors = new Map<number, number>()
  let added = 0
  let position = 0

  for (const slot of working) {
    if (slot.kind === 'keep') {
      if (slot.pendingSwap) {
        const picks = picksByOpIndex.get(slot.pendingSwap.opIndex) ?? []
        const pick = picks[0]
        if (pick && !active.has(pick.trackId)) {
          finalRemovedIds.push(slot.id)
          active.delete(slot.trackId)
          active.add(pick.trackId)
          toInsert.push({
            position,
            trackId: pick.trackId,
            reason: pick.reason,
          })
          added += 1
          position += 1
          continue
        }
        // Falls through to the plain 'keep' handling below: original row,
        // original identity, untouched.
      }
      if (slot.originalPosition !== position) positionUpdates.push({ id: slot.id, position })
      position += 1
    } else {
      const cursor = extendCursors.get(slot.opIndex) ?? 0
      extendCursors.set(slot.opIndex, cursor + 1)
      const picks = picksByOpIndex.get(slot.opIndex) ?? []
      const pick = picks[cursor]
      if (pick && !active.has(pick.trackId)) {
        active.add(pick.trackId)
        toInsert.push({ position, trackId: pick.trackId, reason: pick.reason })
        added += 1
        position += 1
      }
      // else: under-return or duplicate — dropped silently, position does
      // not advance.
    }
  }

  return { finalRemovedIds, toInsert, positionUpdates, added }
}

async function readActiveRows(db: Db, sessionId: string) {
  return db
    .select({
      id: queueTracks.id,
      trackId: queueTracks.trackId,
      reason: queueTracks.reason,
    })
    .from(queueTracks)
    .where(and(eq(queueTracks.sessionId, sessionId), eq(queueTracks.state, 'active')))
    .orderBy(asc(queueTracks.position))
}

/**
 * Applies a batch of queue ops. Runs in two phases because a
 * replacementsProvider call (curation — an LLM round trip) can take
 * 10-30 seconds, and this used to hold `SELECT ... FOR UPDATE` on the
 * session row across that whole call. That was a probed deadlock: the
 * provider itself needs the database (curate()'s candidate-pool query), so
 * a provider invoked from inside the lock could be waiting on a connection
 * this same lock was starving — and even without that, a 10-30s per-session
 * write lock is not an acceptable cost for every swap/extend.
 *
 * Phase 1 (no transaction, no lock): read the session's current
 * queueVersion and active queue, plan the batch (planOps — pure, throws
 * QueueOpError on an invalid op before anything else happens), and call the
 * replacementsProvider for whatever the plan says survived to be resolved.
 * If the provider throws, nothing has been written and no transaction was
 * ever opened — the caller sees a clean throw.
 *
 * Phase 2 (a short, locked transaction): `SELECT ... FROM dj_sessions WHERE
 * id = $1 FOR UPDATE`, then re-read queueVersion. If it moved since phase
 * 1's snapshot, something else wrote to this queue in the gap — phase 1 had
 * no lock to prevent that — so this throws QueueVersionConflict rather than
 * silently overwriting a write it never saw. That's a deliberate trade:
 * detecting a rare cross-phase race and asking the caller to retry the
 * whole turn is a better cost than a lock that spans an LLM call. When the
 * version still matches, the active queue is re-read (now under the lock)
 * and re-planned — this should reproduce the SAME plan phase 1 saw, since
 * nothing could have changed it without bumping the version — and the
 * already-fetched picks are spliced into that plan (materialize) rather
 * than fetched again, so the provider is called exactly once, only in
 * phase 1, no matter how phase 2's re-read comes back.
 *
 * `expectedVersion`, if given, is checked up front in phase 1 too (the
 * manual queue-ops route passes the client's last-known version here) —
 * failing fast on an already-stale version before doing any planning or
 * spending a provider call on it.
 */
export async function applyOps(
  db: Db,
  sessionId: string,
  ops: QueueOp[],
  actor: 'dj' | 'user',
  replacementsProvider?: ReplacementsProvider,
  expectedVersion?: number,
): Promise<ApplyOpsResult> {
  const [snapshot] = await db
    .select({ queueVersion: djSessions.queueVersion })
    .from(djSessions)
    .where(eq(djSessions.id, sessionId))
  if (!snapshot) throw new Error('queue-store: session not found')
  if (expectedVersion !== undefined && snapshot.queueVersion !== expectedVersion) throw new QueueVersionConflict()

  const snapshotRows = await readActiveRows(db, sessionId)
  const { requests } = planOps(snapshotRows, ops)
  if (requests.length > 0 && !replacementsProvider) throw new QueueOpError()

  // Sequential by design: each request is a separate curation call, and
  // there's no lock held here to rush past.
  const picksByOpIndex = new Map<number, ReplacementPick[]>()
  for (const req of requests) {
    picksByOpIndex.set(req.opIndex, await replacementsProvider!(req.count, req.intent))
  }
  const requested = requests.reduce((sum, r) => sum + r.count, 0)

  return db.transaction(async (tx) => {
    const [session] = await tx.select().from(djSessions).where(eq(djSessions.id, sessionId)).for('update')
    if (!session) throw new Error('queue-store: session not found')
    if (session.queueVersion !== snapshot.queueVersion) throw new QueueVersionConflict()

    const currentRows = await readActiveRows(tx, sessionId)
    const { working, removedIds } = planOps(currentRows, ops)
    const { finalRemovedIds, toInsert, positionUpdates, added } = materialize(working, removedIds, picksByOpIndex)

    if (finalRemovedIds.length > 0) {
      await tx
        .update(queueTracks)
        .set({ state: 'removed', removedBy: actor })
        .where(inArray(queueTracks.id, finalRemovedIds))
    }

    // Single bulk statement, only for rows whose position actually changed —
    // avoids both N per-row round trips and touching updatedAt on rows this
    // batch didn't move. Raw SQL (not the query builder) is fine here
    // specifically because it's the one write where $onUpdate's automatic
    // updatedAt bump doesn't apply — so updated_at is set explicitly instead.
    if (positionUpdates.length > 0) {
      const rows = sql.join(
        positionUpdates.map((u) => sql`(${u.id}::uuid, ${u.position}::int)`),
        sql`, `,
      )
      await tx.execute(sql`
        UPDATE queue_tracks AS qt
        SET position = v.position, updated_at = now()
        FROM (VALUES ${rows}) AS v(id, position)
        WHERE qt.id = v.id
      `)
    }

    if (toInsert.length > 0) {
      await tx.insert(queueTracks).values(
        toInsert.map((row) => ({
          sessionId,
          position: row.position,
          trackId: row.trackId,
          reason: row.reason,
          addedBy: actor,
        })),
      )
    }

    const newVersion = session.queueVersion + 1
    await tx.update(djSessions).set({ queueVersion: newVersion }).where(eq(djSessions.id, sessionId))
    return {
      version: newVersion,
      requested,
      added,
      removed: finalRemovedIds.length,
    }
  })
}
