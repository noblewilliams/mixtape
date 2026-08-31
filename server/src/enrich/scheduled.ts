import type { Db } from '../db/types'
import type { EnrichDeps } from './pipeline'
import { runEnrichmentBatch, type RunResult } from './runner'
import {
  runArtworkBatch,
  type ArtworkDeps,
  type ArtworkRunResult,
} from '../artwork/runner'

// Same subrequest budget as MAX_BATCH (see routes/enrich.ts); small batches
// also keep runs well inside the 5-min cadence so overlapping crons stay rare.
export const CRON_BATCH = 3
export const ARTWORK_CRON_BATCH = 300

export type ScheduledDeps = {
  enrichment?: EnrichDeps
  artwork?: ArtworkDeps
}

type FailedRun = { error: 'failed' }
export type ScheduledResult = {
  enrichment?: RunResult | FailedRun
  artwork?: ArtworkRunResult | FailedRun
}

type ScheduledRunners = {
  enrichment: typeof runEnrichmentBatch
  artwork: typeof runArtworkBatch
}

export async function handleScheduled(
  db: Db,
  deps: ScheduledDeps,
  runners: ScheduledRunners = {
    enrichment: runEnrichmentBatch,
    artwork: runArtworkBatch,
  },
): Promise<ScheduledResult> {
  const result: ScheduledResult = {}

  if (deps.enrichment) {
    try {
      result.enrichment = await runners.enrichment(db, deps.enrichment, CRON_BATCH)
    } catch {
      result.enrichment = { error: 'failed' }
    }
  }

  if (deps.artwork) {
    try {
      result.artwork = await runners.artwork(db, deps.artwork, ARTWORK_CRON_BATCH)
    } catch {
      result.artwork = { error: 'failed' }
    }
  }

  return result
}
