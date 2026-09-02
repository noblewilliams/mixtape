import { Hono } from 'hono'
import { and, eq, exists, sql } from 'drizzle-orm'
import type { AppVars } from '../app'
import type { Db } from '../db/types'
import { funnelEvents, userTracks } from '../db/schema'
import type { FunnelEventType } from '../seeds/contracts'
import { listMusicSources } from './music-sources'

// Mounted at /me/onboarding, behind requireSession like every other /me*
// route. One read for both clients' service gate and waiting state: what is
// connected (same rows and serialization as /me/music-sources), whether any
// library landed, which service the listener is on, and when they first
// took each Spotify funnel step (spec 2026-09-01 → Funnel). Two queries,
// both scoped to the caller.
export function onboardingRoutes(db: Db) {
  const app = new Hono<{ Variables: AppVars }>()

  app.get('/', async (c) => {
    const userId = c.get('user').id

    // The earliest row of one funnel step, or null when the listener never
    // took it. An aggregate with no GROUP BY always yields exactly one row,
    // so a listener with no funnel rows still reads every step as null.
    const firstAt = (type: FunnelEventType) =>
      sql`min(${funnelEvents.createdAt}) filter (where ${funnelEvents.type} = ${type})`.mapWith(funnelEvents.createdAt)
    const hasLibrary = exists(
      db
        .select({ one: sql`1` })
        .from(userTracks)
        .where(and(eq(userTracks.userId, userId), eq(userTracks.inLibrary, true))),
    )

    const [sources, [state]] = await Promise.all([
      listMusicSources(db, userId),
      db
        .select({
          hasLibrary: sql<boolean>`${hasLibrary}`,
          choseSpotifyAt: firstAt('chose_spotify'),
          markedRequestedAt: firstAt('marked_requested'),
          interviewCompletedAt: firstAt('interview_completed'),
          importCompletedAt: firstAt('import_completed'),
        })
        .from(funnelEvents)
        .where(eq(funnelEvents.userId, userId)),
    ])

    // Choosing Spotify is an explicit act and wins outright, and so does a
    // completed Spotify import (the "chose" event is fire-and-forget, and a
    // listener who already holds the ZIP never walks the request flow).
    // Apple is inferred from evidence (a synced or exported library, or any
    // Apple source), since the Apple path never posts a "chose" event.
    // hasLibrary alone cannot mean Apple: a Spotify account package marks
    // liked tracks in_library too, which is why the Spotify checks come first.
    const hasSpotifySource = sources.some((s) => s.source === 'spotify_export')
    const hasAppleSource = sources.some((s) => s.source === 'apple_live' || s.source === 'apple_export')
    const chosenService = state.choseSpotifyAt || hasSpotifySource
      ? 'spotify'
      : state.hasLibrary || hasAppleSource
        ? 'apple'
        : null

    return c.json({
      sources,
      hasLibrary: state.hasLibrary,
      chosenService,
      markedRequestedAt: state.markedRequestedAt,
      interviewCompletedAt: state.interviewCompletedAt,
      importCompletedAt: state.importCompletedAt,
    })
  })

  return app
}
