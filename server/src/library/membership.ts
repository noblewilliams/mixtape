import { sql, type SQL } from 'drizzle-orm'
import type { Db } from '../db/types'

type Source = 'apple_live' | 'apple_export' | 'spotify_export'
type Change = { kind: 'add' | 'replace'; trackIds: SQL } | { kind: 'remove' }

/**
 * Call inside the writer's transaction, holding the listener profile lock.
 * Create new user_tracks with in_library=false and leave the flag unchanged on
 * conflict: only this function derives membership. trackIds selects track_id.
 */
export async function updateLibraryMembership(
  tx: Db,
  userId: string,
  source: Source,
  change: Change,
  now: Date,
): Promise<number> {
  // A pre-upgrade writer may clear the boolean after migration copied it.
  // Legacy is only a preservation marker, so it cannot revive an unsaved row.
  await tx.execute(sql`
    DELETE FROM user_track_library_sources ls
    USING user_tracks ut
    WHERE ls.user_id = ${userId} AND ls.source = 'legacy'
      AND ut.user_id = ls.user_id AND ut.track_id = ls.track_id
      AND ut.in_library = false
  `)

  // Covers old saved rows, including writes during a migration/deploy gap. Do
  // this before changing source evidence, or a removed owner looks like legacy.
  await tx.execute(sql`
    INSERT INTO user_track_library_sources (user_id, track_id, source)
    SELECT ut.user_id, ut.track_id, 'legacy'
    FROM user_tracks ut
    WHERE ut.user_id = ${userId} AND ut.in_library = true
      AND NOT EXISTS (
        SELECT 1 FROM user_track_library_sources ls
        WHERE ls.user_id = ut.user_id AND ls.track_id = ut.track_id
      )
    ON CONFLICT DO NOTHING
  `)

  if (change.kind !== 'add') {
    await tx.execute(sql`
      DELETE FROM user_track_library_sources
      WHERE user_id = ${userId} AND source = ${source}
    `)
  }
  if (change.kind !== 'remove') {
    await tx.execute(sql`
      INSERT INTO user_track_library_sources (user_id, track_id, source)
      SELECT ${userId}, incoming.track_id, ${source}
      FROM (${change.trackIds}) incoming
      ON CONFLICT DO NOTHING
    `)
  }

  // The public flag is a projection of all surviving sources. Return only the
  // number that actually left the combined library, not source-row removals.
  const result = await tx.execute(sql`
    WITH membership AS (
      SELECT ut.track_id, EXISTS (
        SELECT 1 FROM user_track_library_sources ls
        WHERE ls.user_id = ut.user_id AND ls.track_id = ut.track_id
      ) AS saved
      FROM user_tracks ut WHERE ut.user_id = ${userId}
    ), changed AS (
      UPDATE user_tracks ut
      SET in_library = m.saved, updated_at = ${now}
      FROM membership m
      WHERE ut.user_id = ${userId} AND ut.track_id = m.track_id
        AND ut.in_library IS DISTINCT FROM m.saved
      RETURNING ut.in_library
    )
    SELECT count(*) FILTER (WHERE NOT in_library)::int AS removed FROM changed
  `)
  const rows = Array.isArray(result) ? result : (result as { rows: { removed: number }[] }).rows
  return Number(rows[0].removed)
}
