import { describe, it, expect, vi } from 'vitest'
import { eq } from 'drizzle-orm'
import { createTestDb, type TestDb } from '../helpers/db'
import { enrichmentFailures, trackFeatureFallbacks, trackFeatures, tracks } from '../../src/db/schema'
import { fillFeaturesForTurn, type FeaturesChainDeps, type TurnSong } from '../../src/enrich/features-chain'
import { resolveAndFetchFeatures } from '../../src/enrich/reccobeats'
import { createDeezerTempoClient } from '../../src/enrich/deezer-tempo'
import { NO_MATCH } from '../../src/enrich/failures'

const DURATION_MS = 200_000
const OPTS = { deadlineMs: 6_000, concurrency: 4 }

type Mode = 'hit' | 'miss' | '429'

// Fake HTTP for ReccoBeats (search then audio features) and Deezer (track by
// ISRC). `reccobeats` and `deezer` pick each host's answer per song title or
// ISRC; every request is recorded.
function fakeHttp(opts: {
  reccobeats?: (title: string) => Mode
  deezer?: (isrc: string) => number | null | 'throw'
  onRequest?: (url: URL) => void
} = {}) {
  const requests: string[] = []
  const fetchLike = async (input: string | URL) => {
    const url = new URL(input)
    requests.push(`${url.host}${url.pathname}`)
    opts.onRequest?.(url)
    if (url.host === 'api.reccobeats.com') {
      if (url.pathname === '/v1/track/search') {
        const title = url.searchParams.get('searchText') ?? ''
        const mode = opts.reccobeats?.(title) ?? 'miss'
        if (mode === '429') return new Response(null, { status: 429 })
        if (mode === 'miss') return Response.json({ content: [] })
        return Response.json({ content: [{ id: 'rb1', trackTitle: title, artists: [{ name: 'Artist' }], durationMs: DURATION_MS, isrc: null }] })
      }
      if (url.pathname === '/v1/track/rb1/audio-features') {
        return Response.json({ tempo: 118, energy: 0.71, valence: 0.42, danceability: 0.6, key: 5, mode: 1 })
      }
    }
    if (url.host === 'api.deezer.com') {
      const isrc = url.pathname.replace('/track/isrc:', '')
      const answer = opts.deezer?.(isrc) ?? null
      if (answer === 'throw') throw new TypeError('network down')
      if (answer === null) return Response.json({ error: { code: 800 } })
      return Response.json({ id: 1, bpm: answer })
    }
    throw new Error(`unexpected request ${url.host}${url.pathname}`)
  }
  const deps: FeaturesChainDeps = {
    features: (key) => resolveAndFetchFeatures(key, fetchLike),
    deezer: createDeezerTempoClient({ fetchLike }),
  }
  return { deps, requests }
}

let counter = 0
async function seedSong(db: TestDb, opts: { isrc?: string | null; estimate?: TurnSong['estimate'] } = {}): Promise<TurnSong> {
  counter += 1
  const isrc = opts.isrc === undefined ? `USUG1190${String(counter).padStart(4, '0')}` : opts.isrc
  const [t] = await db.insert(tracks).values({ appleId: `a${counter}`, title: `Song ${counter}`, artist: 'Artist', durationMs: DURATION_MS, isrc }).returning()
  return { trackId: t.id, isrc, title: t.title, artist: 'Artist', durationMs: DURATION_MS, ...(opts.estimate ? { estimate: opts.estimate } : {}) }
}

const fallbackOf = async (db: TestDb, trackId: string) =>
  (await db.select().from(trackFeatureFallbacks).where(eq(trackFeatureFallbacks.trackId, trackId)))[0]
const featuresOf = async (db: TestDb, trackId: string) =>
  (await db.select().from(trackFeatures).where(eq(trackFeatures.trackId, trackId)))[0]
const failureOf = async (db: TestDb, trackId: string) =>
  (await db.select().from(enrichmentFailures).where(eq(enrichmentFailures.trackId, trackId)))[0]

describe('fillFeaturesForTurn', () => {
  it('a ReccoBeats hit writes track_features as the cron does, and no fallback row', async () => {
    const db = await createTestDb()
    const song = await seedSong(db, { estimate: { energy: 0.2, valence: 0.9 } })
    const { deps, requests } = fakeHttp({ reccobeats: () => 'hit', deezer: () => 99 })

    const result = await fillFeaturesForTurn(db, deps, [song], OPTS)

    expect(result).toMatchObject({ measured: 1, fallback: 0, skipped: 0 })
    expect(await featuresOf(db, song.trackId)).toMatchObject({ tempo: 118, energy: 0.71, valence: 0.42, source: 'reccobeats' })
    expect(await fallbackOf(db, song.trackId)).toBeUndefined()
    expect(await failureOf(db, song.trackId)).toBeUndefined()
    // No Deezer call once measured.
    expect(requests.filter((r) => r.startsWith('api.deezer.com'))).toHaveLength(0)
  })

  it('a ReccoBeats miss records the cron failure, then Deezer tempo and the estimate land in fallbacks', async () => {
    const db = await createTestDb()
    const song = await seedSong(db, { estimate: { energy: 0.8, valence: 0.3 } })
    const { deps } = fakeHttp({ reccobeats: () => 'miss', deezer: () => 124 })

    const result = await fillFeaturesForTurn(db, deps, [song], OPTS)

    expect(result).toMatchObject({ measured: 0, fallback: 1, skipped: 0 })
    expect(await featuresOf(db, song.trackId)).toBeUndefined()
    expect(await failureOf(db, song.trackId)).toMatchObject({ stage: 'features', error: NO_MATCH, attempts: 1 })
    expect(await fallbackOf(db, song.trackId)).toMatchObject({
      tempo: 124, tempoSource: 'deezer', energy: 0.8, valence: 0.3, moodSource: 'model',
    })
  })

  it('a ReccoBeats 429 falls through without using up an attempt', async () => {
    const db = await createTestDb()
    const song = await seedSong(db, { estimate: { energy: 0.5 } })
    const { deps, requests } = fakeHttp({ reccobeats: () => '429', deezer: () => 100 })

    const result = await fillFeaturesForTurn(db, deps, [song], OPTS)

    expect(result).toMatchObject({ measured: 0, fallback: 1 })
    expect(await failureOf(db, song.trackId)).toBeUndefined()
    expect(await fallbackOf(db, song.trackId)).toMatchObject({ tempo: 100, tempoSource: 'deezer', energy: 0.5, valence: null })
    // Not retried in the turn: one search only.
    expect(requests.filter((r) => r === 'api.reccobeats.com/v1/track/search')).toHaveLength(1)
  })

  it('past the deadline, the remaining songs get estimates only, with no network', async () => {
    const db = await createTestDb()
    const songs = [
      await seedSong(db, { estimate: { energy: 0.1 } }),
      await seedSong(db, { estimate: { energy: 0.2 } }),
      await seedSong(db, { estimate: { energy: 0.3 } }),
    ]
    let clock = 0
    // The first song's search takes the turn past the deadline.
    const { deps, requests } = fakeHttp({
      reccobeats: () => 'miss',
      deezer: () => 110,
      onRequest: (url) => { if (url.host === 'api.reccobeats.com') clock += 7_000 },
    })

    const result = await fillFeaturesForTurn(db, { ...deps, now: () => clock }, songs, { deadlineMs: 6_000, concurrency: 1 })

    expect(result).toMatchObject({ measured: 0, fallback: 3 })
    expect(requests.filter((r) => r.startsWith('api.reccobeats.com'))).toHaveLength(1)
    // The first song's Deezer call would start past the deadline too.
    expect(requests.filter((r) => r.startsWith('api.deezer.com'))).toHaveLength(0)
    for (const [i, s] of songs.entries()) {
      expect(await fallbackOf(db, s.trackId)).toMatchObject({ tempo: null, tempoSource: null, energy: (i + 1) / 10, moodSource: 'model' })
    }
    // Only the song that actually missed has a failure row.
    expect(await failureOf(db, songs[0].trackId)).toBeDefined()
    expect(await failureOf(db, songs[1].trackId)).toBeUndefined()
  })

  it('leaves an existing measured row untouched and makes no network call for it', async () => {
    const db = await createTestDb()
    const song = await seedSong(db, { estimate: { energy: 0.9, valence: 0.9 } })
    await db.insert(trackFeatures).values({ trackId: song.trackId, tempo: 90, energy: 0.4, valence: 0.6, source: 'reccobeats' })
    const { deps, requests } = fakeHttp({ reccobeats: () => 'hit', deezer: () => 120 })

    const result = await fillFeaturesForTurn(db, deps, [song], OPTS)

    expect(result).toMatchObject({ measured: 0, fallback: 0, skipped: 1, subrequests: 0 })
    expect(requests).toHaveLength(0)
    expect(await featuresOf(db, song.trackId)).toMatchObject({ tempo: 90, energy: 0.4, valence: 0.6 })
    expect(await fallbackOf(db, song.trackId)).toBeUndefined()
  })

  it('stores out-of-range values as null', async () => {
    const db = await createTestDb()
    const song = await seedSong(db, { estimate: { energy: 1.4, valence: 0.25 } })
    // Deezer's client already drops an out-of-range bpm; the write checks again.
    const { deps } = fakeHttp({ reccobeats: () => 'miss' })
    const wild: FeaturesChainDeps = { ...deps, deezer: { tempoByIsrc: async () => 300 } }

    await fillFeaturesForTurn(db, wild, [song], OPTS)

    expect(await fallbackOf(db, song.trackId)).toMatchObject({ tempo: null, tempoSource: null, energy: null, valence: 0.25, moodSource: 'model' })
  })

  it('writes no fallback row when there is no value at all', async () => {
    const db = await createTestDb()
    const noIsrc = await seedSong(db, { isrc: null })
    const noTempo = await seedSong(db)
    const { deps, requests } = fakeHttp({ reccobeats: () => 'miss', deezer: () => null })

    const result = await fillFeaturesForTurn(db, deps, [noIsrc, noTempo], OPTS)

    expect(result).toMatchObject({ measured: 0, fallback: 0 })
    expect(await db.select().from(trackFeatureFallbacks)).toHaveLength(0)
    // Deezer is only asked for the song with an ISRC.
    expect(requests.filter((r) => r.startsWith('api.deezer.com'))).toHaveLength(1)
  })

  it('a transient Deezer failure is swallowed and the estimate still lands', async () => {
    const db = await createTestDb()
    const song = await seedSong(db, { estimate: { energy: 0.6, valence: 0.7 } })
    const { deps } = fakeHttp({ reccobeats: () => 'miss', deezer: () => 'throw' })

    const result = await fillFeaturesForTurn(db, deps, [song], OPTS)

    expect(result).toMatchObject({ fallback: 1 })
    expect(await fallbackOf(db, song.trackId)).toMatchObject({ tempo: null, energy: 0.6, valence: 0.7, moodSource: 'model' })
  })

  it('skips ReccoBeats for a song the cron has given up on, still asking Deezer', async () => {
    const db = await createTestDb()
    const song = await seedSong(db, { estimate: { energy: 0.5 } })
    await db.insert(enrichmentFailures).values({ trackId: song.trackId, stage: 'features', error: NO_MATCH, attempts: 1 })
    const { deps, requests } = fakeHttp({ reccobeats: () => 'hit', deezer: () => 105 })

    const result = await fillFeaturesForTurn(db, deps, [song], OPTS)

    expect(result).toMatchObject({ measured: 0, fallback: 1 })
    expect(requests.filter((r) => r.startsWith('api.reccobeats.com'))).toHaveLength(0)
    expect(await failureOf(db, song.trackId)).toMatchObject({ attempts: 1 })
    expect(await fallbackOf(db, song.trackId)).toMatchObject({ tempo: 105, tempoSource: 'deezer' })
  })

  it('charges 2 per ReccoBeats lookup and 1 per Deezer lookup, and spends no more than its budget', async () => {
    const db = await createTestDb()
    const songs = [await seedSong(db, { estimate: { energy: 0.5 } }), await seedSong(db, { estimate: { energy: 0.5 } })]
    const { deps, requests } = fakeHttp({ reccobeats: () => 'miss', deezer: () => 120 })

    const full = await fillFeaturesForTurn(db, deps, songs, OPTS)
    expect(full.subrequests).toBe(2 * (2 + 1))

    const db2 = await createTestDb()
    const more = [await seedSong(db2, { estimate: { energy: 0.5 } }), await seedSong(db2, { estimate: { energy: 0.5 } })]
    const before = requests.length
    // Room for one ReccoBeats lookup and one Deezer lookup only.
    const capped = await fillFeaturesForTurn(db2, deps, more, { ...OPTS, concurrency: 1, budget: 3 })
    expect(capped.subrequests).toBeLessThanOrEqual(3)
    expect(requests.length - before).toBeLessThanOrEqual(3)
    expect(capped).toMatchObject({ fallback: 2 })
  })

  it('never throws: a database failure is logged and counted as nothing done', async () => {
    const db = await createTestDb()
    const song = await seedSong(db, { estimate: { energy: 0.5 } })
    const { deps } = fakeHttp()
    const boom = () => { throw new Error('db down') }
    const broken = { select: boom, execute: boom, insert: boom, update: boom, delete: boom } as unknown as TestDb
    const log = vi.spyOn(console, 'log').mockImplementation(() => {})
    try {
      const result = await fillFeaturesForTurn(broken, deps, [song], OPTS)
      expect(result).toMatchObject({ measured: 0, fallback: 0, skipped: 0 })
      expect(log.mock.calls.some((c) => c[0] === 'features chain')).toBe(true)
    } finally {
      log.mockRestore()
    }
  })
})
