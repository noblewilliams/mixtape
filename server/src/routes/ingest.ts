import { Hono } from 'hono'
import { z } from 'zod'
import { zValidator } from '@hono/zod-validator'
import { sql } from 'drizzle-orm'
import { tracks, userTracks } from '../db/schema'
import type { AppVars } from '../app'
import type { Db } from '../db/types'

const songSchema = z.object({
  appleId: z.string().min(1),
  title: z.string().min(1),
  artist: z.string().min(1),
  album: z.string().nullable().optional(),
  genre: z.string().nullable().optional(),
  playCount: z.number().int().min(0),
  lastPlayedAt: z.number().int().nullable().optional(),
  dateAdded: z.number().int().nullable().optional(),
})

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
    const userId = c.get('user').id

    const trackRows = await db
      .insert(tracks)
      .values(
        songs.map((s) => ({
          appleId: s.appleId,
          title: s.title,
          artist: s.artist,
          album: s.album ?? null,
          genre: s.genre ?? null,
        })),
      )
      .onConflictDoUpdate({
        target: tracks.appleId,
        targetWhere: sql`apple_id is not null`,
        set: { title: sql`excluded.title`, artist: sql`excluded.artist` },
      })
      .returning({ id: tracks.id, appleId: tracks.appleId })

    const idByAppleId = new Map(trackRows.map((t) => [t.appleId, t.id]))

    await db
      .insert(userTracks)
      .values(
        songs.map((s) => ({
          userId,
          trackId: idByAppleId.get(s.appleId)!,
          playCount: s.playCount,
          lastPlayedAt: toDate(s.lastPlayedAt),
          dateAdded: toDate(s.dateAdded),
          inLibrary: true,
        })),
      )
      .onConflictDoUpdate({
        target: [userTracks.userId, userTracks.trackId],
        set: {
          playCount: sql`excluded.play_count`,
          lastPlayedAt: sql`excluded.last_played_at`,
          inLibrary: sql`excluded.in_library`,
          updatedAt: sql`now()`,
        },
      })

    return c.json({ ingested: songs.length })
  })

  return app
}
