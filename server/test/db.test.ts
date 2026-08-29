import { describe, it, expect } from 'vitest'
import { eq } from 'drizzle-orm'
import { createTestDb } from './helpers/db'
import {
  tracks,
  user,
  userTracks,
  trackFeatures,
  trackMeanings,
  enrichmentFailures,
  djSessions,
  djMessages,
  queueTracks,
} from '../src/db/schema'

describe('db schema', () => {
  it('round-trips a track', async () => {
    const db = await createTestDb()
    await db.insert(tracks).values({ appleId: '123', title: 'Song', artist: 'Artist' })
    const rows = await db.select().from(tracks)
    expect(rows).toHaveLength(1)
    expect(rows[0].appleId).toBe('123')
    expect(rows[0].id).toMatch(/^[0-9a-f-]{36}$/)
    expect(rows[0].createdAt).toBeInstanceOf(Date)
  })

  it('rejects a duplicate appleId', async () => {
    const db = await createTestDb()
    await db.insert(tracks).values({ appleId: '123', title: 'Song', artist: 'Artist' })
    await expect(
      db.insert(tracks).values({ appleId: '123', title: 'Dup', artist: 'Other' }),
    ).rejects.toThrow()
  })

  it('links a user to a track with play count', async () => {
    const db = await createTestDb()
    await db.insert(user).values({
      id: 'user-1',
      name: 'Test',
      email: 'test@example.com',
      emailVerified: false,
      createdAt: new Date(),
      updatedAt: new Date(),
    })
    const [track] = await db
      .insert(tracks)
      .values({ appleId: '123', title: 'Song', artist: 'Artist' })
      .returning()
    await db.insert(userTracks).values({ userId: 'user-1', trackId: track.id, playCount: 42 })
    const rows = await db.select().from(userTracks)
    expect(rows).toHaveLength(1)
    expect(rows[0].playCount).toBe(42)
  })

  it('rejects a user_track for an unknown user', async () => {
    const db = await createTestDb()
    const [track] = await db
      .insert(tracks)
      .values({ appleId: 'x1', title: 'T', artist: 'A' })
      .returning()
    await expect(
      db.insert(userTracks).values({ userId: 'nope', trackId: track.id }),
    ).rejects.toThrow()
  })

  it('rejects a duplicate (user, track) pair', async () => {
    const db = await createTestDb()
    await db.insert(user).values({
      id: 'u1',
      name: 'T',
      email: 'u1@example.com',
      emailVerified: false,
      createdAt: new Date(),
      updatedAt: new Date(),
    })
    const [track] = await db
      .insert(tracks)
      .values({ appleId: 'x2', title: 'T', artist: 'A' })
      .returning()
    await db.insert(userTracks).values({ userId: 'u1', trackId: track.id })
    await expect(
      db.insert(userTracks).values({ userId: 'u1', trackId: track.id }),
    ).rejects.toThrow()
  })

  it('stores audio features and a 1024-dim embedding for a track', async () => {
    const db = await createTestDb()
    const [track] = await db
      .insert(tracks)
      .values({ appleId: 'e1', title: 'Song', artist: 'Artist' })
      .returning()
    await db.insert(trackFeatures).values({
      trackId: track.id,
      tempo: 128.4,
      key: 4,
      mode: 1,
      energy: 0.342,
      danceability: 0.516,
      valence: 0.167,
      acousticness: 0.832,
      instrumentalness: 0.579,
      liveness: 0.0857,
      speechiness: 0.0342,
      loudness: -9.785,
      source: 'reccobeats',
    })
    await db.insert(trackMeanings).values({
      trackId: track.id,
      embedding: Array.from({ length: 1024 }, (_, i) => i / 1024),
      lyricsSource: 'lrclib',
      instrumental: false,
    })
    const feats = await db.select().from(trackFeatures)
    expect(feats[0].tempo).toBeCloseTo(128.4)
    const meanings = await db.select().from(trackMeanings)
    expect(meanings[0].embedding).toHaveLength(1024)
  })

  it('records enrichment failures with attempt counts', async () => {
    const db = await createTestDb()
    const [track] = await db
      .insert(tracks)
      .values({ appleId: 'e2', title: 'S', artist: 'A' })
      .returning()
    await db.insert(enrichmentFailures).values({ trackId: track.id, stage: 'features', error: 'no match' })
    const rows = await db.select().from(enrichmentFailures)
    expect(rows[0].attempts).toBe(1)
  })

  it('stores a null embedding for instrumentals', async () => {
    const db = await createTestDb()
    const [track] = await db.insert(tracks).values({ appleId: 'e3', title: 'S', artist: 'A' }).returning()
    await db.insert(trackMeanings).values({ trackId: track.id, embedding: null, lyricsSource: 'lrclib', instrumental: true })
    const [m] = await db.select().from(trackMeanings)
    expect(m.embedding).toBeNull()
    expect(m.instrumental).toBe(true)
  })

  it('rejects an embedding of the wrong dimension', async () => {
    const db = await createTestDb()
    const [track] = await db.insert(tracks).values({ appleId: 'e4', title: 'S', artist: 'A' }).returning()
    await expect(
      db.insert(trackMeanings).values({ trackId: track.id, embedding: Array.from({ length: 768 }, () => 0) }),
    ).rejects.toThrow()
  })

  it('round-trips a dj session with messages and queue tracks', async () => {
    const db = await createTestDb()
    await db.insert(user).values({ id: 'u1', name: 'T', email: 'dj@example.com', emailVerified: false, createdAt: new Date(), updatedAt: new Date() })
    const [s] = await db.insert(djSessions).values({ userId: 'u1', title: 'rainy drive' }).returning()
    expect(s.status).toBe('active')
    expect(s.queueVersion).toBe(0)
    await db.insert(djMessages).values({ sessionId: s.id, role: 'user', content: 'rainy night drive' })
    const [track] = await db.insert(tracks).values({ appleId: 'q1', title: 'T', artist: 'A' }).returning()
    await db.insert(queueTracks).values({ sessionId: s.id, position: 0, trackId: track.id, reason: 'moody', addedBy: 'dj' })
    const rows = await db.select().from(queueTracks)
    expect(rows[0].state).toBe('active')
  })

  it('cascades session deletion to messages and queue', async () => {
    const db = await createTestDb()
    await db.insert(user).values({ id: 'u2', name: 'T', email: 'dj2@example.com', emailVerified: false, createdAt: new Date(), updatedAt: new Date() })
    const [s] = await db.insert(djSessions).values({ userId: 'u2', title: 't' }).returning()
    await db.insert(djMessages).values({ sessionId: s.id, role: 'dj', content: 'hi' })
    const [track] = await db.insert(tracks).values({ appleId: 'q2', title: 'T', artist: 'A' }).returning()
    await db.insert(queueTracks).values({ sessionId: s.id, position: 0, trackId: track.id, addedBy: 'dj' })
    await db.delete(djSessions).where(eq(djSessions.id, s.id))
    expect(await db.select().from(djMessages)).toHaveLength(0)
    expect(await db.select().from(queueTracks)).toHaveLength(0)
  })
})
