import { Hono, type Context } from 'hono'
import { zValidator } from '@hono/zod-validator'
import type { AppVars } from '../app'
import type { Db } from '../db/types'
import {
  beginPlaylistSyncSchema,
  playlistChunkSchema,
  playlistEntryChunkSchema,
} from '../playlists/contracts'
import {
  createPlaylistSyncStore,
  PlaylistSyncError,
  type PlaylistSyncStore,
} from '../playlists/sync-store'
import { uuidParam } from './uuid-param'

// A malformed :syncId is the same 404 as a run the caller cannot see.
const syncParam = () => uuidParam('syncId')

function errorResponse(c: Context<{ Variables: AppVars }>, error: unknown) {
  if (!(error instanceof PlaylistSyncError)) throw error
  switch (error.category) {
    case 'not_found': return c.json({ error: 'not_found' }, 404)
    case 'conflict': return c.json({ error: 'sync_conflict' }, 409)
    case 'invalid_state': return c.json({ error: 'invalid_state' }, 409)
    case 'count_mismatch': return c.json({ error: 'count_mismatch' }, 409)
    case 'invalid_storefront': return c.json({ error: 'invalid_storefront' }, 400)
    case 'internal': throw error
  }
}

export function playlistIngestRoutes(
  db: Db,
  store: PlaylistSyncStore = createPlaylistSyncStore(db),
) {
  const app = new Hono<{ Variables: AppVars }>()

  app.post('/playlists/syncs', zValidator('json', beginPlaylistSyncSchema), async (c) => {
    try {
      const body = c.req.valid('json')
      const result = await store.begin(
        c.get('user').id,
        body.storefront,
        body.expectedPlaylists,
        body.expectedEntries,
        body.source,
        body.review,
      )
      return c.json(result, 201)
    } catch (error) {
      return errorResponse(c, error)
    }
  })

  app.put(
    '/playlists/syncs/:syncId/playlists',
    syncParam(),
    zValidator('json', playlistChunkSchema),
    async (c) => {
      try {
        const { syncId } = c.req.valid('param')
        const { playlists } = c.req.valid('json')
        await store.putPlaylists(c.get('user').id, syncId, playlists)
        return c.json({ accepted: playlists.length })
      } catch (error) {
        return errorResponse(c, error)
      }
    },
  )

  app.put(
    '/playlists/syncs/:syncId/entries',
    syncParam(),
    zValidator('json', playlistEntryChunkSchema),
    async (c) => {
      try {
        const { syncId } = c.req.valid('param')
        const { playlistAppleId, entries } = c.req.valid('json')
        await store.putEntries(c.get('user').id, syncId, playlistAppleId, entries)
        return c.json({ accepted: entries.length })
      } catch (error) {
        return errorResponse(c, error)
      }
    },
  )

  app.post(
    '/playlists/syncs/:syncId/complete',
    syncParam(),
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
