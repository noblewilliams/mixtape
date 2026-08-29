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
    const raw = Number(c.req.query('limit'))
    const requested = Number.isFinite(raw) && raw > 0 ? raw : MAX_BATCH
    const limit = Math.min(MAX_BATCH, Math.max(1, requested))
    const result = await runEnrichmentBatch(db, deps, limit)
    return c.json(result)
  })

  app.get('/status', async (c) => {
    const status = await enrichmentStatus(db)
    return c.json(status)
  })

  return app
}
