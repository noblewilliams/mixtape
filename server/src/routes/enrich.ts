import { Hono } from 'hono'
import { runEnrichmentBatch, enrichmentStatus } from '../enrich/runner'
import type { EnrichDeps } from '../enrich/pipeline'
import { ENRICH_BATCH_STEP, largestEnrichBatch } from '../enrich/scheduled'
import type { Db } from '../db/types'
import {
  artworkStatus,
  MAX_ARTWORK_BATCH,
  runArtworkBatch,
  type ArtworkDeps,
} from '../artwork/runner'

// One request is one invocation with the free plan's 50-subrequest ceiling.
// Database statements do not count (WebSocket pool, see buildDb); external
// calls do, and their measured worst case lives beside CRON_BATCH in
// enrich/scheduled.ts. Same step-up rule: ship at ENRICH_BATCH_STEP until a
// day of logs shows no CPU-limit kills.
export const MAX_BATCH = Math.min(largestEnrichBatch(0), ENRICH_BATCH_STEP)

export type EnrichRouteDeps = {
  deps?: EnrichDeps
  artwork?: ArtworkDeps
}

function requestedLimit(value: string | undefined, ceiling: number): number {
  const raw = Number(value ?? ceiling)
  return Number.isFinite(raw) && raw > 0
    ? Math.min(ceiling, Math.max(1, Math.floor(raw)))
    : ceiling
}

export function enrichRoutes(db: Db, wiring: EnrichRouteDeps) {
  const app = new Hono()
  const enrichmentDeps = wiring.deps
  const artworkDeps = wiring.artwork

  if (enrichmentDeps) {
    app.post('/run', async (c) => {
      const result = await runEnrichmentBatch(
        db,
        enrichmentDeps,
        requestedLimit(c.req.query('limit'), MAX_BATCH),
      )
      return c.json(result)
    })

    app.get('/status', async (c) => {
      const status = await enrichmentStatus(db)
      return c.json(status)
    })
  }

  if (artworkDeps) {
    app.post('/artwork/run', async (c) => {
      const result = await runArtworkBatch(
        db,
        artworkDeps,
        requestedLimit(c.req.query('limit'), MAX_ARTWORK_BATCH),
      )
      return c.json(result)
    })

    app.get('/artwork/status', async (c) => {
      const status = await artworkStatus(db, artworkDeps.now?.() ?? new Date())
      return c.json(status)
    })
  }

  return app
}
