import { Hono } from 'hono'
import { asc, eq } from 'drizzle-orm'
import type { AppVars } from '../app'
import type { Db } from '../db/types'
import { userMusicSources } from '../db/schema'

// Mounted at /me/music-sources, behind requireSession like every other /me*
// route. The Music view's picture of what a listener has connected: a bare
// row (begin registered the source, nothing landed) reads as never imported.
export function musicSourcesRoutes(db: Db) {
  const app = new Hono<{ Variables: AppVars }>()

  app.get('/', async (c) => {
    const rows = await db
      .select({
        source: userMusicSources.source,
        connectedAt: userMusicSources.connectedAt,
        lastImportedAt: userMusicSources.lastImportedAt,
        ledgerFrom: userMusicSources.ledgerFrom,
        ledgerTo: userMusicSources.ledgerTo,
      })
      .from(userMusicSources)
      .where(eq(userMusicSources.userId, c.get('user').id))
      .orderBy(asc(userMusicSources.source))
    return c.json({
      sources: rows.map((row) => ({
        source: row.source,
        connectedAt: row.connectedAt.getTime(),
        lastImportedAt: row.lastImportedAt?.getTime() ?? null,
        ledgerFrom: row.ledgerFrom,
        ledgerTo: row.ledgerTo,
      })),
    })
  })

  return app
}
