import { Hono } from 'hono'
import { zValidator } from '@hono/zod-validator'
import { z } from 'zod'
import type { Db } from '../db/types'
import type { AppVars } from '../app'
import {
  batchSchema,
  PlaybackError,
  playbackPreferences,
  savePlaybackPreference,
  clearPlaybackEvidence,
  ingestPlayback,
} from '../playback/store'
export function playbackRoutes(db: Db) {
  const app = new Hono<{ Variables: AppVars }>()
  app.onError((error, c) =>
    c.json(
      { error: 'playback_unavailable' },
      error instanceof PlaybackError ? error.status : 500,
    ),
  )
  app.get('/preferences', async (c) =>
    c.json({
      ...(await playbackPreferences(db, c.get('user').id)),
      userId: c.get('user').id,
    }),
  )
  app.put(
    '/preferences',
    zValidator('json', z.object({ enabled: z.boolean() }).strict()),
    async (c) =>
      c.json(
        await savePlaybackPreference(
          db,
          c.get('user').id,
          c.req.valid('json').enabled,
        ),
      ),
  )
  app.post(
    '/clear',
    zValidator(
      'json',
      z
        .object({
          requestId: z.string().min(1).max(100),
          revision: z.number().int().min(0),
        })
        .strict(),
    ),
    async (c) =>
      c.json(
        await clearPlaybackEvidence(
          db,
          c.get('user').id,
          c.req.valid('json').requestId,
          c.req.valid('json').revision,
        ),
      ),
  )
  app.post('/events', zValidator('json', batchSchema), async (c) =>
    c.json(await ingestPlayback(db, c.get('user').id, c.req.valid('json'))),
  )
  return app
}
