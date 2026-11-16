import { describe, it, expect } from 'vitest'
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
import { PROPOSE_EXTRA, PROPOSE_SYSTEM_PROMPT, PROPOSE_SYSTEM_PROMPT_PERSONAL } from '../../src/dj/propose'
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

// Apple confirms every song in `confirmed`, labelled Jazz.
function fakeApple(confirmed: Proposed[]) {
  const searches: string[] = []
  const songs = new Map(confirmed.map((s, i) => [`${s.title} ${s.artist}`, {
    appleId: `v-${i}`, isrc: null, title: s.title, artist: s.artist, album: 'Album', artwork: null, durationMs: 200_000, genre: 'Jazz', releaseYear: 1959, explicit: false,
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

async function personalTurn(opts: { library?: number; input: Record<string, unknown>; deps?: Partial<DjDeps>; brief?: string; genre?: string }) {
  const db = await createTestDb()
  await seedUser(db)
  await seedLibrary(db, opts.library ?? 30, 'u1', opts.genre)
  const session = await seedSession(db)
  const round = proposals(22)
  const { fill, searches } = fakeApple(round)
  const { llm, requests } = scriptedLlm([generate(opts.input)], round)
  const deps: DjDeps = { llm, embed: embedFake, fill, neverRefuse: true, proposeFirst: true, ...opts.deps }
  const result = await runDjTurn(db, deps, { id: session.id, userId: 'u1' }, opts.brief ?? 'something for tonight')
  const proposedAt = result.queue.flatMap((t, i) => (t.title.startsWith('Song ') ? [i] : []))
  return { db, session, result, requests, searches, proposedAt }
}

describe('PROPOSE_FIRST flag', () => {
  it('only the exact string "on" enables it for everyone', () => {
    expect(proposeFirstEnabled({ PROPOSE_FIRST: 'on' }, 'anyone')).toBe(true)
    expect(proposeFirstEnabled({ PROPOSE_FIRST: 'on' })).toBe(true)
    for (const value of [undefined, 'off', 'ON', ' on', 'true', '1', '']) {
      expect(proposeFirstEnabled({ PROPOSE_FIRST: value }, 'u1')).toBe(false)
    }
  })

  it('PROPOSE_FIRST_USERS turns it on for the listed listeners only', () => {
    const env = { PROPOSE_FIRST: 'off', PROPOSE_FIRST_USERS: 'u1, u2 ,,' }
    expect(proposeFirstEnabled(env, 'u1')).toBe(true)
    expect(proposeFirstEnabled(env, 'u2')).toBe(true)
    expect(proposeFirstEnabled(env, 'u3')).toBe(false)
    expect(proposeFirstEnabled(env, '')).toBe(false)
    expect(proposeFirstEnabled(env)).toBe(false)
    expect(proposeFirstEnabled({ PROPOSE_FIRST_USERS: '' }, 'u1')).toBe(false)
  })

  it('ships off in wrangler.jsonc, with no listener list as a var', () => {
    const config = readFileSync(new URL('../../wrangler.jsonc', import.meta.url), 'utf8')
    expect(config).toMatch(/"PROPOSE_FIRST":\s*"off"/)
    expect(config).not.toMatch(/"PROPOSE_FIRST_USERS":/)
  })

  it('a turn resolves the flag for its own listener', async () => {
    const listed = await personalTurn({ input: { targetCount: 10 }, deps: { proposeFirst: undefined, proposeFirstFor: (id) => id === 'u1' } })
    expect(proposalRequests(listed.requests)).toHaveLength(1)
    expect(listed.requests[0].system).toBe(PERSONA_PROMPT_WITH_PROPOSE_FIRST)

    const other = await personalTurn({ input: { targetCount: 10 }, deps: { proposeFirst: undefined, proposeFirstFor: (id) => id === 'u2' } })
    expect(proposalRequests(other.requests)).toHaveLength(0)
    expect(other.requests[0].system).toBe(PERSONA_PROMPT_WITH_FILL)
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
    const resolvedOff = await personalTurn({ input: { targetCount: 20 }, deps: { proposeFirst: undefined, proposeFirstFor: () => false } })
    expect(shape(off.requests)).toEqual(shape(absent.requests))
    expect(shape(resolvedOff.requests)).toEqual(shape(absent.requests))
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
    expect(block).toContain(`Propose up to ${10 + PROPOSE_EXTRA} songs.`)
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

  async function bothFlags(proposeFirst: boolean) {
    const db = await createTestDb()
    await seedUser(db)
    await seedLibrary(db, 30)
    // Catalogue neighbours the listener does not own: outside-pool rows.
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
    const result = await runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: true, outsidePicks: true, proposeFirst }, { id: session.id, userId: 'u1' }, 'tonight')
    const curationText = JSON.stringify(curationRequests(requests)[0].messages)
    return { result, curationText }
  }

  it('with both flags on, the outside pool is off: new songs are proposals only', async () => {
    // OUTSIDE_PICKS alone draws on the catalogue neighbours...
    const outsideOnly = await bothFlags(false)
    expect(outsideOnly.curationText).toContain('Other ')
    // ...propose first takes its place.
    const { result, curationText } = await bothFlags(true)
    expect(curationText).not.toContain('Other ')
    expect(result.queue.filter((t) => t.title.startsWith('Other '))).toHaveLength(0)
    for (const t of result.queue.filter((q) => q.newToYou)) expect(t.title).toMatch(/^Song /)
  })
})
