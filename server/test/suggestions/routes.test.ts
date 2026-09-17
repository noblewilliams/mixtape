import { expect, it } from 'vitest'
import { Hono } from 'hono'
import { eq } from 'drizzle-orm'
import type { AppVars } from '../../src/app'
import { suggestionRoutes } from '../../src/routes/suggestions'
import { createTestDb } from '../helpers/db'
import {
  user,
  djSessions,
  mixVersions,
  tracks,
  userTracks,
} from '../../src/db/schema'
it('isolates accounts, rechecks availability and persists dismissal/off without generating a mix', async () => {
  const db = await createTestDb()
  const now = new Date('2026-09-18T18:00Z')
  await db.insert(user).values(
    ['u', 'other'].map((id) => ({
      id,
      name: id,
      email: `${id}@example.test`,
      emailVerified: false,
    })),
  )
  const songs = await db
    .insert(tracks)
    .values([1, 2, 3].map((n) => ({ title: `Song ${n}`, artist: 'Artist' })))
    .returning()
  await db
    .insert(userTracks)
    .values(songs.map((t) => ({ userId: 'u', trackId: t.id })))
  for (const day of ['2026-08-28', '2026-09-04', '2026-09-11']) {
    const [s] = await db
      .insert(djSessions)
      .values({
        userId: 'u',
        title: 'Private prompt never used',
        queueVersion: 1,
        createdAt: new Date(`${day}T18:00Z`),
      })
      .returning()
    await db.insert(mixVersions).values({
      sessionId: s.id,
      version: 1,
      energyArc: 'fall',
      entries: songs.map((t, position) => ({
        position,
        trackId: t.id,
        reason: 'chosen',
        addedBy: 'dj',
      })),
    })
  }
  const app = new Hono<{ Variables: AppVars }>()
  app.use('*', async (c, next) => {
    c.set('user', { id: c.req.header('owner') ?? 'u' } as AppVars['user'])
    await next()
  })
  app.route(
    '/suggestions',
    suggestionRoutes(db, () => now),
  )
  const get = async (owner = 'u') =>
    (
      await app.request('http://x/suggestions?timeZone=UTC', {
        headers: { owner },
      })
    ).json()
  const post = (path: string, body: unknown) =>
    app.request(`http://x/suggestions/${path}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body),
    })
  expect(await get()).toMatchObject({
    enabled: true,
    suggestion: { id: '5-3-fall' },
  })
  expect(JSON.stringify(await get())).not.toContain('Private')
  expect(await get('other')).toMatchObject({ suggestion: null })
  expect((await app.request('http://x/suggestions?timeZone=bad')).status).toBe(
    400,
  )
  await db
    .update(djSessions)
    .set({ status: 'archived' })
    .where(eq(djSessions.userId, 'u'))
  expect(await get()).toMatchObject({ suggestion: null })
  await db
    .update(djSessions)
    .set({ status: 'active', notPersonal: true })
    .where(eq(djSessions.userId, 'u'))
  expect(await get()).toMatchObject({ suggestion: null })
  await db
    .update(djSessions)
    .set({ notPersonal: false })
    .where(eq(djSessions.userId, 'u'))
  const [changed] = await db.select().from(djSessions).limit(1)
  await db.insert(mixVersions).values({
    sessionId: changed.id,
    version: 2,
    energyArc: 'rise',
    entries: [],
  })
  await db
    .update(djSessions)
    .set({ queueVersion: 2 })
    .where(eq(djSessions.id, changed.id))
  expect(await get()).toMatchObject({ suggestion: { id: '5-3-fall' } })
  const selection = { id: '5-3-fall', timeZone: 'UTC' }
  expect((await post('select', selection)).status).toBe(200)
  expect(await db.select().from(djSessions)).toHaveLength(3)
  await db
    .update(userTracks)
    .set({ inLibrary: false })
    .where(eq(userTracks.userId, 'u'))
  expect((await post('select', selection)).status).toBe(409)
  await db
    .update(userTracks)
    .set({ inLibrary: true })
    .where(eq(userTracks.userId, 'u'))
  expect((await post('dismiss', selection)).status).toBe(200)
  expect(await get()).toMatchObject({ suggestion: null, dismissed: true })
  expect((await post('select', selection)).status).toBe(409)
  now.setUTCDate(25)
  expect(await get()).toMatchObject({ suggestion: { id: '5-3-fall' } })
  expect((await post('preferences', { enabled: false })).status).toBe(200)
  expect(await get()).toMatchObject({ enabled: false, suggestion: null })
  expect((await post('select', selection)).status).toBe(409)
})
