import { describe, it, expect, vi } from 'vitest'
import { eq } from 'drizzle-orm'
import { createTestDb, type TestDb } from '../helpers/db'
import { djMessages, djSessions, trackFeatures, trackMeanings, tracks, user, userArtistSeeds, userTracks } from '../../src/db/schema'
import {
  runDjTurn,
  blendedNotice,
  CORPUS_NOTICE,
  HONEST_LISTING_PERSONA_LINE,
  artistFewerFitNotice,
  artistNoneFitNotice,
  namedArtistsNotFoundNotice,
  onlyArtistFitNotice,
  NOTHING_FITS_TEXT,
  PERSONA_PROMPT,
  PERSONA_PROMPT_WITH_OUTSIDE,
  PERSONA_PROMPT_WITH_FILL,
  FILL_PERSONA_LINE,
  shortMixNotice,
  TURN_APPLE_BUDGET,
  type DjDeps,
} from '../../src/dj/loop'
import { PROPOSE_EXTRA, PROPOSE_SYSTEM_PROMPT, PROPOSE_SYSTEM_PROMPT_PERSONAL } from '../../src/dj/propose'
import { NAMED_ARTISTS_RULE_PREFIX } from '../../src/dj/curate'
import { creditedKeys } from '../../src/dj/artist-keys'
import { DJ_TOOLS, DJ_TOOLS_WITH_OUTSIDE } from '../../src/dj/contracts'
import { getActiveQueue, replaceQueue } from '../../src/dj/queue-store'
import type { FillDeps } from '../../src/dj/catalogue-fill'
import type { CatalogSong } from '../../src/musickit/catalog'
import type { LlmClient, LlmRequest, LlmTurn } from '../../src/dj/llm'

// Spec 2026-11-09 every-song-earns-its-place, decisions 2 to 5: golden
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

// n enriched rows credited to `artist`, in `owner`'s library when given.
async function seedTracks(db: TestDb, artist: string, n: number, owner?: string) {
  const out: Array<typeof tracks.$inferSelect> = []
  for (let i = 0; i < n; i++) {
    counter += 1
    const [t] = await db.insert(tracks).values({ appleId: `held-${counter}`, title: `${artist} ${counter}`, artist, durationMs: 200_000 }).returning()
    await db.insert(trackFeatures).values({ trackId: t.id, tempo: 100, energy: 0.5, valence: 0.5, source: 'reccobeats' })
    await db.insert(trackMeanings).values({ trackId: t.id, embedding: UNIT, lyricsSource: 'lrclib' })
    if (owner) await db.insert(userTracks).values({ userId: owner, trackId: t.id, inLibrary: true })
    out.push(t)
  }
  return out
}

function song(appleId: string, title: string, artist: string): CatalogSong {
  return { appleId, isrc: null, title, artist, album: 'Album', artwork: null, durationMs: 200_000, genre: 'Jazz', releaseYear: 1959, explicit: false }
}

type Proposed = { title: string; artist: string; reason: string }

function proposals(n: number): Proposed[] {
  return Array.from({ length: n }, (_, i) => ({ title: `Song ${i}`, artist: ['Miles Davis', 'Bill Evans', 'Chet Baker'][i % 3], reason: `reason ${i}` }))
}

// Apple confirms every song in `confirmed`, and knows `artists` by name with
// three top songs each.
function fakeApple(confirmed: Proposed[], artists: Record<string, number> = {}) {
  const searches: string[] = []
  const artistSearches: string[] = []
  const songs = new Map(confirmed.map((s, i) => [`${s.title} ${s.artist}`, song(`v-${i}`, s.title, s.artist)]))
  const catalog: FillDeps['catalog'] = {
    async searchArtists(_sf, term) {
      artistSearches.push(term)
      return term in artists ? [{ id: `a-${term}`, name: term, genres: [] }] : []
    },
    async artistTopSongs(_sf, id) {
      const name = id.slice(2)
      return Array.from({ length: artists[name] ?? 0 }, (_, i) => song(`${id}-top-${i}`, `${name} Top ${i}`, name))
    },
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
  return { fill, searches, artistSearches }
}

const isProposal = (req: LlmRequest) => req.system === PROPOSE_SYSTEM_PROMPT || req.system === PROPOSE_SYSTEM_PROMPT_PERSONAL

function poolIds(req: LlmRequest): string[] {
  const blocks = req.messages[0].content as Array<{ text?: string }>
  return Array.from((blocks[0]?.text ?? '').matchAll(/^([0-9a-f-]{36}) \|/gm)).map((m) => m[1])
}

function textTurn(text: string): LlmTurn {
  return { text, toolCalls: [], raw: [{ type: 'text', text }], stopReason: 'end_turn', usage: null }
}

// Curation answers every pool id up to the count unless `curateAnswer` says
// otherwise; proposals answer `proposed`; the conversation makes each call
// in `calls` in turn, then replies.
function scriptedLlm(calls: Array<{ name: string; input: unknown }>, opts: { proposed?: Proposed[]; curateAnswer?: (ids: string[], count: number) => string } = {}) {
  const requests: LlmRequest[] = []
  let conv = 0
  const llm: LlmClient = async (req) => {
    requests.push(req)
    if (isProposal(req)) return textTurn(JSON.stringify(opts.proposed ?? []))
    if (req.tools.length === 0) {
      const ids = poolIds(req)
      const count = Number(((req.messages[0].content as Array<{ text?: string }>)[1]?.text ?? '').match(/Pick up to (\d+) tracks/)?.[1] ?? ids.length)
      return textTurn(opts.curateAnswer ? opts.curateAnswer(ids, count) : JSON.stringify(ids.slice(0, count).map((id) => ({ id, reason: 'fits' }))))
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

const generate = (input: Record<string, unknown>) => ({ name: 'generate_queue', input: { themes: 'soft jazz for reading', ...input } })

describe('decision 2: a short curation is filled from outside the library, then honestly', () => {
  async function personalListener(owned = 3) {
    const db = await createTestDb()
    await seedUser(db)
    const mine = await seedTracks(db, 'Mine', owned, 'u1')
    const session = await seedSession(db)
    return { db, session, mine }
  }

  it('golden: a personal listener whose library covers half the brief gets the rest proposed, verified and spread through the mix', async () => {
    const { db, session } = await personalListener(3)
    const round = proposals(11)
    const { fill, searches } = fakeApple(round)
    const { llm, requests } = scriptedLlm([generate({ targetCount: 6 })], { proposed: round })
    const deps: DjDeps = { llm, embed: embedFake, fill, neverRefuse: true }

    const result = await runDjTurn(db, deps, { id: session.id, userId: 'u1' }, 'rainy sunday reading, soft jazz')

    expect(result.queue).toHaveLength(6)
    const proposedAt = result.queue.flatMap((t, i) => (t.title.startsWith('Song ') ? [i] : []))
    expect(proposedAt).toHaveLength(3)
    // Spread, never bunched at one end.
    for (let i = 1; i < proposedAt.length; i++) expect(proposedAt[i] - proposedAt[i - 1]).toBeGreaterThan(1)
    // One proposal round for exactly the shortfall, never the curated songs.
    const [proposal] = proposalRequests(requests)
    expect(proposalRequests(requests)).toHaveLength(1)
    const block = proposal.messages[0].content as string
    expect(block).toContain(`Propose up to ${3 + PROPOSE_EXTRA} songs.`)
    expect(block).toContain('Already tried, never propose these again:')
    // The personal prompt, with the listener's own top artists as taste.
    expect(proposal.system).toBe(PROPOSE_SYSTEM_PROMPT_PERSONAL)
    expect(block).toContain('Artists this listener plays most: Mine')
    expect(searches).toHaveLength(3)
    // The reply can say how many are new: outside picks, not a corpus mix.
    const [text] = toolResults(requests)
    expect(text).toContain(blendedNotice(3))
    expect(text).toMatch(/3 of these picks are songs this listener does not have yet/)
    expect(text).not.toContain(CORPUS_NOTICE)
    expect(text).toContain('queue generated: 6 tracks')
    expect(await notPersonal(db, session.id)).toBe(false)
    expect(result.queue.filter((t) => t.newToYou)).toHaveLength(3)
  })

  it('a second generate_queue with a different brief in the same turn proposes afresh; the same brief reuses', async () => {
    const { db, session } = await personalListener(3)
    const round = proposals(11)
    const { fill } = fakeApple(round)
    const { llm, requests } = scriptedLlm([
      generate({ targetCount: 6 }),
      generate({ targetCount: 6, themes: 'late night soul' }),
      generate({ targetCount: 6, themes: 'late night soul' }),
    ], { proposed: round })

    await runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: true }, { id: session.id, userId: 'u1' }, 'jazz, no wait, soul')

    expect(proposalRequests(requests)).toHaveLength(2)
    expect(proposalRequests(requests)[1].messages[0].content as string).toContain('late night soul')
  })

  it('allowOutside false skips the proposals and the result says why the mix is short', async () => {
    const { db, session } = await personalListener(3)
    const { fill, searches } = fakeApple(proposals(11))
    const { llm, requests } = scriptedLlm([generate({ targetCount: 6, allowOutside: false })], { proposed: proposals(11) })

    const result = await runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: true }, { id: session.id, userId: 'u1' }, 'only my music')

    expect(result.queue).toHaveLength(3)
    expect(proposalRequests(requests)).toHaveLength(0)
    expect(searches).toHaveLength(0)
    expect(toolResults(requests)[0]).toContain(shortMixNotice({ count: 3, asked: 6, source: 'library', outside: 'own-only' }))
  })

  it('a comfort brief (their favourites) is never filled from outside, and says why', async () => {
    const { db, session } = await personalListener(3)
    const { fill, searches } = fakeApple(proposals(11))
    const { llm, requests } = scriptedLlm([generate({ targetCount: 6, familiarity: 'comfort' })], { proposed: proposals(11) })

    const result = await runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: true }, { id: session.id, userId: 'u1' }, 'my favourites')

    expect(result.queue).toHaveLength(3)
    expect(proposalRequests(requests)).toHaveLength(0)
    expect(searches).toHaveLength(0)
    expect(toolResults(requests)[0]).toContain(shortMixNotice({ count: 3, asked: 6, source: 'library', outside: 'own-only' }))
  })

  // The model must be able to turn the fill off ("only my own music", or a
  // saved preference saying so) whenever the fill can run, so allowOutside
  // is advertised then, as a whole static variant (cached on its own).
  it('with the fill wired the model sees allowOutside and the fill persona; without it, today\'s', async () => {
    const { db, session } = await personalListener(3)
    const { fill } = fakeApple([])
    const on = scriptedLlm([])
    await runDjTurn(db, { llm: on.llm, embed: embedFake, fill, neverRefuse: true }, { id: session.id, userId: 'u1' }, 'hi')
    const [onReq] = on.requests.filter((r) => r.tools.length > 0)
    expect(onReq.tools).toBe(DJ_TOOLS_WITH_OUTSIDE)
    expect(onReq.system).toBe(PERSONA_PROMPT_WITH_FILL)
    expect(PERSONA_PROMPT_WITH_FILL).toContain(FILL_PERSONA_LINE)
    expect(FILL_PERSONA_LINE).toMatch(/allowOutside: false/)

    for (const deps of [{ fill, neverRefuse: false }, { neverRefuse: true }]) {
      const off = scriptedLlm([])
      await runDjTurn(db, { llm: off.llm, embed: embedFake, ...deps }, { id: session.id, userId: 'u1' }, 'hi')
      const [offReq] = off.requests.filter((r) => r.tools.length > 0)
      expect(offReq.tools).toBe(DJ_TOOLS)
      expect(offReq.system).toBe(PERSONA_PROMPT)
    }

    // OUTSIDE_PICKS on already carries allowOutside: its own variant wins.
    const both = scriptedLlm([])
    await runDjTurn(db, { llm: both.llm, embed: embedFake, fill, neverRefuse: true, outsidePicks: true }, { id: session.id, userId: 'u1' }, 'hi')
    expect(both.requests.filter((r) => r.tools.length > 0)[0].system).toBe(PERSONA_PROMPT_WITH_OUTSIDE)
  })

  it('with NEVER_REFUSE off the mix is shorter and says so, nothing proposed', async () => {
    const { db, session } = await personalListener(3)
    const { fill } = fakeApple(proposals(11))
    const { llm, requests } = scriptedLlm([generate({ targetCount: 6 })], { proposed: proposals(11) })

    const result = await runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: false }, { id: session.id, userId: 'u1' }, 'soft jazz')

    expect(result.queue).toHaveLength(3)
    expect(proposalRequests(requests)).toHaveLength(0)
    expect(toolResults(requests)[0]).toContain(shortMixNotice({ count: 3, asked: 6, source: 'library', outside: 'unavailable' }))
  })

  it('proposals that do not verify leave the mix short, and the result says so', async () => {
    const { db, session } = await personalListener(3)
    const { fill } = fakeApple([])
    const { llm, requests } = scriptedLlm([generate({ targetCount: 6 })], { proposed: proposals(11) })

    const result = await runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: true }, { id: session.id, userId: 'u1' }, 'soft jazz')

    expect(result.queue).toHaveLength(3)
    const [text] = toolResults(requests)
    expect(text).toContain(shortMixNotice({ count: 3, asked: 6, source: 'library', outside: 'unconfirmed' }))
    expect(text).not.toContain('own knowledge')
  })

  it('a proposal that verifies to a song the curator already picked is queued once', async () => {
    const { db, session, mine } = await personalListener(3)
    const { fill } = fakeApple([])
    fill.catalog.searchSongs = async () => [song(mine[0].appleId!, mine[0].title, mine[0].artist)]
    const { llm } = scriptedLlm([generate({ targetCount: 6 })], { proposed: [{ title: mine[0].title, artist: mine[0].artist, reason: 'again' }] })

    const result = await runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: true }, { id: session.id, userId: 'u1' }, 'soft jazz')

    const ids = result.queue.map((q) => q.trackId)
    expect(new Set(ids).size).toBe(ids.length)
    expect(ids).toHaveLength(3)
  })

  it('a curator that finds nothing fits ([]) gets the whole mix proposed, not a failed turn', async () => {
    const { db, session } = await personalListener(3)
    const round = proposals(14)
    const { fill } = fakeApple(round)
    const { llm, requests } = scriptedLlm([generate({ targetCount: 6 })], { proposed: round, curateAnswer: () => '[]' })

    const result = await runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: true }, { id: session.id, userId: 'u1' }, 'focus music, no vocals')

    expect(result.queue).toHaveLength(6)
    expect(result.queue.every((t) => t.title.startsWith('Song '))).toBe(true)
    expect(toolResults(requests)[0]).toContain(blendedNotice(6))
    expect(result.djMessage.content).toBe('here you go.')
  })

  it('nothing fits and nothing can be proposed: the queue is unchanged and the DJ is told why, not an apology', async () => {
    const { db, session } = await personalListener(3)
    const { llm, requests } = scriptedLlm([generate({ targetCount: 6 })], { curateAnswer: () => '[]' })

    const result = await runDjTurn(db, { llm, embed: embedFake }, { id: session.id, userId: 'u1' }, 'focus music, no vocals')

    expect(result.queue).toHaveLength(0)
    const [text] = toolResults(requests)
    expect(text).toContain(NOTHING_FITS_TEXT)
    expect(text).toContain(shortMixNotice({ count: 0, asked: 6, source: 'library', outside: 'unavailable' }))
  })

  it('a corpus listener: the proposed share is the larger of the blend and the shortfall, in one proposal call', async () => {
    const db = await createTestDb()
    await seedUser(db)
    for (const artist of ['SeedA', 'SeedB', 'SeedC']) {
      await db.insert(userArtistSeeds).values({ userId: 'u1', name: artist, source: 'interview' })
      await seedTracks(db, artist, 9)
    }
    const session = await seedSession(db)
    const round = proposals(11)
    const { fill } = fakeApple(round)
    // The catalogue holds one song that fits.
    const { llm, requests } = scriptedLlm([generate({ targetCount: 6 })], {
      proposed: round,
      curateAnswer: (ids) => JSON.stringify([{ id: ids[0], reason: 'fits' }]),
    })

    const result = await runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: true }, { id: session.id, userId: 'u1' }, 'soft jazz')

    expect(result.queue).toHaveLength(6)
    expect(result.queue.filter((t) => t.title.startsWith('Song '))).toHaveLength(5)
    expect(proposalRequests(requests)).toHaveLength(1)
    const [text] = toolResults(requests)
    expect(text.split('\n')[0]).toBe(CORPUS_NOTICE)
    expect(text).toContain(blendedNotice(5))
    expect(await notPersonal(db, session.id)).toBe(true)
  })
})

describe('an edit whose curator finds nothing that fits', () => {
  it('keeps the original track rather than failing the turn', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const mine = await seedTracks(db, 'Mine', 8, 'u1')
    const session = await seedSession(db)
    await replaceQueue(db, session.id, mine.slice(0, 4).map((t) => ({ trackId: t.id, reason: '' })), 'dj')
    const before = (await getActiveQueue(db, session.id)).map((t) => t.trackId)
    const { llm } = scriptedLlm([{ name: 'edit_queue', input: { ops: [{ op: 'swap', position: 1, intent: { themes: 'polka' } }] } }], { curateAnswer: () => '[]' })

    const result = await runDjTurn(db, { llm, embed: embedFake }, { id: session.id, userId: 'u1' }, 'swap 2 for some polka')

    expect(result.queue.map((t) => t.trackId)).toEqual(before)
    expect(result.djMessage.content).toBe('here you go.')
  })
})

describe('artist scopes: what does not fit is said, not failed', () => {
  async function library(artist: string, n: number) {
    const db = await createTestDb()
    await seedUser(db)
    await seedTracks(db, artist, n, 'u1')
    await seedTracks(db, 'Mine', 6, 'u1')
    return { db, session: await seedSession(db) }
  }

  it('an artist-only mix where none of their songs fit leaves the queue and says so', async () => {
    const { db, session } = await library('SZA', 6)
    const { llm, requests } = scriptedLlm([generate({ targetCount: 5, onlyArtist: 'SZA' })], { curateAnswer: () => '[]' })

    const result = await runDjTurn(db, { llm, embed: embedFake }, { id: session.id, userId: 'u1' }, 'sza for the gym')

    expect(result.queue).toHaveLength(0)
    expect(toolResults(requests)[0]).toContain(artistNoneFitNotice('SZA', 'mix'))
    expect(result.djMessage.content).toBe('here you go.')
  })

  it('an artist-only mix with songs to spare but few that fit says only N fit, not only N exist', async () => {
    const { db, session } = await library('SZA', 12)
    const { llm, requests } = scriptedLlm([generate({ targetCount: 10, onlyArtist: 'SZA' })], {
      curateAnswer: (ids) => JSON.stringify(ids.slice(0, 2).map((id) => ({ id, reason: 'fits' }))),
    })

    const result = await runDjTurn(db, { llm, embed: embedFake }, { id: session.id, userId: 'u1' }, 'sza for the gym')

    expect(result.queue).toHaveLength(2)
    const [text] = toolResults(requests)
    expect(text).toContain(onlyArtistFitNotice('SZA', 2, 10))
    expect(text).not.toContain('could be found')
  })

  it('a named-artist swap whose songs exist but none fit keeps the track and says none fit', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const mine = await seedTracks(db, 'Mine', 6, 'u1')
    await seedTracks(db, 'Kendrick Lamar', 3, 'u1')
    const session = await seedSession(db)
    await replaceQueue(db, session.id, mine.slice(0, 4).map((t) => ({ trackId: t.id, reason: '' })), 'dj')
    const before = (await getActiveQueue(db, session.id)).map((t) => t.trackId)
    const { llm, requests } = scriptedLlm([{ name: 'edit_queue', input: { ops: [{ op: 'swap', position: 1, intent: { themes: 'calm', namedArtists: ['Kendrick Lamar'] } }] } }], { curateAnswer: () => '[]' })

    const result = await runDjTurn(db, { llm, embed: embedFake }, { id: session.id, userId: 'u1' }, 'swap in a calm Kendrick song')

    expect(result.queue.map((t) => t.trackId)).toEqual(before)
    expect(toolResults(requests)[0]).toContain(artistNoneFitNotice('Kendrick Lamar', 'edit'))
  })

  it('a named-artist extend with fewer that fit than exist says fewer fit', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const mine = await seedTracks(db, 'Mine', 6, 'u1')
    await seedTracks(db, 'Kendrick Lamar', 6, 'u1')
    const session = await seedSession(db)
    await replaceQueue(db, session.id, mine.slice(0, 4).map((t) => ({ trackId: t.id, reason: '' })), 'dj')
    const { llm, requests } = scriptedLlm([{ name: 'edit_queue', input: { ops: [{ op: 'extend', count: 4, intent: { themes: 'calm', namedArtists: ['Kendrick Lamar'] } }] } }], {
      curateAnswer: (ids) => JSON.stringify(ids.slice(0, 1).map((id) => ({ id, reason: 'fits' }))),
    })

    const result = await runDjTurn(db, { llm, embed: embedFake }, { id: session.id, userId: 'u1' }, 'add a few calm Kendrick songs')

    expect(result.queue).toHaveLength(5)
    const [text] = toolResults(requests)
    expect(text).toContain(artistFewerFitNotice('Kendrick Lamar'))
    expect(text).not.toContain('no more songs credited')
  })
})

describe('decision 3: named artists in an edit are a scope', () => {
  async function standingMix(extra: Record<string, number>) {
    const db = await createTestDb()
    await seedUser(db)
    const mine = await seedTracks(db, 'Mine', 8, 'u1')
    for (const [artist, n] of Object.entries(extra)) await seedTracks(db, artist, n, 'u1')
    const session = await seedSession(db)
    await replaceQueue(db, session.id, mine.slice(0, 5).map((t) => ({ trackId: t.id, reason: '' })), 'dj')
    return { db, session }
  }

  const credits = (artist: string, ...keys: string[]) => creditedKeys(artist).some((k) => keys.includes(k))

  it('golden: "swap in some Kendrick" swaps in a Kendrick song, drawn only from his', async () => {
    const { db, session } = await standingMix({ 'Kendrick Lamar': 3, 'Baby Keem': 3 })
    const { llm, requests } = scriptedLlm([{ name: 'edit_queue', input: { ops: [{ op: 'swap', position: 1, intent: { themes: 'kendrick', namedArtists: ['Kendrick Lamar'] } }] } }])

    const result = await runDjTurn(db, { llm, embed: embedFake }, { id: session.id, userId: 'u1' }, 'swap in some Kendrick')

    expect(result.queue).toHaveLength(5)
    expect(credits(result.queue[1].artist, 'kendricklamar')).toBe(true)
    const [curation] = curationRequests(requests)
    const poolText = (curation.messages[0].content as Array<{ text: string }>)[0].text
    expect(poolText).not.toContain('Baby Keem')
    expect(poolText).not.toContain('Mine')
    expect((curation.messages[0].content as Array<{ text: string }>)[1].text).toContain(NAMED_ARTISTS_RULE_PREFIX)
  })

  it('"add a couple of SZA and Kendrick songs" extends from either artist only', async () => {
    const { db, session } = await standingMix({ 'Kendrick Lamar': 2, SZA: 2, 'Baby Keem': 3 })
    const { llm } = scriptedLlm([{ name: 'edit_queue', input: { ops: [{ op: 'extend', count: 4, intent: { themes: 'x', namedArtists: ['SZA', 'Kendrick Lamar'] } }] } }])

    const result = await runDjTurn(db, { llm, embed: embedFake }, { id: session.id, userId: 'u1' }, 'add a couple of SZA and Kendrick songs')

    expect(result.queue).toHaveLength(9)
    for (const t of result.queue.slice(5)) expect(credits(t.artist, 'sza', 'kendricklamar')).toBe(true)
  })

  it('an artist found nowhere leaves the original track and the result says who could not be found', async () => {
    const { db, session } = await standingMix({ 'Baby Keem': 3 })
    const before = (await getActiveQueue(db, session.id)).map((t) => t.trackId)
    const { llm, requests } = scriptedLlm([{ name: 'edit_queue', input: { ops: [{ op: 'swap', position: 1, intent: { themes: 'x', namedArtists: ['Nobody Known'] } }] } }])

    const result = await runDjTurn(db, { llm, embed: embedFake }, { id: session.id, userId: 'u1' }, 'swap in some Nobody Known')

    expect(result.queue.map((t) => t.trackId)).toEqual(before)
    expect(toolResults(requests)[0]).toContain(namedArtistsNotFoundNotice(['Nobody Known']))
    expect(curationRequests(requests)).toHaveLength(0)
  })

  it('an artist with no rows is filled from Apple first', async () => {
    const { db, session } = await standingMix({})
    const { fill, artistSearches } = fakeApple([], { 'Kendrick Lamar': 3 })
    const { llm } = scriptedLlm([{ name: 'edit_queue', input: { ops: [{ op: 'swap', position: 0, intent: { themes: 'x', namedArtists: ['Kendrick Lamar'] } }] } }])

    const result = await runDjTurn(db, { llm, embed: embedFake, fill }, { id: session.id, userId: 'u1' }, 'swap in some Kendrick')

    expect(artistSearches).toEqual(['Kendrick Lamar'])
    expect(credits(result.queue[0].artist, 'kendricklamar')).toBe(true)
  })
})

describe('one Apple budget per turn', () => {
  it('a short dinner mix plus "swap in some Kendrick" in one turn stays inside TURN_APPLE_BUDGET', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedTracks(db, 'Mine', 3, 'u1')
    const session = await seedSession(db)
    const round = proposals(40)
    const { fill } = fakeApple(round, { 'Kendrick Lamar': 5 })
    // Every Apple-facing call the turn makes: catalogue and enrichment.
    let calls = 0
    const counted = <A extends unknown[], R>(fn: (...a: A) => Promise<R>) => async (...a: A) => { calls += 1; return fn(...a) }
    fill.catalog.searchSongs = counted(fill.catalog.searchSongs.bind(fill.catalog))
    fill.catalog.searchArtists = counted(fill.catalog.searchArtists.bind(fill.catalog))
    fill.catalog.artistTopSongs = counted(fill.catalog.artistTopSongs.bind(fill.catalog))
    fill.enrich.itunes = counted(fill.enrich.itunes)
    fill.enrich.features = counted(fill.enrich.features)
    fill.enrich.lyrics = counted(fill.enrich.lyrics)
    fill.enrich.embed = counted(fill.enrich.embed)
    const { llm } = scriptedLlm([
      generate({ targetCount: 30, themes: '90s r&b slow jams for a dinner date' }),
      { name: 'edit_queue', input: { ops: [{ op: 'swap', position: 0, intent: { themes: 'kendrick', namedArtists: ['Kendrick Lamar'] } }] } },
    ], { proposed: round })

    const log = vi.spyOn(console, 'log').mockImplementation(() => {})
    await runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: true }, { id: session.id, userId: 'u1' }, '90s r&b for dinner, and swap in some Kendrick')
    log.mockRestore()

    expect(calls).toBeGreaterThan(0)
    expect(calls).toBeLessThanOrEqual(TURN_APPLE_BUDGET)
  })
})

describe('decision 4: a turn whose queue changed never fails silently', () => {
  it('golden: an error after a generate landed returns success with a factual message', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedTracks(db, 'Mine', 6, 'u1')
    const session = await seedSession(db)
    const { llm: inner } = scriptedLlm([generate({ targetCount: 5 })])
    let conv = 0
    const llm: LlmClient = async (req) => {
      if (req.tools.length > 0 && ++conv === 2) throw new Error('boom')
      return inner(req)
    }

    const log = vi.spyOn(console, 'log').mockImplementation(() => {})
    const result = await runDjTurn(db, { llm, embed: embedFake }, { id: session.id, userId: 'u1' }, 'play')
    log.mockRestore()

    expect(result.queue).toHaveLength(5)
    expect(result.djMessage.content).toBe('Made a new mix of 5 songs.')
    expect(result.djMessage.queueVersion).toBe(result.queueVersion)
    const dj = await db.select().from(djMessages).where(eq(djMessages.role, 'dj'))
    expect(dj.map((m) => m.content)).toEqual(['Made a new mix of 5 songs.'])
  })

  it('an error after an edit\'s swaps were saved says what was swapped', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const mine = await seedTracks(db, 'Mine', 9, 'u1')
    const session = await seedSession(db)
    await replaceQueue(db, session.id, mine.slice(0, 4).map((t) => ({ trackId: t.id, reason: '' })), 'dj')
    // A curator that never hands back a song it already picked this batch.
    const given = new Set<string>()
    const curateAnswer = (ids: string[], count: number) => {
      const fresh = ids.filter((id) => !given.has(id)).slice(0, count)
      for (const id of fresh) given.add(id)
      return JSON.stringify(fresh.map((id) => ({ id, reason: 'fits' })))
    }
    const { llm: inner } = scriptedLlm([{ name: 'edit_queue', input: { ops: [{ op: 'swap', position: 0 }, { op: 'swap', position: 2 }, { op: 'extend', count: 1 }, { op: 'remove', position: 1 }] } }], { curateAnswer })
    let conv = 0
    const llm: LlmClient = async (req) => {
      if (req.tools.length > 0 && ++conv === 2) throw new Error('boom')
      return inner(req)
    }

    const log = vi.spyOn(console, 'log').mockImplementation(() => {})
    const result = await runDjTurn(db, { llm, embed: embedFake }, { id: session.id, userId: 'u1' }, 'freshen it up')
    log.mockRestore()

    expect(result.queue).toHaveLength(4)
    expect(result.djMessage.content).toBe('Swapped 2 songs. Added 1 song. Removed 1 song.')
  })

  it('an error with no queue change still fails', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const session = await seedSession(db)
    const llm: LlmClient = async () => { throw new Error('boom') }

    const log = vi.spyOn(console, 'log').mockImplementation(() => {})
    await expect(runDjTurn(db, { llm, embed: embedFake }, { id: session.id, userId: 'u1' }, 'play')).rejects.toMatchObject({ kind: 'internal' })
    log.mockRestore()
  })
})

describe('decision 5: the reply describes only what is in the listing', () => {
  it('the persona says so, flag on or off', () => {
    expect(HONEST_LISTING_PERSONA_LINE).toMatch(/anchors, leads or features/)
    expect(HONEST_LISTING_PERSONA_LINE).toMatch(/differs from what they asked/)
    expect(PERSONA_PROMPT).toContain(HONEST_LISTING_PERSONA_LINE)
    expect(PERSONA_PROMPT_WITH_OUTSIDE).toContain(HONEST_LISTING_PERSONA_LINE)
  })
})
