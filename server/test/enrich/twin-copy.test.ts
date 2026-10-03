import { describe, it, expect, vi } from 'vitest'
import { eq } from 'drizzle-orm'
import { createTestDb, type TestDb } from '../helpers/db'
import { okDeps, OK_FEATURES } from '../helpers/enrich-fixtures'
import { runTwinCopy } from '../../src/enrich/twin-copy'
import { runEnrichmentBatch } from '../../src/enrich/runner'
import { tracks, trackFeatures, trackMeanings, enrichmentFailures } from '../../src/db/schema'

const ISRC = 'USUG11904206'
const { isrc: _isrc, matchedDurationMs: _matched, ...FEATURE_COLS } = OK_FEATURES
const vec = (value: number) => Array.from({ length: 1024 }, () => value)

async function track(db: TestDb, isrc: string | null, extra: Partial<typeof tracks.$inferInsert> = {}) {
  const [row] = await db.insert(tracks).values({ title: 'Song', artist: 'Artist', isrc, ...extra }).returning()
  return row
}

async function enriched(db: TestDb, isrc: string | null, tempo = 120, embedding = 0.25) {
  const row = await track(db, isrc)
  await db.insert(trackFeatures).values({ trackId: row.id, ...FEATURE_COLS, tempo, source: 'reccobeats' })
  await db.insert(trackMeanings).values({
    trackId: row.id, embedding: vec(embedding), lyricsSource: 'lrclib', instrumental: false,
  })
  return row
}

describe('runTwinCopy', () => {
  it('copies features and meaning from a same-ISRC twin, marked as twin, matching case-insensitively', async () => {
    const db = await createTestDb()
    await enriched(db, ISRC, 97, 0.5)
    const target = await track(db, ISRC.toLowerCase(), { spotifyId: '4uLU6hMCjMI75M1A2tKUQC' })

    expect(await runTwinCopy(db)).toEqual({ features: 1, meanings: 1 })

    const [features] = await db.select().from(trackFeatures).where(eq(trackFeatures.trackId, target.id))
    expect(features).toMatchObject({ ...FEATURE_COLS, tempo: 97, source: 'twin' })
    const [meaning] = await db.select().from(trackMeanings).where(eq(trackMeanings.trackId, target.id))
    expect(meaning).toMatchObject({ lyricsSource: 'twin', instrumental: false })
    expect(meaning.embedding).toEqual(vec(0.5))
  })

  it('copies an instrumental meaning with no embedding', async () => {
    const db = await createTestDb()
    const donor = await track(db, ISRC)
    await db.insert(trackMeanings).values({ trackId: donor.id, embedding: null, lyricsSource: 'lrclib', instrumental: true })
    const target = await track(db, ISRC)

    expect(await runTwinCopy(db)).toEqual({ features: 0, meanings: 1 })
    const [meaning] = await db.select().from(trackMeanings).where(eq(trackMeanings.trackId, target.id))
    expect(meaning).toMatchObject({ embedding: null, instrumental: true, lyricsSource: 'twin' })
  })

  it("keeps the donor's timestamps, so a copy does not look freshly computed", async () => {
    const db = await createTestDb()
    const donor = await enriched(db, ISRC)
    const fetchedAt = new Date('2026-02-03T04:05:06Z')
    const embeddedAt = new Date('2026-03-04T05:06:07Z')
    await db.update(trackFeatures).set({ fetchedAt }).where(eq(trackFeatures.trackId, donor.id))
    await db.update(trackMeanings).set({ embeddedAt }).where(eq(trackMeanings.trackId, donor.id))
    const target = await track(db, ISRC)

    await runTwinCopy(db)
    const [features] = await db.select().from(trackFeatures).where(eq(trackFeatures.trackId, target.id))
    expect(features.fetchedAt).toEqual(fetchedAt)
    const [meaning] = await db.select().from(trackMeanings).where(eq(trackMeanings.trackId, target.id))
    expect(meaning.embeddedAt).toEqual(embeddedAt)
  })

  it('skips a donor meaning with no embedding that is not instrumental', async () => {
    const db = await createTestDb()
    const donor = await track(db, ISRC)
    await db.insert(trackMeanings).values({ trackId: donor.id, embedding: null, lyricsSource: 'lrclib', instrumental: false })
    const target = await track(db, ISRC)

    expect(await runTwinCopy(db)).toEqual({ features: 0, meanings: 0 })
    expect(await db.select().from(trackMeanings).where(eq(trackMeanings.trackId, target.id))).toEqual([])
  })

  it('passes over an older unusable donor meaning for a newer one with an embedding', async () => {
    const db = await createTestDb()
    const older = await track(db, ISRC)
    await db.insert(trackMeanings).values({
      trackId: older.id, embedding: null, lyricsSource: 'lrclib', instrumental: false,
      embeddedAt: new Date('2026-01-01T00:00:00Z'),
    })
    const newer = await track(db, ISRC)
    await db.insert(trackMeanings).values({
      trackId: newer.id, embedding: vec(0.7), lyricsSource: 'lrclib', instrumental: false,
      embeddedAt: new Date('2026-06-01T00:00:00Z'),
    })
    const target = await track(db, ISRC)

    expect(await runTwinCopy(db)).toEqual({ features: 0, meanings: 1 })
    const [meaning] = await db.select().from(trackMeanings).where(eq(trackMeanings.trackId, target.id))
    expect(meaning.embedding).toEqual(vec(0.7))
  })

  it('fills only what is missing and never overwrites an existing row', async () => {
    const db = await createTestDb()
    await enriched(db, ISRC, 97, 0.5)
    const target = await track(db, ISRC)
    await db.insert(trackFeatures).values({ trackId: target.id, ...FEATURE_COLS, tempo: 140, source: 'reccobeats' })

    expect(await runTwinCopy(db)).toEqual({ features: 0, meanings: 1 })
    const [features] = await db.select().from(trackFeatures).where(eq(trackFeatures.trackId, target.id))
    expect(features).toMatchObject({ tempo: 140, source: 'reccobeats' })

    expect(await runTwinCopy(db)).toEqual({ features: 0, meanings: 0 })
  })

  it('picks the oldest donor deterministically', async () => {
    const db = await createTestDb()
    const older = await enriched(db, ISRC, 90, 0.1)
    const newer = await enriched(db, ISRC, 150, 0.9)
    await db.update(trackFeatures).set({ fetchedAt: new Date('2026-01-01T00:00:00Z') }).where(eq(trackFeatures.trackId, older.id))
    await db.update(trackFeatures).set({ fetchedAt: new Date('2026-06-01T00:00:00Z') }).where(eq(trackFeatures.trackId, newer.id))
    await db.update(trackMeanings).set({ embeddedAt: new Date('2026-01-01T00:00:00Z') }).where(eq(trackMeanings.trackId, older.id))
    await db.update(trackMeanings).set({ embeddedAt: new Date('2026-06-01T00:00:00Z') }).where(eq(trackMeanings.trackId, newer.id))
    const target = await track(db, ISRC)

    await runTwinCopy(db)
    const [features] = await db.select().from(trackFeatures).where(eq(trackFeatures.trackId, target.id))
    expect(features.tempo).toBe(90)
    const [meaning] = await db.select().from(trackMeanings).where(eq(trackMeanings.trackId, target.id))
    expect(meaning.embedding).toEqual(vec(0.1))
  })

  it('respects the limit per table', async () => {
    const db = await createTestDb()
    await enriched(db, ISRC)
    for (let i = 0; i < 3; i++) await track(db, ISRC)

    expect(await runTwinCopy(db, 2)).toEqual({ features: 2, meanings: 2 })
    expect(await runTwinCopy(db, 2)).toEqual({ features: 1, meanings: 1 })
    expect(await db.select().from(trackFeatures)).toHaveLength(4)
  })

  it('ignores null and malformed ISRCs', async () => {
    const db = await createTestDb()
    await enriched(db, null)
    await enriched(db, 'not-an-isrc')
    await track(db, null)
    await track(db, 'not-an-isrc')
    await enriched(db, 'USUG1190420')
    await track(db, 'USUG1190420')

    expect(await runTwinCopy(db)).toEqual({ features: 0, meanings: 0 })
  })

  it('clears the filled stages from enrichment_failures and leaves the other stage alone', async () => {
    const db = await createTestDb()
    const donor = await track(db, ISRC)
    await db.insert(trackFeatures).values({ trackId: donor.id, ...FEATURE_COLS, source: 'reccobeats' })
    const target = await track(db, ISRC)
    await db.insert(enrichmentFailures).values([
      { trackId: target.id, stage: 'features', error: 'no acceptable match', attempts: 2 },
      { trackId: target.id, stage: 'meaning', error: 'no lyrics found', attempts: 2 },
    ])

    expect(await runTwinCopy(db)).toEqual({ features: 1, meanings: 0 })
    const failures = await db.select().from(enrichmentFailures).where(eq(enrichmentFailures.trackId, target.id))
    expect(failures.map((f) => f.stage)).toEqual(['meaning'])
  })

  it('takes a filled track out of the enrichment candidate set', async () => {
    const db = await createTestDb()
    await enriched(db, ISRC)
    await track(db, ISRC)
    const features = vi.fn(okDeps.features)
    const lyrics = vi.fn(okDeps.lyrics)

    await runTwinCopy(db)
    expect(await runEnrichmentBatch(db, { ...okDeps, features, lyrics }, 5))
      .toEqual({ processed: 0, features: 0, meaning: 0, remaining: 0 })
    expect(features).not.toHaveBeenCalled()
    expect(lyrics).not.toHaveBeenCalled()
  })
})
