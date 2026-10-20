import { describe, it, expect } from 'vitest'
import { createTestDb, type TestDb } from '../helpers/db'
import { buildShelf, SHELF_LIMIT, SHELF_MAX_LIMIT, SHELF_MIN_SONGS } from '../../src/albums/shelf'
import { tracks, trackMeanings, userTracks, user, listeningDays } from '../../src/db/schema'

const DIMS = 1024

// A direction vector, nonzero only at the given indices (cosine ignores magnitude).
function vec(pattern: Record<number, number>): number[] {
  const v = new Array(DIMS).fill(0)
  for (const [i, val] of Object.entries(pattern)) v[Number(i)] = val
  return v
}

const BRIEF = vec({ 0: 1 })
const NEAR = vec({ 0: 1 }) // similarity 1
const MID = vec({ 0: 1, 1: 1 }) // similarity ~0.707
const FAR = vec({ 1: 1 }) // similarity 0

async function seedUser(db: TestDb, id: string) {
  await db.insert(user).values({
    id,
    name: id,
    email: `${id}@example.com`,
    emailVerified: false,
    createdAt: new Date(),
    updatedAt: new Date(),
  })
}

type SongOpts = {
  artist: string
  album: string | null
  embedding?: number[]
  playCount?: number
  inLibrary?: boolean
  seeded?: boolean
  appleId?: string | null
  isrc?: string | null
  playCountObserved?: boolean
}

let counter = 0

async function seedSong(db: TestDb, userId: string, opts: SongOpts) {
  counter += 1
  const [t] = await db
    .insert(tracks)
    .values({
      appleId: opts.appleId === undefined ? `shelf-${counter}` : opts.appleId,
      title: `song-${counter}`,
      artist: opts.artist,
      album: opts.album,
      isrc: opts.isrc ?? null,
      durationMs: 200000,
    })
    .returning()
  if (opts.embedding) {
    await db.insert(trackMeanings).values({ trackId: t.id, embedding: opts.embedding, lyricsSource: 'lrclib' })
  }
  await db.insert(userTracks).values({
    userId,
    trackId: t.id,
    playCount: opts.playCount ?? 0,
    playCountObserved: opts.playCountObserved ?? true,
    inLibrary: opts.inLibrary ?? true,
    seeded: opts.seeded ?? false,
  })
  return t
}

const today = () => new Date().toISOString().slice(0, 10)

async function playToday(db: TestDb, userId: string, trackId: string) {
  await db.insert(listeningDays).values({
    userId,
    source: 'apple_export',
    trackId,
    day: today(),
    plays: 5,
    msPlayed: 1_000_000,
  })
}

async function seedAlbum(db: TestDb, userId: string, n: number, opts: SongOpts) {
  const out = []
  for (let i = 0; i < n; i++) out.push(await seedSong(db, userId, opts))
  return out
}

// Six songs far from the brief, four near it, two (never returned) near it,
// plus loose songs with no album.
async function seedShelf(db: TestDb, userId: string) {
  await seedAlbum(db, userId, 6, { artist: 'John Coltrane', album: 'Giant Steps', embedding: FAR })
  await seedAlbum(db, userId, 4, { artist: 'Miles Davis', album: 'Kind of Blue', embedding: NEAR })
  await seedAlbum(db, userId, 2, { artist: 'Bill Evans', album: 'Explorations', embedding: NEAR })
  await seedAlbum(db, userId, 5, { artist: 'Loose Artist', album: null, embedding: NEAR })
  await seedAlbum(db, userId, 4, { artist: 'Blank Album', album: '   ', embedding: NEAR })
}

describe('buildShelf', () => {
  it('exports its defaults', () => {
    expect(SHELF_MIN_SONGS).toBe(4)
    expect(SHELF_LIMIT).toBe(10)
    expect(SHELF_MAX_LIMIT).toBe(25)
  })

  it('returns groups at the floor, ordered by similarity, never null-album or small groups', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedShelf(db, 'u1')

    const shelf = await buildShelf(db, 'u1', BRIEF)

    expect(shelf.map((a) => a.album)).toEqual(['Kind of Blue', 'Giant Steps'])
    expect(shelf[0]).toMatchObject({ artist: 'Miles Davis', songCount: 4, plays: 0 })
    expect(shelf[0].similarity).toBeCloseTo(1, 3)
    expect(shelf[1]).toMatchObject({ artist: 'John Coltrane', songCount: 6 })
    expect(shelf[1].similarity).toBeCloseTo(0, 3)
    expect(shelf[0].sampleAppleIds).toHaveLength(3)
    expect(shelf[1].sampleAppleIds).toHaveLength(3)
    for (const id of shelf[0].sampleAppleIds) expect(id).toMatch(/^shelf-\d+$/)
  })

  it('averages similarity over the rows that have an embedding', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedAlbum(db, 'u1', 2, { artist: 'A', album: 'Half', embedding: NEAR })
    await seedAlbum(db, 'u1', 2, { artist: 'A', album: 'Half', embedding: FAR })
    await seedAlbum(db, 'u1', 1, { artist: 'A', album: 'Half' })

    const [album] = await buildShelf(db, 'u1', BRIEF)
    expect(album.songCount).toBe(5)
    expect(album.similarity).toBeCloseTo(0.5, 3)
  })

  it('drops groups below a raised minSongs floor', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedShelf(db, 'u1')

    const shelf = await buildShelf(db, 'u1', BRIEF, { minSongs: 5, limit: 10 })
    expect(shelf.map((a) => a.album)).toEqual(['Giant Steps'])
  })

  it('respects limit', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedShelf(db, 'u1')

    const shelf = await buildShelf(db, 'u1', BRIEF, { minSongs: 4, limit: 1 })
    expect(shelf.map((a) => a.album)).toEqual(['Kind of Blue'])
  })

  it('returns [] for an empty library', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    expect(await buildShelf(db, 'u1', BRIEF)).toEqual([])
  })

  it('keeps a group with no embeddings at similarity 0', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedAlbum(db, 'u1', 4, { artist: 'Unenriched', album: 'Quiet Record' })

    const shelf = await buildShelf(db, 'u1', BRIEF)
    expect(shelf).toHaveLength(1)
    expect(shelf[0]).toMatchObject({ album: 'Quiet Record', songCount: 4, similarity: 0 })
  })

  it('groups case- and whitespace-insensitively', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedAlbum(db, 'u1', 2, { artist: 'John Coltrane', album: 'Blue Train', embedding: NEAR })
    await seedAlbum(db, 'u1', 2, { artist: ' john coltrane ', album: ' blue train ', embedding: NEAR })

    const shelf = await buildShelf(db, 'u1', BRIEF)
    expect(shelf).toHaveLength(1)
    expect(shelf[0].songCount).toBe(4)
  })

  it('counts only candidate rows', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedAlbum(db, 'u1', 3, { artist: 'Coltrane', album: 'Ballads', embedding: NEAR })
    // Not in the library, not seeded, no plays, no playlist: not a candidate.
    await seedSong(db, 'u1', { artist: 'Coltrane', album: 'Ballads', embedding: NEAR, inLibrary: false })
    expect(await buildShelf(db, 'u1', BRIEF)).toEqual([])

    // A seeded row is a candidate and lifts the group to the floor.
    await seedSong(db, 'u1', { artist: 'Coltrane', album: 'Ballads', embedding: NEAR, inLibrary: false, seeded: true })
    const shelf = await buildShelf(db, 'u1', BRIEF)
    expect(shelf).toHaveLength(1)
    expect(shelf[0].songCount).toBe(4)
  })

  it('reads only the requesting listener', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedUser(db, 'u2')
    await seedShelf(db, 'u2')
    expect(await buildShelf(db, 'u1', BRIEF)).toEqual([])
  })

  it('ignores another listener\'s plays and recency on shared tracks rows', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedUser(db, 'u2')
    // Equal similarity; with nothing else to go on, artist breaks the tie.
    const alpha = await seedAlbum(db, 'u1', 4, { artist: 'Alpha', album: 'First', embedding: MID, playCountObserved: false })
    const beta = await seedAlbum(db, 'u1', 4, { artist: 'Beta', album: 'Second', embedding: MID, playCountObserved: false })
    // u2 owns the very same rows and plays Beta heavily, today.
    for (const t of [...alpha, ...beta]) {
      await db.insert(userTracks).values({
        userId: 'u2',
        trackId: t.id,
        playCount: beta.includes(t) ? 150 : 0,
        playCountObserved: true,
        inLibrary: true,
      })
    }
    await playToday(db, 'u2', beta[0].id)

    const u1 = await buildShelf(db, 'u1', BRIEF)
    expect(u1.map((a) => a.album)).toEqual(['First', 'Second'])
    expect(u1.map((a) => a.plays)).toEqual([null, null])

    const u2 = await buildShelf(db, 'u2', BRIEF)
    expect(u2.map((a) => a.album)).toEqual(['Second', 'First'])
    expect(u2[0].plays).toBe(600)
  })

  it('sums plays and lets plays and recency break a similarity tie', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedAlbum(db, 'u1', 4, { artist: 'Quiet', album: 'Unplayed', embedding: MID })
    const played = await seedAlbum(db, 'u1', 4, { artist: 'Loud', album: 'Played', embedding: MID, playCount: 25 })
    await playToday(db, 'u1', played[0].id)

    const shelf = await buildShelf(db, 'u1', BRIEF)
    expect(shelf.map((a) => a.album)).toEqual(['Played', 'Unplayed'])
    expect(shelf[0].plays).toBe(100)
    expect(shelf[1].plays).toBe(0)
    expect(shelf[0].similarity).toBeCloseTo(Math.SQRT1_2, 3)
  })

  it('lets a recent play alone break a tie on similarity and plays', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedAlbum(db, 'u1', 4, { artist: 'Abe', album: 'Stale', embedding: MID, playCount: 10 })
    const recent = await seedAlbum(db, 'u1', 4, { artist: 'Zed', album: 'Fresh', embedding: MID, playCount: 10 })
    await playToday(db, 'u1', recent[0].id)

    const shelf = await buildShelf(db, 'u1', BRIEF)
    expect(shelf.map((a) => a.album)).toEqual(['Fresh', 'Stale'])
    expect(shelf.map((a) => a.plays)).toEqual([40, 40])
  })

  it('counts songs by recording: ISRC twin rows are one song', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const opts = { artist: 'Twins', album: 'Pair', embedding: NEAR }
    await seedAlbum(db, 'u1', 2, opts)
    // One recording as an Apple row and a Spotify-relinked row.
    await seedSong(db, 'u1', { ...opts, isrc: 'USRC17607839' })
    await seedSong(db, 'u1', { ...opts, isrc: 'USRC17607839', appleId: null })
    expect(await buildShelf(db, 'u1', BRIEF)).toEqual([])

    await seedSong(db, 'u1', opts)
    const shelf = await buildShelf(db, 'u1', BRIEF)
    expect(shelf).toHaveLength(1)
    expect(shelf[0].songCount).toBe(4)
  })

  it('returns plays null when no count in the group was observed', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedAlbum(db, 'u1', 4, { artist: 'Web', album: 'Only', embedding: NEAR, playCount: 0, playCountObserved: false })

    const [album] = await buildShelf(db, 'u1', BRIEF)
    expect(album.plays).toBeNull()
    expect(album.similarity).toBeCloseTo(1, 3)
  })

  it('sums only observed counts when a group mixes observed and unobserved', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedAlbum(db, 'u1', 2, { artist: 'Mixed', album: 'Sources', playCount: 7 })
    await seedAlbum(db, 'u1', 2, { artist: 'Mixed', album: 'Sources', playCount: 99, playCountObserved: false })

    const [album] = await buildShelf(db, 'u1', BRIEF)
    expect(album.plays).toBe(14)
  })

  it('clamps minSongs to 2 and limit to 1', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedAlbum(db, 'u1', 1, { artist: 'Solo', album: 'Single', embedding: NEAR })
    await seedAlbum(db, 'u1', 2, { artist: 'Duo', album: 'Pair', embedding: NEAR })
    await seedAlbum(db, 'u1', 3, { artist: 'Trio', album: 'Three', embedding: FAR })

    const loose = await buildShelf(db, 'u1', BRIEF, { minSongs: 1 })
    expect(loose.map((a) => a.album)).toEqual(['Pair', 'Three'])

    const one = await buildShelf(db, 'u1', BRIEF, { minSongs: 2, limit: 0 })
    expect(one.map((a) => a.album)).toEqual(['Pair'])
  })

  it('rejects non-integer options', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await expect(buildShelf(db, 'u1', BRIEF, { limit: -1 })).rejects.toThrow(/bad limit/)
    await expect(buildShelf(db, 'u1', BRIEF, { limit: 1.5 })).rejects.toThrow(/bad limit/)
    await expect(buildShelf(db, 'u1', BRIEF, { minSongs: Number.NaN })).rejects.toThrow(/bad minSongs/)
  })

  it('omits null apple ids from the sample', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedAlbum(db, 'u1', 3, { artist: 'Spotify Only', album: 'Rows', appleId: null })
    await seedSong(db, 'u1', { artist: 'Spotify Only', album: 'Rows' })

    const [album] = await buildShelf(db, 'u1', BRIEF)
    expect(album.songCount).toBe(4)
    expect(album.sampleAppleIds).toHaveLength(1)
  })

  it('rejects a malformed embedding', async () => {
    const db = await createTestDb()
    await expect(buildShelf(db, 'u1', [1, 2, 3])).rejects.toThrow(/bad embedding/)
  })
})
