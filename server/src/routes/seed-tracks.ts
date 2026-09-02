import { Hono } from 'hono'
import { and, asc, eq, sql } from 'drizzle-orm'
import { zValidator } from '@hono/zod-validator'
import type { AppVars } from '../app'
import type { Db } from '../db/types'
import { listeningDays, tracks, userTracks } from '../db/schema'
import { EnrichSourceError } from '../enrich/types'
import {
  fetchTracksBySpotifyIds,
  type FetchTracksBySpotifyIds,
  type ReccoBeatsTrackHit,
} from '../enrich/reccobeats-by-id'
import { dedupeSeedNames, insertMissingArtistSeeds } from '../seeds/artist-seeds'
import { postSeedTracksSchema } from '../seeds/contracts'
import { uuidParam } from './uuid-param'

export type SeedsWiring = { fetchTracks?: FetchTracksBySpotifyIds }

// Credited artists joined the way the rest of the corpus spells a
// collaboration ("Wizkid & Tems"); a hit with no usable artist name cannot
// become a tracks row (artist is NOT NULL) and is reported unresolved.
const creditedArtists = (hit: ReccoBeatsTrackHit) => dedupeSeedNames(hit.artists)

// Mounted at /me/seed-tracks, behind requireSession. Pasted Spotify links
// become the listener's explicit taste: a tracks row per id (a peer of the
// export's rows, never a merge), a seeded user_tracks row, and a pasted
// artist seed per credited artist.
export function seedTracksRoutes(db: Db, wiring: SeedsWiring = {}) {
  const fetchTracks = wiring.fetchTracks ?? ((ids: string[]) => fetchTracksBySpotifyIds(ids))
  const app = new Hono<{ Variables: AppVars }>()

  app.post('/', zValidator('json', postSeedTracksSchema), async (c) => {
    const userId = c.get('user').id
    const ids = [...new Set(c.req.valid('json').spotifyIds)]

    let hits: ReccoBeatsTrackHit[]
    try {
      hits = (await fetchTracks(ids)).hits
    } catch (error) {
      if (error instanceof EnrichSourceError) return c.json({ error: 'upstream' }, 502)
      throw error
    }

    const requested = new Set(ids)
    const usable = new Map<string, ReccoBeatsTrackHit & { artist: string }>()
    for (const hit of hits) {
      if (!requested.has(hit.spotifyId) || usable.has(hit.spotifyId)) continue
      const names = creditedArtists(hit)
      const title = hit.title.trim()
      if (names.length === 0 || title.length === 0) continue
      usable.set(hit.spotifyId, { ...hit, title, artist: names.join(' & ') })
    }

    const now = new Date()
    const written = usable.size === 0 ? [] : await db.transaction(async (tx) => {
      // ReccoBeats credits the recording's artists, so it corrects an
      // export's album artist; only the Apple catalog outranks it. isrc and
      // duration only fill gaps. A pasted seed is at least priority 1 for
      // enrichment and never lowers a priority an import already raised.
      const rows = await tx
        .insert(tracks)
        .values([...usable.values()].map((hit) => ({
          spotifyId: hit.spotifyId,
          title: hit.title,
          artist: hit.artist,
          isrc: hit.isrc,
          durationMs: hit.durationMs,
          artistSource: 'reccobeats' as const,
          enrichPriority: 1,
        })))
        .onConflictDoUpdate({
          target: tracks.spotifyId,
          targetWhere: sql`spotify_id is not null`,
          set: {
            title: sql`CASE WHEN ${tracks.artistSource} = 'apple_catalog' THEN ${tracks.title} ELSE excluded.title END`,
            artist: sql`CASE WHEN ${tracks.artistSource} = 'apple_catalog' THEN ${tracks.artist} ELSE excluded.artist END`,
            artistSource: sql`CASE WHEN ${tracks.artistSource} = 'apple_catalog' THEN ${tracks.artistSource} ELSE 'reccobeats' END`,
            isrc: sql`coalesce(${tracks.isrc}, excluded.isrc)`,
            durationMs: sql`coalesce(${tracks.durationMs}, excluded.duration_ms)`,
            enrichPriority: sql`GREATEST(${tracks.enrichPriority}, 1)`,
          },
        })
        .returning({ id: tracks.id, spotifyId: tracks.spotifyId, title: tracks.title, artist: tracks.artist })

      // in_library defaults to true and must be false here, or the liked-
      // removal and delete-source sweeps would treat a seed as library.
      await tx
        .insert(userTracks)
        .values(rows.map((row) => ({
          userId,
          trackId: row.id,
          seeded: true,
          inLibrary: false,
          playCount: 0,
          playCountObserved: false,
          updatedAt: now,
        })))
        .onConflictDoUpdate({
          target: [userTracks.userId, userTracks.trackId],
          set: { seeded: true, updatedAt: now },
        })

      await insertMissingArtistSeeds(tx, userId, [...usable.values()].flatMap(creditedArtists), 'pasted')
      return rows
    })

    const bySpotifyId = new Map(written.map((row) => [row.spotifyId, row]))
    return c.json({
      resolved: ids.flatMap((spotifyId) => {
        const row = bySpotifyId.get(spotifyId)
        return row ? [{ spotifyId, trackId: row.id, title: row.title, artist: row.artist }] : []
      }),
      unresolved: ids.filter((spotifyId) => !bySpotifyId.has(spotifyId)),
    })
  })

  app.get('/', async (c) => {
    const rows = await db
      .select({
        trackId: tracks.id,
        spotifyId: tracks.spotifyId,
        title: tracks.title,
        artist: tracks.artist,
        album: tracks.album,
      })
      .from(userTracks)
      .innerJoin(tracks, eq(tracks.id, userTracks.trackId))
      .where(and(eq(userTracks.userId, c.get('user').id), eq(userTracks.seeded, true)))
      .orderBy(asc(tracks.title), asc(tracks.artist), asc(tracks.id))
    return c.json({ tracks: rows })
  })

  // Clears the seed; the row itself goes only when nothing else keeps it
  // (library membership or ledger plays). Another user's row and a row that
  // is not seeded are the same 404. The corpus tracks row always stays.
  app.delete('/:trackId', uuidParam('trackId'), async (c) => {
    const userId = c.get('user').id
    const { trackId } = c.req.valid('param')
    const outcome = await db.transaction(async (tx) => {
      const [row] = await tx
        .select({ seeded: userTracks.seeded, inLibrary: userTracks.inLibrary })
        .from(userTracks)
        .where(and(eq(userTracks.userId, userId), eq(userTracks.trackId, trackId)))
      if (!row || !row.seeded) return null
      const [ledger] = await tx
        .select({ trackId: listeningDays.trackId })
        .from(listeningDays)
        .where(and(eq(listeningDays.userId, userId), eq(listeningDays.trackId, trackId)))
        .limit(1)
      if (!row.inLibrary && !ledger) {
        await tx.delete(userTracks).where(and(eq(userTracks.userId, userId), eq(userTracks.trackId, trackId)))
        return { removed: true, deleted: true }
      }
      await tx
        .update(userTracks)
        .set({ seeded: false })
        .where(and(eq(userTracks.userId, userId), eq(userTracks.trackId, trackId)))
      return { removed: true, deleted: false }
    })
    if (!outcome) return c.json({ error: 'not_found' }, 404)
    return c.json(outcome)
  })

  return app
}
