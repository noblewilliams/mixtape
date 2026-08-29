import type { Db } from '../db/types'
import type { EnrichDeps } from './pipeline'
import { runEnrichmentBatch } from './runner'

// Steady-state cron batch size. Deliberately smaller than the admin route's
// MAX_BATCH (routes/enrich.ts) — this runs unattended and frequently, so a
// tighter batch keeps each invocation's subrequest budget comfortable.
export const CRON_BATCH = 8

export function handleScheduled(db: Db, deps: EnrichDeps) {
  return runEnrichmentBatch(db, deps, CRON_BATCH)
}
