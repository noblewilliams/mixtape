import { spotifyCollectionReview } from '../listening/collection-review'
import { Hono, type Context } from 'hono'
import { z } from 'zod'
import { zValidator } from '@hono/zod-validator'
import type { AppVars } from '../app'
import type { Db } from '../db/types'
import {
  beginListeningImportSchema,
  listeningArtistChunkSchema,
  listeningDayChunkSchema,
  listeningImportSourceSchema,
  listeningLibraryChunkSchema,
  listeningTrackChunkSchema,
} from '../listening/contracts'
import {
  createListeningImportStore,
  ListeningImportError,
  type ListeningImportStore,
} from '../listening/import-store'
import { uuidParam } from './uuid-param'

type Env = { Variables: AppVars }

// A malformed :importId is the same 404 as a run the caller cannot see.
const importParam = () => uuidParam('importId')

const sourceParamSchema = z.object({ source: listeningImportSourceSchema })

// Same bodies as the library and playlist staging routes, so one client
// helper covers all three protocols; invalid_id is the listening-only extra.
function errorResponse(c: Context<Env>, error: unknown) {
  if (!(error instanceof ListeningImportError)) throw error
  switch (error.category) {
    case 'not_found': return c.json({ error: 'not_found' }, 404)
    case 'conflict': return c.json({ error: 'sync_conflict' }, 409)
    case 'invalid_state': return c.json({ error: 'invalid_state' }, 409)
    case 'count_mismatch': return c.json({ error: 'count_mismatch' }, 409)
    case 'invalid_id': return c.json({ error: 'invalid_id' }, 400)
    case 'internal': throw error
  }
}

export function listeningIngestRoutes(
  db: Db,
  store: ListeningImportStore = createListeningImportStore(db),
) {
  const app = new Hono<Env>()

  app.get('/listening/spotify/review', async c => c.json(await spotifyCollectionReview(db,c.get('user').id)))

  app.post('/listening/imports', zValidator('json', beginListeningImportSchema), async (c) => {
    try {
      return c.json(await store.begin(c.get('user').id, c.req.valid('json')), 201)
    } catch (error) {
      return errorResponse(c, error)
    }
  })

  app.put(
    '/listening/imports/:importId/tracks',
    importParam(),
    zValidator('json', listeningTrackChunkSchema),
    async (c) => {
      try {
        const { importId } = c.req.valid('param')
        const { tracks } = c.req.valid('json')
        await store.putTracks(c.get('user').id, importId, tracks)
        return c.json({ accepted: tracks.length })
      } catch (error) {
        return errorResponse(c, error)
      }
    },
  )

  app.put(
    '/listening/imports/:importId/days',
    importParam(),
    zValidator('json', listeningDayChunkSchema),
    async (c) => {
      try {
        const { importId } = c.req.valid('param')
        const { days } = c.req.valid('json')
        await store.putDays(c.get('user').id, importId, days)
        return c.json({ accepted: days.length })
      } catch (error) {
        return errorResponse(c, error)
      }
    },
  )

  app.put(
    '/listening/imports/:importId/library',
    importParam(),
    zValidator('json', listeningLibraryChunkSchema),
    async (c) => {
      try {
        const { importId } = c.req.valid('param')
        const { tracks } = c.req.valid('json')
        await store.putLibrary(c.get('user').id, importId, tracks)
        return c.json({ accepted: tracks.length })
      } catch (error) {
        return errorResponse(c, error)
      }
    },
  )

  app.put(
    '/listening/imports/:importId/artists',
    importParam(),
    zValidator('json', listeningArtistChunkSchema),
    async (c) => {
      try {
        const { importId } = c.req.valid('param')
        const { artists } = c.req.valid('json')
        await store.putArtists(c.get('user').id, importId, artists)
        return c.json({ accepted: artists.length })
      } catch (error) {
        return errorResponse(c, error)
      }
    },
  )

  app.post('/listening/imports/:importId/complete', importParam(), async (c) => {
    try {
      const { importId } = c.req.valid('param')
      return c.json(await store.complete(c.get('user').id, importId))
    } catch (error) {
      return errorResponse(c, error)
    }
  })

  app.delete('/listening/sources/:source', zValidator('param', sourceParamSchema), async (c) => {
    try {
      const { source } = c.req.valid('param')
      return c.json(await store.deleteSource(c.get('user').id, source))
    } catch (error) {
      return errorResponse(c, error)
    }
  })

  return app
}
