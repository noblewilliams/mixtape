import { describe, it, expect, vi } from 'vitest'
import { createTestDb, type TestDb } from '../helpers/db'
import { djSessions, trackFeatures, trackMeanings, tracks, user, userArtistSeeds, userTracks } from '../../src/db/schema'
import { genreCheckNotice, runDjTurn, TURN_APPLE_BUDGET, type DjDeps } from '../../src/dj/loop'
import { GENRE_CHECK_SYSTEM } from '../../src/dj/genre-check'
import { PROPOSE_SYSTEM_PROMPT, PROPOSE_SYSTEM_PROMPT_PERSONAL } from '../../src/dj/propose'
import { getActiveQueue, replaceQueue } from '../../src/dj/queue-store'
import type { FillDeps } from '../../src/dj/catalogue-fill'
import type { CatalogSong } from '../../src/musickit/catalog'
import type { LlmClient, LlmComplete, LlmRequest, LlmTurn } from '../../src/dj/llm'

// Spec 2026-11-09 every-song-earns-its-place, decision 8, through the turn:
// golden structural assertions, never exact tracks.

const UNIT = Array.from({ length: 1024 }, (_, i) => (i === 0 ? 1 : 0))
const embedFake = async () => UNIT
let counter = 0

async function seedUser(db: TestDb) {
  await db.insert(user).values({ id: 'u1', name: 'u1', email: 'u1@example.com', emailVerified: false, createdAt: new Date(), updatedAt: new Date() })
}

async function seedSession(db: TestDb) {
  const [s] = await db.insert(djSessions).values({ userId: 'u1', title: 's' }).returning()
  return s
}

// n enriched rows by `artist`, labelled `genre`, in u1's library.
// A listener with no library: seeds, and catalogue rows by those artists.
async function seedCorpus(db: TestDb, genre: string) {
  for (const artist of ['SeedA', 'SeedB', 'SeedC']) {
    await db.insert(userArtistSeeds).values({ userId: 'u1', name: artist, source: 'interview' })
    for (let i = 0; i < 9; i++) {
      counter += 1
      const [t] = await db.insert(tracks).values({ appleId: `cat-${counter}`, title: `${artist} ${counter}`, artist, genre, durationMs: 200_000 }).returning()
      await db.insert(trackFeatures).values({ trackId: t.id, tempo: 100, energy: 0.5, valence: 0.5, source: 'reccobeats' })
      await db.insert(trackMeanings).values({ trackId: t.id, embedding: UNIT, lyricsSource: 'lrclib' })
    }
  }
}

async function seedTracks(db: TestDb, artist: string, n: number, genre: string | null) {
  const out: Array<typeof tracks.$inferSelect> = []
  for (let i = 0; i < n; i++) {
    counter += 1
    const [t] = await db.insert(tracks).values({ appleId: `held-${counter}`, title: `${artist} ${counter}`, artist, genre, durationMs: 200_000 }).returning()
    await db.insert(trackFeatures).values({ trackId: t.id, tempo: 100, energy: 0.5, valence: 0.5, source: 'reccobeats' })
    await db.insert(trackMeanings).values({ trackId: t.id, embedding: UNIT, lyricsSource: 'lrclib' })
    await db.insert(userTracks).values({ userId: 'u1', trackId: t.id, inLibrary: true })
    out.push(t)
  }
  return out
}

type Proposed = { title: string; artist: string; reason: string }
const proposals = (n: number): Proposed[] =>
  Array.from({ length: n }, (_, i) => ({ title: `Song ${i}`, artist: ['Miles Davis', 'Bill Evans', 'Chet Baker'][i % 3], reason: `reason ${i}` }))

// Apple confirms every proposal, labelled `genre`.
function fakeApple(confirmed: Proposed[], genre: string | ((i: number) => string)) {
  const label = typeof genre === 'string' ? () => genre : genre
  const songs = new Map(confirmed.map((s, i): [string, CatalogSong] => [`${s.title} ${s.artist}`,
    { appleId: `v-${i}`, isrc: null, title: s.title, artist: s.artist, album: 'A', artwork: null, durationMs: 200_000, genre: label(i), releaseYear: 1959, explicit: false }]))
  let calls = 0
  const catalog: FillDeps['catalog'] = {
    async searchArtists() { calls += 1; return [] },
    async artistTopSongs() { calls += 1; return [] },
    async searchSongs(_sf, term) { calls += 1; const hit = songs.get(term); return hit ? [hit] : [] },
  }
  const fill: FillDeps = {
    catalog,
    defaultStorefront: 'us',
    enrich: { storefront: 'us', itunes: async () => null, features: async () => null, lyrics: async () => null, embed: async () => UNIT },
  }
  return { fill, appleCalls: () => calls }
}

// The sound check: answers in turn from `answers` (a thrown Error fails it).
function fakeCheck(answers: Array<string | Error>) {
  const calls: Array<Parameters<LlmComplete>[0]> = []
  const titleComplete: LlmComplete = async (opts) => {
    if (opts.system !== GENRE_CHECK_SYSTEM) return 'A Title'
    calls.push(opts)
    const a = answers[Math.min(calls.length - 1, answers.length - 1)] ?? '[]'
    if (a instanceof Error) throw a
    return a
  }
  return { titleComplete, calls }
}

const textTurn = (text: string): LlmTurn => ({ text, toolCalls: [], raw: [{ type: 'text', text }], stopReason: 'end_turn', usage: null })
const isProposal = (req: LlmRequest) => req.system === PROPOSE_SYSTEM_PROMPT || req.system === PROPOSE_SYSTEM_PROMPT_PERSONAL

function scriptedLlm(calls: Array<{ name: string; input: unknown }>, proposed: Proposed[] = []) {
  const requests: LlmRequest[] = []
  let conv = 0
  const llm: LlmClient = async (req) => {
    requests.push(req)
    if (isProposal(req)) return textTurn(JSON.stringify(proposed))
    if (req.tools.length === 0) {
      const blocks = req.messages[0].content as Array<{ text?: string }>
      const ids = Array.from((blocks[0]?.text ?? '').matchAll(/^([0-9a-f-]{36}) \|/gm)).map((m) => m[1])
      const count = Number((blocks[1]?.text ?? '').match(/Pick up to (\d+) tracks/)?.[1] ?? ids.length)
      return textTurn(JSON.stringify(ids.slice(0, count).map((id) => ({ id, reason: 'fits' }))))
    }
    const call = calls[conv++]
    if (call) {
      const c = { id: `c${conv}`, name: call.name, input: call.input }
      return { text: '', toolCalls: [c], raw: [{ type: 'tool_use', ...c }], stopReason: 'tool_use', usage: null }
    }
    return textTurn('here you go.')
  }
  return { llm, requests }
}

function toolResults(requests: LlmRequest[]): string[] {
  const last = requests.filter((r) => r.tools.length > 0).at(-1)!
  return last.messages
    .filter((m) => m.role === 'user' && Array.isArray(m.content) && (m.content[0] as { type?: string }).type === 'tool_result')
    .map((m) => (m.content as Array<{ content: string }>)[0].content)
}

const generate = (input: Record<string, unknown>) => ({ name: 'generate_queue', input: { themes: 'rainy sunday reading', ...input } })
const quiet = () => vi.spyOn(console, 'log').mockImplementation(() => {})

describe('decision 8: a named genre is checked by how a song sounds', () => {
  it('golden: curated songs that do not sound like jazz leave, and the fill replaces them with labelled jazz, one check call', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedTracks(db, 'Jazz Player', 3, 'Vocal Jazz')
    await seedTracks(db, 'Indie Band', 3, 'Alternative')
    const session = await seedSession(db)
    const { fill } = fakeApple(proposals(11), 'Jazz')
    const { titleComplete, calls } = fakeCheck(['[]'])
    const { llm, requests } = scriptedLlm([generate({ targetCount: 6, genres: ['jazz'] })], proposals(11))
    const deps: DjDeps = { llm, embed: embedFake, fill, neverRefuse: true, titleComplete }

    const result = await runDjTurn(db, deps, { id: session.id, userId: 'u1' }, 'rainy sunday reading, soft jazz')

    expect(result.queue).toHaveLength(6)
    expect(result.queue.some((t) => t.artist === 'Indie Band')).toBe(false)
    expect(result.queue.filter((t) => t.title.startsWith('Song '))).toHaveLength(3)
    // Only the three unlabelled songs were asked about, once; the proposals
    // carry Apple's Jazz label and need no call.
    expect(calls).toHaveLength(1)
    expect(calls[0].prompt.match(/\| Alternative \|/g)).toHaveLength(3)
    expect(toolResults(requests)[0]).toContain(genreCheckNotice({ dropped: 3, genres: ['jazz'], failed: false }))
  })

  it('proposals Apple labels otherwise get at most one more check', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedTracks(db, 'Jazz Player', 3, 'Jazz')
    const session = await seedSession(db)
    const { fill } = fakeApple(proposals(11), 'Pop')
    const { titleComplete, calls } = fakeCheck(['[1]'])
    const { llm, requests } = scriptedLlm([generate({ targetCount: 6, genres: ['jazz'] })], proposals(11))

    const result = await runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: true, titleComplete }, { id: session.id, userId: 'u1' }, 'soft jazz')

    expect(calls).toHaveLength(1)
    expect(result.queue).toHaveLength(4)
    expect(toolResults(requests)[0]).toContain(genreCheckNotice({ dropped: 2, genres: ['jazz'], failed: false }))
  })

  // Live 2026-11-10: a "90s r&b slow jams" mix came back 5 songs where a
  // rerun gave 15. The shortfall round verified only as many songs as it
  // needed, so each that then failed the check left a gap. With a genre
  // named, it verifies spares, and the queue still takes only the shortfall.
  it('outside songs that fail the check are replaced by verified spares', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedTracks(db, 'Jazz Player', 3, 'Jazz')
    const session = await seedSession(db)
    // The first three proposals Apple labels Pop and the check fails; the rest are Jazz.
    const { fill } = fakeApple(proposals(11), (i) => (i < 3 ? 'Pop' : 'Jazz'))
    const { titleComplete, calls } = fakeCheck(['[]'])
    const { llm, requests } = scriptedLlm([generate({ targetCount: 6, genres: ['jazz'] })], proposals(11))

    const result = await runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: true, titleComplete }, { id: session.id, userId: 'u1' }, 'soft jazz')

    expect(result.queue).toHaveLength(6)
    expect(result.queue.filter((t) => t.title.startsWith('Song '))).toHaveLength(3)
    expect(result.queue.some((t) => ['Song 0', 'Song 1', 'Song 2'].includes(t.title))).toBe(false)
    expect(calls).toHaveLength(1)
    // Nothing is missing, so nothing is reported as dropped from the mix.
    expect(toolResults(requests)[0]).not.toContain(genreCheckNotice({ dropped: 3, genres: ['jazz'], failed: false }))
  })

  it('without a named genre the shortfall verifies no spares', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedTracks(db, 'Jazz Player', 3, 'Jazz')
    const session = await seedSession(db)
    const { fill, appleCalls } = fakeApple(proposals(11), 'Jazz')
    const { titleComplete } = fakeCheck(['[]'])
    const { llm } = scriptedLlm([generate({ targetCount: 6 })], proposals(11))

    const result = await runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: true, titleComplete }, { id: session.id, userId: 'u1' }, 'rainy sunday')

    expect(result.queue).toHaveLength(6)
    expect(appleCalls()).toBe(3)
  })

  it('a check that fails keeps only labelled songs, says so, and the turn still succeeds', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedTracks(db, 'Jazz Player', 2, 'Jazz')
    await seedTracks(db, 'Soul Singer', 2, 'Soul')
    const session = await seedSession(db)
    const { titleComplete } = fakeCheck([new Error('timeout')])
    const { llm, requests } = scriptedLlm([generate({ targetCount: 4, genres: ['jazz'] })])

    const log = quiet()
    const result = await runDjTurn(db, { llm, embed: embedFake, titleComplete }, { id: session.id, userId: 'u1' }, 'soft jazz')
    log.mockRestore()

    expect(result.queue.map((t) => t.artist)).toEqual(['Jazz Player', 'Jazz Player'])
    expect(toolResults(requests)[0]).toContain(genreCheckNotice({ dropped: 2, genres: ['jazz'], failed: true }))
    expect(result.djMessage.content).toBe('here you go.')
  })

  it('no named genre: no check at all', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedTracks(db, 'Indie Band', 4, 'Alternative')
    const session = await seedSession(db)
    const { titleComplete, calls } = fakeCheck(['[]'])
    const { llm } = scriptedLlm([generate({ targetCount: 4 })])

    const result = await runDjTurn(db, { llm, embed: embedFake, titleComplete }, { id: session.id, userId: 'u1' }, 'rainy sunday')

    expect(result.queue).toHaveLength(4)
    expect(calls).toHaveLength(0)
  })

  it('a swap whose intent names a genre is checked; one that does not sound right keeps the original', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const jazz = await seedTracks(db, 'Jazz Player', 3, 'Jazz')
    await seedTracks(db, 'Indie Band', 3, 'Alternative')
    const session = await seedSession(db)
    await replaceQueue(db, session.id, jazz.map((t) => ({ trackId: t.id, reason: '' })), 'dj')
    const before = (await getActiveQueue(db, session.id)).map((t) => t.trackId)
    const { titleComplete, calls } = fakeCheck(['[]'])
    const { llm, requests } = scriptedLlm([{ name: 'edit_queue', input: { ops: [{ op: 'swap', position: 1, intent: { themes: 'jazz', genres: ['jazz'] } }] } }])

    const result = await runDjTurn(db, { llm, embed: embedFake, titleComplete }, { id: session.id, userId: 'u1' }, 'swap 2 for another jazz one')

    expect(calls).toHaveLength(1)
    expect(result.queue.map((t) => t.trackId)).toEqual(before)
    expect(toolResults(requests)[0]).toContain(genreCheckNotice({ dropped: 1, genres: ['jazz'], failed: false }))
  })

  it('an artist-only mix skips the check unless a genre is named too', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedTracks(db, 'SZA', 4, 'R&B/Soul')
    await seedTracks(db, 'SZA', 2, 'Pop')
    const session = await seedSession(db)

    const plain = fakeCheck(['[]'])
    const first = scriptedLlm([generate({ targetCount: 6, onlyArtist: 'SZA' })])
    const all = await runDjTurn(db, { llm: first.llm, embed: embedFake, titleComplete: plain.titleComplete }, { id: session.id, userId: 'u1' }, 'sza songs')
    expect(plain.calls).toHaveLength(0)
    expect(all.queue).toHaveLength(6)

    const named = fakeCheck(['[]'])
    const second = scriptedLlm([generate({ targetCount: 6, onlyArtist: 'SZA', genres: ['r&b'] })])
    const rnb = await runDjTurn(db, { llm: second.llm, embed: embedFake, titleComplete: named.titleComplete }, { id: session.id, userId: 'u1' }, 'sza r&b only')
    expect(named.calls).toHaveLength(1)
    expect(rnb.queue).toHaveLength(4)
  })

  it('the check counts against the turn\'s budget: a genre turn with a big shortfall stays inside it', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedTracks(db, 'Indie Band', 3, 'Alternative')
    const session = await seedSession(db)
    const { fill, appleCalls } = fakeApple(proposals(40), 'Pop')
    const { titleComplete, calls } = fakeCheck(['[]', '[1, 2]'])
    const { llm } = scriptedLlm([generate({ targetCount: 30, genres: ['jazz'] })], proposals(40))

    const log = quiet()
    await runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: true, titleComplete }, { id: session.id, userId: 'u1' }, 'soft jazz')
    log.mockRestore()

    // The proposal check still ran: room was kept for it.
    expect(calls).toHaveLength(2)
    expect(appleCalls() + calls.length).toBeLessThanOrEqual(TURN_APPLE_BUDGET)
  })

  it('a listener with no library: their all-proposals "soft jazz" mix is checked too, failures dropped', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const session = await seedSession(db)
    const { fill } = fakeApple(proposals(13), 'Pop')
    const { titleComplete, calls } = fakeCheck(['[1, 2, 3]'])
    const { llm, requests } = scriptedLlm([generate({ targetCount: 5, genres: ['jazz'] })], proposals(13))

    const result = await runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: true, titleComplete }, { id: session.id, userId: 'u1' }, 'soft jazz')

    expect(calls).toHaveLength(1)
    expect(result.queue).toHaveLength(3)
    const [text] = toolResults(requests)
    expect(text).toContain(genreCheckNotice({ dropped: 2, genres: ['jazz'], failed: false }))
  })

  it('a corpus "soft jazz" mix whose blend spends its searches still gets its proposals check', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedCorpus(db, 'Alternative')
    const session = await seedSession(db)
    // Apple confirms one proposal in three, so the blend searches all it may.
    const all = proposals(40)
    const { fill } = fakeApple(all.filter((_, i) => i % 3 === 0), 'Pop')
    const { titleComplete, calls } = fakeCheck(['[]', '[1]'])
    const { llm: inner } = scriptedLlm([generate({ targetCount: 30, genres: ['jazz'] })], all)
    // Curation answers after the blend has searched, as a real curation
    // call (the slower one) does.
    let blendDone: () => void = () => {}
    const blendSearched = new Promise<void>((resolve) => { blendDone = resolve })
    const search = fill.catalog.searchSongs.bind(fill.catalog)
    let searches = 0
    fill.catalog.searchSongs = async (sf, term, limit) => {
      const r = await search(sf, term, limit)
      searches += 1
      if (searches >= 20) blendDone()
      return r
    }
    const llm: LlmClient = async (req) => {
      if (req.tools.length === 0 && !isProposal(req)) await Promise.race([blendSearched, new Promise((r) => setTimeout(r, 3000))])
      return inner(req)
    }

    const log = quiet()
    await runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: true, titleComplete }, { id: session.id, userId: 'u1' }, 'soft jazz')
    const closed = log.mock.calls.filter((c) => c[0] === 'dj genre check')
    log.mockRestore()

    // One check for the curated songs, one for the proposals: neither
    // closed for want of room.
    expect(calls).toHaveLength(2)
    expect(closed).toHaveLength(0)
  })

  it('an extend with no intent after a genre generate in the same turn inherits the genre and is checked', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedTracks(db, 'Jazz Player', 2, 'Jazz')
    await seedTracks(db, 'Indie Band', 6, 'Alternative')
    const session = await seedSession(db)
    const { titleComplete, calls } = fakeCheck(['[]', '[]'])
    const { llm, requests } = scriptedLlm([
      generate({ targetCount: 8, genres: ['jazz'] }),
      { name: 'edit_queue', input: { ops: [{ op: 'extend', count: 2 }] } },
    ])

    const result = await runDjTurn(db, { llm, embed: embedFake, titleComplete }, { id: session.id, userId: 'u1' }, 'soft jazz, then a couple more')

    expect(calls).toHaveLength(2)
    expect(result.queue.map((t) => t.artist)).toEqual(['Jazz Player', 'Jazz Player'])
    expect(toolResults(requests)[1]).toContain(genreCheckNotice({ dropped: 2, genres: ['jazz'], failed: false }))
  })
})
