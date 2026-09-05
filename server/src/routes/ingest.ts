import { Hono } from 'hono'
import { z } from 'zod'
import { zValidator } from '@hono/zod-validator'
import { eq, sql } from 'drizzle-orm'
import { tracks, userTracks, userMusicProfiles } from '../db/schema'
import { updateLibraryMembership } from '../library/membership'
import type { AppVars } from '../app'
import type { Db } from '../db/types'
import { isAppleSongId } from '../musickit/apple-id'

const songSchema = z.object({
  // MusicKit declares catalog IDs as opaque. Bound them to URL-safe,
  // comma-free characters without assuming that every future ID is numeric.
  appleId: z.string().refine(isAppleSongId),
  title: z.string().min(1),
  artist: z.string().min(1),
  album: z.string().nullable().optional(),
  genre: z.string().nullable().optional(),
  releaseYear: z.number().int().min(1900).max(3000).nullable().optional(),
  explicit: z.boolean().nullable().optional(),
  playCount: z.number().int().min(0),
  lastPlayedAt: z.number().int().nullable().optional(),
  dateAdded: z.number().int().nullable().optional(),
})

// load-bearing: keeps bind params well under Postgres's 65535 ceiling (7 params/row)
const bodySchema = z.object({ songs: z.array(songSchema).min(1).max(500) })

type Song = z.infer<typeof songSchema>

const toDate = (ms: number | null | undefined) => (ms == null ? null : new Date(ms))

// A page can repeat an appleId (e.g. the same catalog song appearing twice in a
// library); Postgres rejects touching the same row twice in one upsert.
function dedupe(songs: Song[]): Song[] {
  const byId = new Map<string, Song>()
  for (const s of songs) {
    const prev = byId.get(s.appleId)
    if (!prev || s.playCount > prev.playCount) byId.set(s.appleId, s)
  }
  return [...byId.values()]
}

export function ingestRoutes(db: Db) {
  const app = new Hono<{ Variables: AppVars }>()

  app.post('/library', zValidator('json', bodySchema), async (c) => {
    const songs = dedupe(c.req.valid('json').songs)
    // tracks is a global catalog shared across every user; two requests
    // upserting overlapping rows in different orders can deadlock in
    // Postgres. Sorting gives every request the same lock-acquisition order.
    songs.sort((a, b) => (a.appleId < b.appleId ? -1 : 1))
    const userId = c.get('user').id

    // Shared catalog writes are idempotent. Listener state publishes atomically
    // below; a failure there can leave only harmless unowned catalog rows.
    const trackRows = await db
      .insert(tracks)
      .values(
        songs.map((s) => ({
          appleId: s.appleId,
          title: s.title,
          artist: s.artist,
          album: s.album ?? null,
          genre: s.genre ?? null,
          releaseYear: s.releaseYear ?? null,
          explicit: s.explicit ?? null,
        })),
      )
      .onConflictDoUpdate({
        target: tracks.appleId,
        targetWhere: sql`apple_id is not null`,
        set: {
          title: sql`excluded.title`,
          artist: sql`excluded.artist`,
          // A later sync may know the album/genre an earlier one didn't;
          // never blank out an existing value with an unknown one.
          album: sql`coalesce(excluded.album, ${tracks.album})`,
          genre: sql`coalesce(excluded.genre, ${tracks.genre})`,
          releaseYear: sql`coalesce(excluded.release_year, ${tracks.releaseYear})`,
          explicit: sql`coalesce(excluded.explicit, ${tracks.explicit})`,
        },
      })
      .returning({ id: tracks.id, appleId: tracks.appleId })

    const idByAppleId = new Map(trackRows.map((t) => [t.appleId, t.id]))

    await db.transaction(async (rawTx) => {
      const tx = rawTx as unknown as Db
      await tx.insert(userMusicProfiles).values({ userId }).onConflictDoNothing()
      await tx.select({ userId: userMusicProfiles.userId }).from(userMusicProfiles)
        .where(eq(userMusicProfiles.userId, userId)).for('update')

      // dateAdded is intentionally never updated on conflict — it's the date
      // the track first entered the user's library, and re-syncs shouldn't
      // move it. This paged endpoint is additive; full snapshots own removal.
      await tx
        .insert(userTracks)
        .values(
          songs.map((s) => {
            const trackId = idByAppleId.get(s.appleId)
            if (!trackId) throw new Error(`ingest: no track id returned for ${s.appleId}`)
            return {
              userId,
              trackId,
              playCount: s.playCount,
              lastPlayedAt: toDate(s.lastPlayedAt),
              dateAdded: toDate(s.dateAdded),
              inLibrary: false,
            }
          }),
        )
        .onConflictDoUpdate({
          target: [userTracks.userId, userTracks.trackId],
          set: {
            // greatest() ignores NULLs, so a page/retry that lost track of the
            // play count or last-played date can't clobber a known value.
            playCount: sql`greatest(${userTracks.playCount}, excluded.play_count)`,
            lastPlayedAt: sql`greatest(${userTracks.lastPlayedAt}, excluded.last_played_at)`,
            updatedAt: sql`now()`,
          },
        })
      await updateLibraryMembership(tx, userId, 'apple_live', {
        kind: 'add',
        trackIds: sql`
          SELECT id AS track_id FROM tracks
          WHERE apple_id IN (${sql.join(songs.map((s) => sql`${s.appleId}`), sql`,`)})
        `,
      }, new Date())
    })

    return c.json({ ingested: songs.length })
  })

  return app
}
