import { Hono } from 'hono'
import { and, desc, eq } from 'drizzle-orm'
import type { AppVars } from '../app'
import type { Db } from '../db/types'
import { djMemories } from '../db/schema'

// dj_memories.id is a uuid column — a malformed path segment would otherwise
// surface as a Postgres "invalid input syntax for type uuid" 500, same
// rationale as routes/sessions.ts's own isUuid guard. Resolved the same way:
// a malformed id 404s exactly like a missing-but-well-formed one, never a 500.
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
function isUuid(value: string): boolean {
  return UUID_RE.test(value)
}

// Mounted at /me/memories, behind requireSession like every other /me* route.
export function memoriesRoutes(db: Db) {
  const app = new Hono<{ Variables: AppVars }>()

  // Newest-first, capped at the same MAX_MEMORY_NOTES the dj loop enforces —
  // the note set this endpoint lists can never actually exceed that bound.
  app.get('/', async (c) => {
    const userId = c.get('user').id
    const rows = await db
      .select({ id: djMemories.id, note: djMemories.note, createdAt: djMemories.createdAt })
      .from(djMemories)
      .where(eq(djMemories.userId, userId))
      .orderBy(desc(djMemories.createdAt))
      .limit(50)
    return c.json({ memories: rows })
  })

  // Hard delete, owner-scoped — the WHERE clause itself is the ownership
  // check, so a missing note and another user's note both resolve to the
  // same 404 with no existence leak either way.
  app.delete('/:id', async (c) => {
    const userId = c.get('user').id
    const id = c.req.param('id')
    if (!isUuid(id)) return c.json({ error: 'not_found' }, 404)

    const deleted = await db
      .delete(djMemories)
      .where(and(eq(djMemories.id, id), eq(djMemories.userId, userId)))
      .returning({ id: djMemories.id })
    if (deleted.length === 0) return c.json({ error: 'not_found' }, 404)
    return c.json({ ok: true })
  })

  return app
}
