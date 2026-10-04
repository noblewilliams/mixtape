import type { Db } from '../db/types'
import type { EnrichDeps } from './pipeline'
import { runEnrichmentBatch, type RunResult } from './runner'
import {
  runAppleIsrcBackfill,
  runArtworkBatch,
  type ArtworkDeps,
  type ArtworkRunResult,
  type IsrcBackfillResult,
} from '../artwork/runner'
import {
  cleanupPlaylistSyncStaging,
  type PlaylistSyncCleanupResult,
} from '../playlists/cleanup'
import {
  cleanupLibrarySyncStaging,
  type LibrarySyncCleanupResult,
} from '../library/cleanup'
import {
  cleanupListeningImportStaging,
  type ListeningImportCleanupResult,
} from '../listening/cleanup'
import { runPlaylistCatalogBatch, type PlaylistCatalogResult } from '../playlists/catalog-resolution'
import { runTwinCopy, type TwinCopyResult } from './twin-copy'
import { runAppleIsrcBatch, type AppleIsrcDeps, type AppleIsrcResult } from './apple-isrc'
import {
  FALLBACK_ARTWORK_BATCH,
  runSpotifyArtworkBatch,
  type SpotifyArtworkDeps,
  type SpotifyArtworkResult,
} from '../artwork/spotify-fallback'

// Free-plan Workers allow 50 subrequests per invocation. The database is not
// one of them: buildDb in src/index.ts uses the neon-serverless WebSocket
// pool, so statements run over an open socket rather than one fetch each.
// What counts is outbound fetches and the Workers AI binding, measured worst
// case in test/enrich/subrequest-budget.test.ts:
//   fixed per batch: the two shared ReccoBeats by-id lookups (tracks and
//     audio features), one request each for up to RECCOBEATS_ID_BATCH ids,
//     made only when the batch holds a Spotify-id row;
//   per track, Spotify-id or Apple-only alike: ReccoBeats title search and
//     its features fetch (when the by-id features miss), LRCLIB exact get and
//     search (when the get misses), and one embedding.
// iTunes is a no-op in production and makes no request.
export const ENRICH_FIXED_SUBREQUESTS = 2
export const ENRICH_SUBREQUESTS_PER_TRACK = 5
// 10 of the 50 are held back for the pool's connections and retries.
export const ENRICH_SUBREQUEST_BUDGET = 40
// runAppleIsrcBatch shares the enrichment cron's invocation: one catalogue
// request for up to APPLE_ISRC_BATCH ISRCs.
export const APPLE_ISRC_SUBREQUESTS = 1
// runSpotifyArtworkBatch shares it too: per claimed row, one Spotify oEmbed
// request, then one Deezer request when oEmbed misses and the row has an ISRC.
export const FALLBACK_ARTWORK_CALLS_PER_ROW = 2
// Everything else the enrichment cron spends besides the enrichment batch:
// Apple ISRC linking (1) plus the fallback's worst case (3 rows x 2 = 6).
export const ENRICH_CRON_OVERHEAD_SUBREQUESTS =
  APPLE_ISRC_SUBREQUESTS + FALLBACK_ARTWORK_BATCH * FALLBACK_ARTWORK_CALLS_PER_ROW
export const ENRICH_BATCH_CAP = 8

// Largest batch whose worst case fits the budget alongside `otherSubrequests`.
export function largestEnrichBatch(otherSubrequests: number): number {
  const room = ENRICH_SUBREQUEST_BUDGET - otherSubrequests - ENRICH_FIXED_SUBREQUESTS
  return Math.min(ENRICH_BATCH_CAP, Math.max(0, Math.floor(room / ENRICH_SUBREQUESTS_PER_TRACK)))
}

// Step-up rule: subrequests allow 6 in the cron and 7 through /enrich/run, but
// more tracks also spend more of the free plan's 10 ms CPU, which no test
// measures. Ship at 5 first; the founder checks one day of `maintenance cron`
// logs for CPU-limit kills or `failed` markers before this step is raised. It
// never goes past largestEnrichBatch, which also enforces the cap of 8.
export const ENRICH_BATCH_STEP = 5
export const CRON_BATCH = Math.min(largestEnrichBatch(ENRICH_CRON_OVERHEAD_SUBREQUESTS), ENRICH_BATCH_STEP)
export const ARTWORK_CRON_BATCH = 300

export type ScheduledDeps = {
  enrichment?: EnrichDeps
  artwork?: ArtworkDeps
  appleIsrc?: AppleIsrcDeps
  spotifyArtwork?: SpotifyArtworkDeps
}

// Two hourly triggers, two minutes apart, so Postgres wakes once per hour and
// stays warm for the second. Each invocation gets its own 50-subrequest and
// 10 ms CPU budget: maintenance (cleanup, playlist catalogue resolution, Apple
// artwork, then the Apple ISRC backfill's single catalogue request) on the
// hour, then twin copy, enrichment, Apple ISRC linking and the Spotify artwork
// fallback. Linking follows enrichment because enrichment
// produces ISRCs; the fallback follows linking so Apple gets its chance before
// a Spotify or Deezer thumbnail is written.
// Keep these equal to `triggers.crons` in wrangler.jsonc.
export const MAINTENANCE_CRON = '0 * * * *'
export const ENRICHMENT_CRON = '2 * * * *'

export type ScheduledJobs = 'maintenance' | 'enrichment'

// Anything else (a stale or hand-added trigger) runs nothing.
export function jobsForCron(cron: string): ScheduledJobs | null {
  if (cron === MAINTENANCE_CRON) return 'maintenance'
  if (cron === ENRICHMENT_CRON) return 'enrichment'
  return null
}

type FailedRun = { error: 'failed' }
export type ScheduledResult = {
  playlistCatalog?: PlaylistCatalogResult | FailedRun
  appleIsrc?: AppleIsrcResult | FailedRun
  spotifyArtwork?: SpotifyArtworkResult | FailedRun
  twinCopy?: TwinCopyResult | FailedRun
  enrichment?: RunResult | FailedRun
  artwork?: ArtworkRunResult | FailedRun
  isrcBackfill?: IsrcBackfillResult | FailedRun | { skipped: 'artwork_busy' }
  playlistCleanup?: PlaylistSyncCleanupResult | FailedRun
  libraryCleanup?: LibrarySyncCleanupResult | FailedRun
  listeningCleanup?: ListeningImportCleanupResult | FailedRun
}

type ScheduledRunners = {
  playlistCatalog: typeof runPlaylistCatalogBatch
  appleIsrc: typeof runAppleIsrcBatch
  spotifyArtwork: typeof runSpotifyArtworkBatch
  twinCopy: typeof runTwinCopy
  enrichment: typeof runEnrichmentBatch
  artwork: typeof runArtworkBatch
  isrcBackfill: typeof runAppleIsrcBackfill
  playlistCleanup: typeof cleanupPlaylistSyncStaging
  libraryCleanup: typeof cleanupLibrarySyncStaging
  listeningCleanup: typeof cleanupListeningImportStaging
}

export async function handleScheduled(
  db: Db,
  jobs: ScheduledJobs,
  deps: ScheduledDeps,
  runners: Partial<ScheduledRunners> = {},
): Promise<ScheduledResult> {
  return jobs === 'maintenance'
    ? runMaintenance(db, deps, runners)
    : runEnrichmentJobs(db, deps, runners)
}

async function runMaintenance(
  db: Db,
  deps: ScheduledDeps,
  runners: Partial<ScheduledRunners>,
): Promise<ScheduledResult> {
  const result: ScheduledResult = {}
  const runPlaylistCatalog = runners.playlistCatalog ?? runPlaylistCatalogBatch
  const runArtwork = runners.artwork ?? runArtworkBatch
  const runIsrcBackfill = runners.isrcBackfill ?? runAppleIsrcBackfill
  const runPlaylistCleanup = runners.playlistCleanup ?? cleanupPlaylistSyncStaging
  const runLibraryCleanup = runners.libraryCleanup ?? cleanupLibrarySyncStaging
  const runListeningCleanup = runners.listeningCleanup ?? cleanupListeningImportStaging

  try {
    result.libraryCleanup = await runLibraryCleanup(db)
  } catch {
    result.libraryCleanup = { error: 'failed' }
  }

  try {
    result.listeningCleanup = await runListeningCleanup(db)
  } catch {
    result.listeningCleanup = { error: 'failed' }
  }

  try {
    result.playlistCleanup = await runPlaylistCleanup(db)
  } catch {
    result.playlistCleanup = { error: 'failed' }
  }

  // Reuse the existing server-only catalog client. The resolver selects each
  // listener's persisted storefront instead of the artwork job's default market.
  if (deps.artwork) {
    try {
      result.playlistCatalog = await runPlaylistCatalog(db, {
        catalog: deps.artwork.catalog, now: deps.artwork.now,
      })
    } catch {
      result.playlistCatalog = { error: 'failed' }
    }
  }

  if (deps.artwork) {
    try {
      result.artwork = await runArtwork(db, deps.artwork, ARTWORK_CRON_BATCH)
    } catch {
      result.artwork = { error: 'failed' }
    }
  }

  // After artwork, which already stores the ISRC of every song it fetches, so
  // this only reaches rows whose artwork predates that. Parsing two full
  // 300-song responses would risk the free plan's 10 ms CPU, so a run where
  // artwork took a full batch leaves the backfill to a quieter hour.
  const artworkBusy = result.artwork != null && 'processed' in result.artwork
    && result.artwork.processed >= ARTWORK_CRON_BATCH
  if (deps.artwork && artworkBusy) {
    result.isrcBackfill = { skipped: 'artwork_busy' }
  } else if (deps.artwork) {
    try {
      result.isrcBackfill = await runIsrcBackfill(db, deps.artwork)
    } catch {
      result.isrcBackfill = { error: 'failed' }
    }
  }

  return result
}

async function runEnrichmentJobs(
  db: Db,
  deps: ScheduledDeps,
  runners: Partial<ScheduledRunners>,
): Promise<ScheduledResult> {
  const result: ScheduledResult = {}
  const runTwins = runners.twinCopy ?? runTwinCopy
  const runEnrichment = runners.enrichment ?? runEnrichmentBatch
  const runAppleIsrc = runners.appleIsrc ?? runAppleIsrcBatch
  const runSpotifyArtwork = runners.spotifyArtwork ?? runSpotifyArtworkBatch

  // No external calls, so it needs no enrichment deps. Running it first means
  // a track whose ISRC twin is already enriched drops out of the candidate set
  // before the batch below spends subrequests on it.
  try {
    result.twinCopy = await runTwins(db)
  } catch {
    result.twinCopy = { error: 'failed' }
  }

  if (deps.enrichment) {
    try {
      result.enrichment = await runEnrichment(db, deps.enrichment, CRON_BATCH)
    } catch {
      result.enrichment = { error: 'failed' }
    }
  }

  // Newly observed Spotify ISRCs can link in this same pass. Provider failure
  // does not undo the metadata stage that produced the ISRC.
  if (deps.appleIsrc) {
    try {
      result.appleIsrc = await runAppleIsrc(db, deps.appleIsrc)
    } catch {
      result.appleIsrc = { error: 'failed' }
    }
  }

  // Apple remains the preferred catalog, so this runs after linking. Any
  // Spotify-export row still without an Apple id or artwork is eligible,
  // including rows linking has not reached yet (no ISRC, or not claimed this
  // pass): they can receive a fixed Spotify thumbnail, with exact-ISRC Deezer
  // as a last fallback. Independently fenced and failure-isolated.
  if (deps.spotifyArtwork) {
    try {
      result.spotifyArtwork = await runSpotifyArtwork(db, deps.spotifyArtwork)
    } catch {
      result.spotifyArtwork = { error: 'failed' }
    }
  }

  return result
}
