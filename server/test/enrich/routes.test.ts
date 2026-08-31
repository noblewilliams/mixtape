import { describe, it, expect } from 'vitest'
import { createTestDb } from '../helpers/db'
import { okDeps } from '../helpers/enrich-fixtures'
import { createApp, type AuthLike } from '../../src/app'
import { tracks } from '../../src/db/schema'
import type { ArtworkDeps } from '../../src/artwork/runner'
import type { CatalogSong } from '../../src/musickit/catalog'

const auth: AuthLike = { handler: () => new Response('ok'), api: { getSession: async () => null } }

function artworkDeps(): ArtworkDeps {
  return {
    storefront: 'ng',
    now: () => new Date('2026-08-31T12:00:00Z'),
    catalog: {
      getSongs: async (_storefront, ids) =>
        new Map<string, CatalogSong>(
          ids.map((id) => [
            id,
            {
              appleId: id,
              isrc: null,
              title: `Song ${id}`,
              artist: 'Artist',
              album: null,
              artwork: {
                url: `https://is1-ssl.mzstatic.com/image/thumb/${id}/{w}x{h}.{f}`,
                width: 1000,
                height: 1000,
                bgColor: 'abcdef',
              },
            },
          ]),
        ),
    },
  }
}

describe('/enrich routes', () => {
  it('rejects a missing admin token', async () => {
    const db = await createTestDb()
    const app = createApp({ auth, db, enrich: { deps: okDeps, adminToken: 'secret' } })
    expect((await app.request('http://x/enrich/status')).status).toBe(401)
    expect((await app.request('http://x/enrich/run', { method: 'POST' })).status).toBe(401)
  })

  it.each(['wrong!', 'different-length-token'])(
    'rejects a wrong admin token regardless of input length',
    async (provided) => {
      const db = await createTestDb()
      const app = createApp({ auth, db, enrich: { deps: okDeps, adminToken: 'secret' } })
      const res = await app.request('http://x/enrich/status', {
        headers: { 'X-Admin-Token': provided },
      })
      expect(res.status).toBe(401)
    },
  )

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
    expect(((await run.json()) as { processed: number }).processed).toBe(3)
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

  it('mounts artwork routes without feature and meaning dependencies', async () => {
    const db = await createTestDb()
    await db.insert(tracks).values({ appleId: 'art-1', title: 'T', artist: 'A' })
    const app = createApp({ auth, db, enrich: { artwork: artworkDeps(), adminToken: 'secret' } })

    expect(
      (await app.request('http://x/enrich/status', { headers: { 'X-Admin-Token': 'secret' } })).status,
    ).toBe(404)
    const run = await app.request('http://x/enrich/artwork/run?limit=999', {
      method: 'POST',
      headers: { 'X-Admin-Token': 'secret' },
    })
    expect(run.status).toBe(200)
    expect(await run.json()).toEqual({ processed: 1, matched: 1, missing: 0, failed: 0, remaining: 0 })

    const status = await app.request('http://x/enrich/artwork/status', {
      headers: { 'X-Admin-Token': 'secret' },
    })
    expect(status.status).toBe(200)
    expect(await status.json()).toEqual({ tracks: 1, withArtwork: 1, missingArtwork: 0, retryable: 0 })
  })

  it('protects artwork routes with the same admin token guard', async () => {
    const db = await createTestDb()
    const app = createApp({ auth, db, enrich: { artwork: artworkDeps(), adminToken: 'secret' } })

    expect((await app.request('http://x/enrich/artwork/status')).status).toBe(401)
    expect(
      (await app.request('http://x/enrich/artwork/run', { method: 'POST' })).status,
    ).toBe(401)
  })

  it('keeps artwork routes absent when only feature and meaning enrichment is configured', async () => {
    const db = await createTestDb()
    const app = createApp({ auth, db, enrich: { deps: okDeps, adminToken: 'secret' } })

    expect(
      (await app.request('http://x/enrich/artwork/status', { headers: { 'X-Admin-Token': 'secret' } })).status,
    ).toBe(404)
  })

  it('floors and clamps artwork limits independently', async () => {
    const db = await createTestDb()
    for (let i = 0; i < 3; i++) {
      await db.insert(tracks).values({ appleId: `art-${i}`, title: 'T', artist: 'A' })
    }
    const app = createApp({ auth, db, enrich: { artwork: artworkDeps(), adminToken: 'secret' } })

    const run = await app.request('http://x/enrich/artwork/run?limit=2.9', {
      method: 'POST',
      headers: { 'X-Admin-Token': 'secret' },
    })
    expect(((await run.json()) as { processed: number }).processed).toBe(2)
  })
})
