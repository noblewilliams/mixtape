import { Hono } from 'hono'
import type { AppVars } from '../app'
import type { Db } from '../db/types'
import { listSavedShares } from '../shares/store'

// Mounted at /me/shared-mixes behind requireSession: the "Shared with you"
// rows clients merge into Mixes (spec 2026-11-13 shared-mixes, API table).
export function sharedMixesRoutes(db: Db) {
  const app = new Hono<{ Variables: AppVars }>()

  app.get('/', async (c) => {
    const rows = await listSavedShares(db, c.get('user').id)
    return c.json({ mixes: rows.map((r) => ({ ...r, savedAt: r.savedAt.toISOString() })) })
  })

  return app
}
