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

  it("familiarity 'comfort' ranks a high-play-count track above an otherwise-identical low-play track, and 'adventurous' flattens the gap", async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const highPlay = await seedTrack(db, 'u1', {
      tempo: 120,
      energy: 0.5,
      embedding: SAME_AS_QUERY,
      playCount: 500,
    })
    const lowPlay = await seedTrack(db, 'u1', {
      tempo: 120,
      energy: 0.5,
      embedding: SAME_AS_QUERY,
      playCount: 1,
    })

    const comfortPool = await buildPool(db, fakeEmbed, 'u1', intent({ themes: 'x', familiarity: 'comfort' }))
    const adventurousPool = await buildPool(
      db,
      fakeEmbed,
      'u1',
      intent({ themes: 'x', familiarity: 'adventurous' }),
    )

    const byId = (pool: typeof comfortPool, id: string) => pool.find((p) => p.trackId === id)!

    const comfortHigh = byId(comfortPool, highPlay.id)
    const comfortLow = byId(comfortPool, lowPlay.id)
    const adventurousHigh = byId(adventurousPool, highPlay.id)
    const adventurousLow = byId(adventurousPool, lowPlay.id)

    expect(comfortHigh.score).toBeGreaterThan(comfortLow.score)
    expect(adventurousHigh.score).toBeGreaterThan(adventurousLow.score)

    const comfortGap = comfortHigh.score - comfortLow.score
    const adventurousGap = adventurousHigh.score - adventurousLow.score
    expect(adventurousGap).toBeLessThan(comfortGap)
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

  it('a malicious themes string only ever reaches the embedder, never the SQL', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const track = await seedTrack(db, 'u1', { tempo: 120, embedding: SAME_AS_QUERY })

    const payload = "x'; DROP TABLE tracks; --"
    let seenByEmbedder: string | undefined
    const spyEmbed: Embedder = async (text) => {
      seenByEmbedder = text
      return QUERY_DIRECTION
    }

    const pool = await buildPool(db, spyEmbed, 'u1', intent({ themes: payload }))

    expect(seenByEmbedder).toBe(payload)
    expect(pool.map((p) => p.trackId)).toContain(track.id)
    // proves the table survived: buildPool still works and the row is still there
    const rows = await db.select().from(tracks)
    expect(rows.some((r) => r.id === track.id)).toBe(true)
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
