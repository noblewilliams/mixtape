import { describe, it, expect } from 'vitest'
import { createTestDb, type TestDb } from '../helpers/db'
import { enrichTrack, type EnrichDeps } from '../../src/enrich/pipeline'
import { tracks, trackFeatures, trackMeanings, enrichmentFailures } from '../../src/db/schema'
import { eq } from 'drizzle-orm'

const FEATURES = {
  tempo: 128, key: 4, mode: 1, energy: 0.3, danceability: 0.5, valence: 0.2,
  acousticness: 0.8, instrumentalness: 0.6, liveness: 0.1, speechiness: 0.03,
  loudness: -9.8, isrc: 'ISRC123', matchedDurationMs: null,
}

function deps(over: Partial<EnrichDeps> = {}): EnrichDeps {
  return {
    storefront: 'ng',
    itunes: async () => ({ trackName: 'T', artistName: 'A', previewUrl: null, durationMs: 200000, genre: 'Pop' }),
    features: async () => FEATURES,
    lyrics: async () => ({ lyrics: 'hello darkness', instrumental: false }),
    embed: async () => Array.from({ length: 1024 }, () => 0.1),
    ...over,
  }
}

async function seed(db: TestDb) {
  const [t] = await db
    .insert(tracks)
    .values({ appleId: 'a1', title: 'T', artist: 'A', genre: null })
    .returning()
  return t
}

describe('enrichTrack', () => {
  it('happy path: features, meaning, isrc/duration/genre backfill', async () => {
    const db = await createTestDb()
    const t = await seed(db)
    const result = await enrichTrack(db, deps(), t)
    expect(result).toEqual({ features: 'ok', meaning: 'ok' })
    const [feat] = await db.select().from(trackFeatures)
    expect(feat.tempo).toBe(128)
    expect(feat.source).toBe('reccobeats')
    const [meaning] = await db.select().from(trackMeanings)
    expect(meaning.embedding).toHaveLength(1024)
    expect(meaning.instrumental).toBe(false)
    const [row] = await db.select().from(tracks).where(eq(tracks.id, t.id))
    expect(row.isrc).toBe('ISRC123')
    expect(row.durationMs).toBe(200000)
    expect(row.genre).toBe('Pop')
    expect(await db.select().from(enrichmentFailures)).toHaveLength(0)
  })

  it('passes the itunes duration into the features and lyrics lookups', async () => {
    const db = await createTestDb()
    const t = await seed(db)
    let featuresDuration: number | null = -1
    let lyricsDuration: number | null = -1
    await enrichTrack(db, deps({
      features: async (k) => { featuresDuration = k.durationMs; return FEATURES },
      lyrics: async (k) => { lyricsDuration = k.durationMs; return { lyrics: 'x', instrumental: false } },
    }), t)
    expect(featuresDuration).toBe(200000)
    expect(lyricsDuration).toBe(200000)
  })

  it('instrumental: meaning row without embedding, embed never called', async () => {
    const db = await createTestDb()
    const t = await seed(db)
    let embedCalled = false
    await enrichTrack(db, deps({
      lyrics: async () => ({ lyrics: null, instrumental: true }),
      embed: async () => { embedCalled = true; return [] },
    }), t)
    const [meaning] = await db.select().from(trackMeanings)
    expect(meaning.instrumental).toBe(true)
    expect(meaning.embedding).toBeNull()
    expect(embedCalled).toBe(false)
  })

  it('no feature match: records miss, still does meaning', async () => {
    const db = await createTestDb()
    const t = await seed(db)
    const result = await enrichTrack(db, deps({ features: async () => null }), t)
    expect(result).toEqual({ features: 'miss', meaning: 'ok' })
    const fails = await db.select().from(enrichmentFailures)
    expect(fails).toEqual([expect.objectContaining({ stage: 'features', attempts: 1 })])
  })

  it('source error: records failure, increments attempts on retry', async () => {
    const db = await createTestDb()
    const t = await seed(db)
    const failing = deps({ features: async () => { throw new Error('reccobeats: HTTP 500') } })
    const r1 = await enrichTrack(db, failing, t)
    expect(r1.features).toBe('error')
    await enrichTrack(db, failing, t)
    const fails = await db.select().from(enrichmentFailures)
    expect(fails[0].attempts).toBe(2)
  })

  it('success after failure clears the failure row', async () => {
    const db = await createTestDb()
    const t = await seed(db)
    await enrichTrack(db, deps({ features: async () => { throw new Error('boom') } }), t)
    await enrichTrack(db, deps(), t)
    expect(await db.select().from(enrichmentFailures)).toHaveLength(0)
  })

  it('no lyrics found: meaning recorded as miss', async () => {
    const db = await createTestDb()
    const t = await seed(db)
    const result = await enrichTrack(db, deps({ lyrics: async () => null }), t)
    expect(result.meaning).toBe('miss')
    expect(await db.select().from(trackMeanings)).toHaveLength(0)
  })

  it('itunes miss/error is best-effort: pipeline continues with null duration', async () => {
    const db = await createTestDb()
    const t = await seed(db)
    let seenDuration: number | null = -1
    const r = await enrichTrack(db, deps({
      itunes: async () => { throw new Error('itunes: HTTP 503') },
      features: async (k) => { seenDuration = k.durationMs; return FEATURES },
    }), t)
    expect(r.features).toBe('ok')
    expect(seenDuration).toBeNull()
    const fails = await db.select().from(enrichmentFailures)
    expect(fails).toEqual([expect.objectContaining({ stage: 'itunes' })])
  })

  it('backfills duration from the reccobeats match when the track has none', async () => {
    const db = await createTestDb()
    const t = await seed(db)
    const result = await enrichTrack(
      db,
      deps({
        itunes: async () => null,
        features: async () => ({ ...FEATURES, matchedDurationMs: 201000 }),
      }),
      t,
    )
    expect(result.features).toBe('ok')
    const [row] = await db.select().from(tracks).where(eq(tracks.id, t.id))
    expect(row.durationMs).toBe(201000)
  })

  it('does not overwrite an existing duration with the reccobeats match', async () => {
    const db = await createTestDb()
    const [t] = await db
      .insert(tracks)
      .values({ appleId: 'a6', title: 'T', artist: 'A', durationMs: 100000, genre: 'Pop' })
      .returning()
    const result = await enrichTrack(
      db,
      deps({
        itunes: async () => null,
        features: async () => ({ ...FEATURES, matchedDurationMs: 201000 }),
      }),
      t,
    )
    expect(result.features).toBe('ok')
    const [row] = await db.select().from(tracks).where(eq(tracks.id, t.id))
    expect(row.durationMs).toBe(100000)
  })

  it('does not clobber existing genre or isrc', async () => {
    const db = await createTestDb()
    const [t] = await db
      .insert(tracks)
      .values({ appleId: 'a2', title: 'T', artist: 'A', genre: 'Original', isrc: 'KEEP' })
      .returning()
    await enrichTrack(db, deps(), t)
    const [row] = await db.select().from(tracks).where(eq(tracks.id, t.id))
    expect(row.genre).toBe('Original')
    expect(row.isrc).toBe('KEEP')
  })

  it('failure error text never contains lyric content', async () => {
    const db = await createTestDb()
    const t = await seed(db)
    await enrichTrack(db, deps({
      lyrics: async () => ({ lyrics: 'secret lyric words', instrumental: false }),
      embed: async () => { throw new Error('embedder: AI binding failed (Error)') },
    }), t)
    const fails = await db.select().from(enrichmentFailures)
    expect(fails[0].stage).toBe('meaning')
    expect(fails[0].error).not.toContain('secret')
  })

  it('re-enrichment idempotence: a second full pass skips iTunes (duration now known) with no duplicate rows or failures', async () => {
    const db = await createTestDb()
    const t = await seed(db)
    await enrichTrack(db, deps(), t)
    const [t2] = await db.select().from(tracks).where(eq(tracks.id, t.id))
    let itunesCalls = 0
    const result = await enrichTrack(
      db,
      deps({ itunes: async () => { itunesCalls++; return null } }),
      t2,
    )
    expect(result).toEqual({ features: 'ok', meaning: 'ok' })
    expect(itunesCalls).toBe(0)
    expect(await db.select().from(trackFeatures)).toHaveLength(1)
    expect(await db.select().from(trackMeanings)).toHaveLength(1)
    expect(await db.select().from(enrichmentFailures)).toHaveLength(0)
  })

  it('lyrics null and not instrumental is a miss, not a bare ok', async () => {
    const db = await createTestDb()
    const t = await seed(db)
    const result = await enrichTrack(db, deps({ lyrics: async () => ({ lyrics: null, instrumental: false }) }), t)
    expect(result.meaning).toBe('miss')
    expect(await db.select().from(trackMeanings)).toHaveLength(0)
    const fails = await db.select().from(enrichmentFailures)
    expect(fails).toEqual([expect.objectContaining({ stage: 'meaning' })])
  })

  it('a later instrumental re-run preserves an existing embedding', async () => {
    const db = await createTestDb()
    const t = await seed(db)
    await enrichTrack(db, deps(), t)
    const [t2] = await db.select().from(tracks).where(eq(tracks.id, t.id))
    await enrichTrack(db, deps({ lyrics: async () => ({ lyrics: null, instrumental: true }) }), t2)
    const [meaning] = await db.select().from(trackMeanings)
    expect(meaning.embedding).toHaveLength(1024)
    expect(meaning.instrumental).toBe(true)
  })

  it('skip.features bypasses the features stage entirely', async () => {
    const db = await createTestDb()
    const t = await seed(db)
    const result = await enrichTrack(
      db,
      deps({ features: async () => { throw new Error('features dep should not be called') } }),
      t,
      { features: true },
    )
    expect(result.features).toBe('skipped')
    expect(await db.select().from(trackFeatures)).toHaveLength(0)
  })

  it('skip.meaning bypasses the meaning stage entirely (embed never called)', async () => {
    const db = await createTestDb()
    const t = await seed(db)
    let embedCalled = false
    const result = await enrichTrack(
      db,
      deps({
        lyrics: async () => { throw new Error('lyrics dep should not be called') },
        embed: async () => { embedCalled = true; return [] },
      }),
      t,
      { meaning: true },
    )
    expect(result.meaning).toBe('skipped')
    expect(embedCalled).toBe(false)
    expect(await db.select().from(trackMeanings)).toHaveLength(0)
  })

  it('itunes runs when duration is known but genre is missing (genre backfill)', async () => {
    const db = await createTestDb()
    const [t] = await db
      .insert(tracks)
      .values({ appleId: 'a3', title: 'T', artist: 'A', durationMs: 200000, genre: null })
      .returning()
    let itunesCalls = 0
    const result = await enrichTrack(
      db,
      deps({ itunes: async () => { itunesCalls++; return { trackName: 'T', artistName: 'A', previewUrl: null, durationMs: 200000, genre: 'Pop' } } }),
      t,
    )
    expect(itunesCalls).toBe(1)
    expect(result).toEqual({ features: 'ok', meaning: 'ok' })
    const [row] = await db.select().from(tracks).where(eq(tracks.id, t.id))
    expect(row.genre).toBe('Pop')
  })

  it('itunes does not run when both duration and genre are already known', async () => {
    const db = await createTestDb()
    const [t] = await db
      .insert(tracks)
      .values({ appleId: 'a4', title: 'T', artist: 'A', durationMs: 200000, genre: 'Pop' })
      .returning()
    let itunesCalls = 0
    await enrichTrack(db, deps({ itunes: async () => { itunesCalls++; return null } }), t)
    expect(itunesCalls).toBe(0)
  })

  it('classifies a non-source error down to name only, never storing raw error text', async () => {
    const db = await createTestDb()
    const t = await seed(db)
    const result = await enrichTrack(
      db,
      deps({ embed: async () => { throw new Error('Failed query: insert into "track_meanings" (...) values (...)') } }),
      t,
    )
    expect(result.meaning).toBe('error')
    const fails = await db.select().from(enrichmentFailures)
    const meaningFail = fails.find((f) => f.stage === 'meaning')
    expect(meaningFail?.error).toBe('internal: Error')
    expect(meaningFail?.error).not.toContain('insert into')
  })
})
