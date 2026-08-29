import type { Db } from '../db/types'
import type { EnrichDeps } from './pipeline'
import { runEnrichmentBatch } from './runner'

// Same subrequest budget as MAX_BATCH (see routes/enrich.ts); small batches
// also keep runs well inside the 5-min cadence so overlapping crons stay rare.
export const CRON_BATCH = 3

export function handleScheduled(db: Db, deps: EnrichDeps) {
  return runEnrichmentBatch(db, deps, CRON_BATCH)
}
