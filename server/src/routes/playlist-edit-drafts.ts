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
import { createPlaylistApplyStore } from '../playlist-editing/apply'
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
const fingerprintSchema = z.string().regex(/^[0-9a-f]{64}$/)
const prepareApplySchema = z.object({
  expectedVersion: z.number().int().nonnegative(),
  currentSourceFingerprint: fingerprintSchema,
  clientCapabilities: z.object({
    revisedCopy: z.boolean(),
    append: z.boolean(),
    rebuildReceiptClasses: z.array(z.string().min(1).max(100)).max(20),
  }).strict(),
}).strict()
const confirmApplySchema = z.object({
  operationId: z.string().uuid(),
  expectedVersion: z.number().int().nonnegative(),
  appliedMode: z.literal('revised_copy'),
  applePlaylistLibraryId: z.string().min(1).max(500).regex(/^[A-Za-z0-9._~-]+$/),
  resultingFingerprint: fingerprintSchema,
}).strict()

export function playlistEditDraftRoutes(db: Db, djDeps?: PlaylistEditDjDeps) {
  const app = new Hono<{ Variables: AppVars }>()
  const store = createPlaylistEditDraftStore(db)
  const applies = createPlaylistApplyStore(db)

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

  app.post(
    '/:draftId/prepare-apply',
    bodyLimit({ maxSize: 4 * 1024 }),
    uuidParam('draftId'),
    async (c) => {
      const parsed = prepareApplySchema.safeParse(await c.req.json().catch(() => null))
      if (!parsed.success) return c.json({ error: 'invalid_request' }, 400)
      const result = await applies.prepare(
        c.get('user').id,
        c.req.valid('param').draftId,
        parsed.data.expectedVersion,
        parsed.data.currentSourceFingerprint,
        parsed.data.clientCapabilities.revisedCopy,
      )
      if (result.kind === 'not_found') return c.json({ error: 'not_found' }, 404)
      if (result.kind === 'version_conflict') {
        return c.json({ error: 'draft_version_conflict' }, 409)
      }
      if (result.kind === 'source_conflict') return c.json({ error: 'source_conflict' }, 409)
      if (result.kind === 'blocked') {
        return c.json({ error: 'apply_blocked', unresolved: result.unresolved }, 409)
      }
      if (result.kind === 'no_changes') return c.json({ error: 'no_changes' }, 409)
      if (result.kind === 'unsupported_client') {
        return c.json({ error: 'unsupported_client' }, 409)
      }
      if (result.kind === 'terminal') return c.json({ error: 'draft_not_active' }, 409)
      return c.json(result.plan)
    },
  )

  app.post(
    '/:draftId/confirm-apply',
    bodyLimit({ maxSize: 4 * 1024 }),
    uuidParam('draftId'),
    async (c) => {
      const parsed = confirmApplySchema.safeParse(await c.req.json().catch(() => null))
      if (!parsed.success) return c.json({ error: 'invalid_request' }, 400)
      const result = await applies.confirm(
        c.get('user').id,
        c.req.valid('param').draftId,
        parsed.data,
      )
      if (result.kind === 'not_found') return c.json({ error: 'not_found' }, 404)
      if (result.kind === 'version_conflict') {
        return c.json({ error: 'draft_version_conflict' }, 409)
      }
      if (result.kind === 'result_mismatch') {
        return c.json({ error: 'apply_result_mismatch' }, 409)
      }
      if (result.kind === 'plan_mismatch') return c.json({ error: 'apply_plan_mismatch' }, 409)
      if (result.kind === 'terminal') return c.json({ error: 'draft_not_ready' }, 409)
      return c.json(result.confirmation)
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
