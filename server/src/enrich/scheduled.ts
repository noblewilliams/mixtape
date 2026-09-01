import type { Db } from '../db/types'
import type { EnrichDeps } from './pipeline'
import { runEnrichmentBatch, type RunResult } from './runner'
import {
  runArtworkBatch,
  type ArtworkDeps,
  type ArtworkRunResult,
} from '../artwork/runner'
import {
  cleanupPlaylistSyncStaging,
  type PlaylistSyncCleanupResult,
} from '../playlists/cleanup'

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
  playlistCleanup: PlaylistSyncCleanupResult | FailedRun
}

type ScheduledRunners = {
  enrichment: typeof runEnrichmentBatch
  artwork: typeof runArtworkBatch
  playlistCleanup: typeof cleanupPlaylistSyncStaging
}

export async function handleScheduled(
  db: Db,
  deps: ScheduledDeps,
  runners: Partial<ScheduledRunners> = {},
): Promise<ScheduledResult> {
  const result = {} as ScheduledResult
  const runEnrichment = runners.enrichment ?? runEnrichmentBatch
  const runArtwork = runners.artwork ?? runArtworkBatch
  const runPlaylistCleanup = runners.playlistCleanup ?? cleanupPlaylistSyncStaging

  try {
    result.playlistCleanup = await runPlaylistCleanup(db)
  } catch {
    result.playlistCleanup = { error: 'failed' }
  }

  if (deps.enrichment) {
    try {
      result.enrichment = await runEnrichment(db, deps.enrichment, CRON_BATCH)
    } catch {
      result.enrichment = { error: 'failed' }
    }
  }

  if (deps.artwork) {
    try {
      result.artwork = await runArtwork(db, deps.artwork, ARTWORK_CRON_BATCH)
    } catch {
      result.artwork = { error: 'failed' }
    }
  }

  return result
}
