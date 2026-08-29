import { and, asc, eq, inArray } from "drizzle-orm";
import type { Db } from "../db/types";
import { djSessions, queueTracks, tracks } from "../db/schema";
import type { OpIntent, QueueOp } from "./contracts";

export type QueueTrackView = {
  position: number;
  trackId: string;
  appleId: string | null;
  title: string;
  artist: string;
  reason: string | null;
  durationMs: number | null;
};

// Thrown when an op batch fails validation against the CURRENT queue state
// (an out-of-range position/from/to, or a swap/extend with no
// replacementsProvider). All-or-nothing: nothing in the batch is applied.
// Message is deliberately content-free (never echoes op fields or ids).
export class QueueOpError extends Error {
  constructor() {
    super("queue-store: invalid queue operation");
    this.name = "QueueOpError";
  }
}

export type ReplacementPick = { trackId: string; reason: string };

// The engine (Task 7), not the store, decides what a swap/extend actually
// plays — the store only knows how to splice picks into position order.
export type ReplacementsProvider = (
  count: number,
  intent?: OpIntent,
) => Promise<ReplacementPick[]>;

/**
 * Replaces a session's entire queue: hard-deletes every existing queue_tracks
 * row (active AND removed — history for a discarded queue lives in
 * dj_messages, not queue rows) and inserts `picks` at positions 0..n-1.
 * Bumps queueVersion once. Returns the new version.
 *
 * Runs under `SELECT ... FOR UPDATE` on the session row — see the lock note
 * on applyOps below; the same load-bearing reasons apply here.
 */
export async function replaceQueue(
  db: Db,
  sessionId: string,
  picks: ReplacementPick[],
  addedBy: "dj" | "user",
): Promise<number> {
  return db.transaction(async (tx) => {
    const [session] = await tx
      .select()
      .from(djSessions)
      .where(eq(djSessions.id, sessionId))
      .for("update");
    if (!session) throw new Error("queue-store: session not found");

    await tx.delete(queueTracks).where(eq(queueTracks.sessionId, sessionId));

    if (picks.length > 0) {
      await tx.insert(queueTracks).values(
        picks.map((p, i) => ({
          sessionId,
          position: i,
          trackId: p.trackId,
          reason: p.reason,
          addedBy,
        })),
      );
    }

    const newVersion = session.queueVersion + 1;
    await tx
      .update(djSessions)
      .set({ queueVersion: newVersion })
      .where(eq(djSessions.id, sessionId));
    return newVersion;
  });
}

export async function getActiveQueue(
  db: Db,
  sessionId: string,
): Promise<QueueTrackView[]> {
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
    .where(
      and(
        eq(queueTracks.sessionId, sessionId),
        eq(queueTracks.state, "active"),
      ),
    )
    .orderBy(asc(queueTracks.position));
}

// A position in the working queue, tracked through the op batch so later ops
// see the list as it would stand after earlier ones (remove closes a gap,
// move reorders — a later position/from/to is relative to THAT list, not the
// original). 'keep' references an existing DB row untouched by this batch;
// 'swap'/'extend' are placeholders for a track the replacementsProvider
// hasn't been asked for yet — provider calls only happen once every op in
// the batch has validated, never before (see applyOps).
type WorkingSlot =
  | { kind: "keep"; id: string; trackId: string; reason: string | null }
  | { kind: "swap"; swapOpIdx: number }
  | { kind: "extend"; extendOpIdx: number; pickIdx: number };

/**
 * Applies a batch of queue ops atomically: validates every op against the
 * CURRENT queue state first (all-or-nothing — the first out-of-range
 * position/from/to throws QueueOpError before anything is written or any
 * replacement track is fetched), then applies the whole batch and bumps
 * queueVersion exactly once.
 *
 * Runs inside `SELECT ... FROM dj_sessions WHERE id = $1 FOR UPDATE` in a
 * `db.transaction`. This lock is load-bearing beyond serializing position
 * writes: dj_messages.seq (bigserial) is read elsewhere to order transcript
 * history, and without a per-session write lock a lower seq can commit after
 * a higher one under concurrent writers, corrupting that ordering. Locking
 * here — the one place every queue mutation passes through — closes that
 * window for queue-driven writes.
 */
export async function applyOps(
  db: Db,
  sessionId: string,
  ops: QueueOp[],
  actor: "dj" | "user",
  replacementsProvider?: ReplacementsProvider,
): Promise<number> {
  const needsProvider = ops.some(
    (op) => op.op === "swap" || op.op === "extend",
  );
  if (needsProvider && !replacementsProvider) throw new QueueOpError();

  return db.transaction(async (tx) => {
    const [session] = await tx
      .select()
      .from(djSessions)
      .where(eq(djSessions.id, sessionId))
      .for("update");
    if (!session) throw new Error("queue-store: session not found");

    const currentRows = await tx
      .select({
        id: queueTracks.id,
        trackId: queueTracks.trackId,
        reason: queueTracks.reason,
      })
      .from(queueTracks)
      .where(
        and(
          eq(queueTracks.sessionId, sessionId),
          eq(queueTracks.state, "active"),
        ),
      )
      .orderBy(asc(queueTracks.position));

    let working: WorkingSlot[] = currentRows.map((r) => ({
      kind: "keep",
      id: r.id,
      trackId: r.trackId,
      reason: r.reason,
    }));
    const removedIds: string[] = [];
    const extendCounters: number[] = []; // per extend-op-index running pick counter
    let extendOpIdx = -1;
    let swapOpIdx = -1;

    // Single forward pass: validates bounds AND simulates the reorder in one
    // step, because the two can't be separated — whether a later op's
    // position is in range depends on what earlier ops in THIS batch already
    // did to the list. Nothing outside `working`/`removedIds` is touched
    // (no provider calls, no DB writes) until every op here has validated.
    for (const op of ops) {
      if (op.op === "remove") {
        if (op.position < 0 || op.position >= working.length)
          throw new QueueOpError();
        const [removed] = working.splice(op.position, 1);
        if (removed.kind === "keep") removedIds.push(removed.id);
        // 'swap'/'extend' slots removed here were never persisted — nothing to mark removed.
      } else if (op.op === "move") {
        if (
          op.from < 0 ||
          op.from >= working.length ||
          op.to < 0 ||
          op.to >= working.length
        )
          throw new QueueOpError();
        const [item] = working.splice(op.from, 1);
        working.splice(op.to, 0, item);
      } else if (op.op === "swap") {
        if (op.position < 0 || op.position >= working.length)
          throw new QueueOpError();
        const target = working[op.position];
        if (target.kind === "keep") removedIds.push(target.id);
        swapOpIdx += 1;
        working[op.position] = { kind: "swap", swapOpIdx };
      } else if (op.op === "extend") {
        extendOpIdx += 1;
        extendCounters[extendOpIdx] = 0;
        for (let i = 0; i < op.count; i++) {
          working.push({
            kind: "extend",
            extendOpIdx,
            pickIdx: extendCounters[extendOpIdx]++,
          });
        }
      }
    }

    // Every op validated — now, and only now, fetch replacements. Called
    // once per swap/extend op, in the order those ops appeared.
    const swapPicks: ReplacementPick[][] = [];
    const extendPicks: ReplacementPick[][] = [];
    for (const op of ops) {
      if (op.op === "swap") {
        swapPicks.push(await replacementsProvider!(1, op.intent));
      } else if (op.op === "extend") {
        extendPicks.push(await replacementsProvider!(op.count, op.intent));
      }
    }

    if (removedIds.length > 0) {
      await tx
        .update(queueTracks)
        .set({ state: "removed", removedBy: actor })
        .where(inArray(queueTracks.id, removedIds));
    }

    const toInsert: Array<{
      position: number;
      trackId: string;
      reason: string;
    }> = [];
    let position = 0;
    for (const slot of working) {
      if (slot.kind === "keep") {
        await tx
          .update(queueTracks)
          .set({ position })
          .where(eq(queueTracks.id, slot.id));
        position += 1;
      } else if (slot.kind === "swap") {
        const pick = swapPicks[slot.swapOpIdx]?.[0];
        if (pick) {
          toInsert.push({
            position,
            trackId: pick.trackId,
            reason: pick.reason,
          });
          position += 1;
        }
      } else {
        const pick = extendPicks[slot.extendOpIdx]?.[slot.pickIdx];
        if (pick) {
          toInsert.push({
            position,
            trackId: pick.trackId,
            reason: pick.reason,
          });
          position += 1;
        }
      }
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
      );
    }

    const newVersion = session.queueVersion + 1;
    await tx
      .update(djSessions)
      .set({ queueVersion: newVersion })
      .where(eq(djSessions.id, sessionId));
    return newVersion;
  });
}
