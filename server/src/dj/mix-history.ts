import { and, asc, desc, eq, inArray, lt } from 'drizzle-orm'
import type { Db } from '../db/types'
import { djSessions, mixVersions, queueTracks, tracks, trackFeatures } from '../db/schema'

import { evaluateEnergyJourney, type EnergyArc } from './energy-journey'

export class MixHistoryError extends Error {
  constructor(public kind: 'not_found' | 'conflict' | 'unavailable') {
    super(`mix history: ${kind}`)
  }
}
const activeEntries = (db: Db, sessionId: string) =>
  db
    .select({
      position: queueTracks.position,
      trackId: queueTracks.trackId,
      reason: queueTracks.reason,
      addedBy: queueTracks.addedBy,
    })
    .from(queueTracks)
    .where(
      and(
        eq(queueTracks.sessionId, sessionId),
        eq(queueTracks.state, 'active'),
      ),
    )
    .orderBy(asc(queueTracks.position))

// Caller holds the session lock. Both the snapshot and mutation share its transaction.
export async function captureMixVersion(
  db: Db,
  sessionId: string,
  version: number,
  energyArc?: EnergyArc | null,
) {
  if (version < 1) return
  const [existing] = await db
    .select({ version: mixVersions.version })
    .from(mixVersions)
    .where(
      and(
        eq(mixVersions.sessionId, sessionId),
        eq(mixVersions.version, version),
      ),
    )
  if (existing) return
  const entries = await activeEntries(db, sessionId)
  if (energyArc === undefined) {
    const [previous] = await db.select({ energyArc: mixVersions.energyArc }).from(mixVersions)
      .where(and(eq(mixVersions.sessionId, sessionId), lt(mixVersions.version, version)))
      .orderBy(desc(mixVersions.version)).limit(1)
    energyArc = previous?.energyArc ?? null
  }
  const features = energyArc && entries.length ? await db.select({ id: trackFeatures.trackId, energy: trackFeatures.energy })
    .from(trackFeatures).where(inArray(trackFeatures.trackId, entries.map(e => e.trackId))) : []
  const byId = new Map(features.map(f => [f.id, f.energy]))
  const energyJourney = energyArc ? evaluateEnergyJourney(energyArc, entries.map(e => byId.get(e.trackId) ?? null)) : null
  await db.insert(mixVersions).values({ sessionId, version, entries, energyArc, energyJourney })
}
async function owned(db: Db, sessionId: string, userId: string) {
  const [session] = await db
    .select()
    .from(djSessions)
    .where(and(eq(djSessions.id, sessionId), eq(djSessions.userId, userId)))
    .for('update')
  if (!session) throw new MixHistoryError('not_found')
  return session
}
async function snapshot(
  db: Db,
  session: typeof djSessions.$inferSelect,
  version: number,
) {
  const [saved] = await db
    .select()
    .from(mixVersions)
    .where(
      and(
        eq(mixVersions.sessionId, session.id),
        eq(mixVersions.version, version),
      ),
    )
  if (saved) return saved
  if (version < 1 || version !== session.queueVersion)
    throw new MixHistoryError('not_found')
  return {
    sessionId: session.id,
    version,
    entries: await activeEntries(db, session.id),
    energyArc: null,
    energyJourney: null,
    restoredFrom: null,
    requestId: null,
    expectedVersion: null,
    createdAt: session.updatedAt,
  }
}
export async function listMixVersions(
  db: Db,
  sessionId: string,
  userId: string,
  before?: number,
) {
  return db.transaction(async (tx) => {
    const session = await owned(tx, sessionId, userId)
    const saved = await tx
      .select()
      .from(mixVersions)
      .where(
        and(
          eq(mixVersions.sessionId, sessionId),
          before === undefined ? undefined : lt(mixVersions.version, before),
        ),
      )
      .orderBy(desc(mixVersions.version))
      .limit(51)
    if (
      session.queueVersion > 0 &&
      (before === undefined || session.queueVersion < before) &&
      !saved.some((v) => v.version === session.queueVersion)
    ) {
      saved.unshift(await snapshot(tx, session, session.queueVersion))
    }
    const page = saved.slice(0, 50)
    return {
      currentVersion: session.queueVersion,
      versions: page.map((v) => ({
        version: v.version,
        trackCount: v.entries.length,
        restoredFrom: v.restoredFrom,
        createdAt: v.createdAt,
      })),
      nextBefore: saved.length > 50 ? page.at(-1)!.version : null,
    }
  })
}
export async function readMixVersion(
  db: Db,
  sessionId: string,
  userId: string,
  version: number,
) {
  return db.transaction(async (tx) => {
    const session = await owned(tx, sessionId, userId)
    const saved = await snapshot(tx, session, version)
    const ids = saved.entries.map((e) => e.trackId)
    const songs = ids.length
      ? await tx.select().from(tracks).where(inArray(tracks.id, ids))
      : []
    const byId = new Map(songs.map((s) => [s.id, s]))
    return {
      energyArc: saved.energyArc,
      energyJourney: saved.energyJourney,
      version: saved.version,
      currentVersion: session.queueVersion,
      restoredFrom: saved.restoredFrom,
      entries: saved.entries.map((e) => ({
        ...e,
        title: byId.get(e.trackId)?.title ?? 'Unavailable recording',
        artist: byId.get(e.trackId)?.artist ?? '',
        available: byId.has(e.trackId),
      })),
    }
  })
}
export async function restoreMixVersion(
  db: Db,
  sessionId: string,
  userId: string,
  input: { version: number; expectedVersion: number; requestId: string },
) {
  return db.transaction(async (tx) => {
    const session = await owned(tx, sessionId, userId)
    const [replay] = await tx
      .select()
      .from(mixVersions)
      .where(
        and(
          eq(mixVersions.sessionId, sessionId),
          eq(mixVersions.requestId, input.requestId),
        ),
      )
    if (replay) {
      if (
        replay.restoredFrom !== input.version ||
        replay.expectedVersion !== input.expectedVersion
      )
        throw new MixHistoryError('conflict')
      return { version: replay.version }
    }
    if (session.queueVersion !== input.expectedVersion)
      throw new MixHistoryError('conflict')
    const source = await snapshot(tx, session, input.version)
    const ids = source.entries.map((e) => e.trackId)
    const existing = ids.length
      ? await tx
          .select({ id: tracks.id })
          .from(tracks)
          .where(inArray(tracks.id, ids))
          .for('share')
      : []
    if (existing.length !== new Set(ids).size)
      throw new MixHistoryError('unavailable')
    await captureMixVersion(tx, sessionId, session.queueVersion)
    // Keep existing removed rows: restore is not a new rejection or listening event.
    await tx
      .delete(queueTracks)
      .where(
        and(
          eq(queueTracks.sessionId, sessionId),
          eq(queueTracks.state, 'active'),
        ),
      )
    if (source.entries.length)
      await tx
        .insert(queueTracks)
        .values(source.entries.map((e) => ({ ...e, sessionId })))
    const version = session.queueVersion + 1
    await tx
      .update(djSessions)
      .set({ queueVersion: version })
      .where(eq(djSessions.id, sessionId))
    await tx
      .insert(mixVersions)
      .values({
        sessionId,
        version,
        entries: source.entries,
        energyArc: source.energyArc,
        energyJourney: source.energyJourney,
        restoredFrom: input.version,
        expectedVersion: input.expectedVersion,
        requestId: input.requestId,
      })
    return { version }
  })
}
