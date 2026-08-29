import { describe, it, expect } from "vitest";
import { eq } from "drizzle-orm";
import { createTestDb, type TestDb } from "../helpers/db";
import {
  replaceQueue,
  getActiveQueue,
  applyOps,
  QueueOpError,
  type ReplacementPick,
} from "../../src/dj/queue-store";
import { djSessions, queueTracks, tracks, user } from "../../src/db/schema";

async function seedUser(db: TestDb, id: string) {
  await db.insert(user).values({
    id,
    name: id,
    email: `${id}@example.com`,
    emailVerified: false,
    createdAt: new Date(),
    updatedAt: new Date(),
  });
}

async function seedSession(db: TestDb, userId: string, title = "session") {
  const [s] = await db.insert(djSessions).values({ userId, title }).returning();
  return s;
}

let trackCounter = 0;

async function seedTrack(db: TestDb, opts: { durationMs?: number } = {}) {
  trackCounter += 1;
  const label = `T${trackCounter}`;
  const [t] = await db
    .insert(tracks)
    .values({
      appleId: `apple-${label}`,
      title: label,
      artist: "Artist",
      durationMs: opts.durationMs ?? 200_000,
    })
    .returning();
  return t;
}

async function seedTracks(db: TestDb, n: number) {
  const out = [];
  for (let i = 0; i < n; i++) out.push(await seedTrack(db));
  return out;
}

function picksFrom(
  trackList: { id: string }[],
  reasonPrefix = "r",
): ReplacementPick[] {
  return trackList.map((t, i) => ({
    trackId: t.id,
    reason: `${reasonPrefix}${i}`,
  }));
}

describe("queue-store", () => {
  describe("replaceQueue", () => {
    it("writes tracks at positions 0..n-1 and bumps queueVersion to 1", async () => {
      const db = await createTestDb();
      await seedUser(db, "u1");
      const session = await seedSession(db, "u1");
      const trackList = await seedTracks(db, 3);

      const version = await replaceQueue(
        db,
        session.id,
        picksFrom(trackList),
        "dj",
      );

      expect(version).toBe(1);
      const rows = await db
        .select()
        .from(queueTracks)
        .where(eq(queueTracks.sessionId, session.id))
        .orderBy(queueTracks.position);
      expect(rows.map((r) => r.position)).toEqual([0, 1, 2]);
      expect(rows.map((r) => r.trackId)).toEqual(trackList.map((t) => t.id));
      expect(rows.every((r) => r.state === "active")).toBe(true);
      expect(rows.every((r) => r.addedBy === "dj")).toBe(true);
      expect(rows[0].reason).toBe("r0");

      const [updatedSession] = await db
        .select()
        .from(djSessions)
        .where(eq(djSessions.id, session.id));
      expect(updatedSession.queueVersion).toBe(1);
    });

    it("hard-deletes prior rows on a second replace — no history survives", async () => {
      const db = await createTestDb();
      await seedUser(db, "u1");
      const session = await seedSession(db, "u1");
      const firstTracks = await seedTracks(db, 2);
      const secondTracks = await seedTracks(db, 2);

      const v1 = await replaceQueue(
        db,
        session.id,
        picksFrom(firstTracks),
        "dj",
      );
      // Remove one via ops so a 'removed' row exists in history before the second replace.
      await applyOps(db, session.id, [{ op: "remove", position: 0 }], "user");

      const v2 = await replaceQueue(
        db,
        session.id,
        picksFrom(secondTracks),
        "dj",
      );

      expect(v1).toBe(1);
      expect(v2).toBe(3); // v1 (replace) -> 2 (the intervening remove) -> 3 (this replace)
      const rows = await db
        .select()
        .from(queueTracks)
        .where(eq(queueTracks.sessionId, session.id));
      expect(rows).toHaveLength(2);
      expect(rows.map((r) => r.trackId).sort()).toEqual(
        secondTracks.map((t) => t.id).sort(),
      );
      expect(rows.every((r) => r.state === "active")).toBe(true);
    });
  });

  describe("getActiveQueue", () => {
    it("returns active rows ordered by position with joined track fields", async () => {
      const db = await createTestDb();
      await seedUser(db, "u1");
      const session = await seedSession(db, "u1");
      const trackList = await seedTracks(db, 3);
      await replaceQueue(db, session.id, picksFrom(trackList, "reason-"), "dj");
      await applyOps(db, session.id, [{ op: "remove", position: 1 }], "user");

      const view = await getActiveQueue(db, session.id);

      expect(view).toHaveLength(2);
      expect(view.map((v) => v.position)).toEqual([0, 1]);
      expect(view[0].trackId).toBe(trackList[0].id);
      expect(view[0].appleId).toBe(trackList[0].appleId);
      expect(view[0].title).toBe(trackList[0].title);
      expect(view[0].artist).toBe(trackList[0].artist);
      expect(view[0].reason).toBe("reason-0");
      expect(view[0].durationMs).toBe(trackList[0].durationMs);
      // trackList[1] was removed; trackList[2] renumbered to position 1.
      expect(view[1].trackId).toBe(trackList[2].id);
    });
  });

  describe("applyOps", () => {
    it("remove closes the gap and records removedBy", async () => {
      const db = await createTestDb();
      await seedUser(db, "u1");
      const session = await seedSession(db, "u1");
      const trackList = await seedTracks(db, 3);
      await replaceQueue(db, session.id, picksFrom(trackList), "dj");

      const version = await applyOps(
        db,
        session.id,
        [{ op: "remove", position: 0 }],
        "user",
      );

      expect(version).toBe(2);
      const view = await getActiveQueue(db, session.id);
      expect(view.map((v) => v.position)).toEqual([0, 1]);
      expect(view.map((v) => v.trackId)).toEqual([
        trackList[1].id,
        trackList[2].id,
      ]);

      const removedRows = await db
        .select()
        .from(queueTracks)
        .where(eq(queueTracks.sessionId, session.id));
      const removed = removedRows.find((r) => r.trackId === trackList[0].id)!;
      expect(removed.state).toBe("removed");
      expect(removed.removedBy).toBe("user");
    });

    it("move reorders the queue", async () => {
      const db = await createTestDb();
      await seedUser(db, "u1");
      const session = await seedSession(db, "u1");
      const trackList = await seedTracks(db, 3);
      await replaceQueue(db, session.id, picksFrom(trackList), "dj");

      await applyOps(db, session.id, [{ op: "move", from: 0, to: 2 }], "user");

      const view = await getActiveQueue(db, session.id);
      expect(view.map((v) => v.trackId)).toEqual([
        trackList[1].id,
        trackList[2].id,
        trackList[0].id,
      ]);
      expect(view.map((v) => v.position)).toEqual([0, 1, 2]);
    });

    it("out-of-range op in a multi-op batch throws QueueOpError and applies NOTHING", async () => {
      const db = await createTestDb();
      await seedUser(db, "u1");
      const session = await seedSession(db, "u1");
      const trackList = await seedTracks(db, 3);
      await replaceQueue(db, session.id, picksFrom(trackList), "dj");

      await expect(
        applyOps(
          db,
          session.id,
          [
            { op: "remove", position: 0 }, // valid on its own
            { op: "move", from: 5, to: 0 }, // out of range
          ],
          "user",
        ),
      ).rejects.toThrow(QueueOpError);

      const view = await getActiveQueue(db, session.id);
      expect(view.map((v) => v.trackId)).toEqual(trackList.map((t) => t.id));
      const [sessionRow] = await db
        .select()
        .from(djSessions)
        .where(eq(djSessions.id, session.id));
      expect(sessionRow.queueVersion).toBe(1);
    });

    it("swap replaces one track via the provider, marking the old row removed-not-deleted", async () => {
      const db = await createTestDb();
      await seedUser(db, "u1");
      const session = await seedSession(db, "u1");
      const trackList = await seedTracks(db, 3);
      const [replacement] = await seedTracks(db, 1);
      await replaceQueue(db, session.id, picksFrom(trackList), "dj");

      const provider = async (count: number) => {
        expect(count).toBe(1);
        return [{ trackId: replacement.id, reason: "fresh pick" }];
      };

      await applyOps(
        db,
        session.id,
        [{ op: "swap", position: 1 }],
        "dj",
        provider,
      );

      const view = await getActiveQueue(db, session.id);
      expect(view.map((v) => v.trackId)).toEqual([
        trackList[0].id,
        replacement.id,
        trackList[2].id,
      ]);
      expect(view[1].reason).toBe("fresh pick");

      const oldRow = (
        await db
          .select()
          .from(queueTracks)
          .where(eq(queueTracks.sessionId, session.id))
      ).find((r) => r.trackId === trackList[1].id)!;
      expect(oldRow.state).toBe("removed");
      expect(oldRow.removedBy).toBe("dj");

      const newRow = (
        await db
          .select()
          .from(queueTracks)
          .where(eq(queueTracks.sessionId, session.id))
      ).find((r) => r.trackId === replacement.id)!;
      expect(newRow.addedBy).toBe("dj");
    });

    it("extend appends tracks from the provider", async () => {
      const db = await createTestDb();
      await seedUser(db, "u1");
      const session = await seedSession(db, "u1");
      const trackList = await seedTracks(db, 2);
      const extras = await seedTracks(db, 2);
      await replaceQueue(db, session.id, picksFrom(trackList), "dj");

      const provider = async (count: number) => {
        expect(count).toBe(2);
        return picksFrom(extras, "extra-");
      };

      await applyOps(
        db,
        session.id,
        [{ op: "extend", count: 2 }],
        "dj",
        provider,
      );

      const view = await getActiveQueue(db, session.id);
      expect(view.map((v) => v.trackId)).toEqual([
        ...trackList.map((t) => t.id),
        ...extras.map((t) => t.id),
      ]);
      expect(view.map((v) => v.position)).toEqual([0, 1, 2, 3]);
      expect(view[2].reason).toBe("extra-0");
    });

    it("swap/extend without a replacementsProvider throws QueueOpError", async () => {
      const db = await createTestDb();
      await seedUser(db, "u1");
      const session = await seedSession(db, "u1");
      const trackList = await seedTracks(db, 2);
      await replaceQueue(db, session.id, picksFrom(trackList), "dj");

      await expect(
        applyOps(db, session.id, [{ op: "swap", position: 0 }], "dj"),
      ).rejects.toThrow(QueueOpError);
      await expect(
        applyOps(db, session.id, [{ op: "extend", count: 1 }], "dj"),
      ).rejects.toThrow(QueueOpError);

      const [sessionRow] = await db
        .select()
        .from(djSessions)
        .where(eq(djSessions.id, session.id));
      expect(sessionRow.queueVersion).toBe(1);
    });

    it("bumps queueVersion exactly once for a multi-op batch", async () => {
      const db = await createTestDb();
      await seedUser(db, "u1");
      const session = await seedSession(db, "u1");
      const trackList = await seedTracks(db, 4);
      const extra = await seedTracks(db, 1);
      await replaceQueue(db, session.id, picksFrom(trackList), "dj");

      const provider = async () => picksFrom(extra, "e-");

      const version = await applyOps(
        db,
        session.id,
        [
          { op: "remove", position: 0 },
          { op: "move", from: 0, to: 1 },
          { op: "extend", count: 1 },
        ],
        "dj",
        provider,
      );

      expect(version).toBe(2);
    });

    it("renumbers positions to exactly 0..len-1 with no duplicates after an arbitrary op sequence", async () => {
      const db = await createTestDb();
      await seedUser(db, "u1");
      const session = await seedSession(db, "u1");
      const trackList = await seedTracks(db, 5);
      const extras = await seedTracks(db, 2);
      await replaceQueue(db, session.id, picksFrom(trackList), "dj");

      const provider = async (count: number) =>
        picksFrom(extras.slice(0, count), "p-");

      await applyOps(
        db,
        session.id,
        [
          { op: "remove", position: 4 },
          { op: "move", from: 0, to: 2 },
          { op: "swap", position: 1 },
          { op: "extend", count: 2 },
        ],
        "dj",
        provider,
      );

      const view = await getActiveQueue(db, session.id);
      const positions = view.map((v) => v.position);
      expect(positions).toEqual(
        Array.from({ length: positions.length }, (_, i) => i),
      );
      expect(new Set(positions).size).toBe(positions.length);
    });

    it("two sequential applyOps calls leave the queue with consistent, gap-free positions", async () => {
      const db = await createTestDb();
      await seedUser(db, "u1");
      const session = await seedSession(db, "u1");
      const trackList = await seedTracks(db, 4);
      await replaceQueue(db, session.id, picksFrom(trackList), "dj");

      await applyOps(db, session.id, [{ op: "remove", position: 0 }], "user");
      await applyOps(db, session.id, [{ op: "move", from: 0, to: 1 }], "user");

      const view = await getActiveQueue(db, session.id);
      const positions = view.map((v) => v.position);
      expect(positions).toEqual([0, 1, 2]);
      expect(new Set(positions).size).toBe(positions.length);
    });
  });
});
