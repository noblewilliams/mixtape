import { describe, it, expect } from 'vitest'
import { createTestDb, type TestDb } from '../helpers/db'
import { buildPool } from '../../src/dj/pool'
import { intentSchema, type Intent } from '../../src/dj/contracts'
import { tracks, trackFeatures, trackMeanings, userTracks, user } from '../../src/db/schema'
import type { Embedder } from '../../src/enrich/embedder'

const DIMS = 1024

// A deterministic "direction" vector: nonzero only at the given indices. Only
// direction matters for cosine distance (pgvector normalizes internally), so
// magnitude doesn't need to be 1 for the similarity math to be exact.
function vec(pattern: Record<number, number>): number[] {
  const v = new Array(DIMS).fill(0)
  for (const [i, val] of Object.entries(pattern)) v[Number(i)] = val
  return v
}

const QUERY_DIRECTION = vec({ 0: 1 }) // what the fake embedder always returns
const SAME_AS_QUERY = vec({ 0: 1 }) // cosine distance 0 → similarity 1
const ORTHOGONAL_TO_QUERY = vec({ 1: 1 }) // cosine distance 1 → similarity 0

const fakeEmbed: Embedder = async () => QUERY_DIRECTION

async function seedUser(db: TestDb, id: string) {
  await db.insert(user).values({
    id,
    name: id,
    email: `${id}@example.com`,
    emailVerified: false,
    createdAt: new Date(),
    updatedAt: new Date(),
  })
}

type SeedOpts = {
  tempo?: number
  energy?: number
  valence?: number
  releaseYear?: number | null
  explicit?: boolean | null
  embedding?: number[]
  playCount?: number
  inLibrary?: boolean
  durationMs?: number
  noFeatures?: boolean // when true, no track_features row at all
}

let counter = 0

// Seeds one track in userId's library with the given (mostly optional) shape.
// Omitted feature/meaning pieces are left absent (LEFT JOIN nulls), not
// zeroed, so tests can exercise "missing dimension" behavior deliberately.
async function seedTrack(db: TestDb, userId: string, opts: SeedOpts = {}) {
  counter += 1
  const appleId = `track-${counter}`
  const [t] = await db
    .insert(tracks)
    .values({
      appleId,
      title: appleId,
      artist: 'Artist',
      durationMs: opts.durationMs ?? 200000,
      releaseYear: opts.releaseYear === undefined ? null : opts.releaseYear,
      explicit: opts.explicit ?? null,
    })
    .returning()

  if (!opts.noFeatures && (opts.tempo !== undefined || opts.energy !== undefined || opts.valence !== undefined)) {
    await db.insert(trackFeatures).values({
      trackId: t.id,
      tempo: opts.tempo ?? null,
      energy: opts.energy ?? null,
      valence: opts.valence ?? null,
      source: 'reccobeats',
    })
  }

  if (opts.embedding) {
    await db.insert(trackMeanings).values({ trackId: t.id, embedding: opts.embedding, lyricsSource: 'lrclib' })
  }

  await db.insert(userTracks).values({
    userId,
    trackId: t.id,
    playCount: opts.playCount ?? 0,
    inLibrary: opts.inLibrary ?? true,
  })

  return t
}

function intent(partial: Partial<Intent> & { themes: string }): Intent {
  return intentSchema.parse(partial)
}

describe('buildPool', () => {
  it('hard filters: tempo window excludes out-of-range tracks', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const inWindow = await seedTrack(db, 'u1', { tempo: 100, embedding: SAME_AS_QUERY })
    const outWindow = await seedTrack(db, 'u1', { tempo: 200, embedding: SAME_AS_QUERY })

    const pool = await buildPool(db, fakeEmbed, 'u1', intent({ themes: 'x', tempoMin: 90, tempoMax: 110 }))

    const ids = pool.map((p) => p.trackId)
    expect(ids).toContain(inWindow.id)
    expect(ids).not.toContain(outWindow.id)
  })

  it('hard filters: allowExplicit false excludes explicit tracks', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const clean = await seedTrack(db, 'u1', { explicit: false, embedding: SAME_AS_QUERY })
    const dirty = await seedTrack(db, 'u1', { explicit: true, embedding: SAME_AS_QUERY })
    const unknown = await seedTrack(db, 'u1', { explicit: null, embedding: SAME_AS_QUERY })

    const pool = await buildPool(db, fakeEmbed, 'u1', intent({ themes: 'x', allowExplicit: false }))

    const ids = pool.map((p) => p.trackId)
    expect(ids).toContain(clean.id)
    expect(ids).toContain(unknown.id) // NULL explicit is treated as non-explicit
    expect(ids).not.toContain(dirty.id)
  })

  it('hard filters: era range excludes tracks outside it', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const inRange = await seedTrack(db, 'u1', { releaseYear: 1990, embedding: SAME_AS_QUERY })
    const outRange = await seedTrack(db, 'u1', { releaseYear: 2020, embedding: SAME_AS_QUERY })

    const pool = await buildPool(db, fakeEmbed, 'u1', intent({ themes: 'x', eraFrom: 1980, eraTo: 2000 }))

    const ids = pool.map((p) => p.trackId)
    expect(ids).toContain(inRange.id)
    expect(ids).not.toContain(outRange.id)
  })

  it('era range: a NULL releaseYear passes the filter rather than being excluded', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const noYear = await seedTrack(db, 'u1', { releaseYear: null, embedding: SAME_AS_QUERY })

    const pool = await buildPool(db, fakeEmbed, 'u1', intent({ themes: 'x', eraFrom: 1980, eraTo: 2000 }))

    expect(pool.map((p) => p.trackId)).toContain(noYear.id)
  })

  it('two-bound tempo window: a NULL-tempo track passes the filter but scores lower than an in-window match', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const centerMatch = await seedTrack(db, 'u1', { tempo: 120, embedding: SAME_AS_QUERY })
    const unknownTempo = await seedTrack(db, 'u1', { noFeatures: true, embedding: SAME_AS_QUERY })

    const pool = await buildPool(db, fakeEmbed, 'u1', intent({ themes: 'x', tempoMin: 100, tempoMax: 140 }))

    const ids = pool.map((p) => p.trackId)
    expect(ids).toContain(centerMatch.id)
    expect(ids).toContain(unknownTempo.id) // NULL tempo passes a window filter, unlike a known out-of-window tempo

    const byId = (id: string) => pool.find((p) => p.trackId === id)!
    expect(byId(centerMatch.id).score).toBeGreaterThan(byId(unknownTempo.id).score)
  })

  it('tempo-proximity gradient: centre-of-window outranks edge-of-window, all else equal', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const center = await seedTrack(db, 'u1', { tempo: 120, embedding: SAME_AS_QUERY })
    const edge = await seedTrack(db, 'u1', { tempo: 140, embedding: SAME_AS_QUERY })

    const pool = await buildPool(db, fakeEmbed, 'u1', intent({ themes: 'x', tempoMin: 100, tempoMax: 140 }))

    const byId = (id: string) => pool.find((p) => p.trackId === id)!
    expect(byId(center.id).score).toBeGreaterThan(byId(edge.id).score)
  })

  it('single tempo bound: does not exclude an out-of-range track, but ranks it lower (direction, not cutoff)', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const atBound = await seedTrack(db, 'u1', { tempo: 140, embedding: SAME_AS_QUERY })
    const wellBelow = await seedTrack(db, 'u1', { tempo: 60, embedding: SAME_AS_QUERY })

    const pool = await buildPool(db, fakeEmbed, 'u1', intent({ themes: 'x', tempoMin: 140 }))

    const ids = pool.map((p) => p.trackId)
    expect(ids).toContain(atBound.id)
    expect(ids).toContain(wellBelow.id) // a single bound never hard-excludes

    const byId = (id: string) => pool.find((p) => p.trackId === id)!
    expect(byId(atBound.id).score).toBeGreaterThan(byId(wellBelow.id).score)
  })

  it('DEFAULT_TEMPO_HALF_WIDTH (60bpm): a single bound treats +/-60bpm as the soft window, clamped beyond that', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const atBound = await seedTrack(db, 'u1', { tempo: 140, embedding: SAME_AS_QUERY })
    const atHalfWidth = await seedTrack(db, 'u1', { tempo: 80, embedding: SAME_AS_QUERY }) // 140 - 60
    const beyondHalfWidth = await seedTrack(db, 'u1', { tempo: 20, embedding: SAME_AS_QUERY }) // 140 - 120, clamps same as atHalfWidth

    const pool = await buildPool(db, fakeEmbed, 'u1', intent({ themes: 'x', tempoMin: 140 }))
    const byId = (id: string) => pool.find((p) => p.trackId === id)!

    expect(byId(atBound.id).score).toBeGreaterThan(byId(atHalfWidth.id).score)
    expect(byId(atHalfWidth.id).score).toBeCloseTo(byId(beyondHalfWidth.id).score, 10)
  })

  it('a track with no features row still appears via meaning similarity alone', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const noFeatures = await seedTrack(db, 'u1', { noFeatures: true, embedding: SAME_AS_QUERY })

    const pool = await buildPool(db, fakeEmbed, 'u1', intent({ themes: 'x' }))

    expect(pool.map((p) => p.trackId)).toContain(noFeatures.id)
  })

  it('a track with no meaning row still appears via feature-fit alone', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const noMeaning = await seedTrack(db, 'u1', { tempo: 120, energy: 0.5 })

    const pool = await buildPool(db, fakeEmbed, 'u1', intent({ themes: 'x' }))

    expect(pool.map((p) => p.trackId)).toContain(noMeaning.id)
  })

  // This is the dial's real contract: changing familiarity must be able to
  // change WHICH track wins, not just shrink the margin — the whole point of
  // normalizing the familiarity term (see FAM_REFERENCE_PLAYS in pool.ts) is
  // that at unbounded play counts a fixed-weight combination could otherwise
  // never flip the winner regardless of preset.
  it("familiarity dial flips the winner: 'comfort' favors a popular-but-irrelevant track, 'adventurous' favors a relevant-but-unknown one — same two tracks, opposite winner", async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const popularButIrrelevant = await seedTrack(db, 'u1', { embedding: ORTHOGONAL_TO_QUERY, playCount: 220 })
    const relevantButUnknown = await seedTrack(db, 'u1', { embedding: SAME_AS_QUERY, playCount: 0 })

    const comfortPool = await buildPool(db, fakeEmbed, 'u1', intent({ themes: 'x', familiarity: 'comfort' }))
    const adventurousPool = await buildPool(
      db,
      fakeEmbed,
      'u1',
      intent({ themes: 'x', familiarity: 'adventurous' }),
    )
    const byId = (pool: typeof comfortPool, id: string) => pool.find((p) => p.trackId === id)!

    expect(byId(comfortPool, popularButIrrelevant.id).score).toBeGreaterThan(
      byId(comfortPool, relevantButUnknown.id).score,
    )
    expect(byId(adventurousPool, relevantButUnknown.id).score).toBeGreaterThan(
      byId(adventurousPool, popularButIrrelevant.id).score,
    )
  })

  it('pool size is min(15 * targetCount, 300, available)', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    // 50 available: targetCount 3 (15*3=45) stays under that; targetCount 4
    // (15*4=60) exceeds it and must be capped down to what's available.
    for (let i = 0; i < 50; i++) {
      await seedTrack(db, 'u1', { tempo: 120, energy: 0.5, embedding: SAME_AS_QUERY })
    }

    const uncapped = await buildPool(db, fakeEmbed, 'u1', intent({ themes: 'x', targetCount: 3 }))
    expect(uncapped).toHaveLength(45) // min(45, 300, 50)

    const capped = await buildPool(db, fakeEmbed, 'u1', intent({ themes: 'x', targetCount: 4 }))
    expect(capped).toHaveLength(50) // min(60, 300, 50) -> capped by availability
  })

  it('pool size is hard-capped at MAX_POOL_SIZE (300) even when 15x targetCount and availability both exceed it', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const N = 305
    // Minimal columns, batch-inserted, for speed — this test only needs
    // volume, not scoring signal.
    const trackRows = await db
      .insert(tracks)
      .values(Array.from({ length: N }, (_, i) => ({ appleId: `cap-${i}`, title: `cap-${i}`, artist: 'Artist' })))
      .returning({ id: tracks.id })
    await db.insert(userTracks).values(trackRows.map((t) => ({ userId: 'u1', trackId: t.id, playCount: 0 })))

    const pool = await buildPool(db, fakeEmbed, 'u1', intent({ themes: 'x', targetCount: 60 }))
    expect(pool).toHaveLength(300) // min(900, 300, 305)
  })

  it("only the requesting user's library is eligible", async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedUser(db, 'u2')
    const mine = await seedTrack(db, 'u1', { tempo: 120, embedding: SAME_AS_QUERY })
    const theirs = await seedTrack(db, 'u2', { tempo: 120, embedding: SAME_AS_QUERY })

    const pool = await buildPool(db, fakeEmbed, 'u1', intent({ themes: 'x' }))

    const ids = pool.map((p) => p.trackId)
    expect(ids).toContain(mine.id)
    expect(ids).not.toContain(theirs.id)
  })

  it('a track removed from the library (in_library false) is not eligible', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const removed = await seedTrack(db, 'u1', { tempo: 120, embedding: SAME_AS_QUERY, inLibrary: false })

    const pool = await buildPool(db, fakeEmbed, 'u1', intent({ themes: 'x' }))

    expect(pool.map((p) => p.trackId)).not.toContain(removed.id)
  })

  it('a userId containing SQL metacharacters is just a non-matching value, not a route into the query', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedTrack(db, 'u1', { embedding: SAME_AS_QUERY })

    const maliciousUserId = "u1' OR '1'='1"
    const pool = await buildPool(db, fakeEmbed, maliciousUserId, intent({ themes: 'x' }))

    expect(pool).toEqual([]) // matches no real user_tracks row; no error, no leaked rows

    // the real user's own data is untouched and still queries normally
    const stillThere = await buildPool(db, fakeEmbed, 'u1', intent({ themes: 'x' }))
    expect(stillThere.length).toBeGreaterThan(0)
  })

  it('rejects a malformed embedding before it ever reaches SQL, without leaking its values', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')

    const wrongLength: Embedder = async () => [1, 2, 3]
    await expect(buildPool(db, wrongLength, 'u1', intent({ themes: 'x' }))).rejects.toThrow('bad embedding (len 3)')

    const nonFinite: Embedder = async () => {
      const v = new Array(DIMS).fill(0)
      v[3] = Number.NaN
      return v
    }
    let error: unknown
    try {
      await buildPool(db, nonFinite, 'u1', intent({ themes: 'x' }))
      throw new Error('expected buildPool to reject')
    } catch (e) {
      error = e
    }
    expect(error).toBeInstanceOf(Error)
    expect((error as Error).message).toMatch(/^pool: bad embedding \(len \d+\)$/)
  })

  it('an anti-correlated (opposite-direction) meaning clamps to the same 0 floor as an orthogonal one, never negative', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const opposite = vec({ 0: -1 })
    const orthogonal = await seedTrack(db, 'u1', { embedding: ORTHOGONAL_TO_QUERY, playCount: 10 })
    const antiCorrelated = await seedTrack(db, 'u1', { embedding: opposite, playCount: 10 })

    const pool = await buildPool(db, fakeEmbed, 'u1', intent({ themes: 'x' }))
    const byId = (id: string) => pool.find((p) => p.trackId === id)!

    // Without GREATEST(0, ...), the anti-correlated track's sim term would be
    // negative (distance ~2 -> 1 - 2 = -1) and it would score BELOW the
    // orthogonal track. Clamped, the two are equal — both floor at 0.
    expect(byId(antiCorrelated.id).score).toBeCloseTo(byId(orthogonal.id).score, 10)
  })

  it('orthogonal meaning contributes ~0 similarity while identical meaning contributes ~1', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const identical = await seedTrack(db, 'u1', { tempo: 120, energy: 0.5, embedding: SAME_AS_QUERY })
    const orthogonal = await seedTrack(db, 'u1', { tempo: 120, energy: 0.5, embedding: ORTHOGONAL_TO_QUERY })

    const pool = await buildPool(db, fakeEmbed, 'u1', intent({ themes: 'x', familiarity: 'adventurous' }))

    const byId = (id: string) => pool.find((p) => p.trackId === id)!
    expect(byId(identical.id).score).toBeGreaterThan(byId(orthogonal.id).score)
  })
})
