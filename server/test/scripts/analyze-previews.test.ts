import { describe, it, expect } from 'vitest'
import { eq } from 'drizzle-orm'
import { createTestDb, type TestDb } from '../helpers/db'
import { runAnalyzePreviews, type AnalyzePreviewsDeps } from '../../scripts/analyze-previews'
import { tracks, trackFeatures } from '../../src/db/schema'
import type { FetchPreviewsResult } from '../../scripts/lib/preview-fetcher'
import type { PreviewFeatures } from '../../scripts/lib/preview-analyzer'

const FEATURES: PreviewFeatures = { tempo: 120, key: 2, mode: 1, energy: 0.5, danceability: 0.4, loudness: -8 }

async function seedTrack(db: TestDb, opts: { appleId?: string | null; title?: string; artist?: string } = {}) {
  const [row] = await db
    .insert(tracks)
    .values({
      // Nullish coalescing would treat an explicit `appleId: null` the same
      // as "not provided" — check presence instead so callers can seed a
      // genuinely apple_id-less track.
      appleId: 'appleId' in opts ? opts.appleId : `apple-${Math.random()}`,
      title: opts.title ?? 'Some Track',
      artist: opts.artist ?? 'Some Artist',
    })
    .returning()
  return row
}

function baseDeps(db: TestDb, overrides: Partial<AnalyzePreviewsDeps> = {}): AnalyzePreviewsDeps {
  const logs: string[] = []
  return {
    db: db as unknown as AnalyzePreviewsDeps['db'],
    apply: false,
    storefront: 'ng',
    cacheDir: '/tmp/mixtape-preview-cache-test',
    checkpointPath: '/tmp/mixtape-preview-cache-test/checkpoint.json',
    fetch: async () => {
      throw new Error('unexpected real fetch in test')
    },
    fetchPreviews: async () => {
      throw new Error('unexpected fetchPreviews call in dry run')
    },
    decodeToWav: async () => {
      throw new Error('unexpected decodeToWav call')
    },
    analyzePreview: async () => {
      throw new Error('unexpected analyzePreview call')
    },
    log: (line: string) => logs.push(line),
    ...overrides,
  }
}

describe('runAnalyzePreviews', () => {
  it('selects only tracks with an apple_id and no existing track_features row', async () => {
    const db = await createTestDb()
    const withAppleNoFeatures = await seedTrack(db, { appleId: 'a1' })
    const withAppleAndFeatures = await seedTrack(db, { appleId: 'a2' })
    await seedTrack(db, { appleId: null })
    await db.insert(trackFeatures).values({ trackId: withAppleAndFeatures.id, source: 'reccobeats' })

    let seenIds: readonly string[] = []
    const fetchPreviews = async (appleIds: readonly string[]): Promise<FetchPreviewsResult> => {
      seenIds = appleIds
      return { ready: new Map(), skipped: { no_hit: 0, no_preview: 0, download_failed: 0 } }
    }

    const summary = await runAnalyzePreviews(baseDeps(db, { apply: true, fetchPreviews }))

    expect(summary.candidates).toBe(1)
    expect(seenIds).toEqual([withAppleNoFeatures.appleId])
  })

  it('dry run performs zero fetch/db-write calls and reports the candidate count', async () => {
    const db = await createTestDb()
    for (let i = 0; i < 3; i++) await seedTrack(db, { appleId: `a${i}` })

    const summary = await runAnalyzePreviews(baseDeps(db, { apply: false }))

    expect(summary.candidates).toBe(3)
    expect(summary.analyzed).toBe(0)
    expect(await db.select().from(trackFeatures)).toHaveLength(0)
  })

  it('dry run logs the candidate count and up to the first 10', async () => {
    const db = await createTestDb()
    for (let i = 0; i < 12; i++) await seedTrack(db, { appleId: `a${i}`, title: `Track ${i}` })
    const logs: string[] = []

    await runAnalyzePreviews(baseDeps(db, { apply: false, log: (l) => logs.push(l) }))

    const joined = logs.join('\n')
    expect(joined).toContain('12')
    // exactly 10 track lines printed (one per candidate row, capped at 10)
    const trackLines = logs.filter((l) => /Track \d+/.test(l))
    expect(trackLines).toHaveLength(10)
  })

  it('inserts features only for the honesty-rule subset, with ON CONFLICT DO NOTHING semantics', async () => {
    const db = await createTestDb()
    const track = await seedTrack(db, { appleId: 'a1' })

    const fetchPreviews = async (): Promise<FetchPreviewsResult> => ({
      ready: new Map([['a1', '/tmp/fake/a1.m4a']]),
      skipped: { no_hit: 0, no_preview: 0, download_failed: 0 },
    })

    const summary = await runAnalyzePreviews(
      baseDeps(db, {
        apply: true,
        fetchPreviews,
        decodeToWav: async () => {},
        analyzePreview: async () => FEATURES,
      }),
    )

    expect(summary.analyzed).toBe(1)
    const [row] = await db.select().from(trackFeatures).where(eq(trackFeatures.trackId, track.id))
    expect(row).toMatchObject(FEATURES)
    expect(row.valence).toBeNull()
    expect(row.acousticness).toBeNull()
    expect(row.instrumentalness).toBeNull()
    expect(row.liveness).toBeNull()
    expect(row.speechiness).toBeNull()
  })

  it('never overwrites an existing (e.g. ReccoBeats) track_features row', async () => {
    const db = await createTestDb()
    const track = await seedTrack(db, { appleId: 'a1' })
    // Simulate a ReccoBeats row landing mid-run (e.g. a concurrent enrichment pass).
    await db.insert(trackFeatures).values({ trackId: track.id, tempo: 999, source: 'reccobeats' })

    const fetchPreviews = async (): Promise<FetchPreviewsResult> => ({
      ready: new Map([['a1', '/tmp/fake/a1.m4a']]),
      skipped: { no_hit: 0, no_preview: 0, download_failed: 0 },
    })

    await runAnalyzePreviews(
      baseDeps(db, {
        apply: true,
        fetchPreviews,
        decodeToWav: async () => {},
        analyzePreview: async () => FEATURES,
      }),
    )

    const [row] = await db.select().from(trackFeatures).where(eq(trackFeatures.trackId, track.id))
    expect(row.tempo).toBe(999)
    expect(row.source).toBe('reccobeats')
  })

  it('isolates a per-track decode/analyze failure and continues with the rest', async () => {
    const db = await createTestDb()
    const bad = await seedTrack(db, { appleId: 'bad' })
    const good = await seedTrack(db, { appleId: 'good' })

    const fetchPreviews = async (): Promise<FetchPreviewsResult> => ({
      ready: new Map([
        ['bad', '/tmp/fake/bad.m4a'],
        ['good', '/tmp/fake/good.m4a'],
      ]),
      skipped: { no_hit: 0, no_preview: 0, download_failed: 0 },
    })

    const logs: string[] = []
    const summary = await runAnalyzePreviews(
      baseDeps(db, {
        apply: true,
        fetchPreviews,
        decodeToWav: async (inputPath: string) => {
          if (inputPath.includes('bad')) throw new Error('decode boom with sensitive detail /Users/whoever/secret')
        },
        analyzePreview: async () => FEATURES,
        log: (l) => logs.push(l),
      }),
    )

    expect(summary.analyzed).toBe(1)
    expect(summary.analysisFailed).toBe(1)
    const rows = await db.select().from(trackFeatures)
    expect(rows).toHaveLength(1)
    expect(rows[0].trackId).toBe(good.id)

    expect(logs).toContain(`failed: ${bad.id}`)
    expect(logs.some((l) => l.includes('secret'))).toBe(false)
  })

  it('honors --limit on candidate selection', async () => {
    const db = await createTestDb()
    for (let i = 0; i < 5; i++) await seedTrack(db, { appleId: `a${i}` })

    const summary = await runAnalyzePreviews(baseDeps(db, { apply: false, limit: 2 }))

    expect(summary.candidates).toBe(2)
  })

  it('summary reports fetcher skip counts and resulting features coverage', async () => {
    const db = await createTestDb()
    const t1 = await seedTrack(db, { appleId: 'a1' })
    await seedTrack(db, { appleId: 'a2' })
    await seedTrack(db, { appleId: 'a3' })
    await seedTrack(db, { appleId: 'a4' })

    const fetchPreviews = async (): Promise<FetchPreviewsResult> => ({
      ready: new Map([['a1', '/tmp/fake/a1.m4a']]),
      skipped: { no_hit: 1, no_preview: 1, download_failed: 1 },
    })

    const summary = await runAnalyzePreviews(
      baseDeps(db, {
        apply: true,
        fetchPreviews,
        decodeToWav: async () => {},
        analyzePreview: async () => FEATURES,
      }),
    )

    expect(summary).toMatchObject({
      candidates: 4,
      analyzed: 1,
      noHit: 1,
      noPreview: 1,
      downloadFailed: 1,
      analysisFailed: 0,
    })
    // 1 of 4 total tracks now has a features row.
    expect(summary.coveragePercent).toBeCloseTo(25, 5)
    void t1
  })

  it('converges to zero candidates on a re-run once every candidate has a features row', async () => {
    const db = await createTestDb()
    await seedTrack(db, { appleId: 'a1' })

    const fetchPreviews = async (): Promise<FetchPreviewsResult> => ({
      ready: new Map([['a1', '/tmp/fake/a1.m4a']]),
      skipped: { no_hit: 0, no_preview: 0, download_failed: 0 },
    })
    const deps = baseDeps(db, {
      apply: true,
      fetchPreviews,
      decodeToWav: async () => {},
      analyzePreview: async () => FEATURES,
    })

    const first = await runAnalyzePreviews(deps)
    expect(first.candidates).toBe(1)

    const second = await runAnalyzePreviews(deps)
    expect(second.candidates).toBe(0)
    expect(second.analyzed).toBe(0)
  })
})
