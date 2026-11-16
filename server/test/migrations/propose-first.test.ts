import { eq, sql } from 'drizzle-orm'
import { describe, expect, it } from 'vitest'
import { trackFeatureFallbacks, tracks } from '../../src/db/schema'
import { createTestDb } from '../helpers/db'

describe('propose-first migration', () => {
  it('adds tracks.meaning_deferred, defaulting false', async () => {
    const db = await createTestDb()
    const [track] = await db.insert(tracks).values({ title: 'Song', artist: 'Artist' }).returning()
    expect(track.meaningDeferred).toBe(false)
    const raw = await db.execute<{ meaning_deferred: boolean }>(
      sql`SELECT meaning_deferred FROM tracks WHERE id = ${track.id}`,
    )
    expect(raw.rows).toEqual([{ meaning_deferred: false }])
    await expect(db.execute(sql`UPDATE tracks SET meaning_deferred = NULL`)).rejects.toThrow()
  })

  it('stores fallback features apart from track_features and cascades with the track', async () => {
    const db = await createTestDb()
    const [track] = await db.insert(tracks).values({ title: 'Song', artist: 'Artist' }).returning()
    await db.insert(trackFeatureFallbacks).values({
      trackId: track.id,
      tempo: 120,
      energy: 0.7,
      valence: 0.4,
      tempoSource: 'deezer',
      moodSource: 'model',
    })
    const [row] = await db.select().from(trackFeatureFallbacks)
    expect(row).toMatchObject({ trackId: track.id, tempo: 120, energy: 0.7, valence: 0.4, tempoSource: 'deezer', moodSource: 'model' })
    expect(row.fetchedAt).toBeInstanceOf(Date)
    const features = await db.execute(sql`SELECT 1 FROM track_features`)
    expect(features.rows).toEqual([])

    await db.delete(tracks).where(eq(tracks.id, track.id))
    expect(await db.select().from(trackFeatureFallbacks)).toEqual([])
  })

  it('allows null values and sources, one row per track, known sources only', async () => {
    const db = await createTestDb()
    const [track] = await db.insert(tracks).values({ title: 'Song', artist: 'Artist' }).returning()
    await db.insert(trackFeatureFallbacks).values({ trackId: track.id })
    const [row] = await db.select().from(trackFeatureFallbacks)
    expect(row).toMatchObject({ tempo: null, energy: null, valence: null, tempoSource: null, moodSource: null })
    await expect(db.insert(trackFeatureFallbacks).values({ trackId: track.id })).rejects.toThrow()
    await expect(db.insert(trackFeatureFallbacks).values({ trackId: crypto.randomUUID() })).rejects.toThrow()
    await db.delete(trackFeatureFallbacks)
    await expect(
      db.execute(sql`INSERT INTO track_feature_fallbacks (track_id, tempo_source) VALUES (${track.id}, 'reccobeats')`),
    ).rejects.toThrow()
    await expect(
      db.execute(sql`INSERT INTO track_feature_fallbacks (track_id, mood_source) VALUES (${track.id}, 'deezer')`),
    ).rejects.toThrow()
  })
})
