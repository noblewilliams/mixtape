import { Hono } from 'hono'
import { asc, eq } from 'drizzle-orm'
import type { AppVars } from '../app'
import type { Db } from '../db/types'
import { userMusicSources } from '../db/schema'

// One listener's connected sources, by name. Shared with /me/onboarding so
// the two reads can never drift in shape: a bare row (begin registered the
// source, nothing landed) reads as never imported; timestamps go out as the
// Date values (ISO strings on the wire), the same shape /me/memories uses;
// ledger bounds stay YYYY-MM-DD or null.
export async function listMusicSources(db: Db, userId: string) {
  return db
    .select({
      source: userMusicSources.source,
      connectedAt: userMusicSources.connectedAt,
      lastImportedAt: userMusicSources.lastImportedAt,
      ledgerFrom: userMusicSources.ledgerFrom,
      ledgerTo: userMusicSources.ledgerTo,
    })
    .from(userMusicSources)
    .where(eq(userMusicSources.userId, userId))
    .orderBy(asc(userMusicSources.source))
}

// Mounted at /me/music-sources, behind requireSession like every other /me*
// route. The Music view's picture of what a listener has connected.
export function musicSourcesRoutes(db: Db) {
  const app = new Hono<{ Variables: AppVars }>()

  app.get('/', async (c) => {
    return c.json({ sources: await listMusicSources(db, c.get('user').id) })
  })

  return app
}
