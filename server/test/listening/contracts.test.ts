import { describe, expect, it } from 'vitest'
import {
  beginListeningImportSchema,
  LISTENING_ARTIST_CHUNK_MAX,
  LISTENING_DAY_CHUNK_MAX,
  LISTENING_IMPORT_MAX_ARTISTS,
  LISTENING_IMPORT_MAX_DAYS,
  LISTENING_IMPORT_MAX_LIBRARY_TRACKS,
  LISTENING_IMPORT_MAX_TRACKS,
  LISTENING_LIBRARY_CHUNK_MAX,
  LISTENING_TRACK_CHUNK_MAX,
  listeningArtistChunkSchema,
  listeningDayChunkSchema,
  listeningLibraryChunkSchema,
  listeningTrackChunkSchema,
} from '../../src/listening/contracts'

const SPOTIFY_ID = '4uLU6hMCjMI75M1A2tKUQC'

const begin = (over: Record<string, unknown> = {}) => ({
  source: 'spotify_export',
  package: 'spotify_extended',
  timeZone: 'Africa/Lagos',
  country: 'NG',
  expectedTracks: 10,
  expectedDays: 100,
  expectedLibraryTracks: 0,
  expectedArtists: 0,
  ...over,
})

const account = (over: Record<string, unknown> = {}) => begin({
  package: 'spotify_account',
  expectedDays: 0,
  expectedLibraryTracks: 5,
  expectedArtists: 3,
  ...over,
})

const apple = (over: Record<string, unknown> = {}) => begin({
  source: 'apple_export',
  package: 'apple_media',
  expectedLibraryTracks: 5,
  ...over,
})

const track = (over: Record<string, unknown> = {}) => ({
  ordinal: 0,
  platformId: SPOTIFY_ID,
  title: 'Song',
  artist: 'Artist',
  album: 'Album',
  durationMs: 200_000,
  ...over,
})

const day = (over: Record<string, unknown> = {}) => ({
  ordinal: 0,
  platformId: SPOTIFY_ID,
  day: '2026-08-30',
  plays: 3,
  skips: 1,
  completes: 2,
  msPlayed: 600_000,
  hoursMask: 5,
  ...over,
})

const libraryRow = (over: Record<string, unknown> = {}) => ({
  ordinal: 0,
  platformId: SPOTIFY_ID,
  playCount: 4,
  skipCount: 1,
  lastPlayedAt: 1_720_000_000_000,
  dateAdded: 1_700_000_000_000,
  likeRating: 1,
  ...over,
})

const artist = (over: Record<string, unknown> = {}) => ({
  ordinal: 0,
  name: 'Artist',
  spotifyId: SPOTIFY_ID,
  ...over,
})

describe('listening import contracts', () => {
  describe('begin', () => {
    it('accepts each package and defaults the unresolved counts', () => {
      expect(beginListeningImportSchema.parse(begin())).toEqual({
        ...begin(),
        unresolvedRows: 0,
        unresolvedPlays: 0,
      })
      expect(beginListeningImportSchema.parse(account({ unresolvedRows: 4, unresolvedPlays: 9 })))
        .toMatchObject({ package: 'spotify_account', unresolvedRows: 4, unresolvedPlays: 9 })
      expect(beginListeningImportSchema.parse(apple({ country: null })))
        .toMatchObject({ source: 'apple_export', package: 'apple_media', country: null })
    })

    it.each([
      ['an Apple package on a Spotify source', begin({ package: 'apple_media' })],
      ['a Spotify package on an Apple source', apple({ package: 'spotify_extended' })],
      ['an unknown source', begin({ source: 'spotify' })],
      ['an unknown package', begin({ package: 'spotify_playlists' })],
    ])('rejects %s', (_case, input) => {
      expect(beginListeningImportSchema.safeParse(input).success).toBe(false)
    })

    it.each([
      ['library tracks on the extended package', begin({ expectedLibraryTracks: 1 })],
      ['artists on the extended package', begin({ expectedArtists: 1 })],
      ['days on the account package', account({ expectedDays: 1 })],
      ['artists on the Apple package', apple({ expectedArtists: 1 })],
    ])('rejects %s', (_case, input) => {
      expect(beginListeningImportSchema.safeParse(input).success).toBe(false)
    })

    it.each([
      ['too many tracks', begin({ expectedTracks: LISTENING_IMPORT_MAX_TRACKS + 1 })],
      ['too many days', begin({ expectedDays: LISTENING_IMPORT_MAX_DAYS + 1 })],
      ['too many library tracks', account({ expectedLibraryTracks: LISTENING_IMPORT_MAX_LIBRARY_TRACKS + 1 })],
      ['too many artists', account({ expectedArtists: LISTENING_IMPORT_MAX_ARTISTS + 1 })],
      ['a negative count', begin({ expectedTracks: -1 })],
      ['a fractional count', begin({ expectedDays: 1.5 })],
      ['negative unresolved rows', begin({ unresolvedRows: -1 })],
      ['negative unresolved plays', begin({ unresolvedPlays: -1 })],
      ['an empty time zone', begin({ timeZone: '' })],
      ['an overlong time zone', begin({ timeZone: 'x'.repeat(65) })],
      ['a lowercase country', begin({ country: 'ng' })],
      ['a three-letter country', begin({ country: 'NGA' })],
      ['a missing country', (() => { const { country: _country, ...rest } = begin(); return rest })()],
      ['an unknown field', begin({ storefront: 'ng' })],
    ])('rejects %s', (_case, input) => {
      expect(beginListeningImportSchema.safeParse(input).success).toBe(false)
    })

    it('accepts the caps exactly', () => {
      expect(beginListeningImportSchema.safeParse(begin({
        expectedTracks: LISTENING_IMPORT_MAX_TRACKS,
        expectedDays: LISTENING_IMPORT_MAX_DAYS,
      })).success).toBe(true)
      expect(beginListeningImportSchema.safeParse(account({
        expectedLibraryTracks: LISTENING_IMPORT_MAX_LIBRARY_TRACKS,
        expectedArtists: LISTENING_IMPORT_MAX_ARTISTS,
      })).success).toBe(true)
    })
  })

  describe('track chunks', () => {
    it('accepts a track with nullable album and duration', () => {
      expect(listeningTrackChunkSchema.parse({
        tracks: [track({ album: null, durationMs: null })],
      }).tracks[0]).toMatchObject({ album: null, durationMs: null })
    })

    it.each([
      ['a null byte in the title', track({ title: 'Bad\0Song' })],
      ['a lone surrogate', track({ title: '\ud800' })],
      ['an empty platform id', track({ platformId: '' })],
      ['an overlong platform id', track({ platformId: 'x'.repeat(65) })],
      ['an empty artist', track({ artist: '' })],
      ['an overlong album', track({ album: 'x'.repeat(1_001) })],
      ['a negative ordinal', track({ ordinal: -1 })],
      ['an ordinal past the cap', track({ ordinal: LISTENING_IMPORT_MAX_TRACKS })],
      ['a negative duration', track({ durationMs: -1 })],
      ['an unknown field', track({ genre: 'Pop' })],
    ])('rejects %s', (_case, input) => {
      expect(listeningTrackChunkSchema.safeParse({ tracks: [input] }).success).toBe(false)
    })

    it('bounds the chunk and rejects unknown fields', () => {
      expect(listeningTrackChunkSchema.safeParse({ tracks: [] }).success).toBe(false)
      expect(listeningTrackChunkSchema.safeParse({
        tracks: Array.from({ length: LISTENING_TRACK_CHUNK_MAX + 1 }, (_, ordinal) =>
          track({ ordinal, platformId: String(ordinal) })),
      }).success).toBe(false)
      expect(listeningTrackChunkSchema.safeParse({
        tracks: Array.from({ length: LISTENING_TRACK_CHUNK_MAX }, (_, ordinal) =>
          track({ ordinal, platformId: String(ordinal) })),
      }).success).toBe(true)
      expect(listeningTrackChunkSchema.safeParse({ tracks: [track()], token: 'x' }).success).toBe(false)
    })
  })

  describe('day chunks', () => {
    it('accepts a leap day, nullable counters, and a full-width play time', () => {
      expect(listeningDayChunkSchema.parse({
        days: [day({
          day: '2024-02-29',
          skips: null,
          completes: null,
          hoursMask: null,
          msPlayed: Number.MAX_SAFE_INTEGER,
        })],
      }).days[0]).toMatchObject({ day: '2024-02-29', skips: null, msPlayed: Number.MAX_SAFE_INTEGER })
    })

    it.each([
      ['February 30th', day({ day: '2026-02-30' })],
      ['a non-leap February 29th', day({ day: '2023-02-29' })],
      ['a thirteenth month', day({ day: '2026-13-01' })],
      ['a zero day', day({ day: '2026-01-00' })],
      ['an unpadded day', day({ day: '2026-1-5' })],
      ['a day without dashes', day({ day: '20260105' })],
      ['a timestamp instead of a day', day({ day: '2026-01-05T00:00:00Z' })],
      ['a negative ordinal', day({ ordinal: -1 })],
      ['an ordinal past the cap', day({ ordinal: LISTENING_IMPORT_MAX_DAYS })],
      ['negative plays', day({ plays: -1 })],
      ['negative skips', day({ skips: -1 })],
      ['negative play time', day({ msPlayed: -1 })],
      ['fractional play time', day({ msPlayed: 1.5 })],
      ['play time past the safe range', day({ msPlayed: 2 ** 53 })],
      ['a mask past 24 bits', day({ hoursMask: 16_777_216 })],
      ['a negative mask', day({ hoursMask: -1 })],
      ['an empty platform id', day({ platformId: '' })],
      ['an unknown field', day({ title: 'Song' })],
    ])('rejects %s', (_case, input) => {
      expect(listeningDayChunkSchema.safeParse({ days: [input] }).success).toBe(false)
    })

    it('bounds the chunk', () => {
      expect(listeningDayChunkSchema.safeParse({ days: [] }).success).toBe(false)
      expect(listeningDayChunkSchema.safeParse({
        days: Array.from({ length: LISTENING_DAY_CHUNK_MAX + 1 }, (_, ordinal) =>
          day({ ordinal, platformId: String(ordinal) })),
      }).success).toBe(false)
      expect(listeningDayChunkSchema.safeParse({
        days: Array.from({ length: LISTENING_DAY_CHUNK_MAX }, (_, ordinal) =>
          day({ ordinal, platformId: String(ordinal) })),
      }).success).toBe(true)
    })
  })

  describe('library chunks', () => {
    it.each([-1, 0, 1, null])('accepts a like rating of %s', (likeRating) => {
      expect(listeningLibraryChunkSchema.parse({
        tracks: [libraryRow({ likeRating })],
      }).tracks[0].likeRating).toBe(likeRating)
    })

    it('accepts unknown counts and dates', () => {
      expect(listeningLibraryChunkSchema.parse({
        tracks: [libraryRow({ playCount: null, skipCount: null, lastPlayedAt: null, dateAdded: null })],
      }).tracks[0]).toMatchObject({ playCount: null, lastPlayedAt: null })
    })

    it.each([
      ['a like rating of 2', libraryRow({ likeRating: 2 })],
      ['a fractional like rating', libraryRow({ likeRating: 0.5 })],
      ['a negative play count', libraryRow({ playCount: -1 })],
      ['a negative skip count', libraryRow({ skipCount: -1 })],
      ['a play count past Postgres integer', libraryRow({ playCount: 2_147_483_648 })],
      ['a last-played time past the timestamp range', libraryRow({ lastPlayedAt: 8_640_000_000_000_001 })],
      ['a negative date added', libraryRow({ dateAdded: -1 })],
      ['an ordinal past the cap', libraryRow({ ordinal: LISTENING_IMPORT_MAX_LIBRARY_TRACKS })],
      ['an empty platform id', libraryRow({ platformId: '' })],
      ['an unknown field', libraryRow({ title: 'Song' })],
    ])('rejects %s', (_case, input) => {
      expect(listeningLibraryChunkSchema.safeParse({ tracks: [input] }).success).toBe(false)
    })

    it('bounds the chunk', () => {
      expect(listeningLibraryChunkSchema.safeParse({ tracks: [] }).success).toBe(false)
      expect(listeningLibraryChunkSchema.safeParse({
        tracks: Array.from({ length: LISTENING_LIBRARY_CHUNK_MAX + 1 }, (_, ordinal) =>
          libraryRow({ ordinal, platformId: String(ordinal) })),
      }).success).toBe(false)
    })
  })

  describe('artist chunks', () => {
    it('accepts a base62 Spotify id or none', () => {
      expect(listeningArtistChunkSchema.parse({
        artists: [artist(), artist({ ordinal: 1, name: 'Other', spotifyId: null })],
      }).artists.map((value) => value.spotifyId)).toEqual([SPOTIFY_ID, null])
    })

    it.each([
      ['a 21-character id', artist({ spotifyId: SPOTIFY_ID.slice(0, 21) })],
      ['a 23-character id', artist({ spotifyId: `${SPOTIFY_ID}x` })],
      ['a non-base62 id', artist({ spotifyId: `${SPOTIFY_ID.slice(0, 21)}-` })],
      ['an empty name', artist({ name: '' })],
      ['an overlong name', artist({ name: 'x'.repeat(501) })],
      ['a null byte in the name', artist({ name: 'Bad\0Name' })],
      ['an ordinal past the cap', artist({ ordinal: LISTENING_IMPORT_MAX_ARTISTS })],
      ['an unknown field', artist({ genres: [] })],
    ])('rejects %s', (_case, input) => {
      expect(listeningArtistChunkSchema.safeParse({ artists: [input] }).success).toBe(false)
    })

    it('bounds the chunk', () => {
      expect(listeningArtistChunkSchema.safeParse({ artists: [] }).success).toBe(false)
      expect(listeningArtistChunkSchema.safeParse({
        artists: Array.from({ length: LISTENING_ARTIST_CHUNK_MAX + 1 }, (_, ordinal) =>
          artist({ ordinal, name: `Artist ${ordinal}` })),
      }).success).toBe(false)
    })
  })
})
