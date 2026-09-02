import { describe, expect, it } from 'vitest'
import { createApp, type AuthLike } from '../../src/app'
import { userMusicSources } from '../../src/db/schema'
import { createListeningImportStore } from '../../src/listening/import-store'
import { createTestDb, type TestDb } from '../helpers/db'
import { begin, day, now, publish, seedUser, track } from '../helpers/listening-fixtures'

const authFor = (id: string | null): AuthLike => ({
  handler: () => new Response('ok'),
  api: { getSession: async () => id ? { user: { id } } : null },
})

function list(db: TestDb, auth: AuthLike) {
  return createApp({ auth, db }).request('http://x/me/music-sources')
}

describe('GET /me/music-sources', () => {
  it('401s without a session', async () => {
    const db = await createTestDb()
    expect((await list(db, authFor(null))).status).toBe(401)
  })

  it("lists the caller's sources by name with ISO timestamps and ledger bounds", async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedUser(db, 'u2')
    const store = createListeningImportStore(db, { now: () => now })
    await publish(store, 'u1', begin(), {
      tracks: [track()],
      days: [day({ day: '2026-08-30' }), day({ ordinal: 1, day: '2026-08-31' })],
    })
    // A live library connection that has never imported: nulls, not errors.
    await db.insert(userMusicSources).values({ userId: 'u1', source: 'apple_live', connectedAt: now })
    await publish(store, 'u2', begin(), { tracks: [track()], days: [day()] })

    const response = await list(db, authFor('u1'))
    expect(response.status).toBe(200)
    expect(await response.json()).toEqual({
      sources: [
        {
          source: 'apple_live',
          connectedAt: now.toISOString(),
          lastImportedAt: null,
          ledgerFrom: null,
          ledgerTo: null,
        },
        {
          source: 'spotify_export',
          connectedAt: now.toISOString(),
          lastImportedAt: now.toISOString(),
          ledgerFrom: '2026-08-30',
          ledgerTo: '2026-08-31',
        },
      ],
    })
  })

  it('returns an empty list for a user with no sources', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedUser(db, 'u2')
    await db.insert(userMusicSources).values({ userId: 'u2', source: 'spotify_export', connectedAt: now })
    const response = await list(db, authFor('u1'))
    expect(response.status).toBe(200)
    expect(await response.json()).toEqual({ sources: [] })
  })
})
