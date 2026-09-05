import { describe, it, expect, vi } from 'vitest'
import { eq } from 'drizzle-orm'
import { createTestDb, type TestDb } from '../helpers/db'
import { okDeps, OK_FEATURES } from '../helpers/enrich-fixtures'
import { enrichTrack, type EnrichDeps } from '../../src/enrich/pipeline'
import { tracks, trackFeatures, trackMeanings, enrichmentFailures } from '../../src/db/schema'
import { EnrichSourceError } from '../../src/enrich/types'
import { createListeningImportStore } from '../../src/listening/import-store'
import { begin, day, now, publish, seedUser, track as exportTrack, tenantRows } from '../helpers/listening-fixtures'

const SPOTIFY_ID = '4uLU6hMCjMI75M1A2tKUQC'
const METADATA = {
  spotifyId: SPOTIFY_ID, title: 'Song', artists: ['Artist A', 'Artist B'],
  isrc: 'NGA0A2000001', durationMs: 201_000,
}

async function seedSpotify(db: TestDb, over: Partial<typeof tracks.$inferInsert> = {}) {
  const [track] = await db.insert(tracks).values({
    spotifyId: SPOTIFY_ID, title: 'Song', artist: 'Various Artists', artistSource: 'export', ...over,
  }).returning()
  return track
}

function spotifyDeps(over: Partial<EnrichDeps> = {}): EnrichDeps {
  return {
    ...okDeps,
    spotify: {
      tracks: vi.fn(async () => ({ hits: [METADATA], missing: [] })),
      features: vi.fn(async () => ({
        hits: [{ spotifyId: SPOTIFY_ID, features: { ...OK_FEATURES, isrc: METADATA.isrc } }], missing: [],
      })),
    },
    ...over,
  }
}

describe('Spotify ID enrichment', () => {
  it('corrects album-artist metadata and uses the credited artists in the same meaning pass', async () => {
    const db = await createTestDb()
    const track = await seedSpotify(db)
    const search = vi.fn(async () => null)
    const lyrics = vi.fn(okDeps.lyrics)
    const deps = spotifyDeps({ features: search, lyrics })

    expect(await enrichTrack(db, deps, track)).toEqual({ features: 'ok', meaning: 'ok' })
    expect(deps.spotify?.tracks).toHaveBeenCalledWith([SPOTIFY_ID])
    expect(deps.spotify?.features).toHaveBeenCalledWith([SPOTIFY_ID])
    expect(search).not.toHaveBeenCalled()
    expect(lyrics).toHaveBeenCalledWith({
      title: 'Song', artist: 'Artist A & Artist B', album: null, durationMs: 201_000,
    })
    expect(await db.select().from(tracks)).toEqual([expect.objectContaining({
      id: track.id, artist: 'Artist A & Artist B', artistSource: 'reccobeats',
      spotifyId: SPOTIFY_ID, appleId: null, isrc: METADATA.isrc, durationMs: 201_000,
    })])
    expect(await db.select().from(trackFeatures)).toEqual([expect.objectContaining({
      trackId: track.id, source: 'reccobeats', tempo: OK_FEATURES.tempo,
    })])
    expect(await db.select().from(trackMeanings)).toHaveLength(1)
    expect(await db.select().from(enrichmentFailures)).toHaveLength(0)
  })

  it('uses corrected credits for text fallback when exact-ID features are absent', async () => {
    const db = await createTestDb()
    const track = await seedSpotify(db)
    const search = vi.fn(okDeps.features)
    const deps = spotifyDeps({ features: search })
    deps.spotify!.features = async () => ({ hits: [], missing: [SPOTIFY_ID] })
    expect((await enrichTrack(db, deps, track)).features).toBe('ok')
    expect(search).toHaveBeenCalledWith({ title: 'Song', artist: 'Artist A & Artist B', durationMs: 201_000 })
  })

  it('falls back to existing text matching when neither ID endpoint knows the track', async () => {
    const db = await createTestDb()
    const track = await seedSpotify(db)
    const search = vi.fn(okDeps.features)
    const deps = spotifyDeps({ features: search, spotify: {
      tracks: async () => ({ hits: [], missing: [SPOTIFY_ID] }),
      features: async () => ({ hits: [], missing: [SPOTIFY_ID] }),
    } })
    expect((await enrichTrack(db, deps, track)).features).toBe('ok')
    expect(search).toHaveBeenCalledWith({ title: 'Song', artist: 'Various Artists', durationMs: null })
  })

  it('retains metadata on a feature outage, skips text fallback, and still looks up meaning with corrected credits', async () => {
    const db = await createTestDb()
    const track = await seedSpotify(db)
    const search = vi.fn(okDeps.features)
    const lyrics = vi.fn(okDeps.lyrics)
    const deps = spotifyDeps({ features: search, lyrics })
    deps.spotify!.features = async () => { throw new EnrichSourceError('reccobeats', 'features HTTP 429', 429) }
    expect(await enrichTrack(db, deps, track)).toEqual({ features: 'error', meaning: 'ok' })
    expect(search).not.toHaveBeenCalled()
    expect(lyrics).toHaveBeenCalledWith(expect.objectContaining({ artist: 'Artist A & Artist B' }))
    expect(await db.select().from(trackFeatures)).toHaveLength(0)
    expect(await db.select().from(tracks)).toEqual([expect.objectContaining({
      artistSource: 'reccobeats', isrc: METADATA.isrc, durationMs: 201_000,
    })])
    expect(await db.select().from(enrichmentFailures)).toEqual([expect.objectContaining({
      stage: 'features', attempts: 1, error: 'EnrichSourceError: reccobeats: features HTTP 429',
    })])
  })

  it('keeps an ID lookup error in the retry path without leaking details or calling feature endpoints', async () => {
    const db = await createTestDb()
    const track = await seedSpotify(db)
    const search = vi.fn(okDeps.features)
    const deps = spotifyDeps({ features: search })
    deps.spotify!.tracks = async () => { throw new Error(`private response for ${SPOTIFY_ID}`) }
    expect((await enrichTrack(db, deps, track)).features).toBe('error')
    expect(deps.spotify?.features).not.toHaveBeenCalled()
    expect(search).not.toHaveBeenCalled()
    expect(await db.select().from(enrichmentFailures)).toEqual([expect.objectContaining({
      stage: 'features', attempts: 1, error: 'internal: Error',
    })])
  })

  it('preserves catalog metadata written while an ID request was in flight', async () => {
    const db = await createTestDb()
    const track = await seedSpotify(db)
    const lyrics = vi.fn(okDeps.lyrics)
    const deps = spotifyDeps({ lyrics })
    deps.spotify!.tracks = async () => {
      await db.update(tracks).set({
        artist: 'Catalog credit', artistSource: 'apple_catalog',
        isrc: 'USAAA2400001', durationMs: 202_000,
      }).where(eq(tracks.id, track.id))
      return { hits: [METADATA], missing: [] }
    }
    await enrichTrack(db, deps, track)
    expect(await db.select().from(tracks)).toEqual([expect.objectContaining({
      artist: 'Catalog credit', artistSource: 'apple_catalog',
      isrc: 'USAAA2400001', durationMs: 202_000,
    })])
    expect(lyrics).toHaveBeenCalledWith(expect.objectContaining({ artist: 'Catalog credit', durationMs: 202_000 }))
  })

  it('does not erase export artist credits when the provider has no credited artist', async () => {
    const db = await createTestDb()
    const track = await seedSpotify(db)
    const deps = spotifyDeps()
    deps.spotify!.tracks = async () => ({ hits: [{ ...METADATA, artists: [] }], missing: [] })
    await enrichTrack(db, deps, track)
    expect(await db.select().from(tracks)).toEqual([expect.objectContaining({
      artist: 'Various Artists', artistSource: 'export', isrc: METADATA.isrc,
    })])
  })

  it('skips ID requests when the feature stage is cached or exhausted', async () => {
    const db = await createTestDb()
    const track = await seedSpotify(db)
    const deps = spotifyDeps()
    expect((await enrichTrack(db, deps, track, { features: true })).features).toBe('skipped')
    expect(deps.spotify?.tracks).not.toHaveBeenCalled()
    expect(deps.spotify?.features).not.toHaveBeenCalled()
  })

  it('keeps enrichment across a real staged re-import without changing listener history or membership', async () => {
    const db = await createTestDb()
    await seedUser(db, 'listener')
    const store = createListeningImportStore(db, { now: () => now })
    const chunks = { tracks: [exportTrack({ artist: 'Various Artists', durationMs: null })], days: [day()] }
    const first = await publish(store, 'listener', begin(), chunks)
    const before = await tenantRows(db, 'listener')
    const [track] = await db.select().from(tracks)
    await enrichTrack(db, spotifyDeps(), track)
    expect(await tenantRows(db, 'listener')).toEqual(before)
    const second = await publish(store, 'listener', begin(), chunks)
    expect(second.summary).toEqual(first.summary)
    expect(await db.select().from(tracks)).toEqual([expect.objectContaining({
      id: track.id, artist: 'Artist A & Artist B', artistSource: 'reccobeats',
      isrc: METADATA.isrc, durationMs: 201_000, appleId: null,
    })])
    expect(await db.select().from(trackFeatures)).toHaveLength(1)
  })
})
