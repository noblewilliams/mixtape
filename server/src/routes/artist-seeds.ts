import { Hono } from 'hono'
import { zValidator } from '@hono/zod-validator'
import type { AppVars } from '../app'
import type { Db } from '../db/types'
import { listArtistSeeds, replaceInterviewSeeds } from '../seeds/artist-seeds'
import { putArtistSeedsSchema } from '../seeds/contracts'

// Mounted at /me/artist-seeds, behind requireSession like every other /me*
// route. Timestamps go out as Date values (ISO strings on the wire), the
// same shape /me/memories uses.
export function artistSeedsRoutes(db: Db) {
  const app = new Hono<{ Variables: AppVars }>()

  app.get('/', async (c) => {
    return c.json({ seeds: await listArtistSeeds(db, c.get('user').id) })
  })

  // Replaces the interview-sourced seeds only; pasted and export seeds are
  // owned by their own flows. Answers with the full list.
  app.put('/', zValidator('json', putArtistSeedsSchema), async (c) => {
    const userId = c.get('user').id
    const { names } = c.req.valid('json')
    const seeds = await db.transaction(async (tx) => {
      await replaceInterviewSeeds(tx, userId, names)
      return listArtistSeeds(tx, userId)
    })
    return c.json({ seeds })
  })

  return app
}
