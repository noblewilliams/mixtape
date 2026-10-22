import { describe, it, expect, vi } from 'vitest'
import { eq, inArray, sql } from 'drizzle-orm'
import { createTestDb, type TestDb } from '../helpers/db'
import {
  djSessions,
  enrichmentFailures,
  funnelEvents,
  trackFeatures,
  trackMeanings,
  tracks,
  user,
  userArtistSeeds,
  userTracks,
} from '../../src/db/schema'
import {
  fillForSeeds,
  FILL_BUDGET,
  FILL_DEADLINE_MS,
  FILL_FLOOR,
  FILL_PER_ARTIST,
  FILL_QUEUE_BOOST,
  STAGE_SUBREQUESTS,
  type FillDeps,
} from '../../src/dj/catalogue-fill'
import { FRONT_OF_QUEUE_PRIORITY, runEnrichmentBatch } from '../../src/enrich/runner'
import { buildPool, resolvePoolMode } from '../../src/dj/pool'
import { intentSchema } from '../../src/dj/contracts'
import { runDjTurn, CORPUS_NOTICE, type DjDeps } from '../../src/dj/loop'
import { requestSurface } from '../../src/routes/sessions'
import { AppleCatalogError, type CatalogArtist, type CatalogSong } from '../../src/musickit/catalog'
import { EnrichSourceError } from '../../src/enrich/types'
import type { AudioFeatures } from '../../src/enrich/reccobeats'
import type { LlmClient, LlmRequest, LlmTurn } from '../../src/dj/llm'

const DIMS = 1024
const UNIT = Array.from({ length: DIMS }, (_, i) => (i === 0 ? 1 : 0))
const embedFake = async () => UNIT

const FEATURES: AudioFeatures = {
  tempo: 120, key: 1, mode: 1, energy: 0.5, danceability: 0.5, valence: 0.5, acousticness: 0.1,
  instrumentalness: 0, liveness: 0.1, speechiness: 0.1, loudness: -6, isrc: null, matchedDurationMs: null,
}

let counter = 0

async function seedUser(db: TestDb, id = 'u1') {
  await db.insert(user).values({ id, name: id, email: `${id}@example.com`, emailVerified: false, createdAt: new Date(), updatedAt: new Date() })
}

async function seedArtists(db: TestDb, names: string[], userId = 'u1') {
  // One insert per name, a millisecond apart, so "newest first" is defined.
  for (const [i, name] of names.entries()) {
    await db.insert(userArtistSeeds).values({ userId, name, source: 'prompt', createdAt: new Date(Date.UTC(2026, 9, 21, 12, 0, i)) })
  }
}

async function seedEnriched(db: TestDb, artist: string, n: number, opts: { isrc?: () => string } = {}) {
  const out = []
  for (let i = 0; i < n; i++) {
    counter += 1
    const [t] = await db.insert(tracks)
      .values({ appleId: `held-${counter}`, isrc: opts.isrc?.() ?? null, title: `Held ${counter}`, artist, durationMs: 200_000, genre: 'Hip-Hop' })
      .returning()
    await db.insert(trackFeatures).values({ trackId: t.id, tempo: 100, energy: 0.5, valence: 0.5, source: 'reccobeats' })
    await db.insert(trackMeanings).values({ trackId: t.id, embedding: UNIT, lyricsSource: 'lrclib' })
    out.push(t)
  }
  return out
}

function song(appleId: string, title: string, artist: string, isrc: string | null = null): CatalogSong {
  return { appleId, isrc, title, artist, album: 'Album', artwork: null, durationMs: 200_000, genre: 'Hip-Hop', releaseYear: 2010, explicit: false }
}

function topSongs(prefix: string, artist: string, n = FILL_PER_ARTIST): CatalogSong[] {
  return Array.from({ length: n }, (_, i) => song(`${prefix}-${i}`, `${artist} Song ${i}`, artist))
}

type CatalogScript = {
  artists?: Record<string, CatalogArtist[]>
  top?: Record<string, CatalogSong[]>
  songs?: Record<string, CatalogSong[]>
  failArtists?: Error
}

function fakeCatalog(script: CatalogScript) {
  const calls: string[] = []
  const catalog: FillDeps['catalog'] = {
    async searchArtists(_sf, term) {
      calls.push(`artists:${term}`)
      if (script.failArtists) throw script.failArtists
      return script.artists?.[term] ?? []
    },
    async artistTopSongs(_sf, id, limit) {
      calls.push(`top:${id}`)
      return (script.top?.[id] ?? []).slice(0, limit)
    },
    async searchSongs(_sf, term) {
      calls.push(`songs:${term}`)
      return script.songs?.[term] ?? []
    },
  }
  return { catalog, calls }
}

type EnrichScript = {
  features?: () => Promise<AudioFeatures | null>
  // Fetches each call makes, when the fake counts (FillDeps.enrichFetches).
  fetchesPerCall?: number
  featureFetches?: number
  lyricFetches?: number
}

function fakeEnrich(script: EnrichScript = {}) {
  const calls = { itunes: 0, features: 0, lyrics: 0, embed: 0 }
  let fetches = 0
  const enrich: FillDeps['enrich'] = {
    storefront: 'ng',
    itunes: async () => { calls.itunes += 1; return null },
    features: async () => {
      calls.features += 1
      fetches += script.featureFetches ?? script.fetchesPerCall ?? 0
      return script.features ? script.features() : FEATURES
    },
    lyrics: async () => {
      calls.lyrics += 1
      fetches += script.lyricFetches ?? script.fetchesPerCall ?? 0
      return { lyrics: 'la la', instrumental: false }
    },
    embed: async () => { calls.embed += 1; return UNIT },
  }
  return { enrich, calls, fetches: () => fetches }
}

function deps(catalog: FillDeps['catalog'], enrich: FillDeps['enrich'], enrichFetches?: () => number): FillDeps {
  return { catalog, enrich, defaultStorefront: 'ng', ...(enrichFetches ? { enrichFetches } : {}) }
}

// Three thin artists, each found on Apple with ten top songs.
function threeArtists() {
  return fakeCatalog({
    artists: {
      'Burna Boy': [{ id: 'a-burna', name: 'Burna Boy', genres: [] }],
      'Wizkid': [{ id: 'a-wiz', name: 'Wizkid', genres: [] }],
      'Tems': [{ id: 'a-tems', name: 'Tems', genres: [] }],
    },
    top: {
      'a-burna': topSongs('burna', 'Burna Boy'),
      'a-wiz': topSongs('wiz', 'Wizkid'),
      'a-tems': topSongs('tems', 'Tems'),
    },
  })
}

describe('fillForSeeds: which seeds', () => {
  it('fills only seeds whose key matches fewer than FILL_FLOOR enriched rows', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedArtists(db, ['jay z', 'kanye west'])
    await seedEnriched(db, 'Kanye West', FILL_FLOOR)
    const { catalog, calls } = fakeCatalog({})
    const { enrich } = fakeEnrich()

    await fillForSeeds(db, deps(catalog, enrich), { userId: 'u1' })

    expect(calls).toEqual(['artists:jay z'])
  })

  it('resolves the artist by key: "Jay-Z" answers seed "jay z", "Jay Electronica" does not', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedArtists(db, ['jay z'])
    const { catalog, calls } = fakeCatalog({
      artists: { 'jay z': [{ id: 'a-je', name: 'Jay Electronica', genres: [] }, { id: 'a-jz', name: 'Jay-Z', genres: [] }] },
      top: { 'a-jz': topSongs('jz', 'JAY-Z'), 'a-je': topSongs('je', 'Jay Electronica') },
    })
    const { enrich } = fakeEnrich()

    const result = await fillForSeeds(db, deps(catalog, enrich), { userId: 'u1', budget: 2 })

    expect(calls).toEqual(['artists:jay z', 'top:a-jz'])
    expect(result.inserted).toBe(FILL_PER_ARTIST)
    expect(result.artists).toEqual(['jay z'])
  })

  it('skips a seed whose only search hit is another artist, spending one subrequest', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedArtists(db, ['jay z'])
    const { catalog, calls } = fakeCatalog({ artists: { 'jay z': [{ id: 'a-je', name: 'Jay Electronica', genres: [] }] } })
    const { enrich } = fakeEnrich()

    const result = await fillForSeeds(db, deps(catalog, enrich), { userId: 'u1' })

    expect(calls).toEqual(['artists:jay z'])
    expect(result).toMatchObject({ inserted: 0, enriched: 0, subrequests: 1, artists: [] })
  })

  it('never runs for a personal listener', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedArtists(db, ['jay z'])
    const [t] = await db.insert(tracks).values({ appleId: 'own-1', title: 'Own', artist: 'Someone' }).returning()
    await db.insert(userTracks).values({ userId: 'u1', trackId: t.id, inLibrary: true })
    const { catalog, calls } = threeArtists()
    const { enrich, calls: enrichCalls } = fakeEnrich()

    const result = await fillForSeeds(db, deps(catalog, enrich), { userId: 'u1', namedSongs: [{ title: 'Ye', artist: 'Burna Boy' }] })

    expect(calls).toEqual([])
    expect(enrichCalls).toEqual({ itunes: 0, features: 0, lyrics: 0, embed: 0 })
    expect(result).toMatchObject({ inserted: 0, enriched: 0, subrequests: 0 })
  })
})

describe('fillForSeeds: rows that can never enrich', () => {
  async function seedSpotifyRows(db: TestDb, exhausted: boolean) {
    for (const ch of 'abcdefghijkl') {
      const [t] = await db.insert(tracks)
        .values({ spotifyId: `4uLU6hMCjMI75M1A2tKUQ${ch}`, title: `Spotify ${ch}`, artist: 'Tems' })
        .returning()
      if (exhausted) {
        await db.insert(enrichmentFailures).values({ trackId: t.id, stage: 'features', error: 'no acceptable match', attempts: 3 })
      }
    }
  }

  it('a seed whose 12 Spotify rows have exhausted their ReccoBeats lookups still gets an Apple lookup', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedArtists(db, ['Tems'])
    await seedSpotifyRows(db, true)
    const { catalog, calls } = threeArtists()
    const { enrich } = fakeEnrich()

    await fillForSeeds(db, deps(catalog, enrich), { userId: 'u1', budget: 2 })

    expect(calls).toEqual(['artists:Tems', 'top:a-tems'])
  })

  it('the same 12 rows still due for enrichment need no Apple lookup', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedArtists(db, ['Tems'])
    await seedSpotifyRows(db, false)
    const { catalog, calls } = threeArtists()
    const { enrich } = fakeEnrich()

    const result = await fillForSeeds(db, deps(catalog, enrich), { userId: 'u1', budget: 10 })

    expect(calls).toEqual([])
    // Their pending rows are enriched instead.
    expect(result.enriched).toBe(2)
  })
})

describe('fillForSeeds: queue priority', () => {
  it('rows enriched in-line keep the front; rows that fail fall back to the backlog, behind an import row', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedArtists(db, ['Tems'])
    const { catalog } = threeArtists()
    const { enrich } = fakeEnrich({
      features: async () => { throw new EnrichSourceError('reccobeats', 'HTTP 400', 400) },
    })

    // 2 Apple calls + 10 rows x 5: every filled row is tried in-line and fails.
    await fillForSeeds(db, deps(catalog, enrich), { userId: 'u1', budget: 52 })

    const filled = await db.select().from(tracks).where(sql`${tracks.appleId} LIKE 'tems-%'`)
    expect(filled).toHaveLength(10)
    expect(filled.every((t) => t.enrichPriority === 0)).toBe(true)

    // An import's pool candidate at priority 5 is picked first by the hourly job.
    const [imported] = await db.insert(tracks).values({ appleId: 'import-1', title: 'Imported', artist: 'Someone', enrichPriority: 5 }).returning()
    const { enrich: cron } = fakeEnrich()
    await runEnrichmentBatch(db, cron, 1)
    expect(await db.select().from(trackFeatures).where(eq(trackFeatures.trackId, imported.id))).toHaveLength(1)
  })

  it('a row enriched in-line in full stays at the front', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedArtists(db, ['Tems'])
    const { catalog } = threeArtists()
    const { enrich } = fakeEnrich()

    await fillForSeeds(db, deps(catalog, enrich), { userId: 'u1', budget: 7 })

    const rows = await db.select().from(tracks).where(sql`${tracks.appleId} LIKE 'tems-%'`)
    expect(rows.filter((t) => t.enrichPriority === FRONT_OF_QUEUE_PRIORITY)).toHaveLength(1)
    expect(rows.filter((t) => t.enrichPriority > FILL_QUEUE_BOOST && t.enrichPriority < FRONT_OF_QUEUE_PRIORITY)).toHaveLength(9)
  })
})

describe('fillForSeeds: inserts', () => {
  it('dedupes by ISRC then Apple id, keeps an ISRC peer of a Spotify row, and leaves artist_keys to Postgres', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedArtists(db, ['jay z'])
    await db.insert(tracks).values({ appleId: 'jz-held', title: 'Held', artist: 'JAY-Z' })
    await db.insert(tracks).values({ appleId: 'other-id', isrc: 'USAAA0000002', title: 'Same recording', artist: 'JAY-Z' })
    await db.insert(tracks).values({ spotifyId: '4uLU6hMCjMI75M1A2tKUQC', isrc: 'USAAA0000003', title: 'Spotify row', artist: 'JAY-Z' })
    const { catalog } = fakeCatalog({
      artists: { 'jay z': [{ id: 'a-jz', name: 'Jay-Z', genres: [] }] },
      top: {
        'a-jz': [
          song('jz-1', 'One', 'JAY-Z', 'USAAA0000001'),
          song('jz-1b', 'One (dup isrc)', 'JAY-Z', 'usaaa0000001'),
          song('jz-1', 'One (dup id)', 'JAY-Z'),
          song('jz-held', 'Held', 'JAY-Z'),
          song('jz-2', 'Two', 'JAY-Z', 'USAAA0000002'),
          song('jz-3', 'Three', 'JAY-Z & Kanye West', 'USAAA0000003'),
        ],
      },
    })
    const { enrich } = fakeEnrich()

    const result = await fillForSeeds(db, deps(catalog, enrich), { userId: 'u1', budget: 2 })

    expect(result.inserted).toBe(2)
    const rows = await db.select().from(tracks).where(inArray(tracks.appleId, ['jz-1', 'jz-1b', 'jz-2', 'jz-3']))
    expect(rows.map((r) => r.appleId).sort()).toEqual(['jz-1', 'jz-3'])
    const three = rows.find((r) => r.appleId === 'jz-3')!
    expect(three).toMatchObject({ artistSource: 'apple_catalog', appleCatalogStorefront: 'ng', durationMs: 200_000, genre: 'Hip-Hop' })
    expect(three.artistKeys).toEqual(['jayz', 'kanyewest', 'jayzkanyewest'])
    // Ahead of the backlog, the held row included, but not at the front:
    // with a budget of 2 none of them is enriched in-line.
    const [held] = await db.select().from(tracks).where(eq(tracks.appleId, 'jz-held'))
    expect(held.enrichPriority).toBe(FILL_QUEUE_BOOST)
    expect(three.enrichPriority).toBeGreaterThan(FILL_QUEUE_BOOST)
    expect(three.enrichPriority).toBeLessThan(FRONT_OF_QUEUE_PRIORITY)
  })

  it('a new row with an enriched ISRC twin takes its features and meaning and skips enrichment', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedArtists(db, ['jay z'])
    const [donor] = await db.insert(tracks)
      .values({ spotifyId: '4uLU6hMCjMI75M1A2tKUQC', isrc: 'USAAA0000009', title: 'Twin', artist: 'Somebody Else' })
      .returning()
    await db.insert(trackFeatures).values({ trackId: donor.id, tempo: 90, source: 'reccobeats' })
    await db.insert(trackMeanings).values({ trackId: donor.id, embedding: UNIT, lyricsSource: 'lrclib' })
    const { catalog } = fakeCatalog({
      artists: { 'jay z': [{ id: 'a-jz', name: 'Jay-Z', genres: [] }] },
      top: { 'a-jz': [song('jz-twin', 'Twin', 'JAY-Z', 'USAAA0000009')] },
    })
    const { enrich, calls } = fakeEnrich()

    const result = await fillForSeeds(db, deps(catalog, enrich), { userId: 'u1' })

    expect(result).toMatchObject({ inserted: 1, twins: 1, enriched: 0, subrequests: 2 })
    expect(calls).toEqual({ itunes: 0, features: 0, lyrics: 0, embed: 0 })
    const [row] = await db.select().from(tracks).where(eq(tracks.appleId, 'jz-twin'))
    const [features] = await db.select().from(trackFeatures).where(eq(trackFeatures.trackId, row.id))
    expect(features.source).toBe('twin')
  })

  it('a named song resolves by title key with its artist among the credits, and is enriched first', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedArtists(db, ['burna boy'])
    await seedEnriched(db, 'Burna Boy', FILL_FLOOR)
    const { catalog, calls } = fakeCatalog({
      songs: {
        'last last Burna Boy': [
          song('cover', 'Last Last', 'A Cover Band'),
          song('ll', 'Last Last!', 'Burna Boy'),
        ],
      },
    })
    const { enrich, calls: enrichCalls } = fakeEnrich()

    const result = await fillForSeeds(db, deps(catalog, enrich), { userId: 'u1', namedSongs: [{ title: 'last last', artist: 'Burna Boy' }] })

    // Burna Boy is not thin, so only the song search runs.
    expect(calls).toEqual(['songs:last last Burna Boy'])
    expect(result).toMatchObject({ inserted: 1, enriched: 1 })
    expect(enrichCalls.features).toBe(1)
    expect(await db.select().from(tracks).where(eq(tracks.appleId, 'cover'))).toHaveLength(0)
    const [row] = await db.select().from(tracks).where(eq(tracks.appleId, 'll'))
    expect(await db.select().from(trackFeatures).where(eq(trackFeatures.trackId, row.id))).toHaveLength(1)
  })
})

describe('fillForSeeds: budget', () => {
  it('charges each stage and stops before a row whose worst case does not fit', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedArtists(db, ['Burna Boy', 'Wizkid', 'Tems'])
    const { catalog, calls } = threeArtists()
    const { enrich, calls: enrichCalls } = fakeEnrich()

    const result = await fillForSeeds(db, deps(catalog, enrich), { userId: 'u1', budget: 24 })

    // 3 artists x 2 Apple calls = 6; each row's worst case is ReccoBeats 2 +
    // LRCLIB 2 + AI 1 = 5 (catalogue rows carry duration and genre, so no
    // iTunes), so 18 left fits 3 rows and stops at 3 remaining.
    expect(calls).toHaveLength(6)
    expect(enrichCalls).toEqual({ itunes: 0, features: 3, lyrics: 3, embed: 3 })
    expect(result).toMatchObject({ inserted: 30, enriched: 3, subrequests: 6 + 3 * 5 })
    expect(STAGE_SUBREQUESTS).toEqual({ apple: 1, itunes: 1, features: 2, lyrics: 2, embed: 1 })
  })

  it('enrich: false inserts and queues the rows but enriches none in-request (the never-refuse path)', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedArtists(db, ['Burna Boy', 'Wizkid', 'Tems'])
    const { catalog, calls } = threeArtists()
    const { enrich, calls: enrichCalls } = fakeEnrich()

    const result = await fillForSeeds(db, deps(catalog, enrich), { userId: 'u1', budget: FILL_BUDGET, enrich: false })

    expect(calls).toHaveLength(6)
    expect(enrichCalls).toEqual({ itunes: 0, features: 0, lyrics: 0, embed: 0 })
    expect(result).toMatchObject({ inserted: 30, enriched: 0, subrequests: 6 })
    const rows = await db.select().from(tracks)
    expect(rows.every((r) => r.enrichPriority >= FILL_QUEUE_BOOST && r.enrichPriority < FRONT_OF_QUEUE_PRIORITY)).toBe(true)
  })

  it('charges ReccoBeats and LRCLIB what they fetched when the caller counts', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedArtists(db, ['Burna Boy', 'Wizkid', 'Tems'])
    const { catalog } = threeArtists()
    const { enrich, calls, fetches } = fakeEnrich({ fetchesPerCall: 1 })

    const result = await fillForSeeds(db, deps(catalog, enrich, fetches), { userId: 'u1', budget: 24 })

    // Each row now costs 1 + 1 + 1 = 3 but still needs 5 free to start:
    // 18 -> 15 -> 12 -> 9 -> 6 -> 3, five rows.
    expect(calls.features).toBe(5)
    expect(result).toMatchObject({ enriched: 5, subrequests: 6 + 5 * 3 })
  })

  it('spreads a short budget across the artists, one row each in turn', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedArtists(db, ['Burna Boy', 'Wizkid', 'Tems'])
    const { catalog } = threeArtists()
    const { enrich } = fakeEnrich()

    await fillForSeeds(db, deps(catalog, enrich), { userId: 'u1', budget: 24 })

    const enriched = await db.execute(sql`SELECT DISTINCT t.artist FROM tracks t JOIN track_features f ON f.track_id = t.id`)
    expect((enriched as unknown as { rows: { artist: string }[] }).rows.map((r) => r.artist).sort()).toEqual(['Burna Boy', 'Tems', 'Wizkid'])
  })

  it('at the real FILL_BUDGET, a first fill of three new artists enriches 3 rows and is still short of the floor', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedArtists(db, ['Burna Boy', 'Wizkid', 'Tems'])
    const { catalog } = threeArtists()
    // Production-like fetches: a ReccoBeats hit is search + features (2), an
    // LRCLIB exact get hits first time (1), plus the embed: 4 per row.
    const { enrich, fetches } = fakeEnrich({ featureFetches: 2, lyricFetches: 1 })

    const result = await fillForSeeds(db, deps(catalog, enrich, fetches), { userId: 'u1' })

    // 6 Apple calls leave 14; rows need 5 free and cost 4: 14 -> 10 -> 6 -> 2.
    expect(FILL_BUDGET).toBe(20)
    expect(result).toMatchObject({ inserted: 30, enriched: 3, subrequests: 18 })
    // 3 enriched rows: this first turn is still refused; the cron and the
    // next prompt carry the other 27.
    expect(await resolvePoolMode(db, 'u1')).toEqual({ mode: 'insufficient_seeds', seedTracks: 3, seedArtists: 3 })
  })

  it('stops starting rows and Apple calls once FILL_DEADLINE_MS has passed', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedArtists(db, ['Burna Boy', 'Wizkid', 'Tems'])
    const { catalog } = threeArtists()
    let clock = 0
    const { enrich, calls } = fakeEnrich({ features: async () => { clock += 5_000; return FEATURES } })

    const result = await fillForSeeds(db, { ...deps(catalog, enrich), now: () => clock }, { userId: 'u1', budget: 100 })

    // Rows start at 0, 5 and 10 s; the fourth would start at 15 s > 12 s.
    expect(FILL_DEADLINE_MS).toBe(12_000)
    expect(calls.features).toBe(3)
    expect(result).toMatchObject({ inserted: 30, enriched: 3, timedOut: true })
  })

  it('makes no Apple call once the deadline has passed', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedArtists(db, ['Burna Boy', 'Wizkid', 'Tems'])
    const script = threeArtists()
    let clock = 0
    const catalog: FillDeps['catalog'] = {
      ...script.catalog,
      async artistTopSongs(sf, id, limit) {
        clock += 13_000
        return script.catalog.artistTopSongs(sf, id, limit)
      },
    }
    const { enrich, calls } = fakeEnrich()

    const result = await fillForSeeds(db, { ...deps(catalog, enrich), now: () => clock }, {
      userId: 'u1', namedSongs: [{ title: 'Ye', artist: 'Burna Boy' }],
    })

    // The first artist's two calls land; nothing after them starts.
    expect(script.calls).toEqual(['artists:Tems', 'top:a-tems'])
    expect(result).toMatchObject({ inserted: 10, enriched: 0, subrequests: 2, timedOut: true })
    expect(calls.features).toBe(0)
  })

  it.each([0, 1, 2, 3, 5, 7, 11, 24, 50])('never spends more than a budget of %i', async (budget) => {
    const db = await createTestDb()
    await seedUser(db)
    await seedArtists(db, ['Burna Boy', 'Wizkid', 'Tems'])
    const { catalog } = threeArtists()
    const { enrich } = fakeEnrich()

    const result = await fillForSeeds(db, deps(catalog, enrich), {
      userId: 'u1', budget, namedSongs: [{ title: 'Ye', artist: 'Burna Boy' }],
    })

    expect(result.subrequests).toBeLessThanOrEqual(budget)
  })

  it('a second resolvePoolMode sees a fill of 3 artists x 10 rows, 6 of them enriched', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedArtists(db, ['Burna Boy', 'Wizkid', 'Tems'])
    for (const artist of ['Burna Boy', 'Wizkid', 'Tems']) await seedEnriched(db, artist, 7)
    expect((await resolvePoolMode(db, 'u1')).mode).toBe('insufficient_seeds')
    const { catalog } = threeArtists()
    const { enrich } = fakeEnrich()

    // 6 Apple calls + 6 rows x 5.
    const result = await fillForSeeds(db, deps(catalog, enrich), { userId: 'u1', budget: 36 })

    expect(result).toMatchObject({ inserted: 30, enriched: 6, subrequests: 36 })
    expect(await resolvePoolMode(db, 'u1')).toEqual({ mode: 'corpus', seedTracks: 27, seedArtists: 3 })
  })
})

describe('fillForSeeds: provider failures', () => {
  it('an Apple 429 stops every further Apple call this turn, and the fill still returns', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedArtists(db, ['Burna Boy', 'Wizkid'])
    const { catalog, calls } = fakeCatalog({ failArtists: new AppleCatalogError('rate_limit', 429) })
    const { enrich } = fakeEnrich()

    const result = await fillForSeeds(db, deps(catalog, enrich), {
      userId: 'u1', namedSongs: [{ title: 'Ye', artist: 'Burna Boy' }],
    })

    expect(calls).toEqual(['artists:Wizkid'])
    expect(result).toMatchObject({ inserted: 0, subrequests: 1, appleError: 'rate_limit' })
  })

  it('another Apple failure skips that artist only', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedArtists(db, ['Burna Boy', 'Wizkid'])
    const script = threeArtists()
    const catalog: FillDeps['catalog'] = {
      ...script.catalog,
      async searchArtists(sf, term, limit) {
        if (term === 'Wizkid') throw new AppleCatalogError('upstream', 503)
        return script.catalog.searchArtists(sf, term, limit)
      },
    }
    const { enrich } = fakeEnrich()

    const result = await fillForSeeds(db, deps(catalog, enrich), { userId: 'u1' })

    expect(result).toMatchObject({ inserted: 10, artists: ['Burna Boy'], appleError: 'upstream' })
  })

  it('a ReccoBeats 429 leaves the row queued with a transient failure record', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedArtists(db, ['Tems'])
    const { catalog } = threeArtists()
    const { enrich } = fakeEnrich({
      features: async () => { throw new EnrichSourceError('reccobeats', 'HTTP 429', 429) },
    })

    const result = await fillForSeeds(db, deps(catalog, enrich), { userId: 'u1' })

    expect(result.inserted).toBe(10)
    const failures = await db.select().from(enrichmentFailures).where(eq(enrichmentFailures.stage, 'features'))
    expect(failures.length).toBeGreaterThan(0)
    expect(failures[0].error).toMatch(/^transient: /)
    // Meaning still landed, so the row counts; features waits for the cron.
    expect(result.enriched).toBe(failures.length)
  })
})

describe('fillForSeeds: golden pool', () => {
  it('after a fill the corpus pool holds the filled artist', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedArtists(db, ['Burna Boy', 'Wizkid', 'Tems'])
    for (const artist of ['Burna Boy', 'Wizkid', 'Tems']) await seedEnriched(db, artist, 7)
    await seedEnriched(db, 'Strangers', 20)
    const { catalog } = threeArtists()
    const { enrich } = fakeEnrich()

    await fillForSeeds(db, deps(catalog, enrich), { userId: 'u1', budget: 36 })

    const pool = await buildPool(db, embedFake, 'u1', intentSchema.parse({ themes: 'afrobeats night', targetCount: 15 }), undefined, { mode: 'corpus' })
    const filledIds = (await db.select({ id: tracks.id }).from(tracks).where(sql`${tracks.appleId} LIKE 'tems-%'`)).map((r) => r.id)
    expect(pool.some((t) => filledIds.includes(t.trackId))).toBe(true)
    // Structural: the named artists outrank strangers.
    expect(pool.filter((t) => /Burna Boy|Wizkid|Tems/.test(t.artist)).length).toBeGreaterThan(0)
  })
})

// --- loop -----------------------------------------------------------------

function curateFake(req: LlmRequest): LlmTurn {
  const blocks = req.messages[0].content as Array<{ text?: string }>
  const ids = Array.from((blocks[0]?.text ?? '').matchAll(/^([0-9a-f-]{36}) \|/gm)).map((m) => m[1])
  const count = Number((blocks[1]?.text ?? '').match(/Pick exactly (\d+) tracks/)?.[1] ?? ids.length)
  const text = JSON.stringify(ids.slice(0, count).map((id) => ({ id, reason: 'fits' })))
  return { text, toolCalls: [], raw: [{ type: 'text', text }], stopReason: 'end_turn', usage: { inputTokens: 1, outputTokens: 1, cacheReadInputTokens: null } }
}

function scriptedLlm(input: unknown): { llm: LlmClient; requests: LlmRequest[] } {
  const requests: LlmRequest[] = []
  let round = 0
  const llm: LlmClient = async (req) => {
    requests.push(req)
    if (req.tools.length === 0) return curateFake(req)
    round += 1
    if (round === 1) {
      const call = { id: 'c1', name: 'generate_queue', input }
      return { text: '', toolCalls: [call], raw: [{ type: 'tool_use', ...call }], stopReason: 'tool_use', usage: { inputTokens: 1, outputTokens: 1, cacheReadInputTokens: null } }
    }
    return { text: 'here you go.', toolCalls: [], raw: [{ type: 'text', text: 'here you go.' }], stopReason: 'end_turn', usage: { inputTokens: 1, outputTokens: 1, cacheReadInputTokens: null } }
  }
  return { llm, requests }
}

function toolResult(requests: LlmRequest[]): string {
  const conv = requests.filter((r) => r.tools.length > 0)[1]
  const msg = conv.messages.find((m) => m.role === 'user' && Array.isArray(m.content) && (m.content[0] as { type?: string }).type === 'tool_result')!
  return (msg.content as Array<{ content: string }>)[0].content
}

describe('runDjTurn with the catalogue fill', () => {
  it('an insufficient_seeds turn becomes corpus after the fill, with a funnel row and the counts in the log', async () => {
    const db = await createTestDb()
    await seedUser(db)
    // 24 enriched rows: one short of MIN_SEED_TRACKS until the fill lands.
    for (const artist of ['Burna Boy', 'Wizkid', 'Tems']) await seedEnriched(db, artist, 8)
    const [session] = await db.insert(djSessions).values({ userId: 'u1', title: 's' }).returning()
    const { catalog } = threeArtists()
    const { enrich } = fakeEnrich()
    const { llm, requests } = scriptedLlm({ themes: 'afrobeats night', targetCount: 5, namedArtists: ['Burna Boy', 'Wizkid', 'Tems'] })
    const djDeps: DjDeps = { llm, embed: embedFake, fill: deps(catalog, enrich) }
    const log = vi.spyOn(console, 'log').mockImplementation(() => {})

    try {
      const result = await runDjTurn(db, djDeps, { id: session.id, userId: 'u1' }, 'burna, wizkid and tems', { surface: 'ios' })

      expect(result.queue).toHaveLength(5)
      expect(toolResult(requests).split('\n')[0]).toBe(CORPUS_NOTICE)
      const funnel = await db.select().from(funnelEvents).where(eq(funnelEvents.userId, 'u1'))
      expect(funnel.map((f) => [f.type, f.surface])).toEqual([['catalogue_filled', 'ios']])
      const line = log.mock.calls.find((c) => c[0] === 'dj turn')!
      const logged = JSON.parse(line[1] as string)
      // FILL_BUDGET 20: 6 Apple calls, then 2 rows at their worst case of 5.
      expect(logged.fill).toEqual({ inserted: 30, enriched: 2, subrequests: 16 })
      expect(logged.fill.subrequests).toBeLessThanOrEqual(FILL_BUDGET)
    } finally {
      log.mockRestore()
    }
  })

  it('a turn without fill deps refuses as before and writes no funnel row', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const [session] = await db.insert(djSessions).values({ userId: 'u1', title: 's' }).returning()
    const { llm } = scriptedLlm({ themes: 'x', namedArtists: ['Tems'] })
    const log = vi.spyOn(console, 'log').mockImplementation(() => {})

    try {
      const result = await runDjTurn(db, { llm, embed: embedFake }, { id: session.id, userId: 'u1' }, 'tems')
      expect(result.queue).toHaveLength(0)
      expect(await db.select().from(funnelEvents)).toHaveLength(0)
      const logged = JSON.parse(log.mock.calls.find((c) => c[0] === 'dj turn')![1] as string)
      expect(logged.fill).toBeUndefined()
    } finally {
      log.mockRestore()
    }
  })
})

describe('requestSurface', () => {
  it("reads the native app's Dart client as ios and anything else as web", () => {
    expect(requestSurface('Dart/3.9 (dart:io)')).toBe('ios')
    expect(requestSurface('Mozilla/5.0 (iPhone)')).toBe('web')
    expect(requestSurface(undefined)).toBe('web')
  })
})
