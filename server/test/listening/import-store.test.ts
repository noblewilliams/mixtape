import { spotifyLibraryReview } from '../../src/listening/collection-review'
import { and, eq } from 'drizzle-orm'
import { describe, expect, it } from 'vitest'
import {
  listeningImportArtists,
  listeningImportDays,
  listeningImportLibrary,
  listeningImportRuns,
  listeningImportTracks,
  user,
  userMusicProfiles,
  userMusicSources,
} from '../../src/db/schema'
import type {
  BeginListeningImport,
  ListeningArtistSnapshot,
  ListeningDaySnapshot,
  ListeningLibrarySnapshot,
  ListeningTrackSnapshot,
} from '../../src/listening/contracts'
import {
  createListeningImportStore,
  ListeningImportError,
  type ListeningImportStore,
} from '../../src/listening/import-store'
import { createTestDb, type TestDb } from '../helpers/db'

const now = new Date('2026-09-01T12:00:00.000Z')
const SPOTIFY_A = '4uLU6hMCjMI75M1A2tKUQC'
const SPOTIFY_B = '7ouMYWpwJ422jRcDASZB7P'
const APPLE_A = '1440935467'
const UNKNOWN_IMPORT = '00000000-0000-4000-8000-000000000000'

const begin = (over: Partial<BeginListeningImport> = {}): BeginListeningImport => ({
  source: 'spotify_export',
  package: 'spotify_extended',
  timeZone: 'Africa/Lagos',
  country: 'NG',
  expectedTracks: 2,
  expectedDays: 2,
  expectedLibraryTracks: 0,
  expectedArtists: 0,
  unresolvedRows: 0,
  unresolvedPlays: 0,
  ...over,
})

const accountBegin = (over: Partial<BeginListeningImport> = {}) => begin({
  package: 'spotify_account',
  expectedDays: 0,
  expectedLibraryTracks: 2,
  expectedArtists: 2,
  ...over,
})

const appleBegin = (over: Partial<BeginListeningImport> = {}) => begin({
  source: 'apple_export',
  package: 'apple_media',
  expectedLibraryTracks: 2,
  ...over,
})

const track = (over: Partial<ListeningTrackSnapshot> = {}): ListeningTrackSnapshot => ({
  ordinal: 0,
  platformId: SPOTIFY_A,
  title: 'Song',
  artist: 'Artist',
  album: 'Album',
  durationMs: 200_000,
  ...over,
})

const day = (over: Partial<ListeningDaySnapshot> = {}): ListeningDaySnapshot => ({
  ordinal: 0,
  platformId: SPOTIFY_A,
  day: '2026-08-30',
  plays: 3,
  skips: 1,
  completes: 2,
  msPlayed: 600_000,
  hoursMask: 5,
  ...over,
})

const libraryRow = (over: Partial<ListeningLibrarySnapshot> = {}): ListeningLibrarySnapshot => ({
  ordinal: 0,
  platformId: SPOTIFY_A,
  playCount: null,
  skipCount: null,
  lastPlayedAt: null,
  dateAdded: 1_700_000_000_000,
  likeRating: null,
  ...over,
})

const artist = (over: Partial<ListeningArtistSnapshot> = {}): ListeningArtistSnapshot => ({
  ordinal: 0,
  name: 'Artist',
  spotifyId: SPOTIFY_B,
  ...over,
})

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

async function runRow(db: TestDb, importId: string) {
  const [run] = await db.select().from(listeningImportRuns)
    .where(eq(listeningImportRuns.id, importId))
  return run
}

describe('ListeningImportStore', () => {
  describe('begin', () => {
    it('creates a storefront-less profile, an open run, and the music source', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const store = createListeningImportStore(db, { now: () => now })

      const { importId, expiresAt } = await store.begin('u1', begin({
        unresolvedRows: 7,
        unresolvedPlays: 12,
      }))

      expect(expiresAt).toBe(now.getTime() + 2 * 60 * 60 * 1_000)
      expect(await db.select().from(userMusicProfiles)).toMatchObject([{
        userId: 'u1',
        appleStorefront: null,
        timeZone: 'Africa/Lagos',
        country: 'NG',
      }])
      expect(await runRow(db, importId)).toMatchObject({
        userId: 'u1',
        source: 'spotify_export',
        package: 'spotify_extended',
        status: 'open',
        timeZone: 'Africa/Lagos',
        country: 'NG',
        expectedTracks: 2,
        receivedTracks: 0,
        expectedDays: 2,
        receivedDays: 0,
        expectedLibraryTracks: 0,
        receivedLibraryTracks: 0,
        expectedArtists: 0,
        receivedArtists: 0,
        unresolvedRows: 7,
        unresolvedPlays: 12,
        resultTracks: null,
        completedAt: null,
      })
      expect((await runRow(db, importId)).expiresAt.getTime()).toBe(expiresAt)
      const sources = await db.select().from(userMusicSources)
      expect(sources).toMatchObject([{ userId: 'u1', source: 'spotify_export', lastImportedAt: null }])
      expect(sources[0].connectedAt.getTime()).toBe(now.getTime())
      expect(sources[0].updatedAt.getTime()).toBe(now.getTime())
    })

    it('keeps an existing storefront and country when the begin carries none', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      await db.insert(userMusicProfiles).values({
        userId: 'u1',
        appleStorefront: 'ng',
        country: 'US',
        timeZone: 'America/New_York',
      })
      const store = createListeningImportStore(db, { now: () => now })

      await store.begin('u1', begin({ country: null, timeZone: 'Europe/London' }))

      expect(await db.select().from(userMusicProfiles)).toMatchObject([{
        appleStorefront: 'ng',
        country: 'US',
        timeZone: 'Europe/London',
      }])
    })

    it('expires the open run for the same source and leaves other sources open', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const later = new Date(now.getTime() + 60_000)
      const first = await createListeningImportStore(db, { now: () => now })
        .begin('u1', begin())
      const apple = await createListeningImportStore(db, { now: () => now })
        .begin('u1', appleBegin())
      const second = await createListeningImportStore(db, { now: () => later })
        .begin('u1', accountBegin())

      expect(second.importId).not.toBe(first.importId)
      expect((await runRow(db, first.importId)).status).toBe('expired')
      expect((await runRow(db, apple.importId)).status).toBe('open')
      expect((await runRow(db, second.importId)).status).toBe('open')

      const sources = await db.select().from(userMusicSources).orderBy(userMusicSources.source)
      expect(sources.map((row) => row.source)).toEqual(['apple_export', 'spotify_export'])
      const spotify = sources[1]
      expect(spotify.connectedAt.getTime()).toBe(now.getTime())
      expect(spotify.updatedAt.getTime()).toBe(later.getTime())

      await expect(createListeningImportStore(db, { now: () => later })
        .putTracks('u1', first.importId, [track()]))
        .rejects.toMatchObject({ category: 'invalid_state' })
    })
  })

  describe('tracks', () => {
    it('accepts exact re-sends and rejects changed or colliding re-sends', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const store = createListeningImportStore(db, { now: () => now })
      const { importId } = await store.begin('u1', begin())

      await store.putTracks('u1', importId, [track()])
      await store.putTracks('u1', importId, [track()])
      expect((await runRow(db, importId)).receivedTracks).toBe(1)
      expect(await db.select().from(listeningImportTracks)).toMatchObject([{
        importId, ordinal: 0, platformId: SPOTIFY_A, title: 'Song', durationMs: 200_000,
      }])

      await expect(store.putTracks('u1', importId, [track({ title: 'Changed' })]))
        .rejects.toMatchObject({ category: 'conflict' })
      await expect(store.putTracks('u1', importId, [track({ ordinal: 1 })]))
        .rejects.toMatchObject({ category: 'conflict' })
      await expect(store.putTracks('u1', importId, [track({ platformId: SPOTIFY_B })]))
        .rejects.toMatchObject({ category: 'conflict' })
      await expect(store.putTracks('u1', importId, [
        track(),
        track({ ordinal: 1, platformId: SPOTIFY_B, album: null, durationMs: null }),
      ])).resolves.toBeUndefined()
      expect((await runRow(db, importId)).receivedTracks).toBe(2)
    })

    it('hides runs from other users and unknown ids', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      await seedUser(db, 'u2')
      const store = createListeningImportStore(db, { now: () => now })
      const { importId } = await store.begin('u1', begin())

      await expect(store.putTracks('u2', importId, [track()]))
        .rejects.toMatchObject({ category: 'not_found' })
      await expect(store.putTracks('u1', UNKNOWN_IMPORT, [track()]))
        .rejects.toMatchObject({ category: 'not_found' })
      expect(await db.select().from(listeningImportTracks)).toEqual([])
    })

    it('rejects chunks that would exceed the expected count without staging them', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const store = createListeningImportStore(db, { now: () => now })
      const { importId } = await store.begin('u1', begin({ expectedTracks: 1 }))

      await expect(store.putTracks('u1', importId, [
        track(),
        track({ ordinal: 1, platformId: SPOTIFY_B }),
      ])).rejects.toMatchObject({ category: 'count_mismatch' })
      expect(await db.select().from(listeningImportTracks)).toEqual([])

      await store.putTracks('u1', importId, [track()])
      await expect(store.putTracks('u1', importId, [track({ ordinal: 1, platformId: SPOTIFY_B })]))
        .rejects.toMatchObject({ category: 'count_mismatch' })
      expect((await runRow(db, importId)).receivedTracks).toBe(1)
    })

    it('rejects duplicate ordinals or platform ids inside one chunk', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const store = createListeningImportStore(db, { now: () => now })
      const { importId } = await store.begin('u1', begin())

      await expect(store.putTracks('u1', importId, [track(), track({ platformId: SPOTIFY_B })]))
        .rejects.toMatchObject({ category: 'conflict' })
      await expect(store.putTracks('u1', importId, [track(), track({ ordinal: 1 })]))
        .rejects.toMatchObject({ category: 'conflict' })
      expect(await db.select().from(listeningImportTracks)).toEqual([])
    })

    it('rejects writes to an expired run', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const store = createListeningImportStore(db, { now: () => now, ttlMs: 1 })
      const { importId } = await store.begin('u1', begin())
      const later = createListeningImportStore(db, { now: () => new Date(now.getTime() + 2) })

      await expect(later.putTracks('u1', importId, [track()]))
        .rejects.toMatchObject({ category: 'invalid_state' })
      await expect(later.putDays('u1', importId, [day()]))
        .rejects.toMatchObject({ category: 'invalid_state' })
    })
  })

  describe('platform ids', () => {
    it('rejects Spotify ids that are not 22 base62 characters', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      await seedUser(db, 'u2')
      const store = createListeningImportStore(db, { now: () => now })
      const short = SPOTIFY_A.slice(0, 21)
      const extended = await store.begin('u1', begin())
      // Same source as the extended run, so it needs its own user to stay open.
      const account = await store.begin('u2', accountBegin())

      await expect(store.putTracks('u1', extended.importId, [track({ platformId: short })]))
        .rejects.toMatchObject({ category: 'invalid_id' })
      await expect(store.putDays('u1', extended.importId, [day({ platformId: short })]))
        .rejects.toMatchObject({ category: 'invalid_id' })
      await expect(store.putLibrary('u2', account.importId, [libraryRow({ platformId: short })]))
        .rejects.toMatchObject({ category: 'invalid_id' })
      await expect(store.putTracks('u1', extended.importId, [track({ platformId: '1234567890' })]))
        .rejects.toMatchObject({ category: 'invalid_id' })
      expect(await db.select().from(listeningImportTracks)).toEqual([])
      expect(await db.select().from(listeningImportDays)).toEqual([])
      expect(await db.select().from(listeningImportLibrary)).toEqual([])
    })

    it('rejects Apple ids outside the catalog id alphabet', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const store = createListeningImportStore(db, { now: () => now })
      const { importId } = await store.begin('u1', appleBegin())

      await expect(store.putTracks('u1', importId, [track({ platformId: 'song 1' })]))
        .rejects.toMatchObject({ category: 'invalid_id' })
      await expect(store.putTracks('u1', importId, [track({ platformId: '1,2' })]))
        .rejects.toMatchObject({ category: 'invalid_id' })
      await expect(store.putDays('u1', importId, [day({ platformId: 'song 1' })]))
        .rejects.toMatchObject({ category: 'invalid_id' })
      await expect(store.putLibrary('u1', importId, [libraryRow({ platformId: 'song 1' })]))
        .rejects.toMatchObject({ category: 'invalid_id' })

      await store.putTracks('u1', importId, [track({ platformId: '1440935467' })])
      expect((await runRow(db, importId)).receivedTracks).toBe(1)
    })

    it('rejects an invalid id before checking the rest of the chunk', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const store = createListeningImportStore(db, { now: () => now })
      const { importId } = await store.begin('u1', begin({ expectedTracks: 1 }))

      await expect(store.putTracks('u1', importId, [
        track(),
        track({ ordinal: 1, platformId: 'bad' }),
      ])).rejects.toMatchObject({ category: 'invalid_id' })
      expect(await db.select().from(listeningImportTracks)).toEqual([])
    })
  })

  describe('package gating', () => {
    it('rejects library and artist chunks on the extended package', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const store = createListeningImportStore(db, { now: () => now })
      const { importId } = await store.begin('u1', begin())

      await expect(store.putLibrary('u1', importId, [libraryRow()]))
        .rejects.toMatchObject({ category: 'invalid_state' })
      await expect(store.putArtists('u1', importId, [artist()]))
        .rejects.toMatchObject({ category: 'invalid_state' })
      await store.putTracks('u1', importId, [track()])
      await store.putDays('u1', importId, [day()])
      expect(await runRow(db, importId)).toMatchObject({ receivedTracks: 1, receivedDays: 1 })
    })

    it('rejects day chunks on the account package', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const store = createListeningImportStore(db, { now: () => now })
      const { importId } = await store.begin('u1', accountBegin())

      await expect(store.putDays('u1', importId, [day()]))
        .rejects.toMatchObject({ category: 'invalid_state' })
      await store.putTracks('u1', importId, [track()])
      await store.putLibrary('u1', importId, [libraryRow()])
      await store.putArtists('u1', importId, [artist()])
      expect(await runRow(db, importId)).toMatchObject({
        receivedTracks: 1, receivedLibraryTracks: 1, receivedArtists: 1,
      })
    })

    it('rejects artist chunks on the Apple package', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const store = createListeningImportStore(db, { now: () => now })
      const { importId } = await store.begin('u1', appleBegin())

      await expect(store.putArtists('u1', importId, [artist()]))
        .rejects.toMatchObject({ category: 'invalid_state' })
      await store.putTracks('u1', importId, [track({ platformId: '1440935467' })])
      await store.putDays('u1', importId, [day({ platformId: '1440935467' })])
      await store.putLibrary('u1', importId, [libraryRow({ platformId: '1440935467', likeRating: 1 })])
      expect(await runRow(db, importId)).toMatchObject({
        receivedTracks: 1, receivedDays: 1, receivedLibraryTracks: 1,
      })
    })

    it('reports a non-carried chunk type as invalid_state ahead of id validation', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const store = createListeningImportStore(db, { now: () => now })
      const { importId } = await store.begin('u1', begin())

      await expect(store.putLibrary('u1', importId, [libraryRow({ platformId: 'bad' })]))
        .rejects.toMatchObject({ category: 'invalid_state' })
    })
  })

  describe('days', () => {
    it('stages days without a staged track and keeps exact re-sends idempotent', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const store = createListeningImportStore(db, { now: () => now })
      const { importId } = await store.begin('u1', begin({ expectedDays: 3 }))

      await store.putDays('u1', importId, [day(), day({ ordinal: 1, day: '2026-08-31', hoursMask: null })])
      await store.putDays('u1', importId, [day(), day({ ordinal: 1, day: '2026-08-31', hoursMask: null })])
      expect((await runRow(db, importId)).receivedDays).toBe(2)
      expect(await db.select().from(listeningImportDays).orderBy(listeningImportDays.ordinal))
        .toMatchObject([
          { ordinal: 0, platformId: SPOTIFY_A, day: '2026-08-30', plays: 3, skips: 1, completes: 2, msPlayed: 600_000, hoursMask: 5 },
          { ordinal: 1, platformId: SPOTIFY_A, day: '2026-08-31', hoursMask: null },
        ])

      await expect(store.putDays('u1', importId, [day({ plays: 4 })]))
        .rejects.toMatchObject({ category: 'conflict' })
      await expect(store.putDays('u1', importId, [day({ ordinal: 2 })]))
        .rejects.toMatchObject({ category: 'conflict' })
      await expect(store.putDays('u1', importId, [day({ day: '2026-09-01' })]))
        .rejects.toMatchObject({ category: 'conflict' })
      await store.putDays('u1', importId, [day({ ordinal: 2, platformId: SPOTIFY_B })])
      expect((await runRow(db, importId)).receivedDays).toBe(3)
      await expect(store.putDays('u1', importId, [day({ ordinal: 3, day: '2026-07-01' })]))
        .rejects.toMatchObject({ category: 'count_mismatch' })
    })

    it('rejects the same track and day twice inside one chunk', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const store = createListeningImportStore(db, { now: () => now })
      const { importId } = await store.begin('u1', begin())

      await expect(store.putDays('u1', importId, [day(), day({ ordinal: 1 })]))
        .rejects.toMatchObject({ category: 'conflict' })
      await expect(store.putDays('u1', importId, [day(), day({ day: '2026-08-31' })]))
        .rejects.toMatchObject({ category: 'conflict' })
      expect(await db.select().from(listeningImportDays)).toEqual([])
      await store.putDays('u1', importId, [day(), day({ ordinal: 1, day: '2026-08-31' })])
      expect((await runRow(db, importId)).receivedDays).toBe(2)
    })
  })

  describe('library and artists', () => {
    it('stages library rows with exact re-send idempotency', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const store = createListeningImportStore(db, { now: () => now })
      const { importId } = await store.begin('u1', accountBegin())
      const rows = [
        libraryRow({ playCount: 9, skipCount: 2, lastPlayedAt: 1_720_000_000_000, likeRating: -1 }),
        libraryRow({ ordinal: 1, platformId: SPOTIFY_B, dateAdded: null }),
      ]

      await store.putLibrary('u1', importId, rows)
      await store.putLibrary('u1', importId, rows)
      expect((await runRow(db, importId)).receivedLibraryTracks).toBe(2)
      const staged = await db.select().from(listeningImportLibrary)
        .orderBy(listeningImportLibrary.ordinal)
      expect(staged).toMatchObject([
        { ordinal: 0, platformId: SPOTIFY_A, playCount: 9, skipCount: 2, likeRating: -1 },
        { ordinal: 1, platformId: SPOTIFY_B, playCount: null, dateAdded: null, likeRating: null },
      ])
      expect(staged[0].lastPlayedAt?.getTime()).toBe(1_720_000_000_000)
      expect(staged[0].dateAdded?.getTime()).toBe(1_700_000_000_000)

      await expect(store.putLibrary('u1', importId, [libraryRow({ playCount: 10 })]))
        .rejects.toMatchObject({ category: 'conflict' })
      await expect(store.putLibrary('u1', importId, [libraryRow({ ordinal: 1 })]))
        .rejects.toMatchObject({ category: 'conflict' })
      await expect(store.putLibrary('u1', importId, [rows[0], libraryRow({ ordinal: 1 })]))
        .rejects.toMatchObject({ category: 'conflict' })
    })

    it('stages artists by name with exact re-send idempotency', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const store = createListeningImportStore(db, { now: () => now })
      const { importId } = await store.begin('u1', accountBegin())

      await store.putArtists('u1', importId, [artist(), artist({ ordinal: 1, name: 'Other', spotifyId: null })])
      await store.putArtists('u1', importId, [artist()])
      expect((await runRow(db, importId)).receivedArtists).toBe(2)
      expect(await db.select().from(listeningImportArtists).orderBy(listeningImportArtists.ordinal))
        .toMatchObject([
          { ordinal: 0, name: 'Artist', spotifyId: SPOTIFY_B },
          { ordinal: 1, name: 'Other', spotifyId: null },
        ])

      await expect(store.putArtists('u1', importId, [artist({ spotifyId: null })]))
        .rejects.toMatchObject({ category: 'conflict' })
      await expect(store.putArtists('u1', importId, [artist({ ordinal: 2 })]))
        .rejects.toMatchObject({ category: 'conflict' })
      await expect(store.putArtists('u1', importId, [artist(), artist({ ordinal: 1 })]))
        .rejects.toMatchObject({ category: 'conflict' })
      await expect(store.putArtists('u1', importId, [artist({ ordinal: 2, name: 'Third' })]))
        .rejects.toMatchObject({ category: 'count_mismatch' })
    })
  })

  describe('field conflicts', () => {
    // Stage one row, then re-send it with exactly one field changed and the
    // ordinal held fixed, so the rejection comes from the field comparison
    // (or, for natural-key fields, from the ordinal and key rows diverging).
    type Change<T> = { change: string; before?: Partial<T>; after: Partial<T> }

    const trackChanges: Change<ListeningTrackSnapshot>[] = [
      { change: 'platformId', after: { platformId: SPOTIFY_B } },
      { change: 'title', after: { title: 'Changed' } },
      { change: 'artist', after: { artist: 'Other' } },
      { change: 'album', after: { album: 'Other' } },
      { change: 'album to null', after: { album: null } },
      { change: 'album from null', before: { album: null }, after: { album: 'Album' } },
      { change: 'durationMs', after: { durationMs: 200_001 } },
      { change: 'durationMs to null', after: { durationMs: null } },
      { change: 'durationMs from null', before: { durationMs: null }, after: { durationMs: 200_000 } },
    ]

    it.each(trackChanges)('rejects a track re-send that changes $change', async ({ before, after }) => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const store = createListeningImportStore(db, { now: () => now })
      const { importId } = await store.begin('u1', begin())

      await store.putTracks('u1', importId, [track(before)])
      await expect(store.putTracks('u1', importId, [track({ ...before, ...after })]))
        .rejects.toMatchObject({ category: 'conflict' })
      expect((await runRow(db, importId)).receivedTracks).toBe(1)
      expect(await db.select().from(listeningImportTracks)).toMatchObject([track(before)])
    })

    const dayChanges: Change<ListeningDaySnapshot>[] = [
      { change: 'platformId', after: { platformId: SPOTIFY_B } },
      { change: 'day', after: { day: '2026-08-31' } },
      { change: 'plays', after: { plays: 4 } },
      { change: 'skips', after: { skips: 2 } },
      { change: 'skips from 0 to null', before: { skips: 0 }, after: { skips: null } },
      { change: 'skips from null to 0', before: { skips: null }, after: { skips: 0 } },
      { change: 'completes', after: { completes: 3 } },
      { change: 'completes from 0 to null', before: { completes: 0 }, after: { completes: null } },
      { change: 'completes from null to 0', before: { completes: null }, after: { completes: 0 } },
      { change: 'msPlayed', after: { msPlayed: 600_001 } },
      { change: 'hoursMask', after: { hoursMask: 1 } },
      { change: 'hoursMask from 1 to null', before: { hoursMask: 1 }, after: { hoursMask: null } },
      { change: 'hoursMask from null to 1', before: { hoursMask: null }, after: { hoursMask: 1 } },
    ]

    it.each(dayChanges)('rejects a day re-send that changes $change', async ({ before, after }) => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const store = createListeningImportStore(db, { now: () => now })
      const { importId } = await store.begin('u1', begin())

      await store.putDays('u1', importId, [day(before)])
      await expect(store.putDays('u1', importId, [day({ ...before, ...after })]))
        .rejects.toMatchObject({ category: 'conflict' })
      expect((await runRow(db, importId)).receivedDays).toBe(1)
      expect(await db.select().from(listeningImportDays)).toMatchObject([day(before)])
    })

    const libraryChanges: Change<ListeningLibrarySnapshot>[] = [
      { change: 'platformId', after: { platformId: SPOTIFY_B } },
      { change: 'playCount', before: { playCount: 9 }, after: { playCount: 10 } },
      { change: 'playCount from 0 to null', before: { playCount: 0 }, after: { playCount: null } },
      { change: 'playCount from null to 0', after: { playCount: 0 } },
      { change: 'skipCount', before: { skipCount: 2 }, after: { skipCount: 3 } },
      { change: 'skipCount from 0 to null', before: { skipCount: 0 }, after: { skipCount: null } },
      { change: 'skipCount from null to 0', after: { skipCount: 0 } },
      {
        change: 'lastPlayedAt',
        before: { lastPlayedAt: 1_720_000_000_000 },
        after: { lastPlayedAt: 1_720_000_000_001 },
      },
      { change: 'lastPlayedAt to null', before: { lastPlayedAt: 1_720_000_000_000 }, after: { lastPlayedAt: null } },
      { change: 'lastPlayedAt from null', after: { lastPlayedAt: 1_720_000_000_000 } },
      { change: 'dateAdded', after: { dateAdded: 1_700_000_000_001 } },
      { change: 'dateAdded to null', after: { dateAdded: null } },
      { change: 'dateAdded from null', before: { dateAdded: null }, after: { dateAdded: 1_700_000_000_000 } },
      { change: 'likeRating', before: { likeRating: 1 }, after: { likeRating: -1 } },
      { change: 'likeRating from 1 to null', before: { likeRating: 1 }, after: { likeRating: null } },
      { change: 'likeRating from null to 1', after: { likeRating: 1 } },
    ]

    it.each(libraryChanges)('rejects a library re-send that changes $change', async ({ before, after }) => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const store = createListeningImportStore(db, { now: () => now })
      const { importId } = await store.begin('u1', accountBegin())

      await store.putLibrary('u1', importId, [libraryRow(before)])
      await expect(store.putLibrary('u1', importId, [libraryRow({ ...before, ...after })]))
        .rejects.toMatchObject({ category: 'conflict' })
      expect((await runRow(db, importId)).receivedLibraryTracks).toBe(1)
      expect(await db.select().from(listeningImportLibrary)).toHaveLength(1)
    })

    const artistChanges: Change<ListeningArtistSnapshot>[] = [
      { change: 'name', after: { name: 'Other' } },
      { change: 'spotifyId', after: { spotifyId: SPOTIFY_A } },
      { change: 'spotifyId to null', after: { spotifyId: null } },
      { change: 'spotifyId from null', before: { spotifyId: null }, after: { spotifyId: SPOTIFY_B } },
    ]

    it.each(artistChanges)('rejects an artist re-send that changes $change', async ({ before, after }) => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const store = createListeningImportStore(db, { now: () => now })
      const { importId } = await store.begin('u1', accountBegin())

      await store.putArtists('u1', importId, [artist(before)])
      await expect(store.putArtists('u1', importId, [artist({ ...before, ...after })]))
        .rejects.toMatchObject({ category: 'conflict' })
      expect((await runRow(db, importId)).receivedArtists).toBe(1)
      expect(await db.select().from(listeningImportArtists)).toMatchObject([artist(before)])
    })
  })

  describe('tenancy', () => {
    // Every put resolves the run by (id, user) before gating, id validation, or
    // staging, so another user's chunk is not_found even when the run is open
    // and carries that chunk type. Apple ids on the Apple package; artists only
    // ship with the account package.
    const puts: {
      name: string
      input: BeginListeningImport
      put: (store: ListeningImportStore, userId: string, importId: string) => Promise<void>
    }[] = [
      {
        name: 'putTracks',
        input: appleBegin(),
        put: (store, userId, importId) =>
          store.putTracks(userId, importId, [track({ platformId: APPLE_A })]),
      },
      {
        name: 'putDays',
        input: appleBegin(),
        put: (store, userId, importId) =>
          store.putDays(userId, importId, [day({ platformId: APPLE_A })]),
      },
      {
        name: 'putLibrary',
        input: appleBegin(),
        put: (store, userId, importId) =>
          store.putLibrary(userId, importId, [libraryRow({ platformId: APPLE_A })]),
      },
      {
        name: 'putArtists',
        input: accountBegin(),
        put: (store, userId, importId) => store.putArtists(userId, importId, [artist()]),
      },
    ]

    it.each(puts)("$name reports another user's open run as not_found", async ({ input, put }) => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      await seedUser(db, 'u2')
      const store = createListeningImportStore(db, { now: () => now })
      const { importId } = await store.begin('u1', input)

      await expect(put(store, 'u2', importId)).rejects.toMatchObject({ category: 'not_found' })
      expect(await runRow(db, importId)).toMatchObject({
        status: 'open',
        receivedTracks: 0,
        receivedDays: 0,
        receivedLibraryTracks: 0,
        receivedArtists: 0,
      })
      expect(await db.select().from(listeningImportTracks)).toEqual([])
      expect(await db.select().from(listeningImportDays)).toEqual([])
      expect(await db.select().from(listeningImportLibrary)).toEqual([])
      expect(await db.select().from(listeningImportArtists)).toEqual([])
      // The same chunk stages for the owner, so the rejection was tenancy alone.
      await expect(put(store, 'u1', importId)).resolves.toBeUndefined()
    })
  })

  it('names its error category', () => {
    const error = new ListeningImportError('invalid_id')
    expect(error.category).toBe('invalid_id')
    expect(error.name).toBe('ListeningImportError')
    expect(error.message).toBe('listening-import:invalid_id')
  })

  it('leaves the other user alone when scoping by user and run', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedUser(db, 'u2')
    const store = createListeningImportStore(db, { now: () => now })
    const first = await store.begin('u1', begin())
    const second = await store.begin('u2', begin())
    await store.putTracks('u1', first.importId, [track()])
    await store.putTracks('u2', second.importId, [track({ title: 'Different' })])

    expect(await db.select().from(listeningImportRuns)
      .where(and(eq(listeningImportRuns.userId, 'u2'), eq(listeningImportRuns.status, 'open'))))
      .toHaveLength(1)
    expect(await db.select().from(listeningImportTracks)).toHaveLength(2)
  })
})

it('adds quick-import likes without replacing previous saved music or listening history', async () => {
  const db = await createTestDb()
  await db.insert(user).values({id:'quick-user',name:'Test',email:'quick@example.test',createdAt:now,updatedAt:now})
  const store = createListeningImportStore(db,{now: () => now})
  const original = await store.begin('quick-user', accountBegin({expectedTracks:1,expectedLibraryTracks:1,expectedArtists:0}))
  await store.putTracks('quick-user',original.importId,[track()])
  await store.putLibrary('quick-user',original.importId,[libraryRow()])
  await store.complete('quick-user',original.importId)
  const quick = await store.begin('quick-user', begin({package:'spotify_exportify',expectedTracks:1,expectedDays:0,expectedLibraryTracks:1,libraryReview:{mode:'add'}}))
  await store.putTracks('quick-user',quick.importId,[track({platformId:SPOTIFY_B})])
  await store.putLibrary('quick-user',quick.importId,[libraryRow({platformId:SPOTIFY_B})])
  await store.complete('quick-user',quick.importId)
  const review = await spotifyLibraryReview(db,'quick-user')
  expect(review.ids).toEqual([SPOTIFY_A,SPOTIFY_B].sort())
  const stale = await store.begin('quick-user',begin({package:'spotify_exportify',expectedTracks:0,expectedDays:0,libraryReview:{mode:'replace',fingerprint:'f'.repeat(64)}}))
  await expect(store.complete('quick-user',stale.importId)).rejects.toMatchObject({category:'conflict'})
  expect((await spotifyLibraryReview(db,'quick-user')).ids).toEqual(review.ids)
})

it('keeps history after a quick import and refuses an unreviewed official account rollback',async()=>{
 const db=await createTestDb();await seedUser(db,'quick-history')
 const store=createListeningImportStore(db,{now:()=>now})
 const history=await store.begin('quick-history',begin({expectedTracks:1,expectedDays:1}))
 await store.putTracks('quick-history',history.importId,[track()]);await store.putDays('quick-history',history.importId,[day()]);
 await store.complete('quick-history',history.importId)
 const before=await db.select().from(userMusicSources)
 const quick=await store.begin('quick-history',begin({package:'spotify_exportify',expectedTracks:1,expectedDays:0,libraryReview:{mode:'add'}}))
 await store.putTracks('quick-history',quick.importId,[track({platformId:SPOTIFY_B})]);await store.complete('quick-history',quick.importId)
 const after=await db.select().from(userMusicSources)
 expect(after[0].ledgerFrom).toBe(before[0].ledgerFrom);expect(after[0].ledgerTo).toBe(before[0].ledgerTo)
 const account=await store.begin('quick-history',accountBegin({expectedTracks:0,expectedLibraryTracks:0,expectedArtists:0}))
 await expect(store.complete('quick-history',account.importId)).rejects.toMatchObject({category:'conflict'})
})
