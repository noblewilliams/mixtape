import { expect, it } from 'vitest'
import { Hono } from 'hono'
import type { AppVars } from '../../src/app'
import { playbackRoutes } from '../../src/routes/playback'
import { createTestDb } from '../helpers/db'
import { user } from '../../src/db/schema'
it('validates preference and clear requests and defaults to no collection', async () => {
  const db = await createTestDb()
  await db
    .insert(user)
    .values({
      id: 'u',
      email: 'u@example.test',
      name: 'U',
      emailVerified: false,
    })
  const app = new Hono<{ Variables: AppVars }>()
  app.use('*', async (c, next) => {
    c.set('user', { id: 'u' } as AppVars['user'])
    await next()
  })
  app.route('/playback', playbackRoutes(db))
  expect(
    await (await app.request('http://x/playback/preferences')).json(),
  ).toMatchObject({ enabled: false, revision: 0, userId: 'u' })
  expect(
    (
      await app.request('http://x/playback/preferences', {
        method: 'PUT',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ enabled: 'yes' }),
      })
    ).status,
  ).toBe(400)
  expect(
    (
      await app.request('http://x/playback/clear', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ requestId: 'clear' }),
      })
    ).status,
  ).toBe(400)
  expect(
    (
      await app.request('http://x/playback/events', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ revision: 0, events: [] }),
      })
    ).status,
  ).toBe(400)
})
