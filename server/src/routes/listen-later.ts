import { Hono } from 'hono'
import { z } from 'zod'
import { zValidator } from '@hono/zod-validator'
import { and, desc, eq, isNotNull, isNull, sql } from 'drizzle-orm'
import type { AppVars } from '../app'
import type { Db } from '../db/types'
import { albumPicks, albums, djSessions, listenLater, sessionEvents } from '../db/schema'

// Listen later (spec 2026-10-20 → Listen later): a user-scoped shelf of saved
// albums. Removal is soft and re-saving revives the same row. Each state
// change (saved, unsaved, listened) records one session event when the row
// knows the session it came from; a repeat that changes nothing records
// nothing, so the taste signal counts decisions, not retries.

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

const saveSchema = z.object({ sessionId: z.uuid().optional() }).strict()

type EventType = 'album_saved' | 'album_unsaved' | 'album_listened'

const entryColumns = {
  id: albums.id,
  upc: albums.upc,
  appleId: albums.appleId,
  title: albums.title,
  artist: albums.artist,
  releaseYear: albums.releaseYear,
  type: albums.type,
  trackCount: albums.trackCount,
  durationMs: albums.durationMs,
  artworkUrl: albums.artworkUrlTemplate,
  artworkWidth: albums.artworkWidth,
  artworkHeight: albums.artworkHeight,
  artworkBgColor: albums.artworkBgColor,
  sessionId: listenLater.sessionId,
  savedAt: listenLater.savedAt,
  listenedAt: listenLater.listenedAt,
  // The DJ's "why" for this album in the session it came from, latest version.
  reason: sql<string | null>`(
    SELECT ap.reason FROM album_picks ap
    WHERE ap.session_id = ${listenLater.sessionId} AND ap.album_id = ${listenLater.albumId}
    ORDER BY ap.version DESC, ap.rank ASC
    LIMIT 1
  )`,
}

async function readEntries(db: Db, userId: string, albumId?: string) {
  const rows = await db
    .select(entryColumns)
    .from(listenLater)
    .innerJoin(albums, eq(albums.id, listenLater.albumId))
    .where(and(
      eq(listenLater.userId, userId),
      isNull(listenLater.removedAt),
      ...(albumId ? [eq(listenLater.albumId, albumId)] : []),
    ))
    // Unlistened first, newest saved first; then listened, newest listened first.
    .orderBy(isNotNull(listenLater.listenedAt), desc(sql`coalesce(${listenLater.listenedAt}, ${listenLater.savedAt})`))
  return rows.map(({ artworkUrl, artworkWidth, artworkHeight, artworkBgColor, ...rest }) => ({
    ...rest,
    artwork: artworkUrl ? { url: artworkUrl, width: artworkWidth, height: artworkHeight, bgColor: artworkBgColor } : null,
  }))
}

async function albumExists(db: Db, albumId: string): Promise<boolean> {
  const [row] = await db.select({ id: albums.id }).from(albums).where(eq(albums.id, albumId))
  return Boolean(row)
}

async function recordEvent(db: Db, sessionId: string | null, type: EventType): Promise<void> {
  if (sessionId) await db.insert(sessionEvents).values({ sessionId, type })
}

export function listenLaterRoutes(db: Db) {
  const app = new Hono<{ Variables: AppVars }>()

  app.use('/:albumId/*', async (c, next) => {
    if (!UUID_RE.test(c.req.param('albumId'))) return c.json({ error: 'not_found' }, 404)
    await next()
  })
  app.use('/:albumId', async (c, next) => {
    if (!UUID_RE.test(c.req.param('albumId'))) return c.json({ error: 'not_found' }, 404)
    await next()
  })

  app.get('/', async (c) => c.json({ entries: await readEntries(db, c.get('user').id) }))

  app.put('/:albumId', zValidator('json', saveSchema), async (c) => {
    const userId = c.get('user').id
    const albumId = c.req.param('albumId')
    const { sessionId } = c.req.valid('json')
    if (!(await albumExists(db, albumId))) return c.json({ error: 'not_found' }, 404)
    // A save names its source only when that session is the listener's own
    // album session and actually offered this album in some version.
    if (sessionId) {
      const [offered] = await db
        .select({ id: djSessions.id })
        .from(albumPicks)
        .innerJoin(djSessions, eq(djSessions.id, albumPicks.sessionId))
        .where(and(
          eq(albumPicks.sessionId, sessionId),
          eq(albumPicks.albumId, albumId),
          eq(djSessions.userId, userId),
          eq(djSessions.kind, 'album'),
        ))
        .limit(1)
      if (!offered) return c.json({ error: 'not_found' }, 404)
    }

    const now = new Date()
    const where = and(eq(listenLater.userId, userId), eq(listenLater.albumId, albumId))
    // Three single-statement steps so the transition (new or revived) is
    // read off the write itself, never off an earlier read.
    let [changed] = await db
      .update(listenLater)
      .set({ removedAt: null, savedAt: now, sessionId: sessionId ? sql`${sessionId}::uuid` : sql`${listenLater.sessionId}` })
      .where(and(where, isNotNull(listenLater.removedAt)))
      .returning({ sessionId: listenLater.sessionId })
    if (!changed) {
      ;[changed] = await db
        .insert(listenLater)
        .values({ userId, albumId, sessionId: sessionId ?? null, savedAt: now })
        .onConflictDoNothing()
        .returning({ sessionId: listenLater.sessionId })
    }
    if (changed) {
      await recordEvent(db, changed.sessionId, 'album_saved')
    } else if (sessionId) {
      // A live row is already saved: a repeat keeps its saved date and its
      // source, only filling a source it never had.
      await db
        .update(listenLater)
        .set({ sessionId: sql`coalesce(${listenLater.sessionId}, ${sessionId}::uuid)` })
        .where(and(where, isNull(listenLater.removedAt)))
    }
    const [entry] = await readEntries(db, userId, albumId)
    return c.json({ entry })
  })

  app.delete('/:albumId', async (c) => {
    const userId = c.get('user').id
    const albumId = c.req.param('albumId')
    if (!(await albumExists(db, albumId))) return c.json({ error: 'not_found' }, 404)
    const [removed] = await db
      .update(listenLater)
      .set({ removedAt: new Date() })
      .where(and(eq(listenLater.userId, userId), eq(listenLater.albumId, albumId), isNull(listenLater.removedAt)))
      .returning({ sessionId: listenLater.sessionId })
    if (removed) await recordEvent(db, removed.sessionId, 'album_unsaved')
    return c.json({ ok: true })
  })

  app.post('/:albumId/listened', async (c) => {
    const userId = c.get('user').id
    const albumId = c.req.param('albumId')
    // Keeps the first listened date: only a live, not-yet-listened row changes.
    const [marked] = await db
      .update(listenLater)
      .set({ listenedAt: new Date() })
      .where(and(
        eq(listenLater.userId, userId),
        eq(listenLater.albumId, albumId),
        isNull(listenLater.removedAt),
        isNull(listenLater.listenedAt),
      ))
      .returning({ sessionId: listenLater.sessionId })
    if (marked) await recordEvent(db, marked.sessionId, 'album_listened')
    const [entry] = await readEntries(db, userId, albumId)
    if (!entry) return c.json({ error: 'not_found' }, 404)
    return c.json({ entry })
  })

  return app
}
