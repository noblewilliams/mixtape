import { describe, expect, it } from 'vitest'
import { createApp, type AuthLike } from '../../src/app'
import { funnelEvents, tracks, userMusicSources, userTracks } from '../../src/db/schema'
import { createListeningImportStore } from '../../src/listening/import-store'
import { createTestDb, type TestDb } from '../helpers/db'
import { APPLE_A, begin, day, now, publish, seedUser, track } from '../helpers/listening-fixtures'

const authFor = (id: string | null): AuthLike => ({
  handler: () => new Response('ok'),
  api: { getSession: async () => id ? { user: { id } } : null },
})

function get(db: TestDb, auth: AuthLike) {
  return createApp({ auth, db }).request('http://x/me/onboarding')
}

const earlier = new Date('2026-08-20T08:00:00.000Z')
const later = new Date('2026-08-25T08:00:00.000Z')

const blank = {
  sources: [],
  hasLibrary: false,
  chosenService: null,
  markedRequestedAt: null,
  interviewCompletedAt: null,
  importCompletedAt: null,
}

async function seedAppleLibraryTrack(db: TestDb, userId: string) {
  const [row] = await db
    .insert(tracks)
    .values({ appleId: APPLE_A, title: 'Song', artist: 'Artist' })
    .returning({ id: tracks.id })
  await db.insert(userTracks).values({ userId, trackId: row.id, inLibrary: true })
}

describe('GET /me/onboarding', () => {
  it('401s without a session', async () => {
    const db = await createTestDb()
    expect((await get(db, authFor(null))).status).toBe(401)
  })

  it('reads all-null, false, and empty for a blank user', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const response = await get(db, authFor('u1'))
    expect(response.status).toBe(200)
    expect(await response.json()).toEqual(blank)
  })

  it('a Spotify chooser: chosenService spotify, the EARLIEST marked_requested, and sources as /me/music-sources', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await db.insert(funnelEvents).values([
      { userId: 'u1', type: 'chose_spotify', surface: 'ios', createdAt: earlier },
      { userId: 'u1', type: 'marked_requested', surface: 'ios', createdAt: later },
      { userId: 'u1', type: 'marked_requested', surface: 'web', createdAt: earlier },
    ])
    const store = createListeningImportStore(db, { now: () => now })
    await publish(store, 'u1', begin(), {
      tracks: [track()],
      days: [day({ day: '2026-08-30' }), day({ ordinal: 1, day: '2026-08-31' })],
    })

    const response = await get(db, authFor('u1'))
    expect(response.status).toBe(200)
    expect(await response.json()).toEqual({
      sources: [
        {
          source: 'spotify_export',
          connectedAt: now.toISOString(),
          lastImportedAt: now.toISOString(),
          ledgerFrom: '2026-08-30',
          ledgerTo: '2026-08-31',
        },
      ],
      // A history-only import writes no library rows.
      hasLibrary: false,
      chosenService: 'spotify',
      markedRequestedAt: earlier.toISOString(),
      interviewCompletedAt: null,
      importCompletedAt: null,
    })
  })

  it('chose_spotify wins over an Apple library, and each step reports its first timestamp', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedAppleLibraryTrack(db, 'u1')
    await db.insert(funnelEvents).values([
      { userId: 'u1', type: 'chose_spotify', surface: 'web', createdAt: later },
      { userId: 'u1', type: 'interview_completed', surface: 'web', createdAt: later },
      { userId: 'u1', type: 'interview_completed', surface: 'ios', createdAt: earlier },
      { userId: 'u1', type: 'import_completed', surface: 'web', createdAt: later },
      { userId: 'u1', type: 'file_inspected', surface: 'web', createdAt: earlier },
    ])

    expect(await (await get(db, authFor('u1'))).json()).toEqual({
      sources: [],
      hasLibrary: true,
      chosenService: 'spotify',
      markedRequestedAt: null,
      interviewCompletedAt: earlier.toISOString(),
      importCompletedAt: later.toISOString(),
    })
  })

  it('an Apple live-synced listener reads apple with hasLibrary', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await db.insert(userMusicSources).values({ userId: 'u1', source: 'apple_live', connectedAt: now })
    await seedAppleLibraryTrack(db, 'u1')

    expect(await (await get(db, authFor('u1'))).json()).toEqual({
      sources: [
        { source: 'apple_live', connectedAt: now.toISOString(), lastImportedAt: null, ledgerFrom: null, ledgerTo: null },
      ],
      hasLibrary: true,
      chosenService: 'apple',
      markedRequestedAt: null,
      interviewCompletedAt: null,
      importCompletedAt: null,
    })
  })

  it('an Apple export source with no library rows still reads apple', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await db.insert(userMusicSources).values({ userId: 'u1', source: 'apple_export', connectedAt: now })

    const body = (await (await get(db, authFor('u1'))).json()) as { hasLibrary: boolean; chosenService: string | null }
    expect(body.hasLibrary).toBe(false)
    expect(body.chosenService).toBe('apple')
  })

  it("never leaks another user's events, sources, or library", async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedUser(db, 'u2')
    await db.insert(funnelEvents).values([
      { userId: 'u2', type: 'chose_spotify', surface: 'ios', createdAt: earlier },
      { userId: 'u2', type: 'marked_requested', surface: 'ios', createdAt: earlier },
      { userId: 'u2', type: 'interview_completed', surface: 'ios', createdAt: earlier },
      { userId: 'u2', type: 'import_completed', surface: 'ios', createdAt: earlier },
    ])
    await db.insert(userMusicSources).values({ userId: 'u2', source: 'apple_live', connectedAt: now })
    await seedAppleLibraryTrack(db, 'u2')

    expect(await (await get(db, authFor('u1'))).json()).toEqual(blank)
  })
  it('a Spotify account import with liked tracks and no funnel event still reads spotify', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await db.insert(userMusicSources).values({ userId: 'u1', source: 'spotify_export', connectedAt: now })
    const [row] = await db
      .insert(tracks)
      .values({ appleId: null, spotifyId: '0VjIjW4GlUZAMYd2vXMi3b', title: 'Liked', artist: 'Artist' })
      .returning({ id: tracks.id })
    await db.insert(userTracks).values({ userId: 'u1', trackId: row.id, inLibrary: true })

    const body = (await (await get(db, authFor('u1'))).json()) as {
      hasLibrary: boolean
      chosenService: string | null
    }
    expect(body.hasLibrary).toBe(true)
    expect(body.chosenService).toBe('spotify')
  })
})
