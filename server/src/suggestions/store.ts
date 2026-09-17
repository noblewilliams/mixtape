import { and, desc, eq, gte, sql } from 'drizzle-orm'
import type { Db } from '../db/types'
import {
  djSessions,
  mixVersions,
  suggestionSettings,
  userTracks,
} from '../db/schema'
import { localMoment, suggestRoutine } from './patterns'
export async function readSuggestions(
  db: Db,
  userId: string,
  timeZone: string,
  now: Date,
) {
  const [settings] = await db
    .select()
    .from(suggestionSettings)
    .where(eq(suggestionSettings.userId, userId))
  const enabled = settings?.enabled ?? true
  if (!enabled) return { enabled, suggestion: null, dismissed: false }
  const available = await db
    .select({ id: userTracks.trackId })
    .from(userTracks)
    .where(and(eq(userTracks.userId, userId), eq(userTracks.inLibrary, true)))
    .limit(3)
  if (available.length < 3)
    return { enabled, suggestion: null, dismissed: false }
  const rows = await db
    .select({
      createdAt: djSessions.createdAt,
      energyArc: mixVersions.energyArc,
    })
    .from(djSessions)
    .innerJoin(
      mixVersions,
      and(eq(mixVersions.sessionId, djSessions.id), eq(mixVersions.version, 1)),
    )
    .where(
      and(
        eq(djSessions.userId, userId),
        eq(djSessions.status, 'active'),
        eq(djSessions.notPersonal, false),
        sql`jsonb_array_length(${mixVersions.entries}) >= 3`,
        gte(djSessions.createdAt, new Date(now.getTime() - 84 * 86400000)),
      ),
    )
    .orderBy(desc(djSessions.createdAt))
    .limit(500)
  const suggestion = suggestRoutine(rows, timeZone, now)
  const date = suggestion && settings?.dismissed[suggestion.id]
  const dismissed =
    !!date &&
    now.getTime() - Date.parse(date) < 36 * 3600000 &&
    localMoment(new Date(date), timeZone).date ===
      localMoment(now, timeZone).date
  return { enabled, suggestion: dismissed ? null : suggestion, dismissed }
}
export async function saveSuggestionPreference(
  db: Db,
  userId: string,
  enabled: boolean,
) {
  await db
    .insert(suggestionSettings)
    .values({ userId, enabled })
    .onConflictDoUpdate({
      target: suggestionSettings.userId,
      set: { enabled },
    })
  return { enabled }
}
export async function dismissSuggestion(
  db: Db,
  userId: string,
  id: string,
  now: Date,
) {
  await db.transaction(async (tx) => {
    await tx.insert(suggestionSettings).values({ userId }).onConflictDoNothing()
    const [settings] = await tx
      .select()
      .from(suggestionSettings)
      .where(eq(suggestionSettings.userId, userId))
      .for('update')
    const dismissed = Object.fromEntries(
      Object.entries(settings.dismissed).filter(
        ([, date]) => now.getTime() - Date.parse(date) < 36 * 3600000,
      ),
    )
    dismissed[id] = now.toISOString()
    await tx
      .update(suggestionSettings)
      .set({ dismissed })
      .where(eq(suggestionSettings.userId, userId))
  })
}
