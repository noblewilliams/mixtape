import { describe, it, expect, vi } from 'vitest'
import { eq } from 'drizzle-orm'
import { createTestDb, type TestDb } from '../helpers/db'
import { djSessions, trackFeatures, trackMeanings, tracks, user, userTracks } from '../../src/db/schema'
import {
  runDjTurn,
  CORPUS_NOTICE,
  onlyArtistExhaustedNotice,
  onlyArtistNotFoundNotice,
  onlyArtistShortNotice,
  resolveOnlyArtist,
} from '../../src/dj/loop'
import { PROPOSE_SYSTEM_PROMPT } from '../../src/dj/propose'
import { fillForArtist, FILL_BUDGET, FILL_PER_ARTIST, ONLY_ARTIST_FILL, type FillDeps } from '../../src/dj/catalogue-fill'
import { creditedKeys } from '../../src/dj/artist-keys'
import { curate, NAMED_ARTISTS_RULE_PREFIX, ONLY_ARTIST_RULE_PREFIX } from '../../src/dj/curate'
import type { CatalogSong } from '../../src/musickit/catalog'
import type { LlmClient, LlmRequest, LlmTurn } from '../../src/dj/llm'
import type { PoolTrack } from '../../src/dj/pool'

// Artist-only mixes (spec 2026-11-09 one-platform-play, decision 5): golden
// structural assertions, never exact tracks.

const DIMS = 1024
const UNIT = Array.from({ length: DIMS }, (_, i) => (i === 0 ? 1 : 0))
const embedFake = async () => UNIT
let counter = 0

async function seedUser(db: TestDb, id = 'u1') {
  await db.insert(user).values({ id, name: id, email: `${id}@example.com`, emailVerified: false, createdAt: new Date(), updatedAt: new Date() })
}

async function seedSession(db: TestDb, userId = 'u1') {
  const [s] = await db.insert(djSessions).values({ userId, title: 's' }).returning()
  return s
}

// n rows credited to `artist`. `owner` puts them in that listener's library;
// `enriched` false leaves them as a fill would before enrichment.
async function seedTracks(db: TestDb, artist: string, n: number, opts: { owner?: string; enriched?: boolean } = {}) {
  for (let i = 0; i < n; i++) {
    counter += 1
    const [t] = await db.insert(tracks).values({ appleId: `apple-${counter}`, title: `${artist} song ${counter}`, artist, durationMs: 200_000 }).returning()
    if (opts.enriched !== false) {
      await db.insert(trackFeatures).values({ trackId: t.id, tempo: 100, energy: 0.5, valence: 0.5, source: 'reccobeats' })
      await db.insert(trackMeanings).values({ trackId: t.id, embedding: UNIT, lyricsSource: 'lrclib' })
    }
    if (opts.owner) await db.insert(userTracks).values({ userId: opts.owner, trackId: t.id, inLibrary: true })
  }
}

function curateFake(req: LlmRequest): LlmTurn {
  const blocks = req.messages[0].content as Array<{ text?: string }>
  const ids = Array.from((blocks[0]?.text ?? '').matchAll(/^([0-9a-f-]{36}) \|/gm)).map((m) => m[1])
  const count = Number((blocks[1]?.text ?? '').match(/Pick up to (\d+) tracks/)?.[1] ?? ids.length)
  const text = JSON.stringify(ids.slice(0, count).map((id) => ({ id, reason: 'fits' })))
  return { text, toolCalls: [], raw: [{ type: 'text', text }], stopReason: 'end_turn', usage: null }
}

// One tool call (generate_queue or edit_queue with `input`), then a reply.
function scriptedLlm(tool: 'generate_queue' | 'edit_queue', input: unknown) {
  const requests: LlmRequest[] = []
  let conv = 0
  const llm: LlmClient = async (req) => {
    requests.push(req)
    if (req.system === PROPOSE_SYSTEM_PROMPT) {
      return { text: '[]', toolCalls: [], raw: [{ type: 'text', text: '[]' }], stopReason: 'end_turn', usage: null }
    }
    if (req.tools.length === 0) return curateFake(req)
    conv += 1
    if (conv === 1) {
      const call = { id: 'c1', name: tool, input }
      return { text: '', toolCalls: [call], raw: [{ type: 'tool_use', ...call }], stopReason: 'tool_use', usage: null }
    }
    return { text: 'here you go.', toolCalls: [], raw: [{ type: 'text', text: 'here you go.' }], stopReason: 'end_turn', usage: null }
  }
  return { llm, requests }
}

const curationRequests = (requests: LlmRequest[]) => requests.filter((r) => r.tools.length === 0 && r.system !== PROPOSE_SYSTEM_PROMPT)
const proposalRequests = (requests: LlmRequest[]) => requests.filter((r) => r.system === PROPOSE_SYSTEM_PROMPT)
const intentBlock = (req: LlmRequest) => ((req.messages[0].content as Array<{ text: string }>)[1]).text

function toolResults(requests: LlmRequest[]): string[] {
  const last = requests.filter((r) => r.tools.length > 0).at(-1)!
  return last.messages
    .filter((m) => m.role === 'user' && Array.isArray(m.content) && (m.content[0] as { type?: string }).type === 'tool_result')
    .map((m) => (m.content as Array<{ content: string }>)[0].content)
}

const credits = (artist: string, key: string) => creditedKeys(artist).includes(key)

function song(appleId: string, title: string, artist: string): CatalogSong {
  return { appleId, isrc: null, title, artist, album: 'Album', artwork: null, durationMs: 200_000, genre: 'Hip-Hop', releaseYear: 2016, explicit: false }
}

// Apple knows Drake: 25 top songs, a few of them features.
function drakeApple() {
  const topLimits: number[] = []
  const enrichCalls = { features: 0 }
  const catalog: FillDeps['catalog'] = {
    async searchArtists(_sf, term) {
      return term === 'Drake' ? [{ id: 'a-drake', name: 'Drake', genres: [] }] : []
    },
    async artistTopSongs(_sf, _id, limit) {
      topLimits.push(limit)
      return Array.from({ length: 25 }, (_, i) => song(`drake-${i}`, `Drake Top ${i}`, i % 5 === 0 ? 'Future & Drake' : 'Drake')).slice(0, limit)
    },
    async searchSongs() {
      return []
    },
  }
  const fill: FillDeps = {
    catalog,
    defaultStorefront: 'us',
    enrich: {
      storefront: 'us',
      itunes: async () => null,
      features: async () => { enrichCalls.features += 1; return null },
      lyrics: async () => null,
      embed: async () => UNIT,
    },
  }
  return { fill, topLimits, enrichCalls }
}

async function withLog<T>(fn: () => Promise<T>): Promise<{ value: T; logged: Record<string, unknown> }> {
  const log = vi.spyOn(console, 'log').mockImplementation(() => {})
  try {
    const value = await fn()
    const line = log.mock.calls.find((c) => c[0] === 'dj turn')!
    return { value, logged: JSON.parse(line[1] as string) }
  } finally {
    log.mockRestore()
  }
}

describe('resolveOnlyArtist', () => {
  it('takes the one artist the brief is about', () => {
    expect(resolveOnlyArtist({ onlyArtist: 'J. Cole', namedArtists: ['J. Cole'] })).toEqual({ name: 'J. Cole', key: 'jcole' })
    expect(resolveOnlyArtist({ onlyArtist: 'Drake' })).toEqual({ name: 'Drake', key: 'drake' })
  })

  it('a second named artist means the brief is not about one artist', () => {
    expect(resolveOnlyArtist({ onlyArtist: 'J. Cole', namedArtists: ['J. Cole', 'Kendrick Lamar'] })).toBeUndefined()
  })

  it('another spelling of the same artist is not a second artist', () => {
    expect(resolveOnlyArtist({ onlyArtist: 'J. Cole', namedArtists: ['J Cole', 'j. cole', 'J.COLE'] })).toEqual({ name: 'J. Cole', key: 'jcole' })
  })

  it('keys are compared whole: a name that contains the artist\'s is another artist', () => {
    expect(resolveOnlyArtist({ onlyArtist: 'Drake', namedArtists: ['Drake', 'Drakeo the Ruler'] })).toBeUndefined()
    expect(resolveOnlyArtist({ onlyArtist: 'J. Cole', namedArtists: ['Cole'] })).toBeUndefined()
  })

  it('nothing set, or a name with no letters, is no scope', () => {
    expect(resolveOnlyArtist({ namedArtists: ['J. Cole'] })).toBeUndefined()
    expect(resolveOnlyArtist({ onlyArtist: '...' })).toBeUndefined()
  })
})

describe('curate in artist-only mode', () => {
  const pool: PoolTrack[] = Array.from({ length: 4 }, (_, i) => ({
    trackId: `00000000-0000-4000-8000-00000000000${i}`, appleId: `a${i}`, spotifyId: null, title: `T${i}`, artist: 'J. Cole', playCount: null,
    tempo: null, energy: null, valence: null, releaseYear: null, durationMs: null, score: 1, outside: false,
  }))

  it('lifts the spread rule in the intent block and keeps the cached system prompt', async () => {
    const requests: LlmRequest[] = []
    const llm: LlmClient = async (req) => { requests.push(req); return curateFake(req) }
    const intent = { themes: 'bars', allowExplicit: true, familiarity: 'mix' as const, targetCount: 4 }
    await curate(llm, pool, intent, undefined, { onlyArtist: 'J. Cole' })
    await curate(llm, pool, intent)
    expect(intentBlock(requests[0])).toContain(ONLY_ARTIST_RULE_PREFIX)
    expect(intentBlock(requests[0])).toContain('J. Cole')
    expect(intentBlock(requests[1])).not.toContain(ONLY_ARTIST_RULE_PREFIX)
    expect(requests[0].system).toBe(requests[1].system)
  })
})

describe('artist-only mixes through runDjTurn', () => {
  it('golden: "Cole I can rap to" for a personal listener is J. Cole only, short and said so, features counted', async () => {
    const db = await createTestDb()
    await seedUser(db)
    // The library: a little Cole, a lot of his neighbours.
    await seedTracks(db, 'J. Cole', 3, { owner: 'u1' })
    await seedTracks(db, 'Kendrick Lamar feat. J. Cole', 1, { owner: 'u1' })
    for (const other of ['Kendrick Lamar', 'Baby Keem', 'Travis Scott', 'Childish Gambino']) await seedTracks(db, other, 4, { owner: 'u1' })
    // The shared catalogue: more Cole, one unenriched, and a near-miss name.
    await seedTracks(db, 'J. Cole', 2)
    await seedTracks(db, 'J. Cole', 1, { enriched: false })
    await seedTracks(db, 'J. Coleman', 2)
    const session = await seedSession(db)
    const { llm, requests } = scriptedLlm('generate_queue', { themes: 'hard bars to rap along to', targetCount: 15, onlyArtist: 'J. Cole', namedArtists: ['J. Cole'] })

    const result = await runDjTurn(db, { llm, embed: embedFake }, { id: session.id, userId: 'u1' }, 'Cole I can rap to')

    expect(result.queue).toHaveLength(7)
    for (const t of result.queue) expect(credits(t.artist, 'jcole')).toBe(true)
    const [curation] = curationRequests(requests)
    expect(intentBlock(curation)).toContain('Pick up to 7 tracks.')
    expect(intentBlock(curation)).toContain(ONLY_ARTIST_RULE_PREFIX)
    const [text] = toolResults(requests)
    expect(text).toContain(onlyArtistShortNotice('J. Cole', 7, 15))
    // The catalogue songs are new to them, and the DJ is told.
    expect(text).toContain('does not have yet')
    expect(text).not.toContain(CORPUS_NOTICE)
  })

  it('a pool deeper than the target is a full mix of that artist with no short notice', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedTracks(db, 'SZA', 12, { owner: 'u1' })
    await seedTracks(db, 'Summer Walker', 12, { owner: 'u1' })
    const session = await seedSession(db)
    const { llm, requests } = scriptedLlm('generate_queue', { themes: 'sza songs', targetCount: 10, onlyArtist: 'SZA' })

    const result = await runDjTurn(db, { llm, embed: embedFake }, { id: session.id, userId: 'u1' }, 'SZA songs')

    expect(result.queue).toHaveLength(10)
    for (const t of result.queue) expect(credits(t.artist, 'sza')).toBe(true)
    expect(toolResults(requests)[0]).not.toContain('could be found')
  })

  it('a personal listener\'s artist-only mix clears a catalogue session\'s label, catalogue songs and all', async () => {
    // Spec 2026-11-09 add-your-music-loop, decision 4: the label follows the
    // pool mode, not whether every song is owned.
    const db = await createTestDb()
    await seedUser(db)
    await seedTracks(db, 'J. Cole', 3, { owner: 'u1' })
    await seedTracks(db, 'J. Cole', 4)
    const session = await seedSession(db)
    await db.update(djSessions).set({ notPersonal: true }).where(eq(djSessions.id, session.id))
    const { llm, requests } = scriptedLlm('generate_queue', { themes: 'cole', targetCount: 6, onlyArtist: 'J. Cole' })

    const result = await runDjTurn(db, { llm, embed: embedFake }, { id: session.id, userId: 'u1' }, 'just J. Cole')

    const [row] = await db.select({ notPersonal: djSessions.notPersonal }).from(djSessions).where(eq(djSessions.id, session.id))
    expect(row.notPersonal).toBe(false)
    expect(result.queue).toHaveLength(6)
    expect(result.queue.some((t) => t.newToYou)).toBe(true)
    expect(toolResults(requests)[0]).not.toContain(CORPUS_NOTICE)
  })

  it('allowOutside false keeps an artist-only mix to their own copies', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedTracks(db, 'J. Cole', 3, { owner: 'u1' })
    await seedTracks(db, 'Baby Keem', 5, { owner: 'u1' })
    await seedTracks(db, 'J. Cole', 4)
    const session = await seedSession(db)
    const { llm } = scriptedLlm('generate_queue', { themes: 'cole', targetCount: 10, onlyArtist: 'J. Cole', allowOutside: false })

    const result = await runDjTurn(db, { llm, embed: embedFake }, { id: session.id, userId: 'u1' }, 'just my J. Cole')

    expect(result.queue).toHaveLength(3)
    for (const t of result.queue) expect(t.newToYou).toBe(false)
  })

  it('golden: "just Drake" from a listener with no library fills Drake from Apple past the usual allowance', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const session = await seedSession(db)
    const { fill, topLimits } = drakeApple()
    const { llm, requests } = scriptedLlm('generate_queue', { themes: 'drake', targetCount: 15, onlyArtist: 'Drake', namedArtists: ['Drake'] })

    const { value: result, logged } = await withLog(() =>
      runDjTurn(db, { llm, embed: embedFake, fill }, { id: session.id, userId: 'u1' }, 'just Drake'))

    expect(topLimits).toEqual([ONLY_ARTIST_FILL])
    expect(ONLY_ARTIST_FILL).toBeGreaterThan(FILL_PER_ARTIST)
    expect(result.queue).toHaveLength(15)
    for (const t of result.queue) expect(credits(t.artist, 'drake')).toBe(true)
    expect((logged.fill as { subrequests: number }).subrequests).toBeLessThanOrEqual(FILL_BUDGET)
    expect(toolResults(requests)[0].split('\n')[0]).toBe(CORPUS_NOTICE)
    const [row] = await db.select({ notPersonal: djSessions.notPersonal }).from(djSessions).where(eq(djSessions.id, session.id))
    expect(row.notPersonal).toBe(true)
  })

  it('with NEVER_REFUSE on, a found artist is curated from their songs, not proposed', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const session = await seedSession(db)
    const { fill, enrichCalls } = drakeApple()
    const { llm, requests } = scriptedLlm('generate_queue', { themes: 'drake', targetCount: 12, onlyArtist: 'Drake' })

    const result = await runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: true }, { id: session.id, userId: 'u1' }, 'just Drake')

    expect(result.queue).toHaveLength(12)
    for (const t of result.queue) expect(credits(t.artist, 'drake')).toBe(true)
    expect(proposalRequests(requests)).toHaveLength(0)
    // The never-refuse rule for the fill holds: the subrequests stay free.
    expect(enrichCalls.features).toBe(0)
  })

  it('an artist with no songs anywhere falls back to today\'s mix and the DJ is told it could not find them', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedTracks(db, 'Mine', 8, { owner: 'u1' })
    const session = await seedSession(db)
    const { fill } = drakeApple()
    const { llm, requests } = scriptedLlm('generate_queue', { themes: 'obscure', targetCount: 5, onlyArtist: 'Nobody Known' })

    const result = await runDjTurn(db, { llm, embed: embedFake, fill }, { id: session.id, userId: 'u1' }, 'just Nobody Known')

    expect(result.queue).toHaveLength(5)
    const [text] = toolResults(requests)
    expect(text.split('\n')[0]).toBe(onlyArtistNotFoundNotice('Nobody Known'))
    expect(intentBlock(curationRequests(requests)[0])).not.toContain(ONLY_ARTIST_RULE_PREFIX)
  })
})

describe('controls: "like X" and two artists are today', () => {
  async function coleLibrary() {
    const db = await createTestDb()
    await seedUser(db)
    await seedTracks(db, 'J. Cole', 3, { owner: 'u1' })
    for (const other of ['Kendrick Lamar', 'Baby Keem', 'Travis Scott']) await seedTracks(db, other, 4, { owner: 'u1' })
    return db
  }

  it('"artists like J. Cole" (named, not only) draws from the whole library', async () => {
    const db = await coleLibrary()
    const session = await seedSession(db)
    const { llm, requests } = scriptedLlm('generate_queue', { themes: 'conscious rap', targetCount: 10, namedArtists: ['J. Cole'] })

    const result = await runDjTurn(db, { llm, embed: embedFake }, { id: session.id, userId: 'u1' }, 'artists like J. Cole')

    expect(result.queue).toHaveLength(10)
    expect(result.queue.some((t) => !credits(t.artist, 'jcole'))).toBe(true)
    expect(intentBlock(curationRequests(requests)[0])).not.toContain(ONLY_ARTIST_RULE_PREFIX)
    expect(toolResults(requests)[0]).not.toContain('could be found')
  })

  it('two artists named, even with onlyArtist set, is today\'s mix', async () => {
    const db = await coleLibrary()
    const session = await seedSession(db)
    const { llm, requests } = scriptedLlm('generate_queue', { themes: 'rap', targetCount: 10, onlyArtist: 'J. Cole', namedArtists: ['J. Cole', 'Kendrick Lamar'] })

    const result = await runDjTurn(db, { llm, embed: embedFake }, { id: session.id, userId: 'u1' }, 'J. Cole and Kendrick')

    expect(result.queue).toHaveLength(10)
    expect(result.queue.some((t) => !credits(t.artist, 'jcole'))).toBe(true)
    expect(intentBlock(curationRequests(requests)[0])).not.toContain(ONLY_ARTIST_RULE_PREFIX)
  })
})

describe('edits keep an artist-only session\'s scope', () => {
  async function coleMix(coleSongs: number) {
    const db = await createTestDb()
    await seedUser(db)
    await seedTracks(db, 'J. Cole', coleSongs, { owner: 'u1' })
    for (const other of ['Kendrick Lamar', 'Baby Keem']) await seedTracks(db, other, 6, { owner: 'u1' })
    const session = await seedSession(db)
    const { llm } = scriptedLlm('generate_queue', { themes: 'cole', targetCount: 5, onlyArtist: 'J. Cole' })
    await runDjTurn(db, { llm, embed: embedFake }, { id: session.id, userId: 'u1' }, 'Cole I can rap to')
    return { db, session }
  }

  it('a later turn\'s "add more" with no intent extends with that artist', async () => {
    const { db, session } = await coleMix(12)
    const { llm, requests } = scriptedLlm('edit_queue', { ops: [{ op: 'extend', count: 4 }] })

    const result = await runDjTurn(db, { llm, embed: embedFake }, { id: session.id, userId: 'u1' }, 'add more')

    expect(result.queue).toHaveLength(9)
    for (const t of result.queue) expect(credits(t.artist, 'jcole')).toBe(true)
    expect(intentBlock(curationRequests(requests)[0])).toContain(ONLY_ARTIST_RULE_PREFIX)
  })

  it('"make it longer" past what the artist has adds what there is and says so', async () => {
    const { db, session } = await coleMix(7)
    const { llm, requests } = scriptedLlm('edit_queue', { ops: [{ op: 'extend', count: 6 }] })

    const result = await runDjTurn(db, { llm, embed: embedFake }, { id: session.id, userId: 'u1' }, 'make it longer')

    expect(result.queue).toHaveLength(7)
    for (const t of result.queue) expect(credits(t.artist, 'jcole')).toBe(true)
    expect(toolResults(requests)[0]).toContain(onlyArtistExhaustedNotice('J. Cole'))
  })

  it('the generate records the scope on the session, and a later mix that is not artist-only clears it', async () => {
    const { db, session } = await coleMix(12)
    const scope = async () => (await db.select({ a: djSessions.onlyArtist }).from(djSessions).where(eq(djSessions.id, session.id)))[0].a
    expect(await scope()).toBe('J. Cole')

    const { llm } = scriptedLlm('generate_queue', { themes: 'anything', targetCount: 5 })
    await runDjTurn(db, { llm, embed: embedFake }, { id: session.id, userId: 'u1' }, 'something else now')
    expect(await scope()).toBeNull()

    const extend = scriptedLlm('edit_queue', { ops: [{ op: 'extend', count: 4 }] })
    await runDjTurn(db, { llm: extend.llm, embed: embedFake }, { id: session.id, userId: 'u1' }, 'add more')
    expect(intentBlock(curationRequests(extend.requests)[0])).not.toContain(ONLY_ARTIST_RULE_PREFIX)
  })

  it('a one-artist queue that was not asked as artist-only is not scoped', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedTracks(db, 'Mine', 10, { owner: 'u1' })
    const session = await seedSession(db)
    await runDjTurn(db, { llm: scriptedLlm('generate_queue', { themes: 'x', targetCount: 5 }).llm, embed: embedFake }, { id: session.id, userId: 'u1' }, 'play')
    const { llm, requests } = scriptedLlm('edit_queue', { ops: [{ op: 'extend', count: 2 }] })

    await runDjTurn(db, { llm, embed: embedFake }, { id: session.id, userId: 'u1' }, 'add more')

    expect(intentBlock(curationRequests(requests)[0])).not.toContain(ONLY_ARTIST_RULE_PREFIX)
  })

  it('"swap 3 for something darker": an op intent without onlyArtist inherits the scope', async () => {
    const { db, session } = await coleMix(12)
    const { llm, requests } = scriptedLlm('edit_queue', { ops: [{ op: 'swap', position: 2, intent: { themes: 'something darker' } }] })

    const result = await runDjTurn(db, { llm, embed: embedFake }, { id: session.id, userId: 'u1' }, 'swap 3 for something darker')

    expect(result.queue).toHaveLength(5)
    for (const t of result.queue) expect(credits(t.artist, 'jcole')).toBe(true)
    expect(intentBlock(curationRequests(requests)[0])).toContain(ONLY_ARTIST_RULE_PREFIX)
  })

  it('an op intent naming the same artist, however spelt, stays in scope', async () => {
    const { db, session } = await coleMix(12)
    const { llm, requests } = scriptedLlm('edit_queue', { ops: [{ op: 'extend', count: 2, intent: { themes: 'more', namedArtists: ['j cole'] } }] })

    const result = await runDjTurn(db, { llm, embed: embedFake }, { id: session.id, userId: 'u1' }, 'more j cole')

    for (const t of result.queue) expect(credits(t.artist, 'jcole')).toBe(true)
    expect(intentBlock(curationRequests(requests)[0])).toContain(ONLY_ARTIST_RULE_PREFIX)
  })

  // Spec 2026-11-09 every-song-earns-its-place, decision 3: stepping out of
  // the scope lands in the named artist's own songs, not the whole library.
  it('"add some Kendrick": an op intent naming a different artist steps outside the scope, into Kendrick\'s', async () => {
    const { db, session } = await coleMix(12)
    const { llm, requests } = scriptedLlm('edit_queue', { ops: [{ op: 'extend', count: 4, intent: { themes: 'kendrick lamar', namedArtists: ['Kendrick Lamar'] } }] })

    const result = await runDjTurn(db, { llm, embed: embedFake }, { id: session.id, userId: 'u1' }, 'add some Kendrick')

    expect(intentBlock(curationRequests(requests)[0])).not.toContain(ONLY_ARTIST_RULE_PREFIX)
    expect(intentBlock(curationRequests(requests)[0])).toContain(NAMED_ARTISTS_RULE_PREFIX)
    expect(result.queue.slice(5)).toHaveLength(4)
    for (const t of result.queue.slice(5)) expect(credits(t.artist, 'kendricklamar')).toBe(true)
  })

  it('an op intent with its own onlyArtist uses that artist', async () => {
    const { db, session } = await coleMix(12)
    const { llm, requests } = scriptedLlm('edit_queue', { ops: [{ op: 'extend', count: 3, intent: { themes: 'baby keem', onlyArtist: 'Baby Keem' } }] })

    const result = await runDjTurn(db, { llm, embed: embedFake }, { id: session.id, userId: 'u1' }, 'three Baby Keem songs at the end')

    expect(result.queue.slice(5).every((t) => credits(t.artist, 'babykeem'))).toBe(true)
    expect(intentBlock(curationRequests(requests)[0])).toContain('Baby Keem')
  })
})

describe('fillForArtist', () => {
  it('runs for a personal listener too, unlike the seed fill', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedTracks(db, 'Mine', 3, { owner: 'u1' })
    const { fill, topLimits } = drakeApple()

    const result = await fillForArtist(db, fill, { userId: 'u1', name: 'Drake' })

    expect(topLimits).toEqual([ONLY_ARTIST_FILL])
    expect(result.inserted).toBe(25)
    expect(result.subrequests).toBeLessThanOrEqual(FILL_BUDGET)
  })

  it('skips Apple once the catalogue holds the allowance for that artist', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedTracks(db, 'Drake', ONLY_ARTIST_FILL)
    const { fill, topLimits } = drakeApple()

    const result = await fillForArtist(db, fill, { userId: 'u1', name: 'Drake', enrich: false })

    expect(topLimits).toEqual([])
    expect(result.subrequests).toBe(0)
  })

  it('stays inside a small budget: no top-songs call without room for both', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const { fill, topLimits } = drakeApple()

    const result = await fillForArtist(db, fill, { userId: 'u1', name: 'Drake', budget: 1 })

    expect(topLimits).toEqual([])
    expect(result.subrequests).toBe(0)
  })
})

// Review fix round (2026-11-09).

// Several tool calls in order, then a reply.
function sequenceLlm(calls: Array<{ name: 'generate_queue' | 'edit_queue'; input: unknown }>) {
  const requests: LlmRequest[] = []
  let conv = 0
  const llm: LlmClient = async (req) => {
    requests.push(req)
    if (req.system === PROPOSE_SYSTEM_PROMPT) {
      return { text: '[]', toolCalls: [], raw: [{ type: 'text', text: '[]' }], stopReason: 'end_turn', usage: null }
    }
    if (req.tools.length === 0) return curateFake(req)
    const next = calls[conv]
    conv += 1
    if (next) {
      const call = { id: `c${conv}`, ...next }
      return { text: '', toolCalls: [call], raw: [{ type: 'tool_use', ...call }], stopReason: 'tool_use', usage: null }
    }
    return { text: 'done.', toolCalls: [], raw: [{ type: 'text', text: 'done.' }], stopReason: 'end_turn', usage: null }
  }
  return { llm, requests }
}

// Apple knows three seed artists and Drake; every fill subrequest is
// counted at the rate the fill charges it.
function countingApple() {
  let units = 0
  let searches = 0
  const known = ['SeedA', 'SeedB', 'SeedC', 'Drake']
  const catalog: FillDeps['catalog'] = {
    async searchArtists(_sf, term) { units += 1; searches += 1; return known.includes(term) ? [{ id: `a-${term}`, name: term, genres: [] }] : [] },
    async artistTopSongs(_sf, id, limit) {
      units += 1
      return Array.from({ length: Math.min(limit, 12) }, (_, i) => song(`${id}-${i}`, `${id} Top ${i}`, id.slice(2)))
    },
    async searchSongs() { units += 1; return [] },
  }
  const fill: FillDeps = {
    catalog,
    defaultStorefront: 'us',
    enrich: {
      storefront: 'us',
      itunes: async () => { units += 1; return null },
      features: async () => { units += 2; return null },
      lyrics: async () => { units += 2; return null },
      embed: async () => { units += 1; return UNIT },
    },
  }
  return { fill, units: () => units, searches: () => searches }
}

describe('review fixes', () => {
  it('a seed fill then an artist fill in one turn share one FILL_BUDGET', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const session = await seedSession(db)
    const { fill, units } = countingApple()
    const { llm } = sequenceLlm([
      { name: 'generate_queue', input: { themes: 'party', targetCount: 5, namedArtists: ['SeedA', 'SeedB', 'SeedC'] } },
      { name: 'generate_queue', input: { themes: 'drake', targetCount: 5, onlyArtist: 'Drake' } },
    ])

    const { logged } = await withLog(() => runDjTurn(db, { llm, embed: embedFake, fill }, { id: session.id, userId: 'u1' }, 'party, no, just Drake'))

    expect(units()).toBeLessThanOrEqual(FILL_BUDGET)
    expect((logged.fill as { subrequests: number }).subrequests).toBeLessThanOrEqual(FILL_BUDGET)
  })

  it('a fill that throws is charged its whole allowance, so a later fill this turn gets none', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const session = await seedSession(db)
    const { fill, searches } = countingApple()
    // runDjTurn reads the clock once, fillForArtist once at its start; its
    // next read (the deadline check) throws.
    let reads = 0
    fill.now = () => {
      reads += 1
      if (reads === 3) throw new Error('clock')
      return 0
    }
    const { llm } = scriptedLlm('generate_queue', { themes: 'x', targetCount: 5, onlyArtist: 'Nobody Known', namedArtists: ['Nobody Known'] })

    const { logged } = await withLog(() => runDjTurn(db, { llm, embed: embedFake, fill }, { id: session.id, userId: 'u1' }, 'just Nobody Known'))

    // The fallback's seed fill had nothing left to spend on Apple.
    expect(searches()).toBe(0)
    expect(logged.fill).toBeDefined()
  })

  it('an Apple listener\'s artist-only mix never holds a Spotify-only catalogue row', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedTracks(db, 'J. Cole', 2, { owner: 'u1' })
    for (let i = 0; i < 3; i++) {
      const [t] = await db.insert(tracks).values({ spotifyId: `spotifyOnlyCole000000${i}`, title: `Spotify Cole ${i}`, artist: 'J. Cole', durationMs: 200_000 }).returning()
      await db.insert(trackFeatures).values({ trackId: t.id, tempo: 100, energy: 0.5, valence: 0.5, source: 'reccobeats' })
    }
    const session = await seedSession(db)
    const { llm } = scriptedLlm('generate_queue', { themes: 'cole', targetCount: 10, onlyArtist: 'J. Cole' })

    const result = await runDjTurn(db, { llm, embed: embedFake }, { id: session.id, userId: 'u1' }, 'just J. Cole')

    expect(result.queue).toHaveLength(2)
    for (const t of result.queue) expect(t.appleId).not.toBeNull()
  })

  it('a generate that lands no queue leaves the session\'s scope in force for this turn\'s edits', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedTracks(db, 'J. Cole', 12, { owner: 'u1' })
    await seedTracks(db, 'Baby Keem', 6, { owner: 'u1' })
    const session = await seedSession(db)
    await runDjTurn(db, { llm: scriptedLlm('generate_queue', { themes: 'cole', targetCount: 5, onlyArtist: 'J. Cole' }).llm, embed: embedFake },
      { id: session.id, userId: 'u1' }, 'Cole I can rap to')
    // Every song is out of this brief's tempo window: the generate lands nothing.
    const { llm, requests } = sequenceLlm([
      { name: 'generate_queue', input: { themes: 'fast', targetCount: 5, tempoMin: 200, tempoMax: 210 } },
      { name: 'edit_queue', input: { ops: [{ op: 'extend', count: 2, intent: { themes: 'more' } }] } },
    ])

    const result = await runDjTurn(db, { llm, embed: embedFake }, { id: session.id, userId: 'u1' }, 'something fast, or just more')

    expect(result.queue).toHaveLength(7)
    for (const t of result.queue) expect(credits(t.artist, 'jcole')).toBe(true)
    expect(intentBlock(curationRequests(requests).at(-1)!)).toContain(ONLY_ARTIST_RULE_PREFIX)
  })

  it('an artist-only generate that lands no queue does not scope this turn\'s edits', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedTracks(db, 'Mine', 10, { owner: 'u1' })
    await seedTracks(db, 'J. Cole', 3, { owner: 'u1' })
    const session = await seedSession(db)
    await runDjTurn(db, { llm: scriptedLlm('generate_queue', { themes: 'x', targetCount: 5 }).llm, embed: embedFake },
      { id: session.id, userId: 'u1' }, 'play')
    // Cole's songs are all outside this window, and so is everything else:
    // the artist pool is empty and the fallback lands nothing either.
    const { llm, requests } = sequenceLlm([
      { name: 'generate_queue', input: { themes: 'fast', targetCount: 5, tempoMin: 200, tempoMax: 210, onlyArtist: 'J. Cole' } },
      { name: 'edit_queue', input: { ops: [{ op: 'extend', count: 2, intent: { themes: 'more' } }] } },
    ])

    await runDjTurn(db, { llm, embed: embedFake }, { id: session.id, userId: 'u1' }, 'fast Cole, or just more')

    expect(intentBlock(curationRequests(requests).at(-1)!)).not.toContain(ONLY_ARTIST_RULE_PREFIX)
  })
})
