# P2 Enrichment Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Annotate every track in the taste graph with audio features (BPM, energy, key, …), lyric-meaning embeddings, and backfilled ISRC/duration/genre — cached forever, shared across users — then backfill the founder's 4,689 synced tracks.

**Architecture:** Server-only (no client work). Per-track pipeline: iTunes lookup (duration/genre/preview, `country=<storefront>`) → ReccoBeats resolve-by-title + audio-features (+ISRC) → LRCLIB lyrics fetched transiently → Workers AI bge-m3 embedding (1024-dim, pgvector). Driven by an admin-token-guarded batch endpoint (backfill) + a cron trigger (steady state). Every external call sits behind an injected structural seam so tests run on PGlite + fakes.

**Tech Stack:** Existing Hono/Drizzle/Neon stack + pgvector (Neon + PGlite both support it), Workers AI binding (`@cf/baai/bge-m3`), no new external accounts or keys.

**Working directory:** `~/Documents/work/mixtape` — paths relative to repo root. Branch: `main`.

**Verified API facts (probed live 2026-08-29 — do not re-guess):**
- iTunes: `GET https://itunes.apple.com/lookup?id=<appleId>&country=ng` → `{resultCount, results:[{trackName, artistName, previewUrl, trackTimeMillis, primaryGenreName}]}`. US storefront returns 0 for these IDs — storefront is config, default `ng`.
- ReccoBeats: `GET https://api.reccobeats.com/v1/track/search?searchText=<TITLE ONLY>` (adding artist words breaks matching) → `{content:[{id, trackTitle, artists:[{name}], durationMs, isrc, href}]}`. Then `GET /v1/track/{id}/audio-features` → `{acousticness, danceability, energy, instrumentalness, key, liveness, loudness, mode, speechiness, tempo, valence, isrc}`. No auth.
- LRCLIB: `GET https://lrclib.net/api/get?artist_name=&track_name=&album_name=&duration=<seconds>` → `{plainLyrics, syncedLyrics, instrumental, ...}` or 404; `GET /api/search?track_name=&artist_name=` → array of same. Send a descriptive User-Agent. No auth.
- Workers AI: binding `env.AI.run('@cf/baai/bge-m3', { text: [<string>] })` → `{data: [number[1024]]}` (if the deployed response nests differently, log the raw shape once and adapt — the seam isolates this).

**Ground rules that bind this plan:** lyric TEXT is never stored or logged — fetched transiently, embedded, discarded (`track_meanings` has no text column by design). Enrichment is per-track and global (not per-user), so `/enrich/*` is guarded by an admin token, not a user session.

---

### Task 1: Schema — pgvector, track_features, track_meanings, enrichment_failures

**Files:**
- Modify: `server/src/db/schema.ts`
- Modify: `server/test/helpers/db.ts`
- Create: migration `server/drizzle/0003_*.sql` (generated, then hand-prepend extension)
- Test: `server/test/db.test.ts` (extend)

- [ ] **Step 1: Write failing test** — append to `server/test/db.test.ts`:

```ts
import { trackFeatures, trackMeanings, enrichmentFailures } from '../src/db/schema'

it('stores audio features and a 1024-dim embedding for a track', async () => {
  const db = await createTestDb()
  const [track] = await db
    .insert(tracks)
    .values({ appleId: 'e1', title: 'Song', artist: 'Artist' })
    .returning()
  await db.insert(trackFeatures).values({
    trackId: track.id,
    tempo: 128.4,
    key: 4,
    mode: 1,
    energy: 0.342,
    danceability: 0.516,
    valence: 0.167,
    acousticness: 0.832,
    instrumentalness: 0.579,
    liveness: 0.0857,
    speechiness: 0.0342,
    loudness: -9.785,
    source: 'reccobeats',
  })
  await db.insert(trackMeanings).values({
    trackId: track.id,
    embedding: Array.from({ length: 1024 }, (_, i) => i / 1024),
    lyricsSource: 'lrclib',
    instrumental: false,
  })
  const feats = await db.select().from(trackFeatures)
  expect(feats[0].tempo).toBeCloseTo(128.4)
  const meanings = await db.select().from(trackMeanings)
  expect(meanings[0].embedding).toHaveLength(1024)
})

it('records enrichment failures with attempt counts', async () => {
  const db = await createTestDb()
  const [track] = await db
    .insert(tracks)
    .values({ appleId: 'e2', title: 'S', artist: 'A' })
    .returning()
  await db.insert(enrichmentFailures).values({ trackId: track.id, stage: 'features', error: 'no match' })
  const rows = await db.select().from(enrichmentFailures)
  expect(rows[0].attempts).toBe(1)
})
```

- [ ] **Step 2: Run to verify it fails** — `cd server && npm test` → FAIL (tables missing).

- [ ] **Step 3: Extend `server/src/db/schema.ts`** — add to imports: `doublePrecision, integer, vector` from `drizzle-orm/pg-core`; append:

```ts
export const trackFeatures = pgTable('track_features', {
  trackId: uuid('track_id')
    .primaryKey()
    .references(() => tracks.id, { onDelete: 'cascade' }),
  tempo: doublePrecision('tempo'),
  key: integer('key'),
  mode: integer('mode'),
  energy: doublePrecision('energy'),
  danceability: doublePrecision('danceability'),
  valence: doublePrecision('valence'),
  acousticness: doublePrecision('acousticness'),
  instrumentalness: doublePrecision('instrumentalness'),
  liveness: doublePrecision('liveness'),
  speechiness: doublePrecision('speechiness'),
  loudness: doublePrecision('loudness'),
  source: text('source').notNull(),
  fetchedAt: timestamp('fetched_at', { withTimezone: true }).notNull().defaultNow(),
})

// Lyric MEANING only — never lyric text (docs/decisions.md → lyrics stance).
export const trackMeanings = pgTable('track_meanings', {
  trackId: uuid('track_id')
    .primaryKey()
    .references(() => tracks.id, { onDelete: 'cascade' }),
  embedding: vector('embedding', { dimensions: 1024 }),
  lyricsSource: text('lyrics_source'),
  instrumental: boolean('instrumental').notNull().default(false),
  embeddedAt: timestamp('embedded_at', { withTimezone: true }).notNull().defaultNow(),
})

export const enrichmentFailures = pgTable(
  'enrichment_failures',
  {
    trackId: uuid('track_id')
      .notNull()
      .references(() => tracks.id, { onDelete: 'cascade' }),
    stage: text('stage').notNull(), // 'itunes' | 'features' | 'meaning'
    error: text('error').notNull(),
    attempts: integer('attempts').notNull().default(1),
    lastAt: timestamp('last_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [primaryKey({ columns: [t.trackId, t.stage] })],
)
```

Also add to `tracks` table columns (non-breaking additions): `durationMs: integer('duration_ms'),`.

- [ ] **Step 4: Generate migration and prepend the extension**

Run: `cd server && npx drizzle-kit generate`
Then edit the new `drizzle/0003_*.sql`: add as the FIRST line: `CREATE EXTENSION IF NOT EXISTS vector;--> statement-breakpoint`
(drizzle-kit does not emit extension DDL; Neon and PGlite both accept it.)

- [ ] **Step 5: Wire pgvector into the PGlite test helper** — `server/test/helpers/db.ts`:

```ts
import { vector } from '@electric-sql/pglite/vector'
// in createTestDb(), both PGlite constructions gain the extension:
//   new PGlite({ extensions: { vector } })
//   PGlite.create({ loadDataDir: template, extensions: { vector } })
```

(Keep the snapshot-template pattern intact.)

- [ ] **Step 6: Run tests** — `cd server && npm test && npm run typecheck` → all PASS (existing 23 + 2 new). If the drizzle `vector` column type or PGlite extension import differs in installed versions, check `node_modules` types and adapt — report what you found.

- [ ] **Step 7: Commit** — `git add server && git commit -m "feat(server): enrichment schema + pgvector"`

---

### Task 2: iTunes lookup client

**Files:**
- Create: `server/src/enrich/itunes.ts`
- Test: `server/test/enrich/itunes.test.ts`

- [ ] **Step 1: Write failing test `server/test/enrich/itunes.test.ts`**

```ts
import { describe, it, expect } from 'vitest'
import { lookupItunes, type FetchLike } from '../../src/enrich/itunes'

const ok = (body: unknown): FetchLike => async (url) => {
  expect(String(url)).toContain('itunes.apple.com/lookup')
  expect(String(url)).toContain('country=ng')
  return new Response(JSON.stringify(body), { status: 200 })
}

describe('lookupItunes', () => {
  it('maps a hit to duration, genre, preview', async () => {
    const fetchLike = ok({
      resultCount: 1,
      results: [{
        trackName: 'Space Song',
        artistName: 'Beach House',
        previewUrl: 'https://audio-ssl.itunes.apple.com/x.m4a',
        trackTimeMillis: 320000,
        primaryGenreName: 'Alternative',
      }],
    })
    const hit = await lookupItunes('12345', 'ng', fetchLike)
    expect(hit).toEqual({
      trackName: 'Space Song',
      artistName: 'Beach House',
      previewUrl: 'https://audio-ssl.itunes.apple.com/x.m4a',
      durationMs: 320000,
      genre: 'Alternative',
    })
  })

  it('returns null on zero results', async () => {
    expect(await lookupItunes('999', 'ng', ok({ resultCount: 0, results: [] }))).toBeNull()
  })

  it('throws EnrichSourceError on non-200', async () => {
    const bad: FetchLike = async () => new Response('nope', { status: 503 })
    await expect(lookupItunes('1', 'ng', bad)).rejects.toThrow('itunes')
  })
})
```

- [ ] **Step 2: Run to verify FAIL**, then **Step 3: Create `server/src/enrich/itunes.ts`**

```ts
export type FetchLike = (url: string | URL, init?: RequestInit) => Promise<Response>

export class EnrichSourceError extends Error {
  constructor(source: string, detail: string) {
    super(`${source}: ${detail}`)
  }
}

export type ItunesHit = {
  trackName: string
  artistName: string
  previewUrl: string | null
  durationMs: number | null
  genre: string | null
}

export async function lookupItunes(
  appleId: string,
  storefront: string,
  fetchLike: FetchLike = fetch,
): Promise<ItunesHit | null> {
  const url = `https://itunes.apple.com/lookup?id=${encodeURIComponent(appleId)}&country=${storefront}`
  const res = await fetchLike(url)
  if (!res.ok) throw new EnrichSourceError('itunes', `HTTP ${res.status}`)
  const body = (await res.json()) as {
    resultCount: number
    results: Array<{
      trackName?: string
      artistName?: string
      previewUrl?: string
      trackTimeMillis?: number
      primaryGenreName?: string
    }>
  }
  if (!body.resultCount || !body.results.length) return null
  const r = body.results[0]
  return {
    trackName: r.trackName ?? '',
    artistName: r.artistName ?? '',
    previewUrl: r.previewUrl ?? null,
    durationMs: r.trackTimeMillis ?? null,
    genre: r.primaryGenreName ?? null,
  }
}
```

- [ ] **Step 4: Tests + typecheck PASS**, **Step 5: Commit** — `feat(server): itunes lookup client`

---

### Task 3: ReccoBeats client (resolve by title + features)

**Files:**
- Create: `server/src/enrich/reccobeats.ts`
- Test: `server/test/enrich/reccobeats.test.ts`

- [ ] **Step 1: Write failing test** (key behaviors: title-only search URL; candidate filtering by normalized artist AND duration within 5s; feature mapping; null on no acceptable candidate; EnrichSourceError on 5xx):

```ts
import { describe, it, expect } from 'vitest'
import { resolveAndFetchFeatures } from '../../src/enrich/reccobeats'
import type { FetchLike } from '../../src/enrich/itunes'

const candidate = (over: Record<string, unknown> = {}) => ({
  id: 'rb-1',
  trackTitle: 'Nude',
  artists: [{ name: 'Radiohead' }],
  durationMs: 255386,
  isrc: 'GBSTK0700003',
  ...over,
})

const features = {
  acousticness: 0.832, danceability: 0.516, energy: 0.342, instrumentalness: 0.579,
  key: 4, liveness: 0.0857, loudness: -9.785, mode: 1, speechiness: 0.0342,
  tempo: 128.378, valence: 0.167, isrc: 'GBSTK0700003',
}

function fetchScript(searchBody: unknown, featuresBody: unknown = features): FetchLike {
  return async (url) => {
    const u = String(url)
    if (u.includes('/track/search')) {
      // Title only — artist terms break ReccoBeats matching (probed live).
      expect(u).toContain('searchText=Nude')
      expect(u).not.toContain('Radiohead')
      return new Response(JSON.stringify(searchBody), { status: 200 })
    }
    expect(u).toContain('/track/rb-1/audio-features')
    return new Response(JSON.stringify(featuresBody), { status: 200 })
  }
}

describe('resolveAndFetchFeatures', () => {
  it('finds the right candidate and returns mapped features + isrc', async () => {
    const result = await resolveAndFetchFeatures(
      { title: 'Nude', artist: 'Radiohead', durationMs: 255000 },
      fetchScript({ content: [candidate({ id: 'rb-0', artists: [{ name: 'Someone Else' }] }), candidate()] }),
    )
    expect(result).toMatchObject({ tempo: 128.378, energy: 0.342, key: 4, mode: 1, isrc: 'GBSTK0700003' })
  })

  it('rejects candidates whose duration differs by more than 5s', async () => {
    const result = await resolveAndFetchFeatures(
      { title: 'Nude', artist: 'Radiohead', durationMs: 300000 },
      fetchScript({ content: [candidate()] }),
    )
    expect(result).toBeNull()
  })

  it('matches without duration when the track has none (artist match only)', async () => {
    const result = await resolveAndFetchFeatures(
      { title: 'Nude', artist: 'Radiohead', durationMs: null },
      fetchScript({ content: [candidate()] }),
    )
    expect(result).not.toBeNull()
  })

  it('returns null on empty search results', async () => {
    expect(
      await resolveAndFetchFeatures({ title: 'Nude', artist: 'Radiohead', durationMs: null }, fetchScript({ content: [] })),
    ).toBeNull()
  })

  it('throws EnrichSourceError on server errors', async () => {
    const bad: FetchLike = async () => new Response('x', { status: 500 })
    await expect(
      resolveAndFetchFeatures({ title: 'Nude', artist: 'Radiohead', durationMs: null }, bad),
    ).rejects.toThrow('reccobeats')
  })
})
```

- [ ] **Step 2: FAIL**, then **Step 3: Create `server/src/enrich/reccobeats.ts`**

```ts
import { EnrichSourceError, type FetchLike } from './itunes'

const BASE = 'https://api.reccobeats.com/v1'
const DURATION_TOLERANCE_MS = 5000

export type TrackKey = { title: string; artist: string; durationMs: number | null }

export type AudioFeatures = {
  tempo: number
  key: number
  mode: number
  energy: number
  danceability: number
  valence: number
  acousticness: number
  instrumentalness: number
  liveness: number
  speechiness: number
  loudness: number
  isrc: string | null
}

type Candidate = {
  id: string
  trackTitle: string
  artists: Array<{ name: string }>
  durationMs: number
  isrc: string | null
}

const norm = (s: string) => s.toLowerCase().normalize('NFKD').replace(/[^\p{L}\p{N} ]/gu, '').trim()

export async function resolveAndFetchFeatures(
  track: TrackKey,
  fetchLike: FetchLike = fetch,
): Promise<AudioFeatures | null> {
  // Title only: artist terms in searchText break ReccoBeats matching (probed live).
  const searchUrl = `${BASE}/track/search?searchText=${encodeURIComponent(track.title)}`
  const searchRes = await fetchLike(searchUrl)
  if (!searchRes.ok) throw new EnrichSourceError('reccobeats', `search HTTP ${searchRes.status}`)
  const { content } = (await searchRes.json()) as { content: Candidate[] }

  const artistNorm = norm(track.artist)
  const match = content.find((c) => {
    const artistOk = c.artists.some((a) => norm(a.name) === artistNorm)
    if (!artistOk) return false
    if (track.durationMs == null) return true
    return Math.abs(c.durationMs - track.durationMs) <= DURATION_TOLERANCE_MS
  })
  if (!match) return null

  const featRes = await fetchLike(`${BASE}/track/${match.id}/audio-features`)
  if (!featRes.ok) {
    if (featRes.status === 404) return null
    throw new EnrichSourceError('reccobeats', `features HTTP ${featRes.status}`)
  }
  const f = (await featRes.json()) as Record<string, number> & { isrc?: string }
  return {
    tempo: f.tempo, key: f.key, mode: f.mode, energy: f.energy,
    danceability: f.danceability, valence: f.valence, acousticness: f.acousticness,
    instrumentalness: f.instrumentalness, liveness: f.liveness,
    speechiness: f.speechiness, loudness: f.loudness,
    isrc: f.isrc ?? match.isrc ?? null,
  }
}
```

- [ ] **Step 4: Tests + typecheck PASS**, **Step 5: Commit** — `feat(server): reccobeats features client`

---

### Task 4: LRCLIB client + Workers AI embedder seam

**Files:**
- Create: `server/src/enrich/lrclib.ts`
- Create: `server/src/enrich/embedder.ts`
- Test: `server/test/enrich/lrclib.test.ts`

- [ ] **Step 1: Write failing test `server/test/enrich/lrclib.test.ts`**

```ts
import { describe, it, expect } from 'vitest'
import { fetchLyrics } from '../../src/enrich/lrclib'
import type { FetchLike } from '../../src/enrich/itunes'

describe('fetchLyrics', () => {
  it('gets exact-match lyrics with duration in seconds', async () => {
    const fetchLike: FetchLike = async (url, init) => {
      const u = String(url)
      expect(u).toContain('lrclib.net/api/get')
      expect(u).toContain('duration=255')
      expect((init?.headers as Record<string, string>)['User-Agent']).toContain('mixtape')
      return new Response(
        JSON.stringify({ plainLyrics: 'Some words', instrumental: false }),
        { status: 200 },
      )
    }
    const r = await fetchLyrics(
      { title: 'Nude', artist: 'Radiohead', album: 'In Rainbows', durationMs: 255386 },
      fetchLike,
    )
    expect(r).toEqual({ lyrics: 'Some words', instrumental: false })
  })

  it('falls back to search when exact get 404s', async () => {
    const fetchLike: FetchLike = async (url) => {
      const u = String(url)
      if (u.includes('/api/get')) return new Response('', { status: 404 })
      expect(u).toContain('/api/search')
      return new Response(
        JSON.stringify([{ plainLyrics: 'Found via search', instrumental: false }]),
        { status: 200 },
      )
    }
    const r = await fetchLyrics({ title: 'Nude', artist: 'Radiohead', album: null, durationMs: null }, fetchLike)
    expect(r?.lyrics).toBe('Found via search')
  })

  it('flags instrumentals', async () => {
    const fetchLike: FetchLike = async () =>
      new Response(JSON.stringify({ plainLyrics: null, instrumental: true }), { status: 200 })
    const r = await fetchLyrics({ title: 'X', artist: 'Y', album: null, durationMs: 1000 }, fetchLike)
    expect(r).toEqual({ lyrics: null, instrumental: true })
  })

  it('returns null when nothing is found anywhere', async () => {
    const fetchLike: FetchLike = async (url) =>
      String(url).includes('/api/get')
        ? new Response('', { status: 404 })
        : new Response(JSON.stringify([]), { status: 200 })
    expect(await fetchLyrics({ title: 'X', artist: 'Y', album: null, durationMs: null }, fetchLike)).toBeNull()
  })
})
```

- [ ] **Step 2: FAIL**, then **Step 3: Create `server/src/enrich/lrclib.ts`**

```ts
import { EnrichSourceError, type FetchLike } from './itunes'

const UA = { 'User-Agent': 'mixtape/0.1 (personal project; enrichment)' }

export type LyricsKey = { title: string; artist: string; album: string | null; durationMs: number | null }
export type LyricsResult = { lyrics: string | null; instrumental: boolean }

type LrclibRecord = { plainLyrics: string | null; instrumental: boolean }

function toResult(r: LrclibRecord): LyricsResult {
  return { lyrics: r.plainLyrics, instrumental: r.instrumental }
}

export async function fetchLyrics(key: LyricsKey, fetchLike: FetchLike = fetch): Promise<LyricsResult | null> {
  const params = new URLSearchParams({ artist_name: key.artist, track_name: key.title })
  if (key.album) params.set('album_name', key.album)
  if (key.durationMs != null) params.set('duration', String(Math.round(key.durationMs / 1000)))

  const getRes = await fetchLike(`https://lrclib.net/api/get?${params}`, { headers: UA })
  if (getRes.ok) return toResult((await getRes.json()) as LrclibRecord)
  if (getRes.status !== 404) throw new EnrichSourceError('lrclib', `get HTTP ${getRes.status}`)

  const searchParams = new URLSearchParams({ track_name: key.title, artist_name: key.artist })
  const searchRes = await fetchLike(`https://lrclib.net/api/search?${searchParams}`, { headers: UA })
  if (!searchRes.ok) throw new EnrichSourceError('lrclib', `search HTTP ${searchRes.status}`)
  const hits = (await searchRes.json()) as LrclibRecord[]
  return hits.length ? toResult(hits[0]) : null
}
```

- [ ] **Step 4: Create `server/src/enrich/embedder.ts`** (seam; the real one wraps the AI binding)

```ts
// Lyric text passes through here transiently and is never stored or logged.
export type Embedder = (text: string) => Promise<number[]>

type AiBinding = { run(model: string, input: { text: string[] }): Promise<unknown> }

export function workersAiEmbedder(ai: AiBinding): Embedder {
  return async (text) => {
    const out = (await ai.run('@cf/baai/bge-m3', { text: [text.slice(0, 6000)] })) as {
      data?: number[][]
    }
    const vec = out.data?.[0]
    if (!vec || !vec.length) throw new Error(`embedder: unexpected AI response shape: ${Object.keys(out ?? {})}`)
    return vec
  }
}
```

- [ ] **Step 5: Tests + typecheck PASS**, **Step 6: Commit** — `feat(server): lrclib client + embedder seam`

---

### Task 5: Pipeline orchestrator

**Files:**
- Create: `server/src/enrich/pipeline.ts`
- Test: `server/test/enrich/pipeline.test.ts`

- [ ] **Step 1: Write failing test `server/test/enrich/pipeline.test.ts`** — full-fake deps over real PGlite:

```ts
import { describe, it, expect } from 'vitest'
import { createTestDb, type TestDb } from '../helpers/db'
import { enrichTrack, type EnrichDeps } from '../../src/enrich/pipeline'
import { tracks, trackFeatures, trackMeanings, enrichmentFailures } from '../../src/db/schema'
import { eq } from 'drizzle-orm'

const FEATURES = {
  tempo: 128, key: 4, mode: 1, energy: 0.3, danceability: 0.5, valence: 0.2,
  acousticness: 0.8, instrumentalness: 0.6, liveness: 0.1, speechiness: 0.03,
  loudness: -9.8, isrc: 'ISRC123',
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
    const [meaning] = await db.select().from(trackMeanings)
    expect(meaning.embedding).toHaveLength(1024)
    expect(meaning.instrumental).toBe(false)
    const [row] = await db.select().from(tracks).where(eq(tracks.id, t.id))
    expect(row.isrc).toBe('ISRC123')
    expect(row.durationMs).toBe(200000)
    expect(row.genre).toBe('Pop')
  })

  it('instrumental: meaning row without embedding', async () => {
    const db = await createTestDb()
    const t = await seed(db)
    await enrichTrack(db, deps({ lyrics: async () => ({ lyrics: null, instrumental: true }) }), t)
    const [meaning] = await db.select().from(trackMeanings)
    expect(meaning.instrumental).toBe(true)
    expect(meaning.embedding).toBeNull()
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

  it('no lyrics found: meaning recorded as miss', async () => {
    const db = await createTestDb()
    const t = await seed(db)
    const result = await enrichTrack(db, deps({ lyrics: async () => null }), t)
    expect(result.meaning).toBe('miss')
    expect(await db.select().from(trackMeanings)).toHaveLength(0)
  })

  it('does not clobber existing genre', async () => {
    const db = await createTestDb()
    const [t] = await db
      .insert(tracks)
      .values({ appleId: 'a2', title: 'T', artist: 'A', genre: 'Original' })
      .returning()
    await enrichTrack(db, deps(), t)
    const [row] = await db.select().from(tracks).where(eq(tracks.id, t.id))
    expect(row.genre).toBe('Original')
  })
})
```

- [ ] **Step 2: FAIL**, then **Step 3: Create `server/src/enrich/pipeline.ts`**

```ts
import { eq, sql, and } from 'drizzle-orm'
import { tracks, trackFeatures, trackMeanings, enrichmentFailures } from '../db/schema'
import type { Db } from '../db/types'
import type { ItunesHit } from './itunes'
import type { AudioFeatures, TrackKey } from './reccobeats'
import type { LyricsResult, LyricsKey } from './lrclib'
import type { Embedder } from './embedder'

export type EnrichDeps = {
  storefront: string
  itunes: (appleId: string, storefront: string) => Promise<ItunesHit | null>
  features: (key: TrackKey) => Promise<AudioFeatures | null>
  lyrics: (key: LyricsKey) => Promise<LyricsResult | null>
  embed: Embedder
}

export type TrackRow = typeof tracks.$inferSelect
export type StageOutcome = 'ok' | 'miss' | 'error'
export type EnrichResult = { features: StageOutcome; meaning: StageOutcome }

async function recordFailure(db: Db, trackId: string, stage: string, error: string) {
  await db
    .insert(enrichmentFailures)
    .values({ trackId, stage, error: error.slice(0, 500) })
    .onConflictDoUpdate({
      target: [enrichmentFailures.trackId, enrichmentFailures.stage],
      set: { attempts: sql`${enrichmentFailures.attempts} + 1`, error: error.slice(0, 500), lastAt: sql`now()` },
    })
}

async function clearFailure(db: Db, trackId: string, stage: string) {
  await db
    .delete(enrichmentFailures)
    .where(and(eq(enrichmentFailures.trackId, trackId), eq(enrichmentFailures.stage, stage)))
}

export async function enrichTrack(db: Db, deps: EnrichDeps, track: TrackRow): Promise<EnrichResult> {
  // Stage 0: iTunes metadata (duration/genre backfill; duration improves the
  // ReccoBeats and LRCLIB matches below). Best-effort — a miss is not fatal.
  let durationMs = track.durationMs
  try {
    if (track.appleId) {
      const hit = await deps.itunes(track.appleId, deps.storefront)
      if (hit) {
        durationMs = hit.durationMs ?? durationMs
        await db
          .update(tracks)
          .set({
            durationMs: hit.durationMs ?? track.durationMs,
            genre: track.genre ?? hit.genre,
          })
          .where(eq(tracks.id, track.id))
      }
    }
  } catch (e) {
    await recordFailure(db, track.id, 'itunes', String(e))
  }

  // Stage 1: audio features
  let featuresOutcome: StageOutcome
  try {
    const feats = await deps.features({ title: track.title, artist: track.artist, durationMs })
    if (feats) {
      const { isrc, ...cols } = feats
      await db
        .insert(trackFeatures)
        .values({ trackId: track.id, ...cols, source: 'reccobeats' })
        .onConflictDoUpdate({ target: trackFeatures.trackId, set: { ...cols, source: 'reccobeats', fetchedAt: sql`now()` } })
      if (isrc && !track.isrc) await db.update(tracks).set({ isrc }).where(eq(tracks.id, track.id))
      await clearFailure(db, track.id, 'features')
      featuresOutcome = 'ok'
    } else {
      await recordFailure(db, track.id, 'features', 'no acceptable match')
      featuresOutcome = 'miss'
    }
  } catch (e) {
    await recordFailure(db, track.id, 'features', String(e))
    featuresOutcome = 'error'
  }

  // Stage 2: lyric meaning (text passes through transiently — never stored/logged)
  let meaningOutcome: StageOutcome
  try {
    const lyr = await deps.lyrics({ title: track.title, artist: track.artist, album: track.album, durationMs })
    if (!lyr) {
      await recordFailure(db, track.id, 'meaning', 'no lyrics found')
      meaningOutcome = 'miss'
    } else {
      const embedding = lyr.instrumental || !lyr.lyrics ? null : await deps.embed(lyr.lyrics)
      await db
        .insert(trackMeanings)
        .values({ trackId: track.id, embedding, lyricsSource: 'lrclib', instrumental: lyr.instrumental })
        .onConflictDoUpdate({
          target: trackMeanings.trackId,
          set: { embedding, lyricsSource: 'lrclib', instrumental: lyr.instrumental, embeddedAt: sql`now()` },
        })
      await clearFailure(db, track.id, 'meaning')
      meaningOutcome = 'ok'
    }
  } catch (e) {
    await recordFailure(db, track.id, 'meaning', String(e))
    meaningOutcome = 'error'
  }

  return { features: featuresOutcome, meaning: meaningOutcome }
}
```

- [ ] **Step 4: Tests + typecheck PASS** (an instrumental with `lyrics: null` must still count as `'ok'` — it produced a meaning row), **Step 5: Commit** — `feat(server): enrichment pipeline orchestrator`

---

### Task 6: Batch runner + routes (/enrich/run, /enrich/status) + admin guard

**Files:**
- Create: `server/src/enrich/runner.ts`
- Create: `server/src/routes/enrich.ts`
- Create: `server/src/middleware/require-admin.ts`
- Modify: `server/src/app.ts`, `server/src/index.ts`, `server/wrangler.jsonc`
- Test: `server/test/enrich/runner.test.ts`, `server/test/enrich/routes.test.ts`

- [ ] **Step 1: Write failing runner test `server/test/enrich/runner.test.ts`**

```ts
import { describe, it, expect } from 'vitest'
import { createTestDb } from '../helpers/db'
import { runEnrichmentBatch, enrichmentStatus } from '../../src/enrich/runner'
import { tracks, trackFeatures, enrichmentFailures } from '../../src/db/schema'
import type { EnrichDeps } from '../../src/enrich/pipeline'

const okDeps: EnrichDeps = {
  storefront: 'ng',
  itunes: async () => null,
  features: async () => ({
    tempo: 120, key: 1, mode: 1, energy: 0.5, danceability: 0.5, valence: 0.5,
    acousticness: 0.5, instrumentalness: 0.5, liveness: 0.5, speechiness: 0.5,
    loudness: -10, isrc: null,
  }),
  lyrics: async () => ({ lyrics: 'words', instrumental: false }),
  embed: async () => Array.from({ length: 1024 }, () => 0),
}

async function seedTracks(db: Awaited<ReturnType<typeof createTestDb>>, n: number) {
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
    expect(r.remaining).toBe(2)
    expect(await db.select().from(trackFeatures)).toHaveLength(3)
  })

  it('skips tracks that have exhausted their attempts', async () => {
    const db = await createTestDb()
    await seedTracks(db, 1)
    const [t] = await db.select().from(tracks)
    await db.insert(enrichmentFailures).values({ trackId: t.id, stage: 'features', error: 'x', attempts: 3 })
    await db.insert(enrichmentFailures).values({ trackId: t.id, stage: 'meaning', error: 'x', attempts: 3 })
    const r = await runEnrichmentBatch(db, okDeps, 10)
    expect(r.processed).toBe(0)
  })

  it('status reports coverage', async () => {
    const db = await createTestDb()
    await seedTracks(db, 4)
    await runEnrichmentBatch(db, okDeps, 2)
    const s = await enrichmentStatus(db)
    expect(s).toMatchObject({ tracks: 4, withFeatures: 2, withMeaning: 2 })
  })
})
```

- [ ] **Step 2: FAIL**, then **Step 3: Create `server/src/enrich/runner.ts`**

```ts
import { sql } from 'drizzle-orm'
import { tracks } from '../db/schema'
import type { Db } from '../db/types'
import { enrichTrack, type EnrichDeps, type TrackRow } from './pipeline'

const MAX_ATTEMPTS = 3

// Tracks needing work: no features row OR no meanings row, excluding those
// whose corresponding failure stage has exhausted attempts.
const CANDIDATES = sql`
  SELECT t.* FROM tracks t
  LEFT JOIN track_features f ON f.track_id = t.id
  LEFT JOIN track_meanings m ON m.track_id = t.id
  LEFT JOIN enrichment_failures ff ON ff.track_id = t.id AND ff.stage = 'features'
  LEFT JOIN enrichment_failures fm ON fm.track_id = t.id AND fm.stage = 'meaning'
  WHERE (f.track_id IS NULL AND COALESCE(ff.attempts, 0) < ${MAX_ATTEMPTS})
     OR (m.track_id IS NULL AND COALESCE(fm.attempts, 0) < ${MAX_ATTEMPTS})
`

export type BatchResult = { processed: number; features: number; meaning: number; remaining: number }

export async function runEnrichmentBatch(db: Db, deps: EnrichDeps, limit: number): Promise<BatchResult> {
  const batch = (await db.execute(sql`${CANDIDATES} ORDER BY t.created_at LIMIT ${limit}`)) as unknown as {
    rows: Record<string, unknown>[]
  }
  const rows = toTrackRows(batch)
  let features = 0
  let meaning = 0
  for (const track of rows) {
    const r = await enrichTrack(db, deps, track)
    if (r.features === 'ok') features++
    if (r.meaning === 'ok') meaning++
  }
  const remainingRes = (await db.execute(sql`SELECT count(*) AS n FROM (${CANDIDATES}) c`)) as unknown as {
    rows: Array<{ n: number | string }>
  }
  return { processed: rows.length, features, meaning, remaining: Number(remainingRes.rows[0].n) }
}

// Raw SQL returns snake_case; map to the drizzle row shape the pipeline expects.
function toTrackRows(res: { rows: Record<string, unknown>[] }): TrackRow[] {
  return res.rows.map((r) => ({
    id: r.id,
    appleId: r.apple_id,
    isrc: r.isrc,
    title: r.title,
    artist: r.artist,
    album: r.album,
    genre: r.genre,
    durationMs: r.duration_ms,
    createdAt: r.created_at,
  })) as TrackRow[]
}

export async function enrichmentStatus(db: Db) {
  const res = (await db.execute(sql`
    SELECT
      (SELECT count(*) FROM tracks) AS tracks,
      (SELECT count(*) FROM track_features) AS with_features,
      (SELECT count(*) FROM track_meanings) AS with_meaning,
      (SELECT count(*) FROM track_meanings WHERE embedding IS NOT NULL) AS with_embedding,
      (SELECT count(*) FROM enrichment_failures WHERE attempts >= ${MAX_ATTEMPTS}) AS exhausted
  `)) as unknown as { rows: Array<Record<string, number | string>> }
  const r = res.rows[0]
  return {
    tracks: Number(r.tracks),
    withFeatures: Number(r.with_features),
    withMeaning: Number(r.with_meaning),
    withEmbedding: Number(r.with_embedding),
    exhausted: Number(r.exhausted),
  }
}
```

(Note: `db.execute` result shape differs between neon-http and pglite drivers — if `.rows` isn't present on one of them, normalize inside a tiny helper and report the actual shapes you found. Tests on PGlite plus a live status call in Task 8 cover both drivers.)

- [ ] **Step 4: Write failing routes test `server/test/enrich/routes.test.ts`** — createApp gains optional `enrich` wiring; admin guard via `X-Admin-Token`:

```ts
import { describe, it, expect } from 'vitest'
import { createTestDb } from '../helpers/db'
import { createApp, type AuthLike } from '../../src/app'
import { tracks } from '../../src/db/schema'
import type { EnrichDeps } from '../../src/enrich/pipeline'

const auth: AuthLike = { handler: () => new Response('ok'), api: { getSession: async () => null } }

const fakeDeps: EnrichDeps = {
  storefront: 'ng',
  itunes: async () => null,
  features: async () => null,
  lyrics: async () => null,
  embed: async () => [],
}

describe('/enrich routes', () => {
  it('rejects without the admin token', async () => {
    const db = await createTestDb()
    const app = createApp({ auth, db, enrich: { deps: fakeDeps, adminToken: 'secret' } })
    expect((await app.request('http://x/enrich/status')).status).toBe(401)
    expect((await app.request('http://x/enrich/run', { method: 'POST' })).status).toBe(401)
  })

  it('runs a batch and reports status with the token', async () => {
    const db = await createTestDb()
    await db.insert(tracks).values({ appleId: 'r1', title: 'T', artist: 'A' })
    const app = createApp({ auth, db, enrich: { deps: fakeDeps, adminToken: 'secret' } })
    const run = await app.request('http://x/enrich/run?limit=5', {
      method: 'POST',
      headers: { 'X-Admin-Token': 'secret' },
    })
    expect(run.status).toBe(200)
    expect(await run.json()).toMatchObject({ processed: 1 })
    const status = await app.request('http://x/enrich/status', { headers: { 'X-Admin-Token': 'secret' } })
    expect(status.status).toBe(200)
    expect(await status.json()).toMatchObject({ tracks: 1 })
  })
})
```

- [ ] **Step 5: Create `server/src/middleware/require-admin.ts`**

```ts
import { createMiddleware } from 'hono/factory'

export function requireAdmin(adminToken: string) {
  return createMiddleware(async (c, next) => {
    const provided = c.req.header('X-Admin-Token')
    if (!provided || provided !== adminToken) return c.json({ error: 'unauthorized' }, 401)
    await next()
  })
}
```

- [ ] **Step 6: Create `server/src/routes/enrich.ts`**

```ts
import { Hono } from 'hono'
import type { Db } from '../db/types'
import type { EnrichDeps } from '../enrich/pipeline'
import { runEnrichmentBatch, enrichmentStatus } from '../enrich/runner'

// Batch ceiling keeps one invocation within Workers subrequest limits
// (~5 external calls per track).
const MAX_BATCH = 8

export function enrichRoutes(db: Db, deps: EnrichDeps) {
  const app = new Hono()

  app.post('/run', async (c) => {
    const limit = Math.min(MAX_BATCH, Math.max(1, Number(c.req.query('limit') ?? MAX_BATCH)))
    return c.json(await runEnrichmentBatch(db, deps, limit))
  })

  app.get('/status', async (c) => c.json(await enrichmentStatus(db)))

  return app
}
```

- [ ] **Step 7: Wire `server/src/app.ts`** — extend the signature:

```ts
export type EnrichWiring = { deps: EnrichDeps; adminToken: string }
export function createApp({ auth, db, enrich }: { auth: AuthLike; db?: Db; enrich?: EnrichWiring }) {
  // after the ingest mount, add:
  if (db && enrich) {
    app.use('/enrich/*', requireAdmin(enrich.adminToken))
    app.route('/enrich', enrichRoutes(db, enrich.deps))
  }
}
```

Update the roadmap comment: `/enrich/* [P2]`.

- [ ] **Step 8: Wire `server/src/index.ts`** — Bindings gain `ENRICH_ADMIN_TOKEN: string` and `AI: { run(model: string, input: { text: string[] }): Promise<unknown> }`; `ITUNES_STOREFRONT?: string`. Build real deps:

```ts
import { lookupItunes } from './enrich/itunes'
import { resolveAndFetchFeatures } from './enrich/reccobeats'
import { fetchLyrics } from './enrich/lrclib'
import { workersAiEmbedder } from './enrich/embedder'

// inside fetch():
const enrich = env.ENRICH_ADMIN_TOKEN
  ? {
      adminToken: env.ENRICH_ADMIN_TOKEN,
      deps: {
        storefront: env.ITUNES_STOREFRONT ?? 'ng',
        itunes: lookupItunes,
        features: resolveAndFetchFeatures,
        lyrics: fetchLyrics,
        embed: workersAiEmbedder(env.AI),
      },
    }
  : undefined
const app = createApp({ auth, db, enrich })
```

- [ ] **Step 9: `server/wrangler.jsonc`** — add `"ai": { "binding": "AI" }` and extend the secrets comment with `ENRICH_ADMIN_TOKEN` (+ optional var `ITUNES_STOREFRONT`, default ng).

- [ ] **Step 10: All tests + typecheck PASS** (existing createApp call sites compile — `enrich` optional), **Step 11: Commit** — `feat(server): enrichment runner + admin routes`

---

### Task 7: Cron trigger for steady-state enrichment

**Files:**
- Modify: `server/src/index.ts`, `server/wrangler.jsonc`
- Test: `server/test/enrich/scheduled.test.ts`

- [ ] **Step 1: Write failing test** — extract a `handleScheduled(db, deps)` from index wiring so it's testable:

```ts
import { describe, it, expect } from 'vitest'
import { createTestDb } from '../helpers/db'
import { handleScheduled } from '../../src/enrich/scheduled'
import { tracks, trackFeatures } from '../../src/db/schema'
// reuse okDeps shape from runner.test — import a shared fixture or redefine inline

it('scheduled run processes a small batch', async () => {
  const db = await createTestDb()
  await db.insert(tracks).values({ appleId: 'c1', title: 'T', artist: 'A' })
  await handleScheduled(db, okDeps)
  expect(await db.select().from(trackFeatures)).toHaveLength(1)
})
```

(Move the shared `okDeps` fixture into `server/test/helpers/enrich-fixtures.ts` and import from both test files — DRY.)

- [ ] **Step 2: Create `server/src/enrich/scheduled.ts`**

```ts
import type { Db } from '../db/types'
import type { EnrichDeps } from './pipeline'
import { runEnrichmentBatch } from './runner'

const CRON_BATCH = 8

export async function handleScheduled(db: Db, deps: EnrichDeps) {
  return runEnrichmentBatch(db, deps, CRON_BATCH)
}
```

- [ ] **Step 3: Wire `server/src/index.ts`** — add a `scheduled` handler to the default export that builds db + deps the same way fetch does (extract a small `buildEnv(env)` helper to avoid duplication) and calls `handleScheduled`; add to `wrangler.jsonc`: `"triggers": { "crons": ["*/5 * * * *"] }`.

- [ ] **Step 4: Tests + typecheck PASS**, worker boots (`npx wrangler dev` smoke on /health), **Step 5: Commit** — `feat(server): enrichment cron`

---

### Task 8: Deploy + live backfill + coverage report

**Files:**
- Create: `scripts/backfill.sh`
- Modify: `docs/decisions.md`, `README.md` (status)

- [ ] **Step 1: Create `scripts/backfill.sh`**

```bash
#!/usr/bin/env bash
# Drives the enrichment backfill by hammering /enrich/run until nothing remains.
# Usage: ENRICH_ADMIN_TOKEN=... ./scripts/backfill.sh [api-base]
set -euo pipefail
BASE="${1:-https://mixtape-api.goalympics.workers.dev}"
: "${ENRICH_ADMIN_TOKEN:?set ENRICH_ADMIN_TOKEN}"

while :; do
  OUT=$(curl -sf -X POST "$BASE/enrich/run?limit=8" -H "X-Admin-Token: $ENRICH_ADMIN_TOKEN")
  echo "$(date +%H:%M:%S) $OUT"
  REMAINING=$(echo "$OUT" | sed -n 's/.*"remaining":\([0-9]*\).*/\1/p')
  [ "${REMAINING:-0}" -le 0 ] && break
  sleep 1
done
curl -sf "$BASE/enrich/status" -H "X-Admin-Token: $ENRICH_ADMIN_TOKEN"
echo
```

`chmod +x scripts/backfill.sh`.

- [ ] **Step 2: Deploy**

```bash
cd server
npx drizzle-kit migrate            # DATABASE_URL from .dev.vars (0003: extension + tables)
openssl rand -hex 24 | npx wrangler secret put ENRICH_ADMIN_TOKEN
npx wrangler deploy
```

Record the generated admin token in `server/.dev.vars` as `ENRICH_ADMIN_TOKEN=` too (git-ignored) so scripts can read it.

- [ ] **Step 3: Live smoke** — one batch by hand, inspect the result:

```bash
TOKEN=$(grep '^ENRICH_ADMIN_TOKEN=' server/.dev.vars | cut -d= -f2-)
curl -s -X POST "https://mixtape-api.goalympics.workers.dev/enrich/run?limit=3" -H "X-Admin-Token: $TOKEN"
curl -s "https://mixtape-api.goalympics.workers.dev/enrich/status" -H "X-Admin-Token: $TOKEN"
```

Expected: processed 3, status shows withFeatures/withMeaning ≥ the batch's ok counts. Then spot-check Neon: a `track_features` row has plausible tempo/energy; a `track_meanings.embedding` is non-null; NO lyric text anywhere.

- [ ] **Step 4: Run the full backfill** — `ENRICH_ADMIN_TOKEN=$TOKEN ./scripts/backfill.sh` (4,689 tracks ≈ 590 batches; expect roughly 1–2 hours; it's resumable — re-run anytime, it picks up where it left off). Watch for Workers AI free-tier neuron exhaustion (embeddings stop succeeding): if hit, the failure rows record it and a next-day rerun finishes the tail — note whatever happened in the report.

- [ ] **Step 5: Coverage report + decision** — from `/enrich/status` compute features coverage (withFeatures/tracks) and meaning coverage. Record in `docs/decisions.md` under a dated entry, including the decision this gates: **if features coverage < 80%, P2.5 adds the local preview-analysis leg; otherwise it stays deferred.** Update `README.md` status to "P2 enrichment live; backfill at X%". Commit — `docs: p2 backfill coverage report`.

---

## Out of scope for P2 (resist)

- Theme-tag derivation from lyrics (P3 — needs the curation prompt design; embeddings are enough for matching)
- Local preview-audio analysis leg (P2.5, gated on the Task 8 coverage number)
- HNSW/IVF vector index (add in P3 when similarity queries exist; trivial migration on this data size)
- Recently-played / recommendations ingestion, in_library reconciliation (still P2-backlog → now P3-backlog)
- Any client UI for enrichment
