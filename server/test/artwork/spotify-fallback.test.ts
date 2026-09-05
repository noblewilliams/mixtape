import { eq } from 'drizzle-orm'
import { describe, expect, it, vi } from 'vitest'
import {
  FALLBACK_ARTWORK_BATCH,
  FALLBACK_ARTWORK_LEASE_MS,
  runSpotifyArtworkBatch,
  type SpotifyArtworkDeps,
} from '../../src/artwork/spotify-fallback'
import { ArtworkProviderError } from '../../src/artwork/provider'
import {
  trackArtworkStatus,
  tracks,
  userMusicSources,
  userTracks,
} from '../../src/db/schema'
import { createTestDb, type TestDb } from '../helpers/db'
import {
  now,
  seedUser,
  SPOTIFY_A,
  SPOTIFY_B,
  SPOTIFY_C,
  tenantRows,
} from '../helpers/listening-fixtures'

const ISRC = 'USUG11904206'
const SPOTIFY_IMAGE = 'https://i.scdn.co/image/ab67616d00001e02ff9ca10b55ce82ae553c8228'
const DEEZER_IMAGE = 'https://e-cdns-images.dzcdn.net/images/cover/abc123/1000x1000-000000-80-0-0.jpg'
const spotifyArtwork = { url: SPOTIFY_IMAGE, width: 300, height: 300, bgColor: null }
const deezerArtwork = { url: DEEZER_IMAGE, width: 1000, height: 1000, bgColor: null }

function deps(over: Partial<SpotifyArtworkDeps> = {}): SpotifyArtworkDeps {
  return {
    spotify: { getArtwork: vi.fn(async () => spotifyArtwork) },
    deezer: { getArtwork: vi.fn(async () => deezerArtwork) },
    now: () => now,
    ...over,
  }
}

async function listener(db: TestDb, id = 'u1', complete = true) {
  await seedUser(db, id)
  await db.insert(userMusicSources).values({
    userId: id,
    source: 'spotify_export',
    lastImportedAt: complete ? now : null,
  })
}

async function spotifyTrack(
  db: TestDb,
  spotifyId: string,
  over: Partial<typeof tracks.$inferInsert> = {},
  userId = 'u1',
) {
  const [row] = await db.insert(tracks).values({
    spotifyId,
    isrc: ISRC,
    title: 'Song',
    artist: 'Artist',
    enrichPriority: 4,
    ...over,
  }).returning()
  await db.insert(userTracks).values({ userId, trackId: row.id, inLibrary: true })
  return row
}

describe('Spotify fallback artwork runner', () => {
  it('stores a fixed oEmbed image without changing listener state or calling Deezer', async () => {
    const db = await createTestDb()
    await listener(db)
    const row = await spotifyTrack(db, SPOTIFY_A)
    const before = await tenantRows(db, 'u1')
    const spotify = vi.fn(async () => spotifyArtwork)
    const deezer = vi.fn(async () => deezerArtwork)

    await expect(runSpotifyArtworkBatch(db, deps({
      spotify: { getArtwork: spotify }, deezer: { getArtwork: deezer },
    }))).resolves.toEqual({
      processed: 1, matched: 1, spotify: 1, deezer: 0, missing: 0, failed: 0, skipped: 0, remaining: 0,
    })
    expect(spotify).toHaveBeenCalledWith(SPOTIFY_A)
    expect(deezer).not.toHaveBeenCalled()
    expect(await db.select().from(tracks).where(eq(tracks.id, row.id))).toMatchObject([{
      artworkUrlTemplate: SPOTIFY_IMAGE,
      artworkWidth: 300,
      artworkHeight: 300,
      artworkBgColor: null,
      artworkFetchedAt: now,
    }])
    expect(await tenantRows(db, 'u1')).toEqual(before)
    expect(await db.select().from(trackArtworkStatus)).toEqual([])
  })

  it('falls back to Deezer only when oEmbed misses and the same ISRC is known', async () => {
    const db = await createTestDb()
    await listener(db)
    await spotifyTrack(db, SPOTIFY_A)
    await spotifyTrack(db, SPOTIFY_B, { isrc: null })
    const spotify = vi.fn(async () => null)
    const deezer = vi.fn(async () => deezerArtwork)

    const result = await runSpotifyArtworkBatch(db, deps({
      spotify: { getArtwork: spotify }, deezer: { getArtwork: deezer },
    }))

    expect(result).toMatchObject({ processed: 2, matched: 1, spotify: 0, deezer: 1, missing: 1 })
    expect(deezer).toHaveBeenCalledOnce()
    expect(deezer).toHaveBeenCalledWith(ISRC)
    expect((await db.select().from(tracks).where(eq(tracks.spotifyId, SPOTIFY_A)))[0].artworkUrlTemplate)
      .toBe(DEEZER_IMAGE)
    expect((await db.select().from(tracks).where(eq(tracks.spotifyId, SPOTIFY_B)))[0].artworkUrlTemplate)
      .toBeNull()
  })

  it('isolates provider failures per track and retries only when due', async () => {
    const db = await createTestDb()
    await listener(db)
    const first = await spotifyTrack(db, SPOTIFY_A, { createdAt: new Date('2026-01-01') })
    await spotifyTrack(db, SPOTIFY_B, { createdAt: new Date('2026-01-02') })
    let clock = now
    const spotify = vi.fn(async (id: string) => {
      if (id === SPOTIFY_A) throw new ArtworkProviderError('rate_limit', 'spotify_oembed', 429)
      return spotifyArtwork
    })
    const current = deps({ spotify: { getArtwork: spotify }, now: () => clock })

    expect(await runSpotifyArtworkBatch(db, current)).toMatchObject({
      processed: 2, matched: 1, failed: 1, missing: 0,
    })
    const [retry] = await db.select().from(trackArtworkStatus).where(eq(trackArtworkStatus.trackId, first.id))
    expect(retry).toMatchObject({ attempts: 1, lastCategory: 'rate_limit' })
    expect((await runSpotifyArtworkBatch(db, current)).processed).toBe(0)
    clock = retry.nextAttemptAt
    spotify.mockResolvedValueOnce(spotifyArtwork)
    expect(await runSpotifyArtworkBatch(db, current)).toMatchObject({ processed: 1, matched: 1 })
  })

  it('claims at most three highest-priority candidates and fences overlapping work', async () => {
    const db = await createTestDb()
    await listener(db)
    const ids = [SPOTIFY_A, SPOTIFY_B, SPOTIFY_C, '0VjIjW4GlUZAMYd2vXMi3b']
    for (let index = 0; index < ids.length; index++) {
      await spotifyTrack(db, ids[index], {
        isrc: `USUG1${String(index).padStart(7, '0')}`,
        enrichPriority: index,
      })
    }
    let release!: () => void
    const wait = new Promise<void>((resolve) => { release = resolve })
    let started!: () => void
    const didStart = new Promise<void>((resolve) => { started = resolve })
    const requested: string[] = []
    const slow = runSpotifyArtworkBatch(db, deps({ spotify: { getArtwork: async (id) => {
      requested.push(id)
      if (requested.length === 1) { started(); await wait }
      return spotifyArtwork
    } } }))
    await didStart

    const overlap = await runSpotifyArtworkBatch(db, deps())
    release()
    const first = await slow

    expect(first.processed).toBe(FALLBACK_ARTWORK_BATCH)
    expect(overlap.processed).toBe(1)
    expect(requested).toHaveLength(FALLBACK_ARTWORK_BATCH)
    expect(requested).not.toContain(SPOTIFY_A)
  })

  it.each(['source', 'identity', 'apple', 'artwork'] as const)
  ('rechecks the current source and track after the network request: %s', async (change) => {
    const db = await createTestDb()
    await listener(db)
    const row = await spotifyTrack(db, SPOTIFY_A)
    const spotify = vi.fn(async () => {
      if (change === 'source') await db.delete(userMusicSources).where(eq(userMusicSources.userId, 'u1'))
      if (change === 'identity') await db.update(tracks).set({ spotifyId: SPOTIFY_B }).where(eq(tracks.id, row.id))
      if (change === 'apple') await db.update(tracks).set({ appleId: '1440935467' }).where(eq(tracks.id, row.id))
      if (change === 'artwork') await db.update(tracks).set({ artworkUrlTemplate: DEEZER_IMAGE }).where(eq(tracks.id, row.id))
      return spotifyArtwork
    })

    expect(await runSpotifyArtworkBatch(db, deps({ spotify: { getArtwork: spotify } })))
      .toMatchObject({ processed: 1, matched: 0, skipped: 1 })
    const [saved] = await db.select().from(tracks).where(eq(tracks.id, row.id))
    expect(saved.artworkUrlTemplate).toBe(change === 'artwork' ? DEEZER_IMAGE : null)
    expect(await db.select().from(trackArtworkStatus)).toEqual([])
  })

  it('skips Apple-linked, covered, incomplete-source, and orphan tracks', async () => {
    const db = await createTestDb()
    await listener(db)
    await spotifyTrack(db, SPOTIFY_A, { appleId: '1440935467' })
    await spotifyTrack(db, SPOTIFY_B, { artworkUrlTemplate: SPOTIFY_IMAGE })
    await db.insert(tracks).values({ spotifyId: SPOTIFY_C, title: 'Orphan', artist: 'Artist' })
    await listener(db, 'u2', false)
    await spotifyTrack(db, '0VjIjW4GlUZAMYd2vXMi3b', {}, 'u2')
    const spotify = vi.fn(async () => spotifyArtwork)

    expect(await runSpotifyArtworkBatch(db, deps({ spotify: { getArtwork: spotify } })))
      .toMatchObject({ processed: 0, remaining: 0 })
    expect(spotify).not.toHaveBeenCalled()
  })

  it('does not publish work whose five-minute claim expired', async () => {
    const db = await createTestDb()
    await listener(db)
    await spotifyTrack(db, SPOTIFY_A)
    let clock = now
    const result = await runSpotifyArtworkBatch(db, deps({
      now: () => clock,
      spotify: { getArtwork: async () => {
        clock = new Date(now.getTime() + FALLBACK_ARTWORK_LEASE_MS)
        return spotifyArtwork
      } },
    }))
    expect(result).toMatchObject({ processed: 0, matched: 0 })
    expect((await db.select().from(tracks))[0].artworkUrlTemplate).toBeNull()
  })
})
