import { and, eq, gt, lt, sql } from 'drizzle-orm'
import { z } from 'zod'
import type { Db } from '../db/types'
import {
  djSessions,
  mixVersions,
  playbackEvidence,
  playbackSettings,
  tracks,
} from '../db/schema'
import { captureMixVersion } from '../dj/mix-history'
export const observationSchema = z
  .object({
    playbackId: z.uuid(),
    sequence: z.number().int().min(0).max(100000),
    sessionId: z.uuid(),
    version: z.number().int().positive(),
    position: z.number().int().min(0).max(499),
    trackId: z.uuid(),
    source: z.enum(['apple_native', 'apple_web']),
    kind: z.enum(['listen', 'skip', 'repeat']),
    observedMs: z.number().int().min(0).max(3600000),
    occurredAt: z.iso.datetime(),
  })
  .strict()
export const batchSchema = z
  .object({
    revision: z.number().int().min(0),
    events: z.array(observationSchema).min(1).max(20),
  })
  .strict()
export class PlaybackError extends Error {
  constructor(public status: 400 | 404 | 409 | 429) {
    super('playback evidence rejected')
  }
}
async function locked(db: Db, userId: string) {
  await db.insert(playbackSettings).values({ userId }).onConflictDoNothing()
  const [settings] = await db
    .select()
    .from(playbackSettings)
    .where(eq(playbackSettings.userId, userId))
    .for('update')
  return settings
}
const publicSettings = (s: typeof playbackSettings.$inferSelect) => ({
  enabled: s.enabled,
  revision: s.revision,
})
export async function playbackPreferences(db: Db, userId: string) {
  const [settings] = await db
    .select()
    .from(playbackSettings)
    .where(eq(playbackSettings.userId, userId))
  return settings ? publicSettings(settings) : { enabled: false, revision: 0 }
}
export async function savePlaybackPreference(
  db: Db,
  userId: string,
  enabled: boolean,
) {
  return db.transaction(async (tx) => {
    const settings = await locked(tx, userId)
    if (settings.enabled === enabled) return publicSettings(settings)
    const [next] = await tx
      .update(playbackSettings)
      .set({ enabled, revision: settings.revision + 1 })
      .where(eq(playbackSettings.userId, userId))
      .returning()
    return publicSettings(next)
  })
}
export async function clearPlaybackEvidence(
  db: Db,
  userId: string,
  requestId: string,
  expectedRevision?: number,
) {
  return db.transaction(async (tx) => {
    const settings = await locked(tx, userId)
    if (settings.lastClearId === requestId) return publicSettings(settings)
    if (
      expectedRevision !== undefined &&
      settings.revision !== expectedRevision
    )
      throw new PlaybackError(409)
    await tx.delete(playbackEvidence).where(eq(playbackEvidence.userId, userId))
    const [next] = await tx
      .update(playbackSettings)
      .set({ revision: settings.revision + 1, lastClearId: requestId })
      .where(eq(playbackSettings.userId, userId))
      .returning()
    return publicSettings(next)
  })
}
export async function ingestPlayback(
  db: Db,
  userId: string,
  input: z.infer<typeof batchSchema>,
) {
  const parsed = batchSchema.safeParse(input)
  if (!parsed.success) throw new PlaybackError(400)
  return db.transaction(async (tx) => {
    const settings = await locked(tx, userId)
    if (!settings.enabled || settings.revision !== input.revision)
      throw new PlaybackError(409)
    const now = Date.now()
    await tx
      .delete(playbackEvidence)
      .where(
        and(
          eq(playbackEvidence.userId, userId),
          lt(playbackEvidence.occurredAt, new Date(now - 90 * 86400000)),
        ),
      )
    const [{ count }] = await tx
      .select({ count: sql<number>`count(*)::int` })
      .from(playbackEvidence)
      .where(
        and(
          eq(playbackEvidence.userId, userId),
          gt(playbackEvidence.createdAt, new Date(now - 86400000)),
        ),
      )
    if (count + input.events.length > 500) throw new PlaybackError(429)
    // Stable lock order for batches spanning mixes, matching queue/history writers.
    const owned = new Map<string, typeof djSessions.$inferSelect>()
    for (const id of [
      ...new Set(input.events.map((e) => e.sessionId)),
    ].sort()) {
      const [session] = await tx
        .select()
        .from(djSessions)
        .where(and(eq(djSessions.id, id), eq(djSessions.userId, userId)))
        .for('update')
      if (!session) throw new PlaybackError(404)
      owned.set(id, session)
    }
    for (const event of input.events) {
      const occurredAt = new Date(event.occurredAt)
      if (
        occurredAt.getTime() > now + 300000 ||
        occurredAt.getTime() < now - 7 * 86400000
      )
        throw new PlaybackError(400)
      const session = owned.get(event.sessionId)!
      if (session.queueVersion === event.version)
        await captureMixVersion(tx, event.sessionId, event.version)
      const [version] = await tx
        .select()
        .from(mixVersions)
        .where(
          and(
            eq(mixVersions.sessionId, event.sessionId),
            eq(mixVersions.version, event.version),
          ),
        )
      if (
        !version?.entries.some(
          (e) => e.position === event.position && e.trackId === event.trackId,
        )
      )
        throw new PlaybackError(400)
      const [song] = await tx
        .select()
        .from(tracks)
        .where(eq(tracks.id, event.trackId))
      if (
        !song?.appleId ||
        !song.durationMs ||
        event.observedMs > song.durationMs + 2000
      )
        throw new PlaybackError(400)
      const threshold = Math.max(10000, Math.min(60000, song.durationMs * 0.8))
      const qualifies =
        event.kind === 'skip'
          ? event.observedMs >= 3000 &&
            event.observedMs < Math.min(30000, song.durationMs * 0.25)
          : event.kind === 'repeat'
            ? event.observedMs >= 30000
            : event.observedMs >= threshold
      if (!qualifies) continue
      await tx
        .insert(playbackEvidence)
        .values({ ...event, userId, occurredAt })
        .onConflictDoNothing()
    }
    return { accepted: true }
  })
}
