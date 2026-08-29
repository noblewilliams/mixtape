import { describe, it, expect } from 'vitest'
import { createTestDb } from '../helpers/db'
import { okDeps } from '../helpers/enrich-fixtures'
import { handleScheduled, CRON_BATCH } from '../../src/enrich/scheduled'
import { tracks, trackFeatures } from '../../src/db/schema'

describe('handleScheduled', () => {
  it('processes a small batch', async () => {
    const db = await createTestDb()
    await db.insert(tracks).values({ appleId: 'c1', title: 'T', artist: 'A' })
    const r = await handleScheduled(db, okDeps)
    expect(r.processed).toBe(1)
    expect(await db.select().from(trackFeatures)).toHaveLength(1)
  })

  it('caps at CRON_BATCH', async () => {
    const db = await createTestDb()
    for (let i = 0; i < CRON_BATCH + 3; i++) {
      await db.insert(tracks).values({ appleId: `c${i}`, title: 'T', artist: 'A' })
    }
    const r = await handleScheduled(db, okDeps)
    expect(r.processed).toBe(CRON_BATCH)
  })
})
