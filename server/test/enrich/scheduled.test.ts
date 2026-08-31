import { describe, it, expect, vi } from 'vitest'
import { createTestDb } from '../helpers/db'
import { okDeps } from '../helpers/enrich-fixtures'
import { handleScheduled, CRON_BATCH } from '../../src/enrich/scheduled'
import { tracks, trackFeatures } from '../../src/db/schema'
import type { ArtworkRunResult } from '../../src/artwork/runner'

describe('handleScheduled', () => {
  it('processes a small batch', async () => {
    const db = await createTestDb()
    await db.insert(tracks).values({ appleId: 'c1', title: 'T', artist: 'A' })
    const r = await handleScheduled(db, { enrichment: okDeps })
    expect(r.enrichment).toMatchObject({ processed: 1 })
    expect(await db.select().from(trackFeatures)).toHaveLength(1)
  })

  it('caps at CRON_BATCH', async () => {
    const db = await createTestDb()
    for (let i = 0; i < CRON_BATCH + 3; i++) {
      await db.insert(tracks).values({ appleId: `c${i}`, title: 'T', artist: 'A' })
    }
    const r = await handleScheduled(db, { enrichment: okDeps })
    expect(r.enrichment).toMatchObject({ processed: CRON_BATCH })
  })

  it('runs artwork even when feature and meaning enrichment fails', async () => {
    const db = await createTestDb()
    const artworkResult: ArtworkRunResult = {
      processed: 1,
      matched: 1,
      missing: 0,
      failed: 0,
      remaining: 0,
    }
    const runEnrichment = vi.fn(async () => { throw new Error('secret feature failure') })
    const runArtwork = vi.fn(async () => artworkResult)

    const result = await handleScheduled(
      db,
      { enrichment: okDeps, artwork: { storefront: 'ng', catalog: { getSongs: async () => new Map() } } },
      { enrichment: runEnrichment, artwork: runArtwork },
    )

    expect(runEnrichment).toHaveBeenCalledOnce()
    expect(runArtwork).toHaveBeenCalledOnce()
    expect(result).toEqual({ enrichment: { error: 'failed' }, artwork: artworkResult })
  })

  it('runs feature and meaning enrichment even when artwork fails', async () => {
    const db = await createTestDb()
    const enrichmentResult = { processed: 1, features: 1, meaning: 1, remaining: 0 }
    const runEnrichment = vi.fn(async () => enrichmentResult)
    const runArtwork = vi.fn(async () => { throw new Error('secret artwork failure') })

    const result = await handleScheduled(
      db,
      { enrichment: okDeps, artwork: { storefront: 'ng', catalog: { getSongs: async () => new Map() } } },
      { enrichment: runEnrichment, artwork: runArtwork },
    )

    expect(runEnrichment).toHaveBeenCalledOnce()
    expect(runArtwork).toHaveBeenCalledOnce()
    expect(result).toEqual({ enrichment: enrichmentResult, artwork: { error: 'failed' } })
  })
})
