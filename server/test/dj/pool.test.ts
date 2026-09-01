import { describe, it, expect } from 'vitest'
import { sql } from 'drizzle-orm'
import { createTestDb, type TestDb } from '../helpers/db'
import { buildPool } from '../../src/dj/pool'
import { intentSchema, type Intent } from '../../src/dj/contracts'
import {
  tracks,
  trackFeatures,
  trackMeanings,
  userTracks,
  user,
  djSessions,
  queueTracks,
  sessionEvents,
  userRecentTrackObservations,
  userPlaylists,
  playlistEntries,
} from '../../src/db/schema'
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
  playCountObserved?: boolean
  inLibrary?: boolean
  durationMs?: number
  noFeatures?: boolean // when true, no track_features row at all
  artist?: string
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
      artist: opts.artist ?? 'Artist',
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
    playCountObserved: opts.playCountObserved ?? true,
    inLibrary: opts.inLibrary ?? true,
  })

  return t
}

function intent(partial: Partial<Intent> & { themes: string }): Intent {
  return intentSchema.parse(partial)
}

// --- Taste-signal seeding helpers (Task 3) -------------------------------

async function seedSession(db: TestDb, userId: string, title = 'session') {
  const [s] = await db.insert(djSessions).values({ userId, title }).returning()
  return s
}

// Inserts a queue_tracks row for the given track/session, optionally
// overriding updatedAt for decay tests (the taste CTE keys removal recency
// off this column, not createdAt).
async function seedQueueTrack(
  db: TestDb,
  sessionId: string,
  trackId: string,
  opts: { state: 'active' | 'removed'; removedBy?: 'dj' | 'user'; updatedAt?: Date },
) {
  const [row] = await db
    .insert(queueTracks)
    .values({
      sessionId,
      trackId,
      position: 0,
      addedBy: 'dj',
      state: opts.state,
      removedBy: opts.removedBy,
      updatedAt: opts.updatedAt,
    })
    .returning()
  return row
}

async function seedSessionEvent(db: TestDb, sessionId: string, type: 'played' | 'saved_playlist', createdAt?: Date) {
  const [row] = await db.insert(sessionEvents).values({ sessionId, type, createdAt }).returning()
  return row
}

// The `type` enum has no DB-level CHECK (per the plan's binding facts), so an
// "unknown event type ignored" test needs a raw insert to get a row past
// drizzle's own type narrowing.
async function seedRawSessionEvent(db: TestDb, sessionId: string, type: string) {
  await db.execute(sql`INSERT INTO session_events (session_id, type) VALUES (${sessionId}, ${type})`)
}

const daysAgo = (n: number) => new Date(Date.now() - n * 24 * 60 * 60 * 1000)

// Hand-computed neutral-signal score for a track seeded with `embedding:
// SAME_AS_QUERY, playCount: 0` and no tempo intent, under familiarity 'mix' —
// mirrors the FAMILIARITY_WEIGHTS['mix'] convex combination in pool.ts with
// taste's neutral 0.5: 0.396*1 (sim) + 0.22*0.5 (feat, no tempo target) +
// 0.264*0 (fam, 0 plays) + 0.12*0.5 (taste, no signal) = 0.566.
const NEUTRAL_MIX_SCORE = 0.45 * 0.88 * 1 + 0.25 * 0.88 * 0.5 + 0.3 * 0.88 * 0 + 0.12 * 0.5

describe('buildPool', () => {
  it("calls embed with intent.themes verbatim", async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    let seenText: string | undefined
    const spyEmbed: Embedder = async (text) => {
      seenText = text
      return QUERY_DIRECTION
    }

    await buildPool(db, spyEmbed, 'u1', intent({ themes: 'rainy drive at midnight' }))

    expect(seenText).toBe('rainy drive at midnight')
  })

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

  it('uses recent rank and playlist membership when web play counts are unavailable', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const recent = await seedTrack(db, 'u1', {
      embedding: SAME_AS_QUERY, playCountObserved: false,
    })
    const playlisted = await seedTrack(db, 'u1', {
      embedding: SAME_AS_QUERY, playCountObserved: false,
    })
    const noSignal = await seedTrack(db, 'u1', {
      embedding: SAME_AS_QUERY, playCountObserved: false,
    })
    await db.insert(userRecentTrackObservations).values({
      userId: 'u1', trackId: recent.id, source: 'web_musickit', rank: 0, observedAt: new Date(),
    })
    const [playlist] = await db.insert(userPlaylists).values({
      userId: 'u1', appleLibraryId: 'p-web', name: 'Saved', kind: 'user',
      sourceFingerprint: 'a'.repeat(64), inLibrary: true,
    }).returning()
    await db.insert(playlistEntries).values({
      playlistId: playlist.id,
      position: 0,
      trackId: playlisted.id,
      appleLibraryEntryId: 'entry-1',
      titleSnapshot: 'Playlisted',
      artistSnapshot: 'Artist',
    })

    const pool = await buildPool(db, fakeEmbed, 'u1', intent({ themes: 'x', familiarity: 'comfort' }))
    const byId = (id: string) => pool.find((item) => item.trackId === id)!
    expect(byId(recent.id).playCount).toBeNull()
    expect(byId(playlisted.id).playCount).toBeNull()
    expect(byId(noSignal.id).playCount).toBeNull()
    expect(byId(recent.id).score).toBeGreaterThan(byId(noSignal.id).score)
    expect(byId(playlisted.id).score).toBeGreaterThan(byId(noSignal.id).score)
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

  it('excludeTrackIds removes given tracks from the pool regardless of how well they score', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const excluded = await seedTrack(db, 'u1', { embedding: SAME_AS_QUERY, playCount: 999 }) // would otherwise be top-scored
    const kept = await seedTrack(db, 'u1', { embedding: SAME_AS_QUERY })

    const pool = await buildPool(db, fakeEmbed, 'u1', intent({ themes: 'x' }), [excluded.id])

    const ids = pool.map((p) => p.trackId)
    expect(ids).not.toContain(excluded.id)
    expect(ids).toContain(kept.id)
  })

  it('an empty excludeTrackIds list excludes nothing', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const t = await seedTrack(db, 'u1', { embedding: SAME_AS_QUERY })

    const pool = await buildPool(db, fakeEmbed, 'u1', intent({ themes: 'x' }), [])

    expect(pool.map((p) => p.trackId)).toContain(t.id)
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

describe('buildPool taste term', () => {
  it('neutral when no signal: score equals the hand-computed convex combo with taste=0.5', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const track = await seedTrack(db, 'u1', { embedding: SAME_AS_QUERY, playCount: 0 })

    const pool = await buildPool(db, fakeEmbed, 'u1', intent({ themes: 'x', familiarity: 'mix' }))

    const byId = (id: string) => pool.find((p) => p.trackId === id)!
    expect(byId(track.id).score).toBeCloseTo(NEUTRAL_MIX_SCORE, 5)
  })

  // Genuine near-tie: ArtistB's track has a WORSE raw similarity than
  // ArtistA's (0.8 vs 1.0 — vec({0:0.8,1:0.6}) is an exact-unit-length
  // cosine-0.8 direction from QUERY_DIRECTION), so on sim alone A wins. Taste
  // signal (5 user-removal sessions for A vs. 8 kept+played sessions for B)
  // is strong enough to flip the ranking anyway — this is the dial actually
  // doing something, not just nudging a score that was never in question.
  it("winner-flip: taste overturns a genuine near-tie (worse-sim artist wins on taste alone)", async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const trackA = await seedTrack(db, 'u1', { artist: 'ArtistA', embedding: SAME_AS_QUERY, playCount: 0 })
    const trackB = await seedTrack(db, 'u1', { artist: 'ArtistB', embedding: vec({ 0: 0.8, 1: 0.6 }), playCount: 0 })

    // ArtistA: user-removed across 5 distinct sessions (strong penalty).
    for (let i = 0; i < 5; i++) {
      const s = await seedSession(db, 'u1')
      await seedQueueTrack(db, s.id, trackA.id, { state: 'removed', removedBy: 'user' })
    }
    // ArtistB: kept (active) in 8 distinct sessions, each with a 'played'
    // event — needed at KEEP_WEIGHT=0.25 to match the strength of A's penalty.
    for (let i = 0; i < 8; i++) {
      const s = await seedSession(db, 'u1')
      await seedQueueTrack(db, s.id, trackB.id, { state: 'active' })
      await seedSessionEvent(db, s.id, 'played')
    }

    const pool = await buildPool(db, fakeEmbed, 'u1', intent({ themes: 'x', familiarity: 'mix' }))
    const byId = (id: string) => pool.find((p) => p.trackId === id)!

    // Without taste, A (sim 1.0) would beat B (sim 0.8) — taste flips it.
    expect(byId(trackB.id).score).toBeGreaterThan(byId(trackA.id).score)
  })

  // Companion to the flip above: the SAME taste signals, but now B's sim gap
  // is large (orthogonal, sim 0 vs A's sim 1) rather than small. Taste is
  // bounded (the tanh squash caps how far it can move a score — see TASTE_K),
  // so it must NOT be enough to overturn a big enough similarity gap.
  it('winner-flip is bounded: the same taste signals do NOT flip a large sim gap', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const trackA = await seedTrack(db, 'u1', { artist: 'ArtistA', embedding: SAME_AS_QUERY, playCount: 0 })
    const trackB = await seedTrack(db, 'u1', { artist: 'ArtistB', embedding: ORTHOGONAL_TO_QUERY, playCount: 0 })

    for (let i = 0; i < 5; i++) {
      const s = await seedSession(db, 'u1')
      await seedQueueTrack(db, s.id, trackA.id, { state: 'removed', removedBy: 'user' })
    }
    for (let i = 0; i < 8; i++) {
      const s = await seedSession(db, 'u1')
      await seedQueueTrack(db, s.id, trackB.id, { state: 'active' })
      await seedSessionEvent(db, s.id, 'played')
    }

    const pool = await buildPool(db, fakeEmbed, 'u1', intent({ themes: 'x', familiarity: 'mix' }))
    const byId = (id: string) => pool.find((p) => p.trackId === id)!

    expect(byId(trackA.id).score).toBeGreaterThan(byId(trackB.id).score)
  })

  it('in-session dominance: a same-session removal beats a surviving same-artist keep — net score lands BELOW neutral, not at it', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    // Two tracks by the same artist in the SAME session: one removed by the
    // user, the other survives (active) and the session is played. Without
    // in-session dominance these would roughly cancel (a full-weight penalty
    // vs. a KEEP_WEIGHT-scaled boost) and land back near neutral — that would
    // silently erase the removal signal the user just gave.
    const removedTrack = await seedTrack(db, 'u1', { artist: 'DominantArtist', embedding: SAME_AS_QUERY, playCount: 0 })
    const survivingTrack = await seedTrack(db, 'u1', {
      artist: 'DominantArtist',
      embedding: SAME_AS_QUERY,
      playCount: 0,
    })
    const s = await seedSession(db, 'u1')
    await seedQueueTrack(db, s.id, removedTrack.id, { state: 'removed', removedBy: 'user' })
    await seedQueueTrack(db, s.id, survivingTrack.id, { state: 'active' })
    await seedSessionEvent(db, s.id, 'played')

    const pool = await buildPool(db, fakeEmbed, 'u1', intent({ themes: 'x', familiarity: 'mix' }))
    const byId = (id: string) => pool.find((p) => p.trackId === id)!

    // Both tracks share the artist, so both carry the same (penalized) taste
    // score — assert against the surviving track since that's the one whose
    // score a naive cancellation would have restored to neutral.
    expect(byId(survivingTrack.id).score).toBeLessThan(NEUTRAL_MIX_SCORE)
  })

  it("a DJ removal (removed_by='dj') contributes nothing — score stays neutral", async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const track = await seedTrack(db, 'u1', { artist: 'DjRemovedArtist', embedding: SAME_AS_QUERY, playCount: 0 })
    const s = await seedSession(db, 'u1')
    await seedQueueTrack(db, s.id, track.id, { state: 'removed', removedBy: 'dj' })

    const pool = await buildPool(db, fakeEmbed, 'u1', intent({ themes: 'x', familiarity: 'mix' }))
    const byId = (id: string) => pool.find((p) => p.trackId === id)!

    expect(byId(track.id).score).toBeCloseTo(NEUTRAL_MIX_SCORE, 5)
  })

  it('a kept track in a session with no played/saved_playlist event contributes nothing', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const track = await seedTrack(db, 'u1', { artist: 'UnplayedArtist', embedding: SAME_AS_QUERY, playCount: 0 })
    const s = await seedSession(db, 'u1')
    await seedQueueTrack(db, s.id, track.id, { state: 'active' }) // no session_events row at all

    const pool = await buildPool(db, fakeEmbed, 'u1', intent({ themes: 'x', familiarity: 'mix' }))
    const byId = (id: string) => pool.find((p) => p.trackId === id)!

    expect(byId(track.id).score).toBeCloseTo(NEUTRAL_MIX_SCORE, 5)
  })

  it('an unknown session_events type is ignored — a kept track in that session stays neutral', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const track = await seedTrack(db, 'u1', { artist: 'UnknownEventArtist', embedding: SAME_AS_QUERY, playCount: 0 })
    const s = await seedSession(db, 'u1')
    await seedQueueTrack(db, s.id, track.id, { state: 'active' })
    await seedRawSessionEvent(db, s.id, 'skipped') // not 'played' or 'saved_playlist'

    const pool = await buildPool(db, fakeEmbed, 'u1', intent({ themes: 'x', familiarity: 'mix' }))
    const byId = (id: string) => pool.find((p) => p.trackId === id)!

    expect(byId(track.id).score).toBeCloseTo(NEUTRAL_MIX_SCORE, 5)
  })

  it('5 duplicate played events on one session count the same as 1 (distinct-session pin)', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const trackDup = await seedTrack(db, 'u1', { artist: 'DupEventArtist', embedding: SAME_AS_QUERY, playCount: 0 })
    const trackSingle = await seedTrack(db, 'u1', { artist: 'SingleEventArtist', embedding: SAME_AS_QUERY, playCount: 0 })

    // Same explicit timestamp on every event in both branches: the taste
    // signal's decay is keyed off qualifying_sessions' MAX(created_at), so
    // pinning it exactly (rather than letting each insert take whatever
    // `NOW()` happens to be) makes the two branches' decay factors IDENTICAL
    // rather than merely close within a ~ms-scale insertion-order window.
    const fixedTs = new Date('2026-01-01T00:00:00Z')

    const sDup = await seedSession(db, 'u1')
    await seedQueueTrack(db, sDup.id, trackDup.id, { state: 'active' })
    for (let i = 0; i < 5; i++) await seedSessionEvent(db, sDup.id, 'played', fixedTs)

    const sSingle = await seedSession(db, 'u1')
    await seedQueueTrack(db, sSingle.id, trackSingle.id, { state: 'active' })
    await seedSessionEvent(db, sSingle.id, 'played', fixedTs)

    const pool = await buildPool(db, fakeEmbed, 'u1', intent({ themes: 'x', familiarity: 'mix' }))
    const byId = (id: string) => pool.find((p) => p.trackId === id)!

    expect(byId(trackDup.id).score).toBeCloseTo(byId(trackSingle.id).score, 10)
  })

  it('decay: a 200-day-old removal moves the score less than a 5-day-old one', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const oldTrack = await seedTrack(db, 'u1', { artist: 'OldRemovalArtist', embedding: SAME_AS_QUERY, playCount: 0 })
    const newTrack = await seedTrack(db, 'u1', { artist: 'NewRemovalArtist', embedding: SAME_AS_QUERY, playCount: 0 })

    const sOld = await seedSession(db, 'u1')
    await seedQueueTrack(db, sOld.id, oldTrack.id, { state: 'removed', removedBy: 'user', updatedAt: daysAgo(200) })

    const sNew = await seedSession(db, 'u1')
    await seedQueueTrack(db, sNew.id, newTrack.id, { state: 'removed', removedBy: 'user', updatedAt: daysAgo(5) })

    const pool = await buildPool(db, fakeEmbed, 'u1', intent({ themes: 'x', familiarity: 'mix' }))
    const byId = (id: string) => pool.find((p) => p.trackId === id)!

    // Both penalized, but the older removal has decayed further toward
    // neutral, so it scores HIGHER (closer to 0.5) than the fresh one.
    expect(byId(oldTrack.id).score).toBeGreaterThan(byId(newTrack.id).score)
    expect(byId(oldTrack.id).score).toBeLessThan(NEUTRAL_MIX_SCORE) // still penalized, just less so
  })

  it("cross-user isolation: another user's removals for the same artist name don't touch this user's score", async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedUser(db, 'u2')
    const mine = await seedTrack(db, 'u1', { artist: 'SharedArtistName', embedding: SAME_AS_QUERY, playCount: 0 })
    const theirs = await seedTrack(db, 'u2', { artist: 'SharedArtistName', embedding: SAME_AS_QUERY, playCount: 0 })

    // u2 heavily removes 'SharedArtistName' across 3 sessions.
    for (let i = 0; i < 3; i++) {
      const s = await seedSession(db, 'u2')
      await seedQueueTrack(db, s.id, theirs.id, { state: 'removed', removedBy: 'user' })
    }

    const pool = await buildPool(db, fakeEmbed, 'u1', intent({ themes: 'x', familiarity: 'mix' }))
    const byId = (id: string) => pool.find((p) => p.trackId === id)!

    expect(byId(mine.id).score).toBeCloseTo(NEUTRAL_MIX_SCORE, 5)
  })

  it('taste cannot rescue a track past a hard filter: a saturated boost does not pull a tempo-window-excluded track back into the pool', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    // Outside the tempo window below (90-110bpm) — a hard filter, unlike the
    // taste term, which only ever affects `score`, never `filters` (the
    // WHERE clause has no idea artist_taste exists).
    const excluded = await seedTrack(db, 'u1', {
      artist: 'SaturatedBoostArtist',
      tempo: 200,
      embedding: SAME_AS_QUERY,
      playCount: 0,
    })

    // Saturate this artist's boost near the tanh ceiling — many played,
    // kept sessions.
    for (let i = 0; i < 20; i++) {
      const s = await seedSession(db, 'u1')
      await seedQueueTrack(db, s.id, excluded.id, { state: 'active' })
      await seedSessionEvent(db, s.id, 'played')
    }

    const pool = await buildPool(db, fakeEmbed, 'u1', intent({ themes: 'x', tempoMin: 90, tempoMax: 110 }))

    expect(pool.map((p) => p.trackId)).not.toContain(excluded.id)
  })
})
