import { sql } from 'drizzle-orm'
import { session, user } from '../db/auth-schema'
import type { Db } from '../db/types'

// Spec 2026-10-20 first-run flow → Limits: anonymous users with no session
// activity for 30 days are deleted. ON DELETE CASCADE on every user-keyed
// table removes their mixes, library and events with them.
export const ANONYMOUS_IDLE_DAYS = 30
// Bounded so one maintenance invocation stays inside the free plan's 10 ms CPU.
export const ANONYMOUS_EXPIRE_LIMIT = 200

export type AnonymousRetentionResult = { expired: number }

type Options = { idleDays?: number, limit?: number, now?: () => Date }

// One statement. A user with no session falls back to its own created_at.
// Better Auth's timestamps are `timestamp` (no zone) written as UTC, so the
// cutoff is passed as a UTC ISO string rather than compared with now().
export async function expireAnonymousUsers(
  db: Db,
  { idleDays = ANONYMOUS_IDLE_DAYS, limit = ANONYMOUS_EXPIRE_LIMIT, now }: Options = {},
): Promise<AnonymousRetentionResult> {
  const current = now?.() ?? new Date()
  const cutoff = new Date(current.getTime() - idleDays * 24 * 60 * 60 * 1_000).toISOString()
  const rows = await db
    .delete(user)
    // is_anonymous is re-checked on the outer row: an account linked between
    // the subselect and the delete keeps its row.
    .where(sql`${user.isAnonymous} AND ${user.id} IN (
      SELECT u.id FROM "user" u
      LEFT JOIN ${session} s ON s.user_id = u.id
      WHERE u.is_anonymous
      GROUP BY u.id
      HAVING coalesce(max(s.updated_at), u.created_at) < ${cutoff}::timestamp
      LIMIT ${limit}
    )`)
    .returning({ id: user.id })
  return { expired: rows.length }
}
