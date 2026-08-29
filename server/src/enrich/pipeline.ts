import { eq, sql, and, isNull } from 'drizzle-orm'
import { tracks, trackFeatures, trackMeanings, enrichmentFailures } from '../db/schema'
import type { Db } from '../db/types'
import { EnrichSourceError } from './types'
import type { ItunesHit } from './itunes'
import type { AudioFeatures, TrackKey } from './reccobeats'
import type { LyricsResult, LyricsKey } from './lrclib'
import type { Embedder } from './embedder'

export type EnrichDeps = {
  storefront: string
  itunes: (appleId: string, storefront: string) => Promise<ItunesHit | null>
  features: (key: TrackKey) => Promise<AudioFeatures | null>
  lyrics: (key: LyricsKey) => Promise<LyricsResult | null>
  embed: Embedder
}

export type TrackRow = typeof tracks.$inferSelect
export type StageOutcome = 'ok' | 'miss' | 'error' | 'skipped'
export type EnrichResult = { features: StageOutcome; meaning: StageOutcome }
export type EnrichSkip = { features?: boolean; meaning?: boolean }

type Stage = 'itunes' | 'features' | 'meaning'

// Never store a raw error's message verbatim unless it's one of our own source
// errors (whose text is a controlled `${source}: ${detail}` — see types.ts).
// Anything else (a driver/query error, a thrown string, etc.) may embed SQL,
// params, or other internals we don't want sitting in a DB column — keep only
// its name/kind.
function classifyError(e: unknown): string {
  return e instanceof EnrichSourceError ? String(e) : `internal: ${e instanceof Error ? e.name : typeof e}`
}

async function recordFailure(db: Db, trackId: string, stage: Stage, error: string) {
  await db
    .insert(enrichmentFailures)
    .values({ trackId, stage, error: error.slice(0, 500) })
    .onConflictDoUpdate({
      target: [enrichmentFailures.trackId, enrichmentFailures.stage],
      set: { attempts: sql`${enrichmentFailures.attempts} + 1`, error: error.slice(0, 500), lastAt: sql`now()` },
    })
}

async function clearFailure(db: Db, trackId: string, stage: Stage) {
  await db
    .delete(enrichmentFailures)
    .where(and(eq(enrichmentFailures.trackId, trackId), eq(enrichmentFailures.stage, stage)))
}

export async function enrichTrack(
  db: Db,
  deps: EnrichDeps,
  track: TrackRow,
  skip: EnrichSkip = {},
): Promise<EnrichResult> {
  // Stage 0: iTunes metadata (duration/genre backfill; duration improves the
  // ReccoBeats and LRCLIB matches below). Best-effort — a miss is not fatal.
  // Runs again whenever either duration or genre is still unknown — "duration
  // known" alone must never stand in for "iTunes already ran", since a client
  // can start syncing durations independently of any iTunes lookup, which
  // would otherwise strand tracks without a genre forever. Once both are
  // known, later re-runs skip this stage entirely.
  let durationMs = track.durationMs
  if (track.appleId && (track.durationMs == null || track.genre == null)) {
    try {
      const hit = await deps.itunes(track.appleId, deps.storefront)
      if (hit) {
        durationMs = hit.durationMs ?? durationMs
        await db
          .update(tracks)
          .set({
            durationMs: hit.durationMs ?? track.durationMs,
            genre: track.genre ?? hit.genre,
          })
          .where(eq(tracks.id, track.id))
        await clearFailure(db, track.id, 'itunes')
      }
    } catch (e) {
      await recordFailure(db, track.id, 'itunes', classifyError(e))
    }
  }

  // Stage 1: audio features. The Task 6 runner passes skip.features when its
  // own LEFT JOINs already show a features row exists, so a features-only
  // retry (e.g. after a meaning-stage failure) never re-embeds lyrics.
  let featuresOutcome: StageOutcome
  if (skip.features) {
    featuresOutcome = 'skipped'
  } else {
    try {
      const feats = await deps.features({ title: track.title, artist: track.artist, durationMs })
      if (feats) {
        const { isrc, matchedDurationMs, ...cols } = feats
        await db
          .insert(trackFeatures)
          .values({ trackId: track.id, ...cols, source: 'reccobeats' })
          .onConflictDoUpdate({ target: trackFeatures.trackId, set: { ...cols, source: 'reccobeats', fetchedAt: sql`now()` } })
        if (isrc) {
          await db.update(tracks).set({ isrc }).where(and(eq(tracks.id, track.id), isNull(tracks.isrc)))
        }
        // Spotify-side duration from an exact-title+artist match; unverified against
        // Apple's copy (the ±5s gate doesn't run when the track had no duration), but
        // good enough to key LRCLIB exact-gets and P3 pacing.
        if (matchedDurationMs != null && track.durationMs == null) {
          await db
            .update(tracks)
            .set({ durationMs: matchedDurationMs })
            .where(and(eq(tracks.id, track.id), isNull(tracks.durationMs)))
        }
        durationMs = durationMs ?? matchedDurationMs
        await clearFailure(db, track.id, 'features')
        featuresOutcome = 'ok'
      } else {
        await recordFailure(db, track.id, 'features', 'no acceptable match')
        featuresOutcome = 'miss'
      }
    } catch (e) {
      await recordFailure(db, track.id, 'features', classifyError(e))
      featuresOutcome = 'error'
    }
  }

  // Stage 2: lyric meaning (text passes through transiently — never stored/logged).
  // Same skip contract as stage 1: skip.meaning means the runner already knows
  // a meaning row exists, so embed is never called on a features-only retry.
  let meaningOutcome: StageOutcome
  if (skip.meaning) {
    meaningOutcome = 'skipped'
  } else {
    try {
      const lyr = await deps.lyrics({ title: track.title, artist: track.artist, album: track.album, durationMs })
      if (!lyr || (!lyr.instrumental && !lyr.lyrics)) {
        // Either nothing was found, or what came back has no usable signal
        // (not instrumental, no text) — a silent "ok" here would leave a
        // permanent embedding-less row masquerading as complete.
        await recordFailure(db, track.id, 'meaning', 'no lyrics found')
        meaningOutcome = 'miss'
      } else {
        const embedding = lyr.instrumental || !lyr.lyrics ? null : await deps.embed(lyr.lyrics)
        await db
          .insert(trackMeanings)
          .values({ trackId: track.id, embedding, lyricsSource: 'lrclib', instrumental: lyr.instrumental })
          .onConflictDoUpdate({
            target: trackMeanings.trackId,
            set: {
              lyricsSource: 'lrclib',
              instrumental: lyr.instrumental,
              // Keep an existing embedding when this pass has none (e.g. a
              // later pass classifies the track instrumental): stale > destroyed.
              ...(embedding ? { embedding, embeddedAt: sql`now()` } : {}),
            },
          })
        await clearFailure(db, track.id, 'meaning')
        meaningOutcome = 'ok'
      }
    } catch (e) {
      await recordFailure(db, track.id, 'meaning', classifyError(e))
      meaningOutcome = 'error'
    }
  }

  return { features: featuresOutcome, meaning: meaningOutcome }
}
