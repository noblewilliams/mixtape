import { describe, expect, it } from 'vitest'
import {
  djSessions,
  funnelEvents,
  listeningDays,
  listeningImportRuns,
  tracks,
  user,
  userArtistSeeds,
  userMusicProfiles,
  userMusicSources,
  userPlaylists,
  userTracks,
} from '../../src/db/schema'
import { createTestDb, type TestDb } from '../helpers/db'

const now = new Date('2026-09-01T12:00:00.000Z')
const SPOTIFY_ID = '4uLU6hMCjMI75M1A2tKUQC'

async function seedUser(db: TestDb, id: string) {
  await db.insert(user).values({
    id,
    name: id,
    email: `${id}@example.com`,
    emailVerified: false,
    createdAt: now,
    updatedAt: now,
  })
}

const importRun = (
  over: Partial<typeof listeningImportRuns.$inferInsert> = {},
): typeof listeningImportRuns.$inferInsert => ({
  userId: 'u1',
  source: 'spotify_export',
  package: 'spotify_extended',
  status: 'open',
  timeZone: 'Africa/Lagos',
  expectedTracks: 1,
  expectedDays: 1,
  expectedLibraryTracks: 0,
  expectedArtists: 0,
  expiresAt: new Date(now.getTime() + 60_000),
  ...over,
})

describe('listening import schema', () => {
  it('round-trips a Spotify id on a track and defaults provenance and priority', async () => {
    const db = await createTestDb()
    const [track] = await db
      .insert(tracks)
      .values({ spotifyId: SPOTIFY_ID, title: 'Song', artist: 'Artist' })
      .returning()

    expect(track).toMatchObject({
      spotifyId: SPOTIFY_ID,
      appleId: null,
      artistSource: 'sync',
      enrichPriority: 0,
    })
  })

  it('rejects a duplicate spotify_id while allowing many null ids', async () => {
    const db = await createTestDb()
    await db.insert(tracks).values({ spotifyId: SPOTIFY_ID, title: 'Song', artist: 'Artist' })
    await db.insert(tracks).values({ title: 'No id', artist: 'Artist' })
    await db.insert(tracks).values({ title: 'No id either', artist: 'Artist' })

    await expect(
      db.insert(tracks).values({ spotifyId: SPOTIFY_ID, title: 'Dup', artist: 'Other' }),
    ).rejects.toThrow()
    expect(await db.select().from(tracks)).toHaveLength(3)
  })

  it.each([
    'a'.repeat(21),
    'a'.repeat(23),
    `${'a'.repeat(21)}-`,
    `${'a'.repeat(21)} `,
    `spotify:track:${'a'.repeat(22)}`,
    '',
  ])('rejects malformed spotify_id %j', async (spotifyId) => {
    const db = await createTestDb()
    await expect(
      db.insert(tracks).values({ spotifyId, title: 'Song', artist: 'Artist' }),
    ).rejects.toThrow()
  })

  it.each(['plain', 'unknown'])('rejects artist_source %j', async (artistSource) => {
    const db = await createTestDb()
    await expect(
      db.insert(tracks).values({
        title: 'Song',
        artist: 'Artist',
        artistSource: artistSource as never,
      }),
    ).rejects.toThrow()
  })

  it('rejects a negative enrich_priority', async () => {
    const db = await createTestDb()
    await expect(
      db.insert(tracks).values({ title: 'Song', artist: 'Artist', enrichPriority: -1 }),
    ).rejects.toThrow()
  })

  it('defaults the new user_tracks fields and bounds like_rating', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const [track] = await db
      .insert(tracks)
      .values({ spotifyId: SPOTIFY_ID, title: 'Song', artist: 'Artist' })
      .returning()

    const [row] = await db
      .insert(userTracks)
      .values({ userId: 'u1', trackId: track.id, likeRating: -1, skipCount: 3 })
      .returning()
    expect(row).toMatchObject({
      playCountRecent: 0,
      skipCount: 3,
      likeRating: -1,
      seeded: false,
    })

    const [other] = await db
      .insert(tracks)
      .values({ title: 'Other', artist: 'Artist' })
      .returning()
    await expect(
      db.insert(userTracks).values({ userId: 'u1', trackId: other.id, likeRating: 2 }),
    ).rejects.toThrow()
    await expect(
      db.insert(userTracks).values({ userId: 'u1', trackId: other.id, skipCount: -1 }),
    ).rejects.toThrow()
    await expect(
      db.insert(userTracks).values({ userId: 'u1', trackId: other.id, playCountRecent: -1 }),
    ).rejects.toThrow()
  })

  it('keys listening_days on user, source, track and day', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const [track] = await db
      .insert(tracks)
      .values({ spotifyId: SPOTIFY_ID, title: 'Song', artist: 'Artist' })
      .returning()
    const day = {
      userId: 'u1',
      source: 'spotify_export' as const,
      trackId: track.id,
      day: '2026-08-30',
      plays: 2,
      msPlayed: 360_000,
    }

    await db.insert(listeningDays).values(day)
    await expect(db.insert(listeningDays).values({ ...day, plays: 5 })).rejects.toThrow()
    await db.insert(listeningDays).values({ ...day, day: '2026-08-31', hoursMask: 0xffffff })
    await db.insert(listeningDays).values({ ...day, source: 'apple_export' })

    const rows = await db.select().from(listeningDays)
    expect(rows).toHaveLength(3)
    expect(rows.map((row) => row.day).sort()).toEqual(['2026-08-30', '2026-08-30', '2026-08-31'])
    expect(rows.find((row) => row.day === '2026-08-31')).toMatchObject({
      skips: null,
      completes: null,
      hoursMask: 0xffffff,
    })
  })

  it.each([
    { plays: -1 },
    { skips: -1 },
    { completes: -1 },
    { msPlayed: -1 },
    { hoursMask: -1 },
    { hoursMask: 0x1000000 },
    { source: 'web_musickit' },
  ])('rejects invalid listening_days values: %j', async (over) => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const [track] = await db
      .insert(tracks)
      .values({ title: 'Song', artist: 'Artist' })
      .returning()
    await expect(
      db.insert(listeningDays).values({
        userId: 'u1',
        source: 'spotify_export',
        trackId: track.id,
        day: '2026-08-30',
        plays: 1,
        msPlayed: 1,
        ...(over as object),
      }),
    ).rejects.toThrow()
  })

  it('allows one open import per user and source', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedUser(db, 'u2')

    await db.insert(listeningImportRuns).values(importRun())
    await expect(
      db.insert(listeningImportRuns).values(importRun({ package: 'spotify_account', expectedDays: 0 })),
    ).rejects.toThrow()

    await db.insert(listeningImportRuns).values(
      importRun({ source: 'apple_export', package: 'apple_media' }),
    )
    await db.insert(listeningImportRuns).values(importRun({ userId: 'u2' }))
    await db.insert(listeningImportRuns).values(importRun({ status: 'expired' }))

    expect(await db.select().from(listeningImportRuns)).toHaveLength(4)
  })

  it.each([
    { source: 'spotify_export', package: 'apple_media' },
    { source: 'apple_export', package: 'spotify_extended' },
    { source: 'apple_export', package: 'spotify_account' },
  ] as const)('rejects a package that does not match its source: %j', async (over) => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await expect(
      db.insert(listeningImportRuns).values(importRun({ ...over, expectedDays: 0 })),
    ).rejects.toThrow()
  })

  it.each([
    { package: 'spotify_extended', expectedArtists: 1 },
    { package: 'spotify_extended', expectedLibraryTracks: 1 },
    { package: 'spotify_account', expectedDays: 1 },
    { source: 'apple_export', package: 'apple_media', expectedArtists: 1 },
  ] as const)('rejects an expected count the package does not carry: %j', async (over) => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await expect(
      db.insert(listeningImportRuns).values(
        importRun({ expectedDays: over.package === 'spotify_account' ? 1 : 0, ...over }),
      ),
    ).rejects.toThrow()
  })

  it('accepts each package with the counts it carries', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await db.insert(listeningImportRuns).values(
      importRun({ package: 'spotify_extended', expectedDays: 4, status: 'completed' }),
    )
    await db.insert(listeningImportRuns).values(
      importRun({
        package: 'spotify_account',
        expectedDays: 0,
        expectedLibraryTracks: 2,
        expectedArtists: 3,
        status: 'completed',
      }),
    )
    const [run] = await db
      .insert(listeningImportRuns)
      .values(
        importRun({
          source: 'apple_export',
          package: 'apple_media',
          expectedDays: 4,
          expectedLibraryTracks: 2,
          country: 'NG',
        }),
      )
      .returning()

    expect(run).toMatchObject({
      receivedTracks: 0,
      receivedDays: 0,
      receivedLibraryTracks: 0,
      receivedArtists: 0,
      unresolvedRows: 0,
      unresolvedPlays: 0,
      resultTracks: null,
      ledgerFrom: null,
      ledgerTo: null,
      completedAt: null,
    })
    expect(run.startedAt).toBeInstanceOf(Date)
  })

  it('accepts a profile without a storefront and validates country and time zone', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedUser(db, 'u2')
    await seedUser(db, 'u3')

    const [profile] = await db
      .insert(userMusicProfiles)
      .values({ userId: 'u1', country: 'NG', timeZone: 'Africa/Lagos' })
      .returning()
    expect(profile).toMatchObject({ appleStorefront: null, country: 'NG', timeZone: 'Africa/Lagos' })

    await expect(
      db.insert(userMusicProfiles).values({ userId: 'u2', country: 'ng' }),
    ).rejects.toThrow()
    await expect(
      db.insert(userMusicProfiles).values({ userId: 'u3', timeZone: 'x'.repeat(65) }),
    ).rejects.toThrow()
  })

  it('records the connected sources of a listener once each', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')

    const [source] = await db
      .insert(userMusicSources)
      .values({ userId: 'u1', source: 'spotify_export' })
      .returning()
    expect(source).toMatchObject({ lastImportedAt: null, ledgerFrom: null, ledgerTo: null })
    expect(source.connectedAt).toBeInstanceOf(Date)

    await db.insert(userMusicSources).values({ userId: 'u1', source: 'apple_live' })
    await expect(
      db.insert(userMusicSources).values({ userId: 'u1', source: 'spotify_export' }),
    ).rejects.toThrow()
    await expect(
      db.insert(userMusicSources).values({ userId: 'u1', source: 'web_musickit' as never }),
    ).rejects.toThrow()
  })

  it('keys artist seeds on user and name', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')

    await db.insert(userArtistSeeds).values({ userId: 'u1', name: 'Artist', source: 'interview' })
    await expect(
      db.insert(userArtistSeeds).values({ userId: 'u1', name: 'Artist', source: 'pasted' }),
    ).rejects.toThrow()
    await expect(
      db.insert(userArtistSeeds).values({ userId: 'u1', name: '', source: 'pasted' }),
    ).rejects.toThrow()
    await expect(
      db.insert(userArtistSeeds).values({
        userId: 'u1',
        name: 'Other',
        source: 'spotify_export',
        spotifyId: 'not-base62',
      }),
    ).rejects.toThrow()
  })

  it('records funnel events with a closed set of types', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')

    const [event] = await db
      .insert(funnelEvents)
      .values({ userId: 'u1', type: 'chose_spotify', surface: 'web' })
      .returning()
    expect(event.createdAt).toBeInstanceOf(Date)

    await expect(
      db.insert(funnelEvents).values({ userId: 'u1', type: 'signed_up' as never, surface: 'web' }),
    ).rejects.toThrow()
    await expect(
      db.insert(funnelEvents).values({
        userId: 'u1',
        type: 'first_output',
        surface: 'android' as never,
      }),
    ).rejects.toThrow()
  })

  it('defaults a playlist to the apple source and a session to personal', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')

    const [playlist] = await db
      .insert(userPlaylists)
      .values({
        userId: 'u1',
        appleLibraryId: 'p.1',
        name: 'Evening',
        kind: 'user',
        sourceFingerprint: 'f'.repeat(64),
      })
      .returning()
    expect(playlist.source).toBe('apple')

    const [session] = await db.insert(djSessions).values({ userId: 'u1', title: 't' }).returning()
    expect(session.notPersonal).toBe(false)
  })
})
