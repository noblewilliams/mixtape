import { describe, it, expect } from 'vitest'
import { createTestDb } from '../helpers/db'
import { okDeps } from '../helpers/enrich-fixtures'
import { createApp, type AuthLike } from '../../src/app'
import { tracks } from '../../src/db/schema'

const auth: AuthLike = { handler: () => new Response('ok'), api: { getSession: async () => null } }

describe('/enrich routes', () => {
  it('rejects without or with a wrong admin token', async () => {
    const db = await createTestDb()
    const app = createApp({ auth, db, enrich: { deps: okDeps, adminToken: 'secret' } })
    expect((await app.request('http://x/enrich/status')).status).toBe(401)
    expect((await app.request('http://x/enrich/status', { headers: { 'X-Admin-Token': 'wrong' } })).status).toBe(401)
    expect((await app.request('http://x/enrich/run', { method: 'POST' })).status).toBe(401)
  })

  it('runs a batch and reports status with the token', async () => {
    const db = await createTestDb()
    await db.insert(tracks).values({ appleId: 'r1', title: 'T', artist: 'A' })
    const app = createApp({ auth, db, enrich: { deps: okDeps, adminToken: 'secret' } })
    const run = await app.request('http://x/enrich/run?limit=5', {
      method: 'POST',
      headers: { 'X-Admin-Token': 'secret' },
    })
    expect(run.status).toBe(200)
    expect(await run.json()).toMatchObject({ processed: 1, features: 1, meaning: 1, remaining: 0 })
    const status = await app.request('http://x/enrich/status', { headers: { 'X-Admin-Token': 'secret' } })
    expect(status.status).toBe(200)
    expect(await status.json()).toMatchObject({ tracks: 1, withFeatures: 1 })
  })

  it('clamps limit to the batch ceiling', async () => {
    const db = await createTestDb()
    for (let i = 0; i < 12; i++) await db.insert(tracks).values({ appleId: `c${i}`, title: 'T', artist: 'A' })
    const app = createApp({ auth, db, enrich: { deps: okDeps, adminToken: 'secret' } })
    const run = await app.request('http://x/enrich/run?limit=999', {
      method: 'POST',
      headers: { 'X-Admin-Token': 'secret' },
    })
    expect(((await run.json()) as { processed: number }).processed).toBe(8)
  })

  it('clamps a fractional limit down to an integer', async () => {
    const db = await createTestDb()
    for (let i = 0; i < 3; i++) await db.insert(tracks).values({ appleId: `f${i}`, title: 'T', artist: 'A' })
    const app = createApp({ auth, db, enrich: { deps: okDeps, adminToken: 'secret' } })
    const run = await app.request('http://x/enrich/run?limit=2.5', {
      method: 'POST',
      headers: { 'X-Admin-Token': 'secret' },
    })
    expect(run.status).toBe(200)
    expect(((await run.json()) as { processed: number }).processed).toBe(2)
  })

  it('clamps a fractional limit under 1 up to 1 instead of a no-op LIMIT 0', async () => {
    const db = await createTestDb()
    for (let i = 0; i < 3; i++) await db.insert(tracks).values({ appleId: `h${i}`, title: 'T', artist: 'A' })
    const app = createApp({ auth, db, enrich: { deps: okDeps, adminToken: 'secret' } })
    const run = await app.request('http://x/enrich/run?limit=0.5', {
      method: 'POST',
      headers: { 'X-Admin-Token': 'secret' },
    })
    expect(run.status).toBe(200)
    expect(((await run.json()) as { processed: number }).processed).toBeGreaterThanOrEqual(1)
  })

  it('enrich routes absent when wiring not provided', async () => {
    const db = await createTestDb()
    const app = createApp({ auth, db })
    expect((await app.request('http://x/enrich/status')).status).toBe(404)
  })
})
