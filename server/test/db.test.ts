import { describe, it, expect } from 'vitest'
import { createTestDb } from './helpers/db'
import { tracks, user, userTracks } from '../src/db/schema'

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
    expect(rows[0].playCount).toBe(42)
  })
})
