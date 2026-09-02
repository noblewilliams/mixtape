import { Hono } from 'hono'
import { zValidator } from '@hono/zod-validator'
import type { AppVars } from '../app'
import type { Db } from '../db/types'
import { funnelEvents } from '../db/schema'
import { funnelEventSchema } from '../seeds/contracts'

// Mounted at /me/funnel-events, behind requireSession. Counts only: a row is
// the user, the step, the surface, and the time (spec 2026-09-01 → Funnel).
export function funnelEventsRoutes(db: Db) {
  const app = new Hono<{ Variables: AppVars }>()

  app.post('/', zValidator('json', funnelEventSchema), async (c) => {
    const { type, surface } = c.req.valid('json')
    await db.insert(funnelEvents).values({ userId: c.get('user').id, type, surface })
    return c.json({ ok: true }, 201)
  })

  return app
}
