import { sql } from 'drizzle-orm'
import type { Db } from '../db/types'

export const TWIN_COPY_LIMIT = 500

export type TwinCopyResult = { features: number; meanings: number }

// Same recording, same derived data: a track whose ISRC is shared with an
// already-enriched row takes that row's features and meaning instead of
// spending external calls on them. No provider is contacted here, so this
// costs no subrequests. Copied rows carry source 'twin' so they stay
// distinguishable from a provider match, and keep the donor's fetched_at /
// embedded_at so a copy never looks freshly computed. Existing rows are never
// touched (ON CONFLICT DO NOTHING), and the donor is the oldest usable row so
// reruns agree.
const VALID_ISRC = sql.raw(`'^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$'`)

function count(res: unknown): number {
  const rows = Array.isArray(res) ? res : (res as { rows?: unknown[] } | null)?.rows
  return Number((rows?.[0] as { count?: unknown } | undefined)?.count ?? 0)
}

export async function runTwinCopy(db: Db, limit = TWIN_COPY_LIMIT): Promise<TwinCopyResult> {
  // Filling a stage also clears its failure row, so a twin that had burned
  // through its own attempts reads as complete rather than exhausted.
  const features = count(await db.execute(sql`
    WITH filled AS (
      INSERT INTO track_features (
        track_id, tempo, key, mode, energy, danceability, valence, acousticness,
        instrumentalness, liveness, speechiness, loudness, source, fetched_at
      )
      SELECT * FROM (
        SELECT DISTINCT ON (t.id)
          t.id, f.tempo, f.key, f.mode, f.energy, f.danceability, f.valence, f.acousticness,
          f.instrumentalness, f.liveness, f.speechiness, f.loudness, 'twin', f.fetched_at
        FROM tracks t
        JOIN tracks d ON upper(d.isrc) = upper(t.isrc) AND d.id <> t.id
        JOIN track_features f ON f.track_id = d.id
        WHERE upper(t.isrc) ~ ${VALID_ISRC}
          AND NOT EXISTS (SELECT 1 FROM track_features own WHERE own.track_id = t.id)
        ORDER BY t.id, f.fetched_at, d.id
        LIMIT ${limit}
      ) pick
      ON CONFLICT (track_id) DO NOTHING
      RETURNING track_id
    ), cleared AS (
      DELETE FROM enrichment_failures ef USING filled
      WHERE ef.track_id = filled.track_id AND ef.stage = 'features'
    )
    SELECT COUNT(*) AS count FROM filled
  `))

  // Only a meaning with usable signal is worth copying: an embedding, or an
  // instrumental flag. The embedding is copied as is; no lyric text exists
  // to copy.
  const meanings = count(await db.execute(sql`
    WITH filled AS (
      INSERT INTO track_meanings (track_id, embedding, lyrics_source, instrumental, embedded_at)
      SELECT * FROM (
        SELECT DISTINCT ON (t.id) t.id, m.embedding, 'twin', m.instrumental, m.embedded_at
        FROM tracks t
        JOIN tracks d ON upper(d.isrc) = upper(t.isrc) AND d.id <> t.id
        JOIN track_meanings m ON m.track_id = d.id
        WHERE upper(t.isrc) ~ ${VALID_ISRC}
          AND (m.embedding IS NOT NULL OR m.instrumental)
          AND NOT EXISTS (SELECT 1 FROM track_meanings own WHERE own.track_id = t.id)
        ORDER BY t.id, m.embedded_at, d.id
        LIMIT ${limit}
      ) pick
      ON CONFLICT (track_id) DO NOTHING
      RETURNING track_id
    ), cleared AS (
      DELETE FROM enrichment_failures ef USING filled
      WHERE ef.track_id = filled.track_id AND ef.stage = 'meaning'
    )
    SELECT COUNT(*) AS count FROM filled
  `))

  return { features, meanings }
}
