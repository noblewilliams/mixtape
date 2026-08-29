import { describe, it, expect } from 'vitest'
import { eq } from 'drizzle-orm'
import { createTestDb, type TestDb } from '../helpers/db'
import { okDeps, OK_FEATURES } from '../helpers/enrich-fixtures'
import { runEnrichmentBatch, enrichmentStatus, MAX_ATTEMPTS } from '../../src/enrich/runner'
import { tracks, trackFeatures, trackMeanings, enrichmentFailures } from '../../src/db/schema'

async function seedTracks(db: TestDb, n: number) {
  for (let i = 0; i < n; i++) {
    await db.insert(tracks).values({ appleId: `s${i}`, title: `T${i}`, artist: 'A' })
  }
}

describe('runEnrichmentBatch', () => {
  it('processes up to limit unenriched tracks and reports remaining', async () => {
    const db = await createTestDb()
    await seedTracks(db, 5)
    const r = await runEnrichmentBatch(db, okDeps, 3)
    expect(r.processed).toBe(3)
    expect(r.features).toBe(3)
    expect(r.meaning).toBe(3)
    expect(r.remaining).toBe(2)
    expect(await db.select().from(trackFeatures)).toHaveLength(3)
  })

  it('completes everything over successive batches', async () => {
    const db = await createTestDb()
    await seedTracks(db, 5)
    await runEnrichmentBatch(db, okDeps, 3)
    const r2 = await runEnrichmentBatch(db, okDeps, 3)
    expect(r2.processed).toBe(2)
    expect(r2.remaining).toBe(0)
    const r3 = await runEnrichmentBatch(db, okDeps, 3)
    expect(r3.processed).toBe(0)
  })

  it('passes skip flags for stages that already have rows (no re-fetch)', async () => {
    const db = await createTestDb()
    await seedTracks(db, 1)
    // First pass: features fails, meaning succeeds
    let featureCalls = 0
    const failingFeatures = {
      ...okDeps,
      features: async () => { featureCalls++; throw new Error('x') },
    }
    await runEnrichmentBatch(db, failingFeatures, 5)
    expect(featureCalls).toBe(1)
    // Second pass with working deps: meaning must be SKIPPED (already exists), features retried
    let meaningCalls = 0
    const counting = {
      ...okDeps,
      lyrics: async () => { meaningCalls++; return { lyrics: 'w', instrumental: false } },
    }
    const r = await runEnrichmentBatch(db, counting, 5)
    expect(meaningCalls).toBe(0)
    expect(r.features).toBe(1)
    expect(await db.select().from(trackFeatures)).toHaveLength(1)
    expect(await db.select().from(trackMeanings)).toHaveLength(1)
  })

  it('skips tracks that have exhausted their attempts', async () => {
    const db = await createTestDb()
    await seedTracks(db, 1)
    const [t] = await db.select().from(tracks)
    await db.insert(enrichmentFailures).values({ trackId: t.id, stage: 'features', error: 'x', attempts: 3 })
    await db.insert(enrichmentFailures).values({ trackId: t.id, stage: 'meaning', error: 'x', attempts: 3 })
    const r = await runEnrichmentBatch(db, okDeps, 10)
    expect(r.processed).toBe(0)
    expect(r.remaining).toBe(0)
  })

  it('does not retry a stage that has exhausted its attempts, even when the track is selected via the other stage', async () => {
    const db = await createTestDb()
    await seedTracks(db, 1)
    const [t] = await db.select().from(tracks)
    // features is exhausted; meaning is still missing, so the track is still
    // a candidate — but only the meaning stage should actually run.
    await db.insert(enrichmentFailures).values({ trackId: t.id, stage: 'features', error: 'x', attempts: MAX_ATTEMPTS })
    let featureCalls = 0
    const counting = {
      ...okDeps,
      features: async () => { featureCalls++; return OK_FEATURES },
    }
    const r = await runEnrichmentBatch(db, counting, 5)
    expect(featureCalls).toBe(0)
    expect(r.meaning).toBe(1)
    expect(await db.select().from(trackMeanings)).toHaveLength(1)
    const [failure] = await db
      .select()
      .from(enrichmentFailures)
      .where(eq(enrichmentFailures.stage, 'features'))
    expect(failure.attempts).toBe(MAX_ATTEMPTS)
  })

  it('status reports coverage', async () => {
    const db = await createTestDb()
    await seedTracks(db, 4)
    await runEnrichmentBatch(db, okDeps, 2)
    const s = await enrichmentStatus(db)
    expect(s).toMatchObject({ tracks: 4, withFeatures: 2, withMeaning: 2, withEmbedding: 2, exhausted: 0 })
  })

  it('status counts exhausted tracks, not exhausted failure rows', async () => {
    const db = await createTestDb()
    await seedTracks(db, 1)
    const [t] = await db.select().from(tracks)
    // Same track exhausted on two stages — should count as ONE exhausted track.
    await db.insert(enrichmentFailures).values({ trackId: t.id, stage: 'features', error: 'x', attempts: MAX_ATTEMPTS })
    await db.insert(enrichmentFailures).values({ trackId: t.id, stage: 'meaning', error: 'x', attempts: MAX_ATTEMPTS })
    const s = await enrichmentStatus(db)
    expect(s.exhausted).toBe(1)
  })
})
