/**
 * reprioritize-playlist-tracks: one-off backfill for imports that landed
 * before playlist songs became pool candidates (decision 2026-10-03). Those
 * imports gave a playlist-only song enrich_priority 0, so the enrichment
 * runner reached it last. This raises every track that is a candidate
 * through the playlist leg (dj/pool.ts → playlistCandidateTracksSql) for any
 * listener to greatest(enrich_priority, 1).
 *
 * Usage (from server/):  npm run reprioritize-playlist-tracks [-- --apply]
 * Loads DATABASE_URL from .dev.vars (scripts/lib/dev-vars.ts). Not run
 * automatically by anything.
 *
 * Defaults to a DRY RUN: prints counts only (never ids, titles or users) and
 * writes nothing. Pass --apply to write; this is a real-prod-DB write, so it
 * is opt-in.
 */
import { sql } from 'drizzle-orm'
import { neon } from '@neondatabase/serverless'
import { drizzle } from 'drizzle-orm/neon-http'
import * as schema from '../src/db/schema'
import { playlistCandidateTracksSql } from '../src/dj/pool'
import { loadDevVars } from './lib/dev-vars'

function rowsOf(res: unknown): Record<string, unknown>[] {
  if (Array.isArray(res)) return res as Record<string, unknown>[]
  const rows = (res as { rows?: unknown } | null | undefined)?.rows
  return Array.isArray(rows) ? (rows as Record<string, unknown>[]) : []
}

async function main() {
  const apply = process.argv.includes('--apply')
  const env = loadDevVars()
  if (!env.DATABASE_URL) throw new Error('DATABASE_URL missing from .dev.vars')

  // A construction failure must never surface e.message: a malformed
  // DATABASE_URL makes neon() throw with the connection string in it.
  let db: ReturnType<typeof drizzle>
  try {
    db = drizzle(neon(env.DATABASE_URL), { schema })
  } catch {
    throw new Error('invalid DATABASE_URL in .dev.vars')
  }

  const listeners = rowsOf(await db.execute(sql`
    SELECT DISTINCT user_id FROM user_playlists WHERE in_library = true ORDER BY user_id
  `)).map((r) => String(r.user_id))
  console.log(`${listeners.length} listener(s) with active playlists${apply ? '' : ', dry run, no writes'}`)
  if (listeners.length === 0) return

  // One UNION across listeners so a track two listeners share counts once.
  // Only rows the listener already has count, exactly as the pool admits.
  const targets = sql.join(
    listeners.map((userId) => sql`
      SELECT ut.track_id FROM user_tracks ut
      WHERE ut.user_id = ${userId}
        AND ut.track_id IN (${playlistCandidateTracksSql(userId)})`),
    sql` UNION `,
  )

  if (!apply) {
    const [row] = rowsOf(await db.execute(sql`
      SELECT
        count(*)::int AS candidates,
        count(*) FILTER (WHERE tr.enrich_priority < 1)::int AS raise
      FROM tracks tr
      WHERE tr.id IN (${targets})
    `))
    console.log(`${Number(row?.candidates ?? 0)} playlist-candidate track(s), ${Number(row?.raise ?? 0)} would be raised to priority 1`)
    return
  }

  const updated = rowsOf(await db.execute(sql`
    UPDATE tracks tr
    SET enrich_priority = greatest(tr.enrich_priority, 1)
    WHERE tr.id IN (${targets}) AND tr.enrich_priority < 1
    RETURNING 1
  `)).length
  console.log(`${updated} track(s) raised to priority 1`)
}

main().catch((e) => {
  // Fixed shape only: a DB error's own message can carry connection details.
  console.error('reprioritize-playlist-tracks failed:', e instanceof Error && e.message.includes('.dev.vars') ? e.message : 'database error')
  process.exit(1)
})
