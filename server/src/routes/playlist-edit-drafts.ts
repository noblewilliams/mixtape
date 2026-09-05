import { z } from 'zod'
import { Hono } from 'hono'
import { bodyLimit } from 'hono/body-limit'
import type { AppVars } from '../app'
import type { Db } from '../db/types'
import { createPlaylistEditDraftStore } from '../playlist-editing/store'
import {
  PlaylistEditDjError,
  runPlaylistEditTurn,
  type PlaylistEditDjDeps,
} from '../playlist-editing/loop'
import { playlistEditMessageSchema } from '../playlist-editing/contracts'
import { uuidParam } from './uuid-param'

const anchors = {
  afterEntryKey: z.string().uuid().optional(),
  beforeEntryKey: z.string().uuid().optional(),
}
const operationSchema = z.discriminatedUnion('type', [
  z.object({ type: z.literal('add'), trackId: z.string().uuid(), ...anchors }).strict(),
  z.object({ type: z.literal('remove'), entryKey: z.string().uuid() }).strict(),
  z.object({ type: z.literal('move'), entryKey: z.string().uuid(), ...anchors }).strict(),
  z.object({
    type: z.literal('replace'),
    entryKey: z.string().uuid(),
    trackId: z.string().uuid(),
  }).strict(),
])
const operationsSchema = z.object({
  expectedVersion: z.number().int().nonnegative(),
  operations: z.array(operationSchema).min(1).max(50),
}).strict()

export function playlistEditDraftRoutes(db: Db, djDeps?: PlaylistEditDjDeps) {
  const app = new Hono<{ Variables: AppVars }>()
  const store = createPlaylistEditDraftStore(db)

  app.get('/:draftId', uuidParam('draftId'), async (c) => {
    const view = await store.getThread(c.get('user').id, c.req.valid('param').draftId)
    return view ? c.json(view) : c.json({ error: 'not_found' }, 404)
  })

  app.post(
    '/:draftId/operations',
    bodyLimit({ maxSize: 16 * 1024 }),
    uuidParam('draftId'),
    async (c) => {
      const parsed = operationsSchema.safeParse(await c.req.json().catch(() => null))
      if (!parsed.success) return c.json({ error: 'invalid_request' }, 400)
      const result = await store.mutate(
        c.get('user').id,
        c.req.valid('param').draftId,
        parsed.data.expectedVersion,
        parsed.data.operations,
      )
      if (result.kind === 'not_found') return c.json({ error: 'not_found' }, 404)
      if (result.kind === 'version_conflict') {
        return c.json({ error: 'draft_version_conflict' }, 409)
      }
      if (result.kind === 'terminal') return c.json({ error: 'draft_not_active' }, 409)
      if (result.kind === 'invalid_track') return c.json({ error: 'track_not_eligible' }, 409)
      if (result.kind === 'invalid_operation') {
        return c.json({ error: 'invalid_operation' }, 400)
      }
      return c.json(result.view)
    },
  )

  if (djDeps) app.post(
    '/:draftId/messages',
    bodyLimit({ maxSize: 16 * 1024 }),
    uuidParam('draftId'),
    async (c) => {
      const parsed = playlistEditMessageSchema.safeParse(await c.req.json().catch(() => null))
      if (!parsed.success) return c.json({ error: 'invalid_request' }, 400)
      try {
        return c.json(await runPlaylistEditTurn(
          db,
          djDeps,
          { draftId: c.req.valid('param').draftId, userId: c.get('user').id },
          parsed.data.content.trim(),
          parsed.data.expectedVersion,
        ))
      } catch (error) {
        if (!(error instanceof PlaylistEditDjError)) throw error
        if (error.kind === 'not_found') return c.json({ error: 'not_found' }, 404)
        return c.json(
          { error: error.kind, message: error.message, ...(error.draft ? { draft: error.draft } : {}) },
          error.kind === 'conflict' ? 409 : error.kind === 'validation' ? 400 : 502,
        )
      }
    },
  )

  app.delete('/:draftId', uuidParam('draftId'), async (c) => {
    const result = await store.abandon(c.get('user').id, c.req.valid('param').draftId)
    if (result === 'not_found') return c.json({ error: 'not_found' }, 404)
    if (result === 'terminal') return c.json({ error: 'draft_not_active' }, 409)
    return c.body(null, 204)
  })

  return app
}
