import { describe, it, expect, vi } from 'vitest'
import { eq } from 'drizzle-orm'
import { readFileSync } from 'node:fs'
import { createTestDb, type TestDb } from '../helpers/db'
import { djSessions, funnelEvents, trackFeatures, trackMeanings, tracks, user, userArtistSeeds, userTracks } from '../../src/db/schema'
import {
  runDjTurn,
  CORPUS_NOTICE,
  INSUFFICIENT_SEEDS_TEXT,
  SHORT_VERIFIED_TEXT,
  partialVerifiedNotice,
  type DjDeps,
} from '../../src/dj/loop'
import { PROPOSED_NOTICE, PROPOSE_SYSTEM_PROMPT, ROUND_TWO_CUTOFF_MS, VERIFY_MAX } from '../../src/dj/propose'
import { FILL_QUEUE_BOOST, type FillDeps } from '../../src/dj/catalogue-fill'
import { neverRefuseEnabled } from '../../src/index'
import { AppleCatalogError, type CatalogSong } from '../../src/musickit/catalog'
import { LlmError, type LlmClient, type LlmRequest, type LlmTurn } from '../../src/dj/llm'

// Never refuse (spec 2026-10-21 everyone-gets-a-mix, step 4, reshaped
// 2026-10-22): golden structural assertions, never exact tracks.

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

async function seedEnriched(db: TestDb, artist: string, n: number, userId?: string) {
  for (let i = 0; i < n; i++) {
    counter += 1
    const [t] = await db.insert(tracks).values({ appleId: `held-${counter}`, title: `Held ${counter}`, artist, durationMs: 200_000 }).returning()
    await db.insert(trackFeatures).values({ trackId: t.id, tempo: 100, energy: 0.5, valence: 0.5, source: 'reccobeats' })
    await db.insert(trackMeanings).values({ trackId: t.id, embedding: UNIT, lyricsSource: 'lrclib' })
    if (userId) await db.insert(userTracks).values({ userId, trackId: t.id, inLibrary: true })
  }
}

function song(appleId: string, title: string, artist: string): CatalogSong {
  return { appleId, isrc: null, title, artist, album: 'Album', artwork: null, durationMs: 200_000, genre: 'Afrobeats', releaseYear: 2023, explicit: false }
}

const ARTISTS = ['Asake', 'Seyi Vibez', 'Shallipopi']

// n proposals cycling the three artists, so no two by one artist in a row.
function proposals(prefix: string, n: number) {
  return Array.from({ length: n }, (_, i) => ({ title: `${prefix} ${i}`, artist: ARTISTS[i % 3], reason: `${prefix} reason ${i}` }))
}

type Proposed = { title: string; artist: string; reason: string }

// Apple: the three artists are found (the fill inserts their top songs) and
// every song in `confirmed` answers its own search.
function fakeFill(confirmed: Proposed[]) {
  const searches: string[] = []
  const enrichCalls = { features: 0, lyrics: 0, embed: 0 }
  const songs = new Map(confirmed.map((s, i) => [`${s.title} ${s.artist}`, song(`v-${s.title}-${i}`, s.title, s.artist)]))
  const catalog: FillDeps['catalog'] = {
    async searchArtists(_sf, term) {
      return ARTISTS.includes(term) ? [{ id: `a-${term}`, name: term, genres: [] }] : []
    },
    async artistTopSongs(_sf, id) {
      return Array.from({ length: 3 }, (_, i) => song(`${id}-top-${i}`, `${id} Top ${i}`, id.slice(2)))
    },
    async searchSongs(_sf, term) {
      searches.push(term)
      const hit = songs.get(term)
      return hit ? [hit] : []
    },
  }
  const fill: FillDeps = {
    catalog,
    defaultStorefront: 'ng',
    enrich: {
      storefront: 'ng',
      itunes: async () => null,
      features: async () => { enrichCalls.features += 1; return null },
      lyrics: async () => { enrichCalls.lyrics += 1; return null },
      embed: async () => { enrichCalls.embed += 1; return UNIT },
    },
  }
  return { fill, searches, enrichCalls }
}

function curateFake(req: LlmRequest): LlmTurn {
  const blocks = req.messages[0].content as Array<{ text?: string }>
  const ids = Array.from((blocks[0]?.text ?? '').matchAll(/^([0-9a-f-]{36}) \|/gm)).map((m) => m[1])
  const count = Number((blocks[1]?.text ?? '').match(/Pick exactly (\d+) tracks/)?.[1] ?? ids.length)
  const text = JSON.stringify(ids.slice(0, count).map((id) => ({ id, reason: 'fits' })))
  return { text, toolCalls: [], raw: [{ type: 'text', text }], stopReason: 'end_turn', usage: null }
}

// Conversation: generate_queue with `input` (once per entry of `generates`),
// then a reply. Proposal calls answer from `rounds` in order.
function scriptedLlm(inputs: unknown[], rounds: Proposed[][]) {
  const requests: LlmRequest[] = []
  let conv = 0
  let proposal = 0
  const llm: LlmClient = async (req) => {
    requests.push(req)
    if (req.system === PROPOSE_SYSTEM_PROMPT) {
      const text = JSON.stringify(rounds[Math.min(proposal++, rounds.length - 1)] ?? [])
      return { text, toolCalls: [], raw: [{ type: 'text', text }], stopReason: 'end_turn', usage: null }
    }
    if (req.tools.length === 0) return curateFake(req)
    const input = inputs[conv]
    conv += 1
    if (input !== undefined) {
      const call = { id: `c${conv}`, name: 'generate_queue', input }
      return { text: '', toolCalls: [call], raw: [{ type: 'tool_use', ...call }], stopReason: 'tool_use', usage: null }
    }
    return { text: 'here you go.', toolCalls: [], raw: [{ type: 'text', text: 'here you go.' }], stopReason: 'end_turn', usage: null }
  }
  return { llm, requests }
}

const proposalRequests = (requests: LlmRequest[]) => requests.filter((r) => r.system === PROPOSE_SYSTEM_PROMPT)

function toolResults(requests: LlmRequest[]): string[] {
  const last = requests.filter((r) => r.tools.length > 0).at(-1)!
  return last.messages
    .filter((m) => m.role === 'user' && Array.isArray(m.content) && (m.content[0] as { type?: string }).type === 'tool_result')
    .map((m) => (m.content as Array<{ content: string }>)[0].content)
}

async function queueTitles(db: TestDb, sessionId: string) {
  const result = await db.execute(`SELECT t.title, q.reason FROM queue_tracks q JOIN tracks t ON t.id = q.track_id
    WHERE q.session_id = '${sessionId}' AND q.state = 'active' ORDER BY q.position`)
  return (result.rows as Array<{ title: string; reason: string }>)
}

async function notPersonal(db: TestDb, sessionId: string) {
  const [row] = await db.select({ notPersonal: djSessions.notPersonal }).from(djSessions).where(eq(djSessions.id, sessionId))
  return row.notPersonal
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

const brief = (targetCount: number) => ({ themes: 'lagos street party', targetCount, namedArtists: ARTISTS })

describe('never refuse: proposed songs verified on Apple', () => {
  it('golden: a no-library listener naming three artists the catalogue lacks gets a full queue in proposal order, not personal, with the notice', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const session = await seedSession(db)
    const round = proposals('Song', 13)
    const { fill, searches, enrichCalls } = fakeFill(round)
    const { llm, requests } = scriptedLlm([brief(5)], [round])
    const deps: DjDeps = { llm, embed: embedFake, fill, neverRefuse: true }

    const { value: result, logged } = await withLog(() =>
      runDjTurn(db, deps, { id: session.id, userId: 'u1' }, 'asake, seyi vibez and shallipopi', { surface: 'ios' }))

    expect(result.queue).toHaveLength(5)
    expect(await queueTitles(db, session.id)).toEqual(round.slice(0, 5).map((s) => ({ title: s.title, reason: s.reason })))
    expect(await notPersonal(db, session.id)).toBe(true)
    const [text] = toolResults(requests)
    expect(text.split('\n')[0]).toBe(PROPOSED_NOTICE)
    expect(text).toContain('queue generated: 5 tracks')
    expect(text).not.toContain(SHORT_VERIFIED_TEXT)
    // One proposal, stopped searching once the mix was full.
    expect(proposalRequests(requests)).toHaveLength(1)
    expect(searches).toHaveLength(5)
    expect(logged.propose).toEqual({ proposed: 13, verified: 5, searches: 5, rounds: 1 })
    // The fill still inserted the artists' top songs, but enriched nothing.
    expect(logged.fill).toMatchObject({ inserted: 9, enriched: 0 })
    expect(enrichCalls).toEqual({ features: 0, lyrics: 0, embed: 0 })
    const funnel = await db.select().from(funnelEvents).where(eq(funnelEvents.userId, 'u1'))
    expect(funnel.map((f) => [f.type, f.surface])).toContainEqual(['proposed_mix', 'ios'])
    // Verified rows are catalogue rows queued with the boost, never enriched here.
    const queued = await db.select().from(tracks).where(eq(tracks.title, round[0].title))
    expect(queued).toHaveLength(1)
    expect(queued[0].enrichPriority).toBeGreaterThanOrEqual(FILL_QUEUE_BOOST)
    expect(await db.select().from(trackFeatures)).toHaveLength(0)
    // The proposal saw the brief and the named artists.
    const block = proposalRequests(requests)[0].messages[0].content as string
    expect(block).toContain('Request: asake, seyi vibez and shallipopi')
    for (const artist of ARTISTS) expect(block).toContain(artist)
  })

  it('a short first round asks once for replacements, naming what was tried, and merges in order', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const session = await seedSession(db)
    const first = proposals('First', 16)
    const second = proposals('Second', 6)
    const { fill, searches } = fakeFill([first[2], first[9], first[15], ...second])
    const { llm, requests } = scriptedLlm([brief(8)], [first, second])

    const { logged } = await withLog(() =>
      runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: true }, { id: session.id, userId: 'u1' }, 'party'))

    const asks = proposalRequests(requests)
    expect(asks).toHaveLength(2)
    const replacement = asks[1].messages[0].content as string
    expect(replacement).toContain('Already tried, never propose these again:')
    expect(replacement).toContain(`- ${first[0].title} by ${first[0].artist}`)
    expect(replacement).toContain(`- ${first[2].title} by ${first[2].artist}`)
    // What the budget leaves: 22 searches less the 16 spent.
    expect(replacement).toContain(`Propose exactly ${VERIFY_MAX - 16} songs.`)
    // Round two stops once the mix is full: 5 of its 6.
    expect(searches).toHaveLength(16 + 5)
    expect((await queueTitles(db, session.id)).map((r) => r.title)).toEqual([first[2], first[9], first[15], ...second.slice(0, 5)].map((s) => s.title))
    expect(logged.propose).toEqual({ proposed: 22, verified: 8, searches: 21, rounds: 2 })
  })

  it('still short after the replacement: the queue holds what verified and the DJ offers to loosen', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const session = await seedSession(db)
    const first = proposals('First', 13)
    const { fill } = fakeFill([first[0], first[4]])
    const { llm, requests } = scriptedLlm([brief(5)], [first, proposals('Second', 11)])

    const result = await runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: true }, { id: session.id, userId: 'u1' }, 'party')

    expect(proposalRequests(requests)).toHaveLength(2)
    expect(result.queue).toHaveLength(2)
    const [text] = toolResults(requests)
    expect(text.split('\n')[0]).toBe(PROPOSED_NOTICE)
    expect(text).toContain(SHORT_VERIFIED_TEXT)
    expect(await notPersonal(db, session.id)).toBe(true)
  })

  it('nothing verified: today\'s refusal, no queue, no proposed_mix row', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const session = await seedSession(db)
    const { fill } = fakeFill([])
    const { llm, requests } = scriptedLlm([brief(5)], [proposals('First', 13), proposals('Second', 12)])

    const { value: result, logged } = await withLog(() =>
      runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: true }, { id: session.id, userId: 'u1' }, 'party'))

    expect(result.queue).toHaveLength(0)
    expect(toolResults(requests)).toEqual([INSUFFICIENT_SEEDS_TEXT])
    expect(proposalRequests(requests)).toHaveLength(2)
    expect(logged.propose).toEqual({ proposed: 22, verified: 0, searches: 22, rounds: 2 })
    const types = (await db.select().from(funnelEvents)).map((f) => f.type)
    expect(types).not.toContain('proposed_mix')
    expect(await notPersonal(db, session.id)).toBe(false)
  })

  it('a second generate_queue in the same turn reuses the verified songs: no second proposal or search', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const session = await seedSession(db)
    const round = proposals('Song', 13)
    const { fill, searches } = fakeFill(round)
    const { llm, requests } = scriptedLlm([brief(5), brief(5)], [round])

    const result = await runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: true }, { id: session.id, userId: 'u1' }, 'party')

    expect(proposalRequests(requests)).toHaveLength(1)
    expect(searches).toHaveLength(5)
    expect(result.queue).toHaveLength(5)
  })

  it('a corpus listener is unchanged with the flag on: curated, the corpus notice, no proposal', async () => {
    const db = await createTestDb()
    await seedUser(db)
    for (const artist of ['SeedA', 'SeedB', 'SeedC']) {
      await db.insert(userArtistSeeds).values({ userId: 'u1', name: artist, source: 'interview' })
      await seedEnriched(db, artist, 9)
    }
    const session = await seedSession(db)
    const { fill, searches } = fakeFill([])
    const { llm, requests } = scriptedLlm([{ themes: 'x', targetCount: 5 }], [])

    const result = await runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: true }, { id: session.id, userId: 'u1' }, 'play')

    expect(result.queue).toHaveLength(5)
    expect(toolResults(requests)[0].split('\n')[0]).toBe(CORPUS_NOTICE)
    expect(proposalRequests(requests)).toHaveLength(0)
    expect(searches).toHaveLength(0)
  })

  it('a personal listener is unchanged with the flag on', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedEnriched(db, 'Mine', 6, 'u1')
    const session = await seedSession(db)
    const { fill, searches } = fakeFill([])
    const { llm, requests } = scriptedLlm([{ themes: 'x', targetCount: 5 }], [])

    const result = await runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: true }, { id: session.id, userId: 'u1' }, 'play')

    expect(result.queue).toHaveLength(5)
    expect(toolResults(requests)[0]).not.toContain(PROPOSED_NOTICE)
    expect(toolResults(requests)[0]).not.toContain(CORPUS_NOTICE)
    expect(proposalRequests(requests)).toHaveLength(0)
    expect(searches).toHaveLength(0)
    expect(await notPersonal(db, session.id)).toBe(false)
  })

  it('without the Apple fill wired, the flag on still refuses as before', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const session = await seedSession(db)
    const { llm, requests } = scriptedLlm([brief(5)], [proposals('Song', 13)])

    const result = await runDjTurn(db, { llm, embed: embedFake, neverRefuse: true }, { id: session.id, userId: 'u1' }, 'party')

    expect(result.queue).toHaveLength(0)
    expect(toolResults(requests)).toEqual([INSUFFICIENT_SEEDS_TEXT])
    expect(proposalRequests(requests)).toHaveLength(0)
  })
})

describe('NEVER_REFUSE off is today', () => {
  it('an insufficient listener is refused, the fill enriches in-request, nothing is proposed or searched', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const session = await seedSession(db)
    const round = proposals('Song', 13)

    for (const neverRefuse of [undefined, false]) {
      const { fill, searches, enrichCalls } = fakeFill(round)
      const { llm, requests } = scriptedLlm([brief(5)], [round])
      const { value: result, logged } = await withLog(() =>
        runDjTurn(db, { llm, embed: embedFake, fill, ...(neverRefuse === undefined ? {} : { neverRefuse }) }, { id: session.id, userId: 'u1' }, 'party'))
      expect(result.queue).toHaveLength(0)
      expect(logged.propose).toBeUndefined()
      expect(toolResults(requests)).toEqual([INSUFFICIENT_SEEDS_TEXT])
      expect(proposalRequests(requests)).toHaveLength(0)
      expect(searches).toHaveLength(0)
      if (neverRefuse === undefined) expect(enrichCalls.features).toBeGreaterThan(0)
    }
    expect((await db.select().from(funnelEvents)).map((f) => f.type)).not.toContain('proposed_mix')
  })

  it('only the exact string "on" enables it', () => {
    expect(neverRefuseEnabled({ NEVER_REFUSE: 'on' })).toBe(true)
    for (const value of [undefined, 'off', 'ON', ' on', 'true', '1', '']) {
      expect(neverRefuseEnabled({ NEVER_REFUSE: value })).toBe(false)
    }
  })

  it('ships off in wrangler.jsonc', () => {
    const config = readFileSync(new URL('../../wrangler.jsonc', import.meta.url), 'utf8')
    expect(config).toMatch(/"NEVER_REFUSE":\s*"off"/)
  })
})

// A catalogue that answers each search through `answer` (no echo of the
// proposal), on an optional injected clock.
function fakeApple(answer: (term: string, n: number) => CatalogSong[] | Promise<CatalogSong[]>, now?: () => number) {
  const searches: string[] = []
  const fill: FillDeps = {
    catalog: {
      async searchArtists() { return [] },
      async artistTopSongs() { return [] },
      async searchSongs(_sf, term) {
        searches.push(term)
        return answer(term, searches.length)
      },
    },
    defaultStorefront: 'ng',
    enrich: { storefront: 'ng', itunes: async () => null, features: async () => null, lyrics: async () => null, embed: async () => UNIT },
    ...(now ? { now } : {}),
  }
  return { fill, searches }
}

// Confirms a proposal as itself, by its own title and artist.
const echo = (term: string) => {
  const artist = ARTISTS.find((a) => term.endsWith(` ${a}`))!
  const title = term.slice(0, -(artist.length + 1))
  return [song(`apple-${title}`, title, artist)]
}

function editLlm(ops: unknown, edit: Proposed[]) {
  const requests: LlmRequest[] = []
  let conv = 0
  const llm: LlmClient = async (req) => {
    requests.push(req)
    if (req.system === PROPOSE_SYSTEM_PROMPT) {
      const text = JSON.stringify(edit)
      return { text, toolCalls: [], raw: [{ type: 'text', text }], stopReason: 'end_turn', usage: null }
    }
    conv += 1
    if (conv === 1) {
      const call = { id: 'e1', name: 'edit_queue', input: { ops } }
      return { text: '', toolCalls: [call], raw: [{ type: 'tool_use', ...call }], stopReason: 'tool_use', usage: null }
    }
    return { text: 'done.', toolCalls: [], raw: [{ type: 'text', text: 'done.' }], stopReason: 'end_turn', usage: null }
  }
  return { llm, requests }
}

async function proposedMix(db: TestDb, sessionId: string, fill: FillDeps) {
  const round = proposals('Song', 13)
  const { llm } = scriptedLlm([brief(5)], [round])
  await runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: true }, { id: sessionId, userId: 'u1' }, 'party')
  return round
}

describe('never refuse: edits on a proposed mix', () => {
  it('"swap the third one" replaces that row with a verified song and never refuses', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const session = await seedSession(db)
    const { fill } = fakeApple(echo)
    const round = await proposedMix(db, session.id, fill)
    const { llm, requests } = editLlm([{ op: 'swap', position: 2 }], [{ title: 'Swap In', artist: 'Asake', reason: 'new lift' }])

    const result = await runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: true }, { id: session.id, userId: 'u1' }, 'swap the third one')

    const titles = (await queueTitles(db, session.id)).map((r) => r.title)
    expect(titles).toEqual([round[0].title, round[1].title, 'Swap In', round[3].title, round[4].title])
    expect(result.queue).toHaveLength(5)
    const [text] = toolResults(requests)
    expect(text).not.toBe(INSUFFICIENT_SEEDS_TEXT)
    expect(text.split('\n')[0]).toBe(PROPOSED_NOTICE)
    const ask = proposalRequests(requests)[0].messages[0].content as string
    expect(ask).toContain('Propose exactly 1 songs.')
    // The queue and the swapped-out song are never proposed again.
    expect(ask).toContain(`- ${round[0].title} by ${round[0].artist}`)
    expect(ask).toContain(`- ${round[2].title} by ${round[2].artist}`)
  })

  it('extend by 3 appends three verified songs', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const session = await seedSession(db)
    const { fill } = fakeApple(echo)
    const round = await proposedMix(db, session.id, fill)
    const more = proposals('More', 3)
    const { llm, requests } = editLlm([{ op: 'extend', count: 3 }], more)

    await runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: true }, { id: session.id, userId: 'u1' }, 'three more')

    const titles = (await queueTitles(db, session.id)).map((r) => r.title)
    expect(titles).toEqual([...round.slice(0, 5), ...more].map((s) => s.title))
    expect(toolResults(requests)[0].split('\n')[0]).toBe(PROPOSED_NOTICE)
  })
})

describe('never refuse: failures, limits and recordings through runDjTurn', () => {
  it('a cover returned for a proposal is dropped', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const session = await seedSession(db)
    const round = proposals('Song', 13)
    const { fill } = fakeApple((term) => (term.startsWith(`${round[0].title} `) ? [song('cover', round[0].title, 'Tribute Band')] : echo(term)))
    const { llm } = scriptedLlm([brief(5)], [round])

    await runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: true }, { id: session.id, userId: 'u1' }, 'party')

    expect((await queueTitles(db, session.id)).map((r) => r.title)).toEqual(round.slice(1, 6).map((s) => s.title))
    expect(await db.select().from(tracks).where(eq(tracks.appleId, 'cover'))).toHaveLength(0)
  })

  it('explicit off rejects an explicit hit', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const session = await seedSession(db)
    const round = proposals('Song', 13)
    const { fill } = fakeApple((term) => (term.startsWith(`${round[1].title} `)
      ? [{ ...echo(term)[0], explicit: true }]
      : echo(term)))
    const { llm } = scriptedLlm([{ ...brief(5), allowExplicit: false }], [round])

    await runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: true }, { id: session.id, userId: 'u1' }, 'clean party')

    const titles = (await queueTitles(db, session.id)).map((r) => r.title)
    expect(titles).not.toContain(round[1].title)
    expect(titles).toHaveLength(5)
  })

  it('a 429 in round one skips round two', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const session = await seedSession(db)
    const { fill, searches } = fakeApple((term, n) => {
      if (n === 2) throw new AppleCatalogError('rate_limit', 429)
      return echo(term)
    })
    const { llm, requests } = scriptedLlm([brief(5)], [proposals('Song', 13), proposals('Second', 9)])

    const { logged } = await withLog(() =>
      runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: true }, { id: session.id, userId: 'u1' }, 'party'))

    expect(proposalRequests(requests)).toHaveLength(1)
    expect(searches).toHaveLength(2)
    expect(await queueTitles(db, session.id)).toHaveLength(1)
    expect(logged.propose).toMatchObject({ rounds: 1, searches: 2, verified: 1 })
  })

  it('the verification deadline carries across rounds on an injected clock', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const session = await seedSession(db)
    let clock = 0
    const { fill, searches } = fakeApple(() => { clock += 2_000; return [] }, () => clock)
    const { llm, requests } = scriptedLlm([brief(5)], [proposals('First', 4), proposals('Second', 9)])

    await runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: true }, { id: session.id, userId: 'u1' }, 'party')

    // Round one spends 8 s on 4 searches; round two has 2 s, one search.
    expect(proposalRequests(requests)).toHaveLength(2)
    expect(searches).toHaveLength(5)
  })

  it(`skips round two once the turn has run past ${ROUND_TWO_CUTOFF_MS / 1000} s`, async () => {
    const db = await createTestDb()
    await seedUser(db)
    const session = await seedSession(db)
    let clock = 0
    const { fill } = fakeApple(() => [], () => clock)
    const base = scriptedLlm([brief(5)], [proposals('First', 13), proposals('Second', 9)])
    // A slow first proposal call.
    const llm: LlmClient = async (req) => {
      if (req.system === PROPOSE_SYSTEM_PROMPT) clock += ROUND_TWO_CUTOFF_MS + 1_000
      return base.llm(req)
    }

    const result = await runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: true }, { id: session.id, userId: 'u1' }, 'party')

    expect(proposalRequests(base.requests)).toHaveLength(1)
    expect(result.queue).toHaveLength(0)
    expect(toolResults(base.requests)).toEqual([INSUFFICIENT_SEEDS_TEXT])
  })

  it('a failed replacement round keeps round one\'s songs and logs the error', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const session = await seedSession(db)
    const round = proposals('Song', 13)
    const { fill } = fakeApple((term) => (term.startsWith(`${round[0].title} `) || term.startsWith(`${round[3].title} `) ? echo(term) : []))
    const base = scriptedLlm([brief(5)], [round])
    let asks = 0
    const llm: LlmClient = async (req) => {
      if (req.system === PROPOSE_SYSTEM_PROMPT && ++asks === 2) throw new LlmError('HTTP 529', 529)
      return base.llm(req)
    }

    const { value: result, logged } = await withLog(() =>
      runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: true }, { id: session.id, userId: 'u1' }, 'party'))

    expect(result.queue).toHaveLength(2)
    expect(toolResults(base.requests)[0]).toContain(SHORT_VERIFIED_TEXT)
    expect(logged.propose).toMatchObject({ rounds: 2, verified: 2, error: 'replacement' })
    expect(logged.error).toBeNull()
  })

  it('a mix that verifies enough but fewer than asked tells the DJ how many', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const session = await seedSession(db)
    const round = proposals('Song', 18)
    // 9 of the 18 confirm: at least MIN_VERIFIED, so no replacement round.
    const { fill } = fakeApple((term) => (Number(term.split(' ')[1]) % 2 === 0 ? echo(term) : []))
    const { llm, requests } = scriptedLlm([brief(10)], [round])

    await runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: true }, { id: session.id, userId: 'u1' }, 'party')

    const [text] = toolResults(requests)
    expect(proposalRequests(requests)).toHaveLength(1)
    expect(text).toContain(partialVerifiedNotice(9, 10))
    expect(text).not.toContain(SHORT_VERIFIED_TEXT)
  })

  it('a conflict retry reuses the verified songs: one proposal, one funnel row', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const session = await seedSession(db)
    const { fill } = fakeApple(async (term, n) => {
      // A concurrent writer moves the queue while the first search runs.
      if (n === 1) await db.update(djSessions).set({ queueVersion: 7 }).where(eq(djSessions.id, session.id))
      return echo(term)
    })
    const { llm, requests } = scriptedLlm([brief(5), brief(5)], [proposals('Song', 13)])

    const result = await runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: true }, { id: session.id, userId: 'u1' }, 'party')

    expect(result.queue).toHaveLength(5)
    expect(proposalRequests(requests)).toHaveLength(1)
    const rows = await db.select().from(funnelEvents).where(eq(funnelEvents.type, 'proposed_mix'))
    expect(rows).toHaveLength(1)
  })
})
