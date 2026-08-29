import { eq, sql, and } from 'drizzle-orm'
import { tracks, trackFeatures, trackMeanings, enrichmentFailures } from '../db/schema'
import type { Db } from '../db/types'
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
export type StageOutcome = 'ok' | 'miss' | 'error'
export type EnrichResult = { features: StageOutcome; meaning: StageOutcome }

type Stage = 'itunes' | 'features' | 'meaning'

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

export async function enrichTrack(db: Db, deps: EnrichDeps, track: TrackRow): Promise<EnrichResult> {
  // Stage 0: iTunes metadata (duration/genre backfill; duration improves the
  // ReccoBeats and LRCLIB matches below). Best-effort — a miss is not fatal.
  let durationMs = track.durationMs
  try {
    if (track.appleId) {
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
    }
  } catch (e) {
    await recordFailure(db, track.id, 'itunes', String(e))
  }

  // Stage 1: audio features
  let featuresOutcome: StageOutcome
  try {
    const feats = await deps.features({ title: track.title, artist: track.artist, durationMs })
    if (feats) {
      const { isrc, ...cols } = feats
      await db
        .insert(trackFeatures)
        .values({ trackId: track.id, ...cols, source: 'reccobeats' })
        .onConflictDoUpdate({ target: trackFeatures.trackId, set: { ...cols, source: 'reccobeats', fetchedAt: sql`now()` } })
      if (isrc && !track.isrc) await db.update(tracks).set({ isrc }).where(eq(tracks.id, track.id))
      await clearFailure(db, track.id, 'features')
      featuresOutcome = 'ok'
    } else {
      await recordFailure(db, track.id, 'features', 'no acceptable match')
      featuresOutcome = 'miss'
    }
  } catch (e) {
    await recordFailure(db, track.id, 'features', String(e))
    featuresOutcome = 'error'
  }

  // Stage 2: lyric meaning (text passes through transiently — never stored/logged)
  let meaningOutcome: StageOutcome
  try {
    const lyr = await deps.lyrics({ title: track.title, artist: track.artist, album: track.album, durationMs })
    if (!lyr) {
      await recordFailure(db, track.id, 'meaning', 'no lyrics found')
      meaningOutcome = 'miss'
    } else {
      const embedding = lyr.instrumental || !lyr.lyrics ? null : await deps.embed(lyr.lyrics)
      await db
        .insert(trackMeanings)
        .values({ trackId: track.id, embedding, lyricsSource: 'lrclib', instrumental: lyr.instrumental })
        .onConflictDoUpdate({
          target: trackMeanings.trackId,
          set: { embedding, lyricsSource: 'lrclib', instrumental: lyr.instrumental, embeddedAt: sql`now()` },
        })
      await clearFailure(db, track.id, 'meaning')
      meaningOutcome = 'ok'
    }
  } catch (e) {
    await recordFailure(db, track.id, 'meaning', String(e))
    meaningOutcome = 'error'
  }

  return { features: featuresOutcome, meaning: meaningOutcome }
}
