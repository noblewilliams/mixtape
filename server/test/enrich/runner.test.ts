import { describe, it, expect, vi } from 'vitest'
import { eq } from 'drizzle-orm'
import { createTestDb, type TestDb } from '../helpers/db'
import { okDeps, OK_FEATURES } from '../helpers/enrich-fixtures'
import { runEnrichmentBatch, enrichmentStatus, MAX_ATTEMPTS } from '../../src/enrich/runner'
import { tracks, trackFeatures, trackMeanings, enrichmentFailures } from '../../src/db/schema'
import type { EnrichDeps } from '../../src/enrich/pipeline'
import { EnrichSourceError } from '../../src/enrich/types'

async function seedTracks(db: TestDb, n: number) {
  for (let i = 0; i < n; i++) {
    await db.insert(tracks).values({ appleId: `s${i}`, title: `T${i}`, artist: 'A' })
  }
}

describe('runEnrichmentBatch', () => {
  it('shares one metadata/feature batch across Spotify candidates and does not refetch completed tracks', async () => {
    const db = await createTestDb()
    const ids = ['4uLU6hMCjMI75M1A2tKUQC', '7ouMYWpwJ422jRcDASZB7P']
    await db.insert(tracks).values(ids.map((spotifyId, index) => ({
      spotifyId, title: 'Song', artist: 'Various Artists', artistSource: 'export' as const,
      enrichPriority: 2 - index,
    })))
    const metadata = vi.fn(async (requested: string[]) => ({
      hits: requested.map((spotifyId) => ({ spotifyId, title: 'Song', artists: ['Credited'], isrc: null, durationMs: 200_000 })),
      missing: [],
    }))
    const features = vi.fn(async (requested: string[]) => ({
      hits: requested.map((spotifyId) => ({ spotifyId, features: OK_FEATURES })), missing: [],
    }))
    const search = vi.fn(okDeps.features)
    const deps: EnrichDeps = { ...okDeps, features: search, spotify: { tracks: metadata, features } }
    expect(await runEnrichmentBatch(db, deps, 3)).toEqual({ processed: 2, features: 2, meaning: 2, remaining: 0 })
    expect(metadata).toHaveBeenCalledExactlyOnceWith(ids)
    expect(features).toHaveBeenCalledExactlyOnceWith(ids)
    expect(search).not.toHaveBeenCalled()
    expect(await runEnrichmentBatch(db, deps, 3)).toEqual({ processed: 0, features: 0, meaning: 0, remaining: 0 })
    expect(metadata).toHaveBeenCalledTimes(1)
    expect(features).toHaveBeenCalledTimes(1)
  })

  it('omits cached and exhausted Spotify feature stages while Apple candidates use text matching', async () => {
    const db = await createTestDb()
    const ids = ['4uLU6hMCjMI75M1A2tKUQC', '7ouMYWpwJ422jRcDASZB7P', '1301WleyT98MSxVHPZCA6M']
    const rows = await db.insert(tracks).values(ids.map((spotifyId, index) => ({
      spotifyId, title: 'Song', artist: 'Various Artists', artistSource: 'export' as const,
      enrichPriority: 3 - index,
    }))).returning()
    await db.insert(trackFeatures).values({ trackId: rows[1].id, tempo: 100, source: 'local_preview' })
    await db.insert(enrichmentFailures).values({ trackId: rows[2].id, stage: 'features', attempts: MAX_ATTEMPTS, error: 'miss' })
    await db.insert(tracks).values({ appleId: '1440935467', title: 'Apple song', artist: 'Apple artist' })
    const metadata = vi.fn(async () => ({
      hits: [{ spotifyId: ids[0], title: 'Song', artists: ['Credited'], isrc: null, durationMs: null }], missing: [],
    }))
    const features = vi.fn(async () => ({ hits: [{ spotifyId: ids[0], features: OK_FEATURES }], missing: [] }))
    const search = vi.fn(okDeps.features)
    const deps: EnrichDeps = { ...okDeps, features: search, spotify: { tracks: metadata, features } }
    expect(await runEnrichmentBatch(db, deps, 5)).toEqual({ processed: 4, features: 2, meaning: 4, remaining: 0 })
    expect(metadata).toHaveBeenCalledExactlyOnceWith([ids[0]])
    expect(features).toHaveBeenCalledExactlyOnceWith([ids[0]])
    expect(search).toHaveBeenCalledExactlyOnceWith({ title: 'Apple song', artist: 'Apple artist', durationMs: null })
    expect(await db.select().from(trackFeatures).where(eq(trackFeatures.trackId, rows[1].id)))
      .toEqual([expect.objectContaining({ source: 'local_preview', tempo: 100 })])
    expect(await db.select().from(enrichmentFailures)).toEqual([expect.objectContaining({
      trackId: rows[2].id, stage: 'features', attempts: MAX_ATTEMPTS,
    })])
  })

  it('shares a failed batch once, retries next invocation, and keeps successful meanings', async () => {
    const db = await createTestDb()
    const ids = ['4uLU6hMCjMI75M1A2tKUQC', '7ouMYWpwJ422jRcDASZB7P']
    await db.insert(tracks).values(ids.map((spotifyId) => ({
      spotifyId, title: 'Song', artist: 'Various Artists', artistSource: 'export' as const,
    })))
    const metadata = vi.fn(async (requested: string[]) => ({
      hits: requested.map((spotifyId) => ({ spotifyId, title: 'Song', artists: ['Credited'], isrc: null, durationMs: null })),
      missing: [],
    }))
    const features = vi.fn(async (requested: string[]) => {
      if (features.mock.calls.length === 1) throw new EnrichSourceError('reccobeats', 'features HTTP 429', 429)
      return { hits: requested.map((spotifyId) => ({ spotifyId, features: OK_FEATURES })), missing: [] }
    })
    const search = vi.fn(okDeps.features)
    const deps: EnrichDeps = { ...okDeps, features: search, spotify: { tracks: metadata, features } }
    expect(await runEnrichmentBatch(db, deps, 3)).toEqual({ processed: 2, features: 0, meaning: 2, remaining: 2 })
    expect(features).toHaveBeenCalledTimes(1)
    expect(await db.select().from(enrichmentFailures)).toHaveLength(2)
    expect(await runEnrichmentBatch(db, deps, 3)).toEqual({ processed: 2, features: 2, meaning: 0, remaining: 0 })
    expect(features).toHaveBeenCalledTimes(2)
    expect(metadata).toHaveBeenCalledTimes(2)
    expect(search).not.toHaveBeenCalled()
    expect(await db.select().from(enrichmentFailures)).toHaveLength(0)
    expect(await db.select().from(trackMeanings)).toHaveLength(2)
  })

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

// Priority ordering: an import raises enrich_priority for a listener's pool
// candidates, so a batch must walk highest priority first, then creation order.
const OLDER = new Date('2026-01-01T00:00:00Z')
const NEWER = new Date('2026-02-01T00:00:00Z')

async function seedTrack(
  db: TestDb,
  opts: { title: string; priority?: number; createdAt: Date },
) {
  await db.insert(tracks).values({
    appleId: `p-${opts.title}`,
    title: opts.title,
    artist: 'A',
    enrichPriority: opts.priority ?? 0,
    createdAt: opts.createdAt,
  })
}

// Records each track's title as the features stage sees it — i.e. the order
// the runner walked the batch.
function recordingDeps() {
  const order: string[] = []
  const deps = {
    ...okDeps,
    features: async (key: { title: string }) => {
      order.push(key.title)
      return OK_FEATURES
    },
  }
  return { deps, order }
}

describe('runEnrichmentBatch priority', () => {
  it('processes a newer high-priority track before an older zero-priority one', async () => {
    const db = await createTestDb()
    await seedTrack(db, { title: 'old-zero', createdAt: OLDER })
    await seedTrack(db, { title: 'new-hot', priority: 5, createdAt: NEWER })
    const { deps, order } = recordingDeps()
    const r = await runEnrichmentBatch(db, deps, 10)
    expect(r.processed).toBe(2)
    expect(order).toEqual(['new-hot', 'old-zero'])
  })

  it('keeps creation order between tracks of equal priority', async () => {
    const db = await createTestDb()
    // Inserted newest-first so insert order and creation order disagree.
    await seedTrack(db, { title: 'second', priority: 2, createdAt: NEWER })
    await seedTrack(db, { title: 'first', priority: 2, createdAt: OLDER })
    const { deps, order } = recordingDeps()
    await runEnrichmentBatch(db, deps, 10)
    expect(order).toEqual(['first', 'second'])
  })

  it('a batch of one picks the highest-priority track', async () => {
    const db = await createTestDb()
    await seedTrack(db, { title: 'old-zero', createdAt: OLDER })
    await seedTrack(db, { title: 'mid', priority: 1, createdAt: OLDER })
    await seedTrack(db, { title: 'top', priority: 7, createdAt: NEWER })
    const { deps, order } = recordingDeps()
    const r = await runEnrichmentBatch(db, deps, 1)
    expect(r.processed).toBe(1)
    expect(order).toEqual(['top'])
    expect(r.remaining).toBe(2)
  })
})
