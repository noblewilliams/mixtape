import { it, expect } from 'vitest'
import { Hono } from 'hono'
import type { AppVars } from '../../src/app'
import { createTestDb } from '../helpers/db'
import { mixHistoryRoutes } from '../../src/routes/mix-history'
import { user, djSessions, tracks } from '../../src/db/schema'
import { replaceQueue } from '../../src/dj/queue-store'
it('serves owner snapshots, validates input and rejects foreign or stale restore', async () => {
  const db = await createTestDb()
  await db
    .insert(user)
    .values({
      id: 'owner',
      name: 'Owner',
      email: 'owner@example.test',
      emailVerified: false,
    })
  const [session] = await db
    .insert(djSessions)
    .values({ userId: 'owner', title: 'Test' })
    .returning()
  const [song] = await db
    .insert(tracks)
    .values({ title: 'Test', artist: 'Test' })
    .returning()
  await replaceQueue(
    db,
    session.id,
    [{ trackId: song.id, reason: 'test' }],
    'dj',
  )
  let viewer = 'owner'
  const app = new Hono<{ Variables: AppVars }>()
  app.use('*', async (c, next) => {
    c.set('user', { id: viewer } as AppVars['user'])
    await next()
  })
  app.route('/sessions', mixHistoryRoutes(db))
  const base = `http://x/sessions/${session.id}/versions`
  expect((await app.request(base)).status).toBe(200)
  expect((await app.request(base + '/1')).status).toBe(200)
  expect((await app.request(base + '?before=0')).status).toBe(400)
  const post = (body: unknown) =>
    app.request(base + '/restore', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    })
  expect(
    (await post({ version: 1, expectedVersion: 0, requestId: 'stale' })).status,
  ).toBe(409)
  expect(
    (await post({ version: 1, expectedVersion: 1, requestId: 'ok' })).status,
  ).toBe(200)
  viewer = 'foreign'
  expect((await app.request(base)).status).toBe(404)
  expect(
    (await post({ version: 1, expectedVersion: 2, requestId: 'foreign' }))
      .status,
  ).toBe(404)
  expect((await app.request('http://x/sessions/bad/versions')).status).toBe(404)
})
