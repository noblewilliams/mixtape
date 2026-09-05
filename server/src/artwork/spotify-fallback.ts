import { and, eq, gt, inArray, sql } from 'drizzle-orm'
import { trackArtworkStatus } from '../db/schema'
import type { Db } from '../db/types'
import type { ArtworkMetadata } from './normalize'
import { ArtworkProviderError } from './provider'
import type { DeezerArtworkClient } from './deezer'
import type { SpotifyOEmbedArtworkClient } from './spotify-oembed'
import {
  artworkRetryMs,
  type ArtworkFailureCategory,
} from './runner'

export const FALLBACK_ARTWORK_BATCH = 3
export const FALLBACK_ARTWORK_LEASE_MS = 5 * 60_000

export type SpotifyArtworkDeps = {
  spotify: SpotifyOEmbedArtworkClient
  deezer?: DeezerArtworkClient
  now?: () => Date
}

export type SpotifyArtworkResult = {
  processed: number
  matched: number
  spotify: number
  deezer: number
  missing: number
  failed: number
  skipped: number
  remaining: number
}

type Candidate = {
  track_id: string
  spotify_id: string
  isrc: string | null
  attempts: number
}

type Lookup =
  | { kind: 'spotify' | 'deezer'; artwork: ArtworkMetadata }
  | { kind: 'failure'; category: ArtworkFailureCategory }

function rows<T>(value: unknown): T[] {
  return (Array.isArray(value) ? value : (value as { rows: T[] }).rows) as T[]
}

const eligibleTracks = () => sql`
  SELECT DISTINCT t.id AS track_id, t.spotify_id,
    CASE WHEN upper(t.isrc) ~ '^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$' THEN upper(t.isrc) END AS isrc,
    t.enrich_priority AS priority, t.created_at
  FROM tracks t
  JOIN user_tracks ut ON ut.track_id = t.id
  JOIN user_music_sources src ON src.user_id = ut.user_id
    AND src.source = 'spotify_export' AND src.last_imported_at IS NOT NULL
  WHERE t.spotify_id ~ '^[0-9A-Za-z]{22}$'
    AND t.apple_id IS NULL
    AND t.artwork_url_template IS NULL
`

async function claim(db: Db, now: Date): Promise<Candidate[]> {
  const leaseUntil = new Date(now.getTime() + FALLBACK_ARTWORK_LEASE_MS)
  return rows(await db.execute(sql`
    WITH eligible AS (${eligibleTracks()}), ready AS (
      SELECT e.*, s.updated_at AS last_attempt
      FROM eligible e LEFT JOIN track_artwork_status s ON s.track_id = e.track_id
      WHERE s.track_id IS NULL OR s.next_attempt_at <= ${now}
    ), chosen AS (
      SELECT * FROM ready
      ORDER BY priority DESC, last_attempt NULLS FIRST, created_at, track_id
      LIMIT ${FALLBACK_ARTWORK_BATCH}
    ), claimed AS (
      INSERT INTO track_artwork_status
        (track_id, attempts, last_category, next_attempt_at, updated_at)
      SELECT track_id, 1, 'internal', ${leaseUntil}, ${now}
      FROM chosen ORDER BY track_id
      ON CONFLICT (track_id) DO UPDATE SET
        attempts = track_artwork_status.attempts + 1,
        last_category = 'internal',
        next_attempt_at = excluded.next_attempt_at,
        updated_at = excluded.updated_at
      WHERE track_artwork_status.next_attempt_at <= ${now}
      RETURNING track_id, attempts
    )
    SELECT e.track_id, e.spotify_id, e.isrc, c.attempts
    FROM claimed c JOIN eligible e ON e.track_id = c.track_id
    ORDER BY e.priority DESC, e.created_at, e.track_id
  `))
}

function categoryForError(error: unknown): ArtworkFailureCategory {
  if (!(error instanceof ArtworkProviderError)) return 'internal'
  return error.category === 'response' ? 'malformed' : error.category
}

async function lookup(candidate: Candidate, deps: SpotifyArtworkDeps): Promise<Lookup> {
  try {
    const spotify = await deps.spotify.getArtwork(candidate.spotify_id)
    if (spotify) return { kind: 'spotify', artwork: spotify }
    if (candidate.isrc && deps.deezer) {
      const deezer = await deps.deezer.getArtwork(candidate.isrc)
      if (deezer) return { kind: 'deezer', artwork: deezer }
    }
    return { kind: 'failure', category: 'no_match' }
  } catch (error) {
    return { kind: 'failure', category: categoryForError(error) }
  }
}

async function complete(
  db: Db,
  candidates: Candidate[],
  lookups: Map<string, Lookup>,
  now: Date,
): Promise<Omit<SpotifyArtworkResult, 'remaining'>> {
  const result = { processed: 0, matched: 0, spotify: 0, deezer: 0, missing: 0, failed: 0, skipped: 0 }
  if (!candidates.length) return result

  await db.transaction(async (tx) => {
    const statuses = await tx.select().from(trackArtworkStatus).where(and(
      inArray(trackArtworkStatus.trackId, candidates.map(item => item.track_id)),
      gt(trackArtworkStatus.nextAttemptAt, now),
      eq(trackArtworkStatus.lastCategory, 'internal'),
    )).orderBy(trackArtworkStatus.trackId).for('update')
    const byTrack = new Map(statuses.map(status => [status.trackId, status]))

    for (const candidate of candidates) {
      const status = byTrack.get(candidate.track_id)
      if (!status || status.attempts !== candidate.attempts) continue
      result.processed++
      const current = rows(await tx.execute(sql`
        SELECT 1 FROM (${eligibleTracks()}) e
        WHERE e.track_id = ${candidate.track_id}
          AND e.spotify_id = ${candidate.spotify_id}
          AND e.isrc IS NOT DISTINCT FROM ${candidate.isrc}
      `)).length === 1
      const claim = and(
        eq(trackArtworkStatus.trackId, candidate.track_id),
        eq(trackArtworkStatus.attempts, candidate.attempts),
        eq(trackArtworkStatus.lastCategory, 'internal'),
      )
      if (!current) {
        result.skipped++
        await tx.delete(trackArtworkStatus).where(claim)
        continue
      }

      const found = lookups.get(candidate.track_id) ?? { kind: 'failure', category: 'internal' as const }
      if (found.kind === 'failure') {
        if (found.category === 'no_match') result.missing++
        else result.failed++
        await tx.update(trackArtworkStatus).set({
          lastCategory: found.category,
          nextAttemptAt: new Date(now.getTime() + artworkRetryMs(found.category)),
          updatedAt: now,
        }).where(claim)
        continue
      }

      const saved = rows(await tx.execute(sql`
        UPDATE tracks target SET
          artwork_url_template = ${found.artwork.url},
          artwork_width = ${found.artwork.width},
          artwork_height = ${found.artwork.height},
          artwork_bg_color = ${found.artwork.bgColor},
          artwork_fetched_at = ${now}
        WHERE target.id = ${candidate.track_id}
          AND target.spotify_id = ${candidate.spotify_id}
          AND target.apple_id IS NULL
          AND target.artwork_url_template IS NULL
          AND EXISTS (
            SELECT 1 FROM (${eligibleTracks()}) active
            WHERE active.track_id = target.id
              AND active.spotify_id = ${candidate.spotify_id}
              AND active.isrc IS NOT DISTINCT FROM ${candidate.isrc}
          )
        RETURNING target.id
      `))
      if (saved.length === 1) {
        result.matched++
        result[found.kind]++
      } else result.skipped++
      await tx.delete(trackArtworkStatus).where(claim)
    }
  })
  return result
}

async function remaining(db: Db, now: Date): Promise<number> {
  const count = rows<{ count: number | string }>(await db.execute(sql`
    WITH eligible AS (${eligibleTracks()})
    SELECT count(*) AS count FROM eligible e
    LEFT JOIN track_artwork_status s ON s.track_id = e.track_id
    WHERE s.track_id IS NULL OR s.next_attempt_at <= ${now}
  `))[0]?.count ?? 0
  return Number(count)
}

export async function runSpotifyArtworkBatch(
  db: Db,
  deps: SpotifyArtworkDeps,
): Promise<SpotifyArtworkResult> {
  const currentTime = () => deps.now?.() ?? new Date()
  const candidates = await claim(db, currentTime())
  const lookups = new Map<string, Lookup>()
  for (const candidate of candidates) {
    lookups.set(candidate.track_id, await lookup(candidate, deps))
  }
  const completed = await complete(db, candidates, lookups, currentTime())
  return { ...completed, remaining: await remaining(db, currentTime()) }
}
