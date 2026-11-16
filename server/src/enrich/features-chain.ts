import { and, eq, inArray, sql } from 'drizzle-orm'
import { alias } from 'drizzle-orm/pg-core'
import { enrichmentFailures, trackFeatureFallbacks, trackFeatures, tracks } from '../db/schema'
import type { Db } from '../db/types'
import type { AudioFeatures, TrackKey } from './reccobeats'
import type { DeezerTempoClient } from './deezer-tempo'
import { failureBlocked, isTransientFailure, NO_MATCH } from './failures'
import { failureText, recordFailure, saveMeasuredFeatures } from './pipeline'

// Features for the songs a DJ turn proposed and verified (plan 2026-11-16
// propose-first, S4), so the pools and the ordering have tempo, energy and
// valence for them in the same turn instead of after the cron's next pass.
//
// Per song, in order: ReccoBeats (the cron's own fetch; a hit is a measured
// track_features row, written exactly as the cron writes it), then Deezer
// tempo by ISRC, then the proposal model's energy and valence estimate. The
// last two land in track_feature_fallbacks, never track_features, which
// stays measured-only (a row there marks a song enriched).
//
// A ReccoBeats miss is recorded as the cron records it, so the cron's
// backoff applies; a transient failure (429, 5xx, timeout) records nothing
// and is not retried in the turn. A song the cron has given up on, or is
// backing off, skips ReccoBeats. The deadline and the subrequest budget are
// checked before each network call; past either, a song gets its estimate
// only. Never throws.

// Worst-case subrequests per lookup: ReccoBeats is a search then an
// audio-features fetch (catalogue-fill.ts STAGE_SUBREQUESTS.features),
// Deezer one track-by-ISRC request.
export const CHAIN_SUBREQUESTS = { reccobeats: 2, deezer: 1 } as const

// Matches deezer-tempo.ts and the plan's shared contract.
const TEMPO_MIN = 40
const TEMPO_MAX = 250

export type FeaturesChainDeps = {
  // The same ReccoBeats fetch enrich/pipeline.ts uses (EnrichDeps.features).
  features: (key: TrackKey) => Promise<AudioFeatures | null>
  deezer: DeezerTempoClient
  // Milliseconds, for the deadline; Date.now when absent.
  now?: () => number
}

export type TurnSong = {
  trackId: string
  isrc: string | null
  title: string
  artist: string
  durationMs: number | null
  estimate?: { energy?: number; valence?: number }
}

export type FeaturesChainOptions = {
  deadlineMs: number
  concurrency: number
  // Subrequests this call may spend; unlimited when absent.
  budget?: number
}

// measured: ReccoBeats hits written. fallback: fallback rows written.
// skipped: songs that already had a measured row. subrequests: what the
// network calls were charged (worst case per lookup started).
export type FeaturesChainResult = { measured: number; fallback: number; skipped: number; subrequests: number }

type SongState = { measured: boolean; blocked: boolean; deezerTempo: boolean }

const inRange = (v: number | null | undefined, min: number, max: number): number | null =>
  typeof v === 'number' && Number.isFinite(v) && v >= min && v <= max ? v : null

export async function fillFeaturesForTurn(
  db: Db,
  deps: FeaturesChainDeps,
  songs: TurnSong[],
  options: FeaturesChainOptions,
): Promise<FeaturesChainResult> {
  const result: FeaturesChainResult = { measured: 0, fallback: 0, skipped: 0, subrequests: 0 }
  const now = deps.now ?? Date.now
  const startedAt = now()
  const budget = options.budget ?? Number.POSITIVE_INFINITY
  const pastDeadline = () => now() - startedAt >= options.deadlineMs
  // Charged before the call starts, so concurrent songs never overspend.
  const take = (cost: number): boolean => {
    if (pastDeadline() || budget - result.subrequests < cost) return false
    result.subrequests += cost
    return true
  }
  let errors = 0

  try {
    const unique = [...new Map(songs.map((s) => [s.trackId, s])).values()]
    if (unique.length === 0) return result
    const states = await readStates(db, unique.map((s) => s.trackId))

    const one = async (song: TurnSong) => {
      const state = states.get(song.trackId)
      // Gone since verification: nothing to write against.
      if (!state) return
      if (state.measured) {
        result.skipped += 1
        return
      }
      if (!state.blocked && take(CHAIN_SUBREQUESTS.reccobeats)) {
        try {
          const feats = await deps.features({ title: song.title, artist: song.artist, durationMs: song.durationMs })
          if (feats) {
            await saveMeasuredFeatures(db, { id: song.trackId, durationMs: song.durationMs }, feats)
            result.measured += 1
            return
          }
          await recordFailure(db, song.trackId, 'features', NO_MATCH)
        } catch (e) {
          // A transient failure says nothing about the song: no attempt is
          // used up, and the cron tries again on its own schedule.
          if (!isTransientFailure(e)) await recordFailure(db, song.trackId, 'features', failureText(e))
        }
      }

      let tempo: number | null = null
      if (song.isrc && !state.deezerTempo && take(CHAIN_SUBREQUESTS.deezer)) {
        try {
          tempo = await deps.deezer.tempoByIsrc(song.isrc)
        } catch {
          // Deezer's failure leaves the estimate to stand alone.
        }
      }
      if (await writeFallback(db, song.trackId, tempo, song.estimate)) result.fallback += 1
    }

    const queue = [...unique]
    const worker = async () => {
      for (let song = queue.shift(); song; song = queue.shift()) {
        try {
          await one(song)
        } catch {
          errors += 1
        }
      }
    }
    await Promise.all(Array.from({ length: Math.max(1, Math.min(options.concurrency, queue.length)) }, worker))
  } catch (e) {
    console.log('features chain', JSON.stringify({ error: e instanceof Error ? e.name : typeof e, ...result }))
    return result
  }
  if (errors > 0) console.log('features chain', JSON.stringify({ error: 'song', songs: errors, ...result }))
  return result
}

// One query: per song, whether it has a measured row, whether the cron's
// features stage has given up on it or is backing off, and whether a Deezer
// tempo is already on file.
async function readStates(db: Db, trackIds: string[]): Promise<Map<string, SongState>> {
  const ef = alias(enrichmentFailures, 'ef')
  const rows = await db
    .select({
      trackId: tracks.id,
      measured: sql<boolean>`${trackFeatures.trackId} IS NOT NULL`,
      blocked: sql<boolean>`${failureBlocked('ef')}`,
      deezerTempo: sql<boolean>`COALESCE(${trackFeatureFallbacks.tempoSource} = 'deezer' AND ${trackFeatureFallbacks.tempo} IS NOT NULL, false)`,
    })
    .from(tracks)
    .leftJoin(trackFeatures, eq(trackFeatures.trackId, tracks.id))
    .leftJoin(ef, and(eq(ef.trackId, tracks.id), eq(ef.stage, 'features')))
    .leftJoin(trackFeatureFallbacks, eq(trackFeatureFallbacks.trackId, tracks.id))
    .where(inArray(tracks.id, trackIds))
  return new Map(rows.map((r) => [r.trackId, { measured: r.measured === true, blocked: r.blocked === true, deezerTempo: r.deezerTempo === true }]))
}

// Range-checked on write (tempo 40 to 250, energy and valence 0 to 1, else
// null). No row when nothing survives. A value this turn lacks keeps what an
// earlier turn stored.
async function writeFallback(
  db: Db,
  trackId: string,
  rawTempo: number | null,
  estimate: TurnSong['estimate'],
): Promise<boolean> {
  const tempo = inRange(rawTempo, TEMPO_MIN, TEMPO_MAX)
  const energy = inRange(estimate?.energy, 0, 1)
  const valence = inRange(estimate?.valence, 0, 1)
  if (tempo === null && energy === null && valence === null) return false
  const f = trackFeatureFallbacks
  await db
    .insert(f)
    .values({
      trackId,
      tempo,
      energy,
      valence,
      tempoSource: tempo === null ? null : 'deezer',
      moodSource: energy === null && valence === null ? null : 'model',
    })
    .onConflictDoUpdate({
      target: f.trackId,
      set: {
        tempo: sql`COALESCE(excluded.tempo, ${f.tempo})`,
        tempoSource: sql`CASE WHEN excluded.tempo IS NOT NULL THEN excluded.tempo_source ELSE ${f.tempoSource} END`,
        energy: sql`COALESCE(excluded.energy, ${f.energy})`,
        valence: sql`COALESCE(excluded.valence, ${f.valence})`,
        moodSource: sql`COALESCE(excluded.mood_source, ${f.moodSource})`,
        fetchedAt: sql`now()`,
      },
    })
  return true
}
