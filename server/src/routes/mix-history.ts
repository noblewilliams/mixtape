import { Hono } from 'hono'
import { z } from 'zod'
import { zValidator } from '@hono/zod-validator'
import { createMiddleware } from 'hono/factory'
import { and, eq } from 'drizzle-orm'
import { djSessions } from '../db/schema'
import type { AppVars } from '../app'
import type { Db } from '../db/types'
import {
  listMixVersions,
  readMixVersion,
  restoreMixVersion,
  MixHistoryError,
} from '../dj/mix-history'
const version = z.coerce.number().int().min(1).max(2147483647)
export function mixHistoryRoutes(db: Db) {
  const app = new Hono<{ Variables: AppVars }>()
  app.onError((e, c) => {
    if (e instanceof MixHistoryError)
      return c.json({ error: e.kind }, e.kind === 'not_found' ? 404 : 409)
    return c.json({ error: 'internal_error' }, 500)
  })
  app.use('/:id/*', async (c, next) => {
    if (!z.uuid().safeParse(c.req.param('id')).success)
      return c.json({ error: 'not_found' }, 404)
    await next()
  })
  // Mix history is mix-only: an album session's versions are pick versions,
  // served by POST /sessions/:id/pick, so these routes refuse it before any
  // version read. Scoped to the versions paths because this group is mounted
  // at the sessions root and '/:id/*' would catch every session route.
  const mixOnly = createMiddleware<{ Variables: AppVars }>(async (c, next) => {
    const [row] = await db
      .select({ kind: djSessions.kind })
      .from(djSessions)
      .where(and(eq(djSessions.id, c.req.param('id')!), eq(djSessions.userId, c.get('user').id)))
    if (row && row.kind !== 'mix') return c.json({ error: 'wrong_session_kind' }, 409)
    await next()
  })
  app.use('/:id/versions', mixOnly)
  app.use('/:id/versions/*', mixOnly)
  app.get(
    '/:id/versions',
    zValidator('query', z.object({ before: version.optional() })),
    async (c) =>
      c.json(
        await listMixVersions(
          db,
          c.req.param('id'),
          c.get('user').id,
          c.req.valid('query').before,
        ),
      ),
  )
  app.get(
    '/:id/versions/:version',
    zValidator('param', z.object({ id: z.uuid(), version })),
    async (c) =>
      c.json(
        await readMixVersion(
          db,
          c.req.param('id'),
          c.get('user').id,
          c.req.valid('param').version,
        ),
      ),
  )
  app.post(
    '/:id/versions/restore',
    zValidator(
      'json',
      z
        .object({
          version: version,
          expectedVersion: z.number().int().min(0).max(2147483646),
          requestId: z
            .string()
            .min(1)
            .max(100)
            .regex(/^[a-zA-Z0-9_-]+$/),
        })
        .strict(),
    ),
    async (c) =>
      c.json(
        await restoreMixVersion(
          db,
          c.req.param('id'),
          c.get('user').id,
          c.req.valid('json'),
        ),
      ),
  )
  return app
}
