import { Hono } from 'hono'
import { and, eq, exists, sql } from 'drizzle-orm'
import type { AppVars } from '../app'
import type { Db } from '../db/types'
import { djMemories, funnelEvents, userArtistSeeds, userTracks } from '../db/schema'
import type { FunnelEventType } from '../seeds/contracts'
import { musicReady, onSpotifySql } from '../dj/pool'
import { listMusicSources } from './music-sources'

// Mounted at /me/onboarding, behind requireSession like every other /me*
// route. One read for both clients' service gate and waiting state: what is
// connected (same rows and serialization as /me/music-sources), whether any
// library landed, which service the listener is on, and when they first
// took each Spotify funnel step (spec 2026-09-01 → Funnel), and whether a
// mix would draw from their own music (musicReady, spec 2026-11-09
// add-your-music-loop → decision 6). All scoped to the caller, in parallel.
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

    const [sources, [state], ready] = await Promise.all([
      listMusicSources(db, userId),
      db
        .select({
          hasLibrary: sql<boolean>`${hasLibrary}`,
          onSpotify: sql<boolean>`${onSpotifySql(userId)}`,
          markedRequestedAt: firstAt('marked_requested'),
          interviewCompletedAt: firstAt('interview_completed'),
          importCompletedAt: firstAt('import_completed'),
        })
        .from(funnelEvents)
        .where(eq(funnelEvents.userId, userId)),
      musicReady(db, userId),
    ])

    // Choosing Spotify, or a Spotify export source, wins outright
    // (dj/pool.ts onSpotifySql, which the DJ's history pill reads too).
    // Apple is inferred from evidence (a synced or exported library, or any
    // Apple source), since the Apple path never posts a "chose" event.
    // hasLibrary alone cannot mean Apple: a Spotify account package marks
    // liked tracks in_library too, which is why the Spotify check comes first.
    const hasAppleSource = sources.some((s) => s.source === 'apple_live' || s.source === 'apple_export')
    const chosenService = state.onSpotify
      ? 'spotify'
      : state.hasLibrary || hasAppleSource
        ? 'apple'
        : null

    // What the interview produced, for the "Interview done" tile: artists are
    // the interview-sourced seeds; notes are the memory notes carrying the
    // interview's fixed prefixes (see routes/interview.ts). Null until the
    // interview has been completed at all.
    const interview = state.interviewCompletedAt
      ? await (async () => {
        const [[artists], [notes]] = await Promise.all([
          db
            .select({ count: sql<number>`count(*)::int` })
            .from(userArtistSeeds)
            .where(and(eq(userArtistSeeds.userId, userId), eq(userArtistSeeds.source, 'interview'))),
          db
            .select({ count: sql<number>`count(*)::int` })
            .from(djMemories)
            .where(and(
              eq(djMemories.userId, userId),
              sql`(${djMemories.note} LIKE 'Never skips: %' OR ${djMemories.note} LIKE 'Plays most: %' OR ${djMemories.note} LIKE 'Listens when: %' OR ${djMemories.note} LIKE 'Never wants: %' OR ${djMemories.note} LIKE 'Era: %')`,
            )),
        ])
        return { artists: Number(artists?.count ?? 0), notes: Number(notes?.count ?? 0) }
      })()
      : null

    return c.json({
      // The clients key their per-device "service chosen" flag by user id.
      userId,
      sources,
      hasLibrary: state.hasLibrary,
      chosenService,
      markedRequestedAt: state.markedRequestedAt,
      interviewCompletedAt: state.interviewCompletedAt,
      importCompletedAt: state.importCompletedAt,
      interview,
      // The remake button's gate: true only when the DJ would draw this
      // listener's mix from their own music (dj/pool.ts musicReady).
      musicReady: ready,
    })
  })

  return app
}
