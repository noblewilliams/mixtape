import { describe, it, expect, vi } from 'vitest'
import { eq } from 'drizzle-orm'
import { readFileSync } from 'node:fs'
import { createTestDb, type TestDb } from '../helpers/db'
import { djSessions, trackFeatureFallbacks, trackFeatures, trackMeanings, tracks, user, userArtistSeeds, userTracks } from '../../src/db/schema'
import {
  runDjTurn,
  blendedNotice,
  corpusProposeShare,
  personalBlendNotice,
  CORPUS_NOTICE,
  CORPUS_PROPOSE_SHARE,
  NEW_MARKER_LEGEND,
  PERSONA_PROMPT_WITH_FILL,
  PERSONA_PROMPT_WITH_PROPOSE_FIRST,
  PROPOSE_FIRST_PERSONA_LINE,
  PERSONA_PROMPT,
  DjError,
  PROPOSE_SHARE,
  type DjDeps,
} from '../../src/dj/loop'
import { PROPOSE_EXTRA, PROPOSE_SYSTEM_PROMPT, PROPOSE_SYSTEM_PROMPT_PERSONAL, VERIFY_MAX } from '../../src/dj/propose'
import { DJ_TOOLS_WITH_OUTSIDE } from '../../src/dj/contracts'
import { proposeFirstEnabled } from '../../src/index'
import type { FillDeps } from '../../src/dj/catalogue-fill'
import type { CatalogSong } from '../../src/musickit/catalog'
import type { LlmClient, LlmRequest, LlmTurn } from '../../src/dj/llm'

// PROPOSE_FIRST (spec 2026-11-16 propose-first, step 2; plan S7): a
// personal mix blends songs the DJ proposes from all of music, verified on
// Apple. Golden structural assertions, never exact tracks.

const DIMS = 1024
const UNIT = Array.from({ length: DIMS }, (_, i) => (i === 0 ? 1 : 0))
const embedFake = async () => UNIT

async function seedUser(db: TestDb, id = 'u1') {
  await db.insert(user).values({ id, name: id, email: `${id}@example.com`, emailVerified: false, createdAt: new Date(), updatedAt: new Date() })
}

async function seedSession(db: TestDb, userId = 'u1') {
  const [s] = await db.insert(djSessions).values({ userId, title: 's' }).returning()
  return s
}

// n enriched library songs, Apple-labelled `genre`, cycling three artists.
// Titles are deterministic so two databases seeded alike read alike.
async function seedLibrary(db: TestDb, n: number, owner = 'u1', genre = 'Soul') {
  const artists = ['Mine A', 'Mine B', 'Mine C']
  for (let i = 0; i < n; i++) {
    const [t] = await db.insert(tracks).values({ appleId: `lib-${owner}-${i}`, title: `Library ${i}`, artist: artists[i % 3], genre, durationMs: 200_000 }).returning()
    await db.insert(trackFeatures).values({ trackId: t.id, tempo: 100, energy: 0.5, valence: 0.5, source: 'reccobeats' })
    await db.insert(trackMeanings).values({ trackId: t.id, embedding: UNIT, lyricsSource: 'lrclib' })
    await db.insert(userTracks).values({ userId: owner, trackId: t.id, inLibrary: true })
  }
}

type Proposed = { title: string; artist: string; reason: string; energy?: number; valence?: number }

function proposals(n: number): Proposed[] {
  return Array.from({ length: n }, (_, i) => ({ title: `Song ${i}`, artist: ['Miles Davis', 'Bill Evans', 'Chet Baker'][i % 3], reason: `reason ${i}` }))
}

// Apple confirms every song in `confirmed`, labelled Jazz unless `genreOf`
// says otherwise.
function fakeApple(confirmed: Proposed[], genreOf: (s: Proposed) => string = () => 'Jazz') {
  const searches: string[] = []
  const songs = new Map(confirmed.map((s, i) => [`${s.title} ${s.artist}`, {
    appleId: `v-${i}`, isrc: null, title: s.title, artist: s.artist, album: 'Album', artwork: null, durationMs: 200_000, genre: genreOf(s), releaseYear: 1959, explicit: false,
  } satisfies CatalogSong]))
  const catalog: FillDeps['catalog'] = {
    async searchArtists() { return [] },
    async artistTopSongs() { return [] },
    async searchSongs(_sf, term) {
      searches.push(term)
      const hit = songs.get(term)
      return hit ? [hit] : []
    },
  }
  const fill: FillDeps = {
    catalog,
    defaultStorefront: 'us',
    enrich: { storefront: 'us', itunes: async () => null, features: async () => null, lyrics: async () => null, embed: async () => UNIT },
  }
  return { fill, searches }
}

const isProposal = (req: LlmRequest) => req.system === PROPOSE_SYSTEM_PROMPT || req.system === PROPOSE_SYSTEM_PROMPT_PERSONAL

function textTurn(text: string): LlmTurn {
  return { text, toolCalls: [], raw: [{ type: 'text', text }], stopReason: 'end_turn', usage: null }
}

function curationCount(req: LlmRequest): number {
  return Number(((req.messages[0].content as Array<{ text?: string }>)[1]?.text ?? '').match(/Pick up to (\d+) tracks/)?.[1] ?? NaN)
}

// Curation answers every pool id up to the count asked; proposals answer
// `proposed`; the conversation makes each call in `calls`, then replies.
function scriptedLlm(calls: Array<{ name: string; input: unknown }>, proposed: Proposed[] = []) {
  const requests: LlmRequest[] = []
  let conv = 0
  const llm: LlmClient = async (req) => {
    requests.push(req)
    if (isProposal(req)) return textTurn(JSON.stringify(proposed))
    if (req.tools.length === 0) {
      const blocks = req.messages[0].content as Array<{ text?: string }>
      const ids = Array.from((blocks[0]?.text ?? '').matchAll(/^([0-9a-f-]{36}) \|/gm)).map((m) => m[1])
      return textTurn(JSON.stringify(ids.slice(0, curationCount(req)).map((id) => ({ id, reason: 'fits' }))))
    }
    const call = calls[conv]
    conv += 1
    if (call) {
      const c = { id: `c${conv}`, name: call.name, input: call.input }
      return { text: '', toolCalls: [c], raw: [{ type: 'tool_use', ...c }], stopReason: 'tool_use', usage: null }
    }
    return textTurn('here you go.')
  }
  return { llm, requests }
}

const proposalRequests = (requests: LlmRequest[]) => requests.filter(isProposal)
const curationRequests = (requests: LlmRequest[]) => requests.filter((r) => r.tools.length === 0 && !isProposal(r))

function toolResults(requests: LlmRequest[]): string[] {
  const last = requests.filter((r) => r.tools.length > 0).at(-1)!
  return last.messages
    .filter((m) => m.role === 'user' && Array.isArray(m.content) && (m.content[0] as { type?: string }).type === 'tool_result')
    .map((m) => (m.content as Array<{ content: string }>)[0].content)
}

async function notPersonal(db: TestDb, sessionId: string) {
  const [row] = await db.select({ notPersonal: djSessions.notPersonal }).from(djSessions).where(eq(djSessions.id, sessionId))
  return row.notPersonal
}

const generate = (input: Record<string, unknown>) => ({ name: 'generate_queue', input: { themes: 'late evening, warm', ...input } })

async function personalTurn(opts: { library?: number; input: Record<string, unknown>; deps?: Partial<DjDeps>; brief?: string; genre?: string; lyrics?: FillDeps['enrich']['lyrics'] }) {
  const db = await createTestDb()
  await seedUser(db)
  await seedLibrary(db, opts.library ?? 30, 'u1', opts.genre)
  const session = await seedSession(db)
  const round = proposals(22)
  const { fill, searches } = fakeApple(round)
  if (opts.lyrics) fill.enrich.lyrics = opts.lyrics
  const { llm, requests } = scriptedLlm([generate(opts.input)], round)
  const deps: DjDeps = { llm, embed: embedFake, fill, neverRefuse: true, proposeFirst: true, ...opts.deps }
  const result = await runDjTurn(db, deps, { id: session.id, userId: 'u1' }, opts.brief ?? 'something for tonight')
  const proposedAt = result.queue.flatMap((t, i) => (t.title.startsWith('Song ') ? [i] : []))
  return { db, session, result, requests, searches, proposedAt }
}

describe('PROPOSE_FIRST flag', () => {
  it('only the exact string "on" enables it', () => {
    expect(proposeFirstEnabled({ PROPOSE_FIRST: 'on' })).toBe(true)
    for (const value of [undefined, 'off', 'ON', ' on', 'true', '1', '']) {
      expect(proposeFirstEnabled({ PROPOSE_FIRST: value })).toBe(false)
    }
  })

  // S10 (2026-11-17): the per-listener rollout list is gone; the flag is
  // one switch for everyone.
  it('ships on in wrangler.jsonc (cutover 2026-11-17), with no listener list', () => {
    const config = readFileSync(new URL('../../wrangler.jsonc', import.meta.url), 'utf8')
    expect(config).toMatch(/"PROPOSE_FIRST":\s*"on"/)
    expect(config).not.toMatch(/"PROPOSE_FIRST_USERS":/)
    expect(config).not.toMatch(/OUTSIDE_PICKS/)
  })
})

describe('flag off is today', () => {
  // What the model and Apple see, uuids aside: off and absent must match,
  // and both are today's personal mix (no blend, a full-length curation).
  const shape = (requests: LlmRequest[]) => requests.map((r) => ({
    system: r.system,
    tools: r.tools,
    kind: isProposal(r) ? 'propose' : r.tools.length === 0 ? 'curate' : 'chat',
    count: r.tools.length === 0 && !isProposal(r) ? curationCount(r) : null,
  }))

  it('proposeFirst false sends exactly what an unset flag sends', async () => {
    const absent = await personalTurn({ input: { targetCount: 20 }, deps: { proposeFirst: undefined } })
    const off = await personalTurn({ input: { targetCount: 20 }, deps: { proposeFirst: false } })
    expect(shape(off.requests)).toEqual(shape(absent.requests))
    expect(off.searches).toEqual(absent.searches)

    // The tool result line for line, bar which library songs were listed
    // (equal-scored pool rows tie by their random ids).
    const lines = (text: string) => text.replace(/[0-9a-f-]{36}/g, 'ID').replace(/^\[\d+\] Library \d+ — Mine [ABC]$/gm, '[n] library song')
    expect(lines(toolResults(off.requests)[0])).toEqual(lines(toolResults(absent.requests)[0]))
    // Today's personal mix: the library fills it, nothing is proposed.
    expect(proposalRequests(off.requests)).toHaveLength(0)
    expect(curationCount(curationRequests(off.requests)[0])).toBe(20)
    expect(off.requests[0].system).toBe(PERSONA_PROMPT_WITH_FILL)
    expect(off.proposedAt).toHaveLength(0)
  })

  it('the corpus share is 0.75 with the flag on, 0.5 off', () => {
    expect(corpusProposeShare(true)).toBe(0.75)
    expect(corpusProposeShare(false)).toBe(0.5)
    expect(CORPUS_PROPOSE_SHARE).toBe(0.5)
  })

  async function corpusTurn(proposeFirst: boolean) {
    const db = await createTestDb()
    await seedUser(db)
    // Seeds whose songs sit in someone else's library: a corpus listener.
    await seedUser(db, 'other')
    await seedLibrary(db, 27, 'other')
    for (const name of ['Mine A', 'Mine B', 'Mine C']) await db.insert(userArtistSeeds).values({ userId: 'u1', name, source: 'interview' })
    const session = await seedSession(db)
    const round = proposals(22)
    const { fill } = fakeApple(round)
    const { llm } = scriptedLlm([generate({ targetCount: 8 })], round)
    const result = await runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: true, proposeFirst }, { id: session.id, userId: 'u1' }, 'play')
    return result.queue.filter((t) => t.title.startsWith('Song ')).length
  }

  it('a corpus mix proposes 0.75 of itself with the flag on, 0.5 off', async () => {
    expect(await corpusTurn(true)).toBe(6)
    expect(await corpusTurn(false)).toBe(4)
  })
})

describe('a personal mix blends proposals', () => {
  it('golden: mix and 20 songs, about half proposed, spread, new to them, still personal', async () => {
    const { db, session, result, requests, searches, proposedAt } = await personalTurn({ input: { targetCount: 20 } })

    expect(result.queue).toHaveLength(20)
    expect(proposedAt.length).toBe(Math.floor(20 * PROPOSE_SHARE.mix))
    // Interleaved, never bunched: no two proposed songs side by side.
    for (let i = 1; i < proposedAt.length; i++) expect(proposedAt[i] - proposedAt[i - 1]).toBeGreaterThan(1)
    // New to them, as outside picks are; the library's own songs are not.
    for (const [i, t] of result.queue.entries()) expect(t.newToYou).toBe(proposedAt.includes(i))
    expect(await notPersonal(db, session.id)).toBe(false)

    // The library curates the whole mix, so it covers any proposal that
    // does not land.
    expect(curationRequests(requests).map(curationCount)).toEqual([20])
    // One personal proposal round, leaning to their taste.
    const [proposal] = proposalRequests(requests)
    expect(proposalRequests(requests)).toHaveLength(1)
    expect(proposal.system).toBe(PROPOSE_SYSTEM_PROMPT_PERSONAL)
    const block = proposal.messages[0].content as string
    // Asked for the whole mix, so the unsearched rest are spares; only the
    // share (10) is verified up front.
    expect(block).toContain(`Propose up to ${Math.min(20 + PROPOSE_EXTRA, VERIFY_MAX)} songs.`)
    expect(block).toMatch(/Artists this listener plays most: Mine/)
    expect(searches).toHaveLength(10)

    const [text] = toolResults(requests)
    expect(text).toContain(personalBlendNotice(10))
    expect(text).not.toContain(CORPUS_NOTICE)
    expect(text).not.toContain(blendedNotice(10))
    expect(text).toMatch(/10 of these picks are songs this listener does not have yet/)
    expect(text).toContain('queue generated: 20 tracks')
    // The listing marks the new ones too.
    expect(text).toMatch(/Song \d+ — [^\n]+ \| new/)
    expect(text).toContain(NEW_MARKER_LEGEND)
    // The persona and tools that carry allowOutside.
    expect(requests[0].system).toBe(PERSONA_PROMPT_WITH_PROPOSE_FIRST)
    expect(requests[0].tools).toBe(DJ_TOOLS_WITH_OUTSIDE)
  })

  it('the proposal call is told the songs they own, at most 60', async () => {
    const { requests } = await personalTurn({ library: 80, input: { targetCount: 20 } })
    const block = proposalRequests(requests)[0].messages[0].content as string
    const owned = block.split('\n').filter((l) => /^- Library \d+ by Mine [ABC]$/.test(l))
    expect(owned.length).toBeGreaterThan(0)
    expect(owned.length).toBeLessThanOrEqual(60)
  })

  it('comfort is the library\'s', async () => {
    const { result, proposedAt } = await personalTurn({ input: { targetCount: 20, familiarity: 'comfort' } })
    expect(result.queue).toHaveLength(20)
    expect(proposedAt.length).toBeLessThan(10)
  })

  it('adventurous is mostly proposals', async () => {
    const { result, proposedAt, requests } = await personalTurn({ input: { targetCount: 20, familiarity: 'adventurous' } })
    expect(result.queue).toHaveLength(20)
    expect(proposedAt.length).toBeGreaterThan(10)
    expect(proposedAt.length).toBe(Math.floor(20 * PROPOSE_SHARE.adventurous))
    expect(curationRequests(requests).map(curationCount)).toEqual([20])
  })

  it('allowOutside false proposes nothing', async () => {
    const { result, requests, searches, proposedAt } = await personalTurn({ input: { targetCount: 20, allowOutside: false } })
    expect(proposalRequests(requests)).toHaveLength(0)
    expect(searches).toHaveLength(0)
    expect(proposedAt).toHaveLength(0)
    expect(result.queue).toHaveLength(20)
    expect(curationRequests(requests).map(curationCount)).toEqual([20])
  })

  it('an own-music brief (their favourites) proposes nothing', async () => {
    const { requests, proposedAt } = await personalTurn({ input: { targetCount: 20, familiarity: 'comfort' }, brief: 'my favourites' })
    expect(proposalRequests(requests)).toHaveLength(0)
    expect(proposedAt).toHaveLength(0)
    expect(toolResults(requests)[0]).not.toContain('own yet, chosen for this brief')
  })

  it('golden: a library with no jazz and a soft jazz brief comes back full and jazz, with no shortfall', async () => {
    // The sound check passes none of the library's Soul songs.
    const checked: string[] = []
    const titleComplete = async (opts: { prompt: string }) => { checked.push(opts.prompt); return '[]' }
    const { result, requests, proposedAt } = await personalTurn({
      input: { themes: 'rainy sunday reading, soft jazz', genres: ['jazz'], targetCount: 12 },
      brief: 'rainy sunday reading, soft jazz',
      genre: 'Soul',
      deps: { titleComplete: titleComplete as DjDeps['titleComplete'] },
    })
    // The library really came up short: its songs went to the check and failed.
    expect(checked.some((p) => /Library \d+/.test(p))).toBe(true)
    expect(result.queue).toHaveLength(12)
    const [text] = toolResults(requests)
    expect(text).not.toMatch(/this mix is \d+ of the \d+ songs asked for/)
    // Apple labels every verified proposal Jazz (fakeApple); the library none.
    expect(proposedAt.length).toBeGreaterThanOrEqual(6)
    expect(result.queue.filter((t) => t.title.startsWith('Library '))).toHaveLength(0)
  })

  it('the feature chain runs on the blended proposals only', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedLibrary(db, 30)
    const session = await seedSession(db)
    const round = proposals(22).map((p) => ({ ...p, energy: 0.3, valence: 0.6 }))
    const { fill } = fakeApple(round)
    fill.deezerTempo = { tempoByIsrc: async () => 120 }
    const { llm } = scriptedLlm([generate({ targetCount: 10 })], round)
    const result = await runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: true, proposeFirst: true }, { id: session.id, userId: 'u1' }, 'tonight')
    const rows = await db.select({ title: tracks.title, energy: trackFeatureFallbacks.energy })
      .from(trackFeatureFallbacks).innerJoin(tracks, eq(tracks.id, trackFeatureFallbacks.trackId))
    const queued = result.queue.map((t) => t.title).filter((t) => t.startsWith('Song '))
    expect(queued).toHaveLength(5)
    expect(rows.map((r) => r.title).sort()).toEqual([...queued].sort())
    for (const r of rows) expect(r.energy).toBe(0.3)
  })

  it('a rise mix places its proposals by energy, from the model\'s estimates (S9)', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedLibrary(db, 30)
    const session = await seedSession(db)
    // Proposed loudest first; no feature chain, so the estimates are all there is.
    const round = proposals(22).map((p, i) => ({ ...p, energy: Math.round((0.9 - i * 0.03) * 100) / 100 }))
    const energyOf = new Map(round.map((p) => [p.title, p.energy]))
    const { fill } = fakeApple(round)
    const { llm } = scriptedLlm([generate({ targetCount: 10, energyArc: 'rise' })], round)
    const result = await runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: true, proposeFirst: true }, { id: session.id, userId: 'u1' }, 'tonight')
    const placed = result.queue.filter((t) => t.title.startsWith('Song ')).map((t) => energyOf.get(t.title)!)
    expect(result.queue).toHaveLength(10)
    expect(placed).toHaveLength(5)
    expect(placed).toEqual([...placed].sort((a, b) => a - b))
    expect(placed[0]).toBeLessThan(placed.at(-1)!)
  })

  it('a library short of its share is topped up from the same proposal round, the mix stays full', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedLibrary(db, 3)
    const session = await seedSession(db)
    const round = proposals(22)
    const { fill, searches } = fakeApple(round)
    const { llm, requests } = scriptedLlm([generate({ targetCount: 12 })], round)
    const result = await runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: true, proposeFirst: true }, { id: session.id, userId: 'u1' }, 'tonight')
    expect(result.queue).toHaveLength(12)
    // The blend's 6, then 3 more from the round's unsearched songs: one call.
    expect(result.queue.filter((t) => t.title.startsWith('Song '))).toHaveLength(9)
    expect(result.queue.filter((t) => t.title.startsWith('Library '))).toHaveLength(3)
    expect(proposalRequests(requests)).toHaveLength(1)
    expect(searches).toHaveLength(9)
    expect(toolResults(requests)[0]).not.toMatch(/this mix is \d+ of the \d+ songs asked for/)
  })


  // Live 2026-11-16 ("lofi afro house slow living"): the library curated
  // next to nothing for the genre and the first round, sized for the
  // proposed share, had too few unsearched songs left to fill the rest. The
  // round is sized to the whole mix, so its spares cover it.
  it('a genre brief the library cannot cover fills from the one round\'s spares, no second proposal call', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedLibrary(db, 30, 'u1', 'Soul')
    const session = await seedSession(db)
    const round = proposals(22)
    // Apple misses the first four.
    const { fill, searches } = fakeApple(round.slice(4))
    const titleComplete = async () => '[]'
    const { llm, requests } = scriptedLlm([generate({ genres: ['jazz'], targetCount: 15 })], round)
    const result = await runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: true, proposeFirst: true, titleComplete: titleComplete as DjDeps['titleComplete'] },
      { id: session.id, userId: 'u1' }, 'soft jazz')
    expect(result.queue).toHaveLength(15)
    expect(result.queue.every((t) => t.title.startsWith('Song '))).toBe(true)
    expect(proposalRequests(requests)).toHaveLength(1)
    const block = proposalRequests(requests)[0].messages[0].content as string
    expect(Number(block.match(/Propose up to (\d+) songs\./)?.[1])).toBeGreaterThanOrEqual(15)
    expect(searches.length).toBeLessThanOrEqual(22)
    expect(toolResults(requests)[0]).not.toMatch(/this mix is \d+ of the \d+ songs asked for/)
  })

  it('proposals the sound check drops are replaced from the round\'s spares, with at most one more check', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedLibrary(db, 6, 'u1', 'Jazz')
    const session = await seedSession(db)
    const round = proposals(22)
    // Five of the first round and one spare are labelled Pop and fail the check.
    const pop = new Set(['Song 0', 'Song 1', 'Song 2', 'Song 3', 'Song 4', 'Song 11'])
    const { fill } = fakeApple(round, (s) => (pop.has(s.title) ? 'Pop' : 'Jazz'))
    const checked: string[] = []
    const titleComplete = async (opts: { prompt: string }) => { checked.push(opts.prompt); return '[]' }
    const { llm, requests } = scriptedLlm([generate({ genres: ['jazz'], targetCount: 15 })], round)
    const result = await runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: true, proposeFirst: true, titleComplete: titleComplete as DjDeps['titleComplete'] },
      { id: session.id, userId: 'u1' }, 'soft jazz')
    expect(result.queue).toHaveLength(15)
    expect(result.queue.filter((t) => t.title.startsWith('Library '))).toHaveLength(6)
    expect(result.queue.some((t) => pop.has(t.title))).toBe(false)
    expect(proposalRequests(requests)).toHaveLength(1)
    // The proposals' check, and one for the spares.
    expect(checked.length).toBeLessThanOrEqual(2)
    const [text] = toolResults(requests)
    expect(text).not.toMatch(/this mix is \d+ of the \d+ songs asked for/)
    expect(text).not.toMatch(/failed the jazz check/)
  })
})

describe('the library covers proposals that do not land', () => {
  const noShortfall = (requests: LlmRequest[]) => expect(toolResults(requests)[0]).not.toMatch(/this mix is \d+ of the \d+ songs asked for/)

  it('a proposal call that throws leaves a full mix from the library, with no shortfall', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedLibrary(db, 30)
    const session = await seedSession(db)
    const { fill } = fakeApple(proposals(22))
    const { llm: base, requests } = scriptedLlm([generate({ targetCount: 20 })])
    const llm: LlmClient = async (req) => {
      if (isProposal(req)) { requests.push(req); throw new Error('proposal call failed') }
      return base(req)
    }
    const result = await runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: true, proposeFirst: true }, { id: session.id, userId: 'u1' }, 'tonight')
    expect(result.queue).toHaveLength(20)
    expect(result.queue.every((t) => t.title.startsWith('Library '))).toBe(true)
    noShortfall(requests)
  })

  it('Apple confirming nothing leaves a full mix from the library', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedLibrary(db, 30)
    const session = await seedSession(db)
    const { fill } = fakeApple([])
    const { llm, requests } = scriptedLlm([generate({ targetCount: 20 })], proposals(22))
    const result = await runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: true, proposeFirst: true }, { id: session.id, userId: 'u1' }, 'tonight')
    expect(result.queue).toHaveLength(20)
    expect(result.queue.every((t) => t.title.startsWith('Library '))).toBe(true)
    noShortfall(requests)
    expect(toolResults(requests)[0]).not.toContain('own yet, chosen for this brief')
  })

  it('an adventurous 40-song mix past the turn\'s searches is still 40 songs', async () => {
    const { result, requests, proposedAt, searches } = await personalTurn({ library: 60, input: { targetCount: 40, familiarity: 'adventurous' } })
    expect(result.queue).toHaveLength(40)
    expect(searches.length).toBeLessThanOrEqual(22)
    expect(proposedAt.length).toBeGreaterThan(0)
    expect(proposedAt.length).toBeLessThanOrEqual(30)
    noShortfall(requests)
  })

  it('a personal blend whose library curation fails fails the turn, as before', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedLibrary(db, 30)
    const session = await seedSession(db)
    const { fill } = fakeApple(proposals(22))
    const { llm: base } = scriptedLlm([generate({ targetCount: 20 })], proposals(22))
    const llm: LlmClient = async (req) => (req.tools.length === 0 && !isProposal(req) ? textTurn('not json at all') : base(req))
    const error = await runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: true, proposeFirst: true }, { id: session.id, userId: 'u1' }, 'tonight').catch((e) => e)
    expect(error).toBeInstanceOf(DjError)
    expect((error as DjError).kind).toBe('curation')
  })
})

describe('new marks and persona', () => {
  it('the propose-first persona is today\'s plus its own line, not the outside cap', () => {
    expect(PERSONA_PROMPT_WITH_PROPOSE_FIRST.replace(`${PROPOSE_FIRST_PERSONA_LINE}\n`, '')).toBe(PERSONA_PROMPT)
    expect(PROPOSE_FIRST_PERSONA_LINE).not.toMatch(/a few|cap/)
  })

  it('new songs stay marked on the next turn\'s session context and after an edit', async () => {
    const { db, session } = await personalTurn({ input: { targetCount: 10 } })
    const { fill } = fakeApple(proposals(22))

    const chat = scriptedLlm([])
    await runDjTurn(db, { llm: chat.llm, embed: embedFake, fill, neverRefuse: true, proposeFirst: true }, { id: session.id, userId: 'u1' }, 'nice')
    expect(JSON.stringify(chat.requests[0].messages)).toMatch(/Song \d+ — [^"\\]+ \| new/)

    const edit = scriptedLlm([{ name: 'edit_queue', input: { ops: [{ op: 'remove', position: 0 }] } }])
    await runDjTurn(db, { llm: edit.llm, embed: embedFake, fill, neverRefuse: true, proposeFirst: true }, { id: session.id, userId: 'u1' }, 'drop the first')
    expect(toolResults(edit.requests).at(-1)).toMatch(/Song \d+ — [^\n]+ \| new/)
  })
})

describe('remake and outside picks', () => {
  it('"Remake with my music" never blends proposals', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedLibrary(db, 30)
    const [session] = await db.insert(djSessions).values({ userId: 'u1', title: 's', notPersonal: true }).returning()
    const { fill, searches } = fakeApple(proposals(22))
    const { llm, requests } = scriptedLlm([generate({ targetCount: 20, familiarity: 'adventurous' })], proposals(22))
    const result = await runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: true, proposeFirst: true }, { id: session.id, userId: 'u1' }, 'remake', { remake: true })
    expect(proposalRequests(requests)).toHaveLength(0)
    expect(searches).toHaveLength(0)
    expect(result.queue).toHaveLength(20)
    expect(result.queue.every((t) => t.title.startsWith('Library '))).toBe(true)
  })

  // Retired with OUTSIDE_PICKS (S10, 2026-11-17): the catalogue outside
  // pool. Catalogue neighbours a personal listener does not own never reach
  // the curation; the songs new to them are proposals only.
  it('catalogue neighbours never join a personal mix: new songs are proposals only', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedLibrary(db, 30)
    // Catalogue neighbours the listener does not own: what the retired
    // outside pool drew on.
    await seedUser(db, 'other')
    for (let i = 0; i < 20; i++) {
      const [t] = await db.insert(tracks).values({ appleId: `other-${i}`, title: `Other ${i}`, artist: 'Someone Else', genre: 'Soul', durationMs: 200_000 }).returning()
      await db.insert(trackFeatures).values({ trackId: t.id, tempo: 100, energy: 0.5, valence: 0.5, source: 'reccobeats' })
      await db.insert(trackMeanings).values({ trackId: t.id, embedding: UNIT, lyricsSource: 'lrclib' })
      await db.insert(userTracks).values({ userId: 'other', trackId: t.id, inLibrary: true })
    }
    const session = await seedSession(db)
    const { fill } = fakeApple(proposals(22))
    const { llm, requests } = scriptedLlm([generate({ targetCount: 20, familiarity: 'adventurous' })], proposals(22))
    const result = await runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: true, proposeFirst: true }, { id: session.id, userId: 'u1' }, 'tonight')
    const curationText = JSON.stringify(curationRequests(requests)[0].messages)
    expect(curationText).not.toContain('Other ')
    expect(result.queue.filter((t) => t.title.startsWith('Other '))).toHaveLength(0)
    for (const t of result.queue.filter((q) => q.newToYou)) expect(t.title).toMatch(/^Song /)
  })
})

// Live 2026-11-16 ("lofi afro house slow living great instrumentals"): 15
// proposed, 8 verified, the sound check rightly rejected the ambient and
// electronica ones, and the library holds almost no afro house: 1 song. A
// genre brief now asks for a larger, genre-true first pool, verifies more of
// it, and refills to a floor from the closest songs the check rejected.
// These turns name no artists (the scripted model answers the artist call
// with an empty list), so they run on the song-proposal fallback; the
// artist pool itself is covered in artist-pool.test.ts.
describe('a genre brief comes back full (floor)', () => {
  // The sound check passes the songs whose titles `passes` accepts.
  function checker(passes: (title: string) => boolean = () => false) {
    const prompts: string[] = []
    const titleComplete = async (opts: { prompt: string }) => {
      prompts.push(opts.prompt)
      const ok = Array.from(opts.prompt.matchAll(/^(\d+) \| (.+?) — /gm)).filter((m) => passes(m[2])).map((m) => Number(m[1]))
      return JSON.stringify(ok)
    }
    return { prompts, titleComplete: titleComplete as unknown as DjDeps['titleComplete'] }
  }

  async function genreTurn(opts: {
    targetCount: number
    library?: number
    libraryGenre?: string
    round?: number
    confirmed?: (p: Proposed, i: number) => boolean
    genreOf?: (p: Proposed) => string
    passes?: (title: string) => boolean
    genres?: string[]
    deps?: Partial<DjDeps>
    checkThrows?: boolean
  }) {
    const db = await createTestDb()
    await seedUser(db)
    await seedLibrary(db, opts.library ?? 30, 'u1', opts.libraryGenre ?? 'Soul')
    const session = await seedSession(db)
    const round = proposals(opts.round ?? 34)
    const { fill, searches } = fakeApple(round.filter((p, i) => (opts.confirmed ?? (() => true))(p, i)), opts.genreOf ?? (() => 'Pop'))
    const check = checker(opts.passes)
    const titleComplete = opts.checkThrows ? (async () => { throw new Error('check down') }) as unknown as DjDeps['titleComplete'] : check.titleComplete
    const { llm, requests } = scriptedLlm([generate({ genres: opts.genres ?? ['jazz'], targetCount: opts.targetCount })], round)
    const deps: DjDeps = { llm, embed: embedFake, fill, neverRefuse: true, proposeFirst: true, titleComplete, ...opts.deps }
    const result = await runDjTurn(db, deps, { id: session.id, userId: 'u1' }, 'lofi jazz slow living')
    const [text] = toolResults(requests)
    return { result, requests, searches, text, checks: check.prompts }
  }

  const askedFor = (req: LlmRequest) => Number((req.messages[0].content as string).match(/Propose up to (\d+) songs\./)?.[1])
  const noDuplicates = (queue: Array<{ trackId: string; title: string; artist: string }>) => {
    expect(new Set(queue.map((t) => t.trackId)).size).toBe(queue.length)
    expect(new Set(queue.map((t) => `${t.title.toLowerCase()}|${t.artist.toLowerCase()}`)).size).toBe(queue.length)
  }

  it('the proposal call asks for twice the mix, genre-true, with thinking off', async () => {
    const { requests } = await genreTurn({ targetCount: 15, genreOf: () => 'Jazz' })
    const [req] = proposalRequests(requests)
    expect(askedFor(req)).toBe(30)
    expect(req.messages[0].content as string).toContain('Genre: every song must be jazz.')
    expect(req.thinking).toBe('off')
  })

  it('a brief with no genre keeps proposalCount, thinking off as well', async () => {
    const { requests } = await personalTurn({ input: { targetCount: 10 } })
    const [req] = proposalRequests(requests)
    expect(askedFor(req)).toBe(10 + PROPOSE_EXTRA)
    expect(req.messages[0].content as string).not.toMatch(/^Genres?:/m)
    expect(req.thinking).toBe('off')
  })

  it('a long genre mix asks for at most 34 and may search past 22, never past 34', async () => {
    const { requests, searches } = await genreTurn({ targetCount: 20, passes: (t) => Number(t.split(' ')[1]) % 4 === 0 })
    expect(askedFor(proposalRequests(requests)[0])).toBe(34)
    expect(searches.length).toBeGreaterThan(VERIFY_MAX)
    expect(searches.length).toBeLessThanOrEqual(34)
  })

  it('golden: library curates nothing, Apple confirms many, the check rejects most: the mix refills to the floor and says some lean adjacent', async () => {
    const jazz = new Set(['Song 0', 'Song 1', 'Song 2'])
    const { result, text, requests } = await genreTurn({ targetCount: 15, genreOf: (p) => (jazz.has(p.title) ? 'Jazz' : 'Pop') })
    // floor = min(15, max(10, ceil(2/3 × 15))) = 10
    expect(result.queue).toHaveLength(10)
    expect(result.queue.filter((t) => t.title.startsWith('Library '))).toHaveLength(0)
    for (const t of jazz) expect(result.queue.map((q) => q.title)).toContain(t)
    expect(text).toContain('note: 7 of these songs lean adjacent to jazz (close in sound, not strictly the genre) so the mix could stay full. Say so in one line.')
    expect(text).not.toMatch(/this mix is \d+ of the \d+ songs asked for/)
    expect(proposalRequests(requests)).toHaveLength(1)
    noDuplicates(result.queue)
  })

  it('refills from verified proposals first, then the library songs the check dropped, in curator order', async () => {
    const jazz = new Set(['Song 0', 'Song 1', 'Song 2'])
    // Apple confirms only five songs: three jazz, two not.
    const { result, text } = await genreTurn({
      targetCount: 15, confirmed: (_p, i) => i < 5, genreOf: (p) => (jazz.has(p.title) ? 'Jazz' : 'Pop'),
    })
    expect(result.queue).toHaveLength(10)
    expect(result.queue.filter((t) => t.title.startsWith('Song '))).toHaveLength(5)
    expect(result.queue.filter((t) => t.title.startsWith('Library '))).toHaveLength(5)
    expect(text).toContain('note: 7 of these songs lean adjacent to jazz')
    noDuplicates(result.queue)
  })

  it('a check that passes enough refills nothing and says nothing of adjacency', async () => {
    const { result, text } = await genreTurn({ targetCount: 15, genreOf: () => 'Jazz' })
    expect(result.queue).toHaveLength(15)
    expect(text).not.toMatch(/lean adjacent/)
    expect(text).not.toMatch(/this mix is \d+ of the \d+ songs asked for/)
  })

  it('a mix already at the floor without a refill is left as it is', async () => {
    const jazz = new Set(Array.from({ length: 11 }, (_, i) => `Song ${i}`))
    const { result, text } = await genreTurn({ targetCount: 15, confirmed: (_p, i) => i < 11, genreOf: (p) => (jazz.has(p.title) ? 'Jazz' : 'Pop') })
    expect(result.queue).toHaveLength(11)
    expect(text).not.toMatch(/lean adjacent/)
    expect(text).toMatch(/this mix is 11 of the 15 songs asked for/)
  })

  it('nothing to refill: the short notice stands as before', async () => {
    // Two library songs Apple labels Jazz, three verified jazz proposals: no rejects.
    const { result, text } = await genreTurn({ targetCount: 15, library: 2, libraryGenre: 'Jazz', confirmed: (_p, i) => i < 3, genreOf: () => 'Jazz' })
    expect(result.queue).toHaveLength(5)
    expect(text).not.toMatch(/lean adjacent/)
    expect(text).toMatch(/this mix is 5 of the 15 songs asked for/)
  })

  it('below the floor even after refilling everything: adjacency and the short notice both', async () => {
    const { result, text } = await genreTurn({ targetCount: 15, library: 2, confirmed: (_p, i) => i < 3 })
    expect(result.queue).toHaveLength(5)
    expect(text).toContain('note: 5 of these songs lean adjacent to jazz')
    expect(text).toMatch(/this mix is 5 of the 15 songs asked for/)
  })

  it('a check that cannot run refills nothing: no unchecked song is queued', async () => {
    const jazz = new Set(['Song 0', 'Song 1', 'Song 2'])
    const { result, text } = await genreTurn({ targetCount: 15, checkThrows: true, genreOf: (p) => (jazz.has(p.title) ? 'Jazz' : 'Pop') })
    expect(result.queue.every((t) => jazz.has(t.title))).toBe(true)
    expect(text).not.toMatch(/lean adjacent/)
  })

  it('never more than targetCount: a small mix refills to its own length', async () => {
    const { result, text } = await genreTurn({ targetCount: 8 })
    expect(result.queue).toHaveLength(8)
    expect(text).toContain('note: 8 of these songs lean adjacent to jazz')
    noDuplicates(result.queue)
  })

  it('several genres are named as alternatives in the notice', async () => {
    const { text } = await genreTurn({ targetCount: 8, genres: ['afro house', 'lofi'] })
    expect(text).toContain('lean adjacent to afro house or lofi')
  })

  it('flag off: a personal genre brief keeps the old limits, thinking and notices', async () => {
    const { requests, searches, text } = await genreTurn({ targetCount: 15, deps: { proposeFirst: false } })
    for (const req of proposalRequests(requests)) {
      expect('thinking' in req).toBe(false)
      expect(askedFor(req)).toBeLessThanOrEqual(VERIFY_MAX)
    }
    expect(searches.length).toBeLessThanOrEqual(VERIFY_MAX)
    expect(text).not.toMatch(/lean adjacent/)
  })

  it('a corpus genre mix with the flag on is unchanged: no thinking change, no refill', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedUser(db, 'other')
    await seedLibrary(db, 27, 'other')
    for (const name of ['Mine A', 'Mine B', 'Mine C']) await db.insert(userArtistSeeds).values({ userId: 'u1', name, source: 'interview' })
    const session = await seedSession(db)
    const round = proposals(22)
    const { fill, searches } = fakeApple(round, () => 'Pop')
    const { llm, requests } = scriptedLlm([generate({ genres: ['jazz'], targetCount: 15 })], round)
    const { titleComplete } = checker()
    await runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: true, proposeFirst: true, titleComplete }, { id: session.id, userId: 'u1' }, 'jazz')
    const [req] = proposalRequests(requests)
    expect('thinking' in req).toBe(false)
    expect(askedFor(req)).toBe(Math.floor(15 * 0.75) + PROPOSE_EXTRA)
    expect(searches.length).toBeLessThanOrEqual(VERIFY_MAX)
    expect(toolResults(requests)[0]).not.toMatch(/lean adjacent/)
  })
})

// Instrumental briefs check verified proposals on LRCLIB too (2026-11-17,
// dj/vocal-check.ts): a song with lyrics is dropped, a flagged instrumental
// leads, and an unknown stays after it.
describe('an instrumental brief checks verified proposals on LRCLIB', () => {
  const n = (title: string) => Number(title.replace('Song ', ''))
  // Song 0 and 3 have lyrics, songs 1 and 4 are flagged instrumental, the rest unknown.
  function lrclib() {
    const titles: string[] = []
    const lyrics = async (key: { title: string }) => {
      titles.push(key.title)
      const i = n(key.title)
      return i === 0 || i === 3 ? { lyrics: 'words', instrumental: false } : i === 1 || i === 4 ? { lyrics: null, instrumental: true } : null
    }
    return { titles, lyrics }
  }

  it('drops proposals with lyrics and puts flagged instrumentals first', async () => {
    const { titles, lyrics } = lrclib()
    const log = vi.spyOn(console, 'log').mockImplementation(() => {})
    let turn: Awaited<ReturnType<typeof personalTurn>>
    let logged: { propose: { vocalDropped: number; lyricsChecked: number } }
    try {
      turn = await personalTurn({ input: { targetCount: 10, instrumental: true }, lyrics })
      logged = JSON.parse(log.mock.calls.find((c) => c[0] === 'dj turn')![1] as string)
    } finally {
      log.mockRestore()
    }
    const { result } = turn
    expect(titles.length).toBeGreaterThan(0)
    const proposed = result.queue.filter((t) => t.title.startsWith('Song ')).map((t) => n(t.title))
    expect(proposed).not.toContain(0)
    expect(proposed).not.toContain(3)
    expect(proposed).toContain(1)
    expect(proposed).toContain(4)
    // Known instrumentals lead the proposals.
    expect(proposed.slice(0, 2).sort()).toEqual([1, 4])
    expect(logged.propose.vocalDropped).toBe(2)
    expect(logged.propose.lyricsChecked).toBe(titles.length)
  })

  it('a brief without instrumental makes no LRCLIB request', async () => {
    const { titles, lyrics } = lrclib()
    const { result } = await personalTurn({ input: { targetCount: 10 }, lyrics })
    expect(titles).toHaveLength(0)
    expect(result.queue.some((t) => t.title === 'Song 0')).toBe(true)
  })
})
