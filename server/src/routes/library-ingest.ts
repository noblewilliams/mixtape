import { Hono, type Context } from 'hono'
import { z } from 'zod'
import { zValidator } from '@hono/zod-validator'
import type { AppVars } from '../app'
import type { Db } from '../db/types'
import {
  beginLibrarySyncSchema,
  libraryRecentTrackChunkSchema,
  librarySongChunkSchema,
} from '../library/contracts'
import {
  createLibrarySyncStore,
  LibrarySyncError,
  type LibrarySyncStore,
} from '../library/sync-store'

const syncParamSchema = z.object({ syncId: z.string().uuid() })

function errorResponse(c: Context<{ Variables: AppVars }>, error: unknown) {
  if (!(error instanceof LibrarySyncError)) throw error
  switch (error.category) {
    case 'not_found': return c.json({ error: 'not_found' }, 404)
    case 'conflict': return c.json({ error: 'sync_conflict' }, 409)
    case 'invalid_state': return c.json({ error: 'invalid_state' }, 409)
    case 'count_mismatch': return c.json({ error: 'count_mismatch' }, 409)
    case 'internal': throw error
  }
}

export function libraryIngestRoutes(
  db: Db,
  store: LibrarySyncStore = createLibrarySyncStore(db),
) {
  const app = new Hono<{ Variables: AppVars }>()

  app.post('/library/syncs', zValidator('json', beginLibrarySyncSchema), async (c) => {
    try {
      const body = c.req.valid('json')
      return c.json(await store.begin(
        c.get('user').id,
        body.source,
        body.storefront,
        body.expectedSongs,
        body.expectedRecentTracks,
      ), 201)
    } catch (error) {
      return errorResponse(c, error)
    }
  })

  app.put(
    '/library/syncs/:syncId/songs',
    zValidator('param', syncParamSchema),
    zValidator('json', librarySongChunkSchema),
    async (c) => {
      try {
        const { syncId } = c.req.valid('param')
        const { songs } = c.req.valid('json')
        await store.putSongs(c.get('user').id, syncId, songs)
        return c.json({ accepted: songs.length })
      } catch (error) {
        return errorResponse(c, error)
      }
    },
  )

  app.put(
    '/library/syncs/:syncId/recent-tracks',
    zValidator('param', syncParamSchema),
    zValidator('json', libraryRecentTrackChunkSchema),
    async (c) => {
      try {
        const { syncId } = c.req.valid('param')
        const { catalogIds } = c.req.valid('json')
        await store.putRecentTracks(c.get('user').id, syncId, catalogIds)
        return c.json({ accepted: catalogIds.length })
      } catch (error) {
        return errorResponse(c, error)
      }
    },
  )

  app.post(
    '/library/syncs/:syncId/complete',
    zValidator('param', syncParamSchema),
    async (c) => {
      try {
        const { syncId } = c.req.valid('param')
        return c.json(await store.complete(c.get('user').id, syncId))
      } catch (error) {
        return errorResponse(c, error)
      }
    },
  )

  return app
}
