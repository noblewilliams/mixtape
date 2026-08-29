import { Hono } from 'hono'
import { runEnrichmentBatch, enrichmentStatus } from '../enrich/runner'
import type { EnrichDeps } from '../enrich/pipeline'
import type { Db } from '../db/types'

// Each enriched track costs roughly 5 subrequests (itunes + features +
// lyrics + embed, plus DB round trips) — keep a single batch well under a
// Workers invocation's subrequest ceiling.
export const MAX_BATCH = 8

export function enrichRoutes(db: Db, deps: EnrichDeps) {
  const app = new Hono()

  app.post('/run', async (c) => {
    // Floor before clamping so a fractional ?limit (e.g. 2.5) can never reach
    // the raw SQL LIMIT clause, which rejects non-integer parameters outright.
    // Clamp up to 1 afterward too — a limit like 0.5 floors to 0, which would
    // otherwise reach LIMIT 0 as a silent no-op.
    const raw = Number(c.req.query('limit') ?? MAX_BATCH)
    const limit = Number.isFinite(raw) && raw > 0 ? Math.min(MAX_BATCH, Math.max(1, Math.floor(raw))) : MAX_BATCH
    const result = await runEnrichmentBatch(db, deps, limit)
    return c.json(result)
  })

  app.get('/status', async (c) => {
    const status = await enrichmentStatus(db)
    return c.json(status)
  })

  return app
}
