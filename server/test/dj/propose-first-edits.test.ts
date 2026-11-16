import { describe, it, expect } from 'vitest'
import { createTestDb, type TestDb } from '../helpers/db'
import { eq } from 'drizzle-orm'
import { djSessions, trackFeatures, trackMeanings, tracks, user, userTracks } from '../../src/db/schema'
import {
  runDjTurn,
  editOutsideShortNotice,
  genreCheckNotice,
  namedArtistsNotFoundNotice,
  outsidePicksNotice,
  type DjDeps,
} from '../../src/dj/loop'
import { PROPOSE_SYSTEM_PROMPT, PROPOSE_SYSTEM_PROMPT_PERSONAL } from '../../src/dj/propose'
import type { FillDeps } from '../../src/dj/catalogue-fill'
import type { CatalogSong } from '../../src/musickit/catalog'
import type { LlmClient, LlmRequest, LlmTurn } from '../../src/dj/llm'

// PROPOSE_FIRST edits (spec 2026-11-16 propose-first, step 2; plan S8): a
// personal listener's swap or extend that their music cannot cover is
// proposed from outside it and verified on Apple, with two spares per
// request. Structural assertions, never exact tracks.

const DIMS = 1024
const UNIT = Array.from({ length: DIMS }, (_, i) => (i === 0 ? 1 : 0))
const embedFake = async () => UNIT

async function seedUser(db: TestDb, id = 'u1') {
  await db.insert(user).values({ id, name: id, email: `${id}@example.com`, emailVerified: false, createdAt: new Date(), updatedAt: new Date() })
}

async function seedSongs(db: TestDb, n: number, artist: (i: number) => string, prefix: string, genre = 'Soul') {
  for (let i = 0; i < n; i++) {
    const [t] = await db.insert(tracks).values({ appleId: `${prefix}-${i}`, title: `${prefix} ${i}`, artist: artist(i), genre, durationMs: 200_000 }).returning()
    await db.insert(trackFeatures).values({ trackId: t.id, tempo: 100, energy: 0.5, valence: 0.5, source: 'reccobeats' })
    await db.insert(trackMeanings).values({ trackId: t.id, embedding: UNIT, lyricsSource: 'lrclib' })
    await db.insert(userTracks).values({ userId: 'u1', trackId: t.id, inLibrary: true })
  }
}

type Proposed = { title: string; artist: string; reason: string }

const kendrick = (n: number): Proposed[] => Array.from({ length: n }, (_, i) => ({ title: `K Song ${i}`, artist: 'Kendrick Lamar', reason: `k ${i}` }))
const jazz = (n: number): Proposed[] => Array.from({ length: n }, (_, i) => ({ title: `Jazz ${i}`, artist: ['Miles Davis', 'Bill Evans'][i % 2], reason: `j ${i}` }))

// Apple confirms every song in `confirmed`, labelled Jazz unless `opts.genre`
// says otherwise; finds no artists. `opts.freshIds` gives every search its
// own Apple id, as another release of the same song would.
function fakeApple(confirmed: Proposed[], opts: { genre?: (title: string) => string; freshIds?: boolean } = {}) {
  const searches: string[] = []
  const songs = new Map(confirmed.map((s, i) => [`${s.title} ${s.artist}`, {
    appleId: `v-${i}`, isrc: null, title: s.title, artist: s.artist, album: 'Album', artwork: null, durationMs: 200_000,
    genre: opts.genre?.(s.title) ?? 'Jazz', releaseYear: 1990, explicit: false,
  } satisfies CatalogSong]))
  const fill: FillDeps = {
    catalog: {
      async searchArtists() { return [] },
      async artistTopSongs() { return [] },
      async searchSongs(_sf, term) {
        searches.push(term)
        const hit = songs.get(term)
        if (!hit) return []
        return [opts.freshIds ? { ...hit, appleId: `${hit.appleId}-${searches.length}` } : hit]
      },
    },
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

function toolResults(requests: LlmRequest[]): string[] {
  const last = requests.filter((r) => r.tools.length > 0).at(-1)!
  return last.messages
    .filter((m) => m.role === 'user' && Array.isArray(m.content) && (m.content[0] as { type?: string }).type === 'tool_result')
    .map((m) => (m.content as Array<{ content: string }>)[0].content)
}

// A personal listener with 30 Soul songs and a standing 10-song mix made
// from them (flag off, so the standing mix is the library's alone).
async function standingMix() {
  const db = await createTestDb()
  await seedUser(db)
  await seedSongs(db, 30, (i) => ['Mine A', 'Mine B', 'Mine C'][i % 3], 'Library')
  const [session] = await db.insert(djSessions).values({ userId: 'u1', title: 's' }).returning()
  const { fill } = fakeApple([])
  const { llm } = scriptedLlm([{ name: 'generate_queue', input: { themes: 'late evening', targetCount: 10 } }])
  const first = await runDjTurn(db, { llm, embed: embedFake, fill, neverRefuse: true }, { id: session.id, userId: 'u1' }, 'tonight')
  expect(first.queue).toHaveLength(10)
  return { db, session, before: first.queue }
}

const swapKendrick = (extra: Record<string, unknown> = {}) =>
  ({ name: 'edit_queue', input: { ops: [{ op: 'swap', position: 1, intent: { themes: 'kendrick', namedArtists: ['Kendrick Lamar'], ...extra } }] } })

async function editTurn(db: TestDb, sessionId: string, call: { name: string; input: unknown }, opts: {
  proposed: Proposed[]; confirmed: Proposed[]; deps?: Partial<DjDeps>; brief?: string
  apple?: Parameters<typeof fakeApple>[1]; turn?: Parameters<typeof runDjTurn>[4]
}) {
  const { fill, searches } = fakeApple(opts.confirmed, opts.apple)
  const { llm, requests } = scriptedLlm([call], opts.proposed)
  const deps: DjDeps = { llm, embed: embedFake, fill, neverRefuse: true, proposeFirst: true, ...opts.deps }
  const result = await runDjTurn(db, deps, { id: sessionId, userId: 'u1' }, opts.brief ?? 'swap in some Kendrick', opts.turn)
  return { result, requests, searches, text: toolResults(requests)[0] }
}

describe('propose first: edits reach songs they do not own', () => {
  it('golden: "swap in some Kendrick" with no Kendrick in the library lands a Kendrick song, marked new', async () => {
    const { db, session, before } = await standingMix()
    const { result, requests, text } = await editTurn(db, session.id, swapKendrick(), { proposed: kendrick(3), confirmed: kendrick(3) })

    expect(result.queue).toHaveLength(10)
    expect(result.queue[1].artist).toBe('Kendrick Lamar')
    expect(result.queue[1].newToYou).toBe(true)
    // The rest of the mix is as it was.
    expect(result.queue.filter((_, i) => i !== 1).map((t) => t.trackId)).toEqual(before.filter((_, i) => i !== 1).map((t) => t.trackId))
    // One personal proposal call for the edit: the song needed plus two spares.
    const asks = proposalRequests(requests)
    expect(asks).toHaveLength(1)
    expect(asks[0].system).toBe(PROPOSE_SYSTEM_PROMPT_PERSONAL)
    expect(asks[0].messages[0].content as string).toContain('Propose up to 3 songs.')
    expect(text).toContain(outsidePicksNotice([1]))
    expect(text).not.toContain(namedArtistsNotFoundNotice(['Kendrick Lamar']))
    expect(text).toMatch(/K Song \d+ — Kendrick Lamar \| new/)
  })

  it('with Kendrick in the library, the library row is used and nothing is proposed', async () => {
    const { db, session } = await standingMix()
    await seedSongs(db, 3, () => 'Kendrick Lamar', 'Owned K')
    const { result, requests, searches } = await editTurn(db, session.id, swapKendrick(), { proposed: kendrick(3), confirmed: kendrick(3) })

    expect(result.queue[1].artist).toBe('Kendrick Lamar')
    expect(result.queue[1].title).toMatch(/^Owned K /)
    expect(result.queue[1].newToYou).toBe(false)
    expect(proposalRequests(requests)).toHaveLength(0)
    expect(searches).toHaveLength(0)
  })

  it('every proposal failing verify keeps the original song, and the DJ is told', async () => {
    const { db, session, before } = await standingMix()
    const { result, searches, text } = await editTurn(db, session.id, swapKendrick(), { proposed: kendrick(3), confirmed: [] })

    expect(result.queue.map((t) => t.trackId)).toEqual(before.map((t) => t.trackId))
    // The song and both spares were tried.
    expect(searches).toHaveLength(3)
    expect(text).toContain(editOutsideShortNotice(1, ['Kendrick Lamar']))
    expect(text).not.toContain('— Kendrick')
    expect(editOutsideShortNotice(1, ['Kendrick Lamar'])).not.toContain('—')
  })

  it('a spare stands in when the first proposal misses on Apple', async () => {
    const { db, session } = await standingMix()
    const round = kendrick(3)
    const { result, searches, text } = await editTurn(db, session.id, swapKendrick(), { proposed: round, confirmed: [round[1]] })

    expect(result.queue[1].title).toBe(round[1].title)
    expect(result.queue[1].newToYou).toBe(true)
    // The song needed and its spares, searched together.
    expect(searches).toHaveLength(3)
    expect(text).not.toMatch(/could not be found in their music/)
  })

  it('extend by 5 of a genre the library lacks adds 5 verified songs', async () => {
    const { db, session, before } = await standingMix()
    // The sound check passes none of the library's Soul songs.
    const titleComplete = (async () => '[]') as unknown as DjDeps['titleComplete']
    const call = { name: 'edit_queue', input: { ops: [{ op: 'extend', count: 5, intent: { themes: 'soft jazz', genres: ['jazz'] } }] } }
    const { result, requests, text } = await editTurn(db, session.id, call, { proposed: jazz(7), confirmed: jazz(7), deps: { titleComplete }, brief: 'add 5 soft jazz songs' })

    expect(result.queue).toHaveLength(15)
    const added = result.queue.slice(10)
    expect(added.every((t) => t.title.startsWith('Jazz '))).toBe(true)
    expect(added.every((t) => t.newToYou)).toBe(true)
    expect(result.queue.slice(0, 10).map((t) => t.trackId)).toEqual(before.map((t) => t.trackId))
    expect(proposalRequests(requests)).toHaveLength(1)
    expect(proposalRequests(requests)[0].messages[0].content as string).toContain('Propose up to 7 songs.')
    expect(text).toContain(outsidePicksNotice([10, 11, 12, 13, 14]))
    expect(text).not.toMatch(/could not be found in their music/)
  })

  it('allowOutside false proposes nothing: today\'s named-artist edit', async () => {
    const { db, session, before } = await standingMix()
    const { result, requests, searches, text } = await editTurn(db, session.id, swapKendrick({ allowOutside: false }), { proposed: kendrick(3), confirmed: kendrick(3) })
    expect(proposalRequests(requests)).toHaveLength(0)
    expect(searches).toHaveLength(0)
    expect(result.queue.map((t) => t.trackId)).toEqual(before.map((t) => t.trackId))
    expect(text).toContain(namedArtistsNotFoundNotice(['Kendrick Lamar']))
  })

  it('an own-music edit (comfort) proposes nothing', async () => {
    const { db, session } = await standingMix()
    const { requests, searches, text } = await editTurn(db, session.id, swapKendrick({ familiarity: 'comfort' }), { proposed: kendrick(3), confirmed: kendrick(3) })
    expect(proposalRequests(requests)).toHaveLength(0)
    expect(searches).toHaveLength(0)
    expect(text).toContain(namedArtistsNotFoundNotice(['Kendrick Lamar']))
  })

  it('an edit with no intent of its own (the listener\'s words alone) proposes nothing', async () => {
    const { db, session } = await standingMix()
    const call = { name: 'edit_queue', input: { ops: [{ op: 'extend', count: 3 }] } }
    const { requests } = await editTurn(db, session.id, call, { proposed: jazz(5), confirmed: jazz(5), brief: 'more' })
    expect(proposalRequests(requests)).toHaveLength(0)
  })
})

describe('propose first edits: flag off is today', () => {
  const shape = (requests: LlmRequest[]) => requests.map((r) => ({ system: r.system, tools: r.tools, kind: isProposal(r) ? 'propose' : r.tools.length === 0 ? 'curate' : 'chat' }))

  it('proposeFirst false sends exactly what an unset flag sends, and proposes nothing', async () => {
    const run = async (proposeFirst: boolean | undefined) => {
      const { db, session, before } = await standingMix()
      const out = await editTurn(db, session.id, swapKendrick(), { proposed: kendrick(3), confirmed: kendrick(3), deps: { proposeFirst } })
      return { ...out, before }
    }
    const absent = await run(undefined)
    const off = await run(false)
    expect(shape(off.requests)).toEqual(shape(absent.requests))
    expect(off.searches).toEqual(absent.searches)
    expect(off.text.replace(/[0-9a-f-]{36}/g, 'ID').replace(/Library \d+ — Mine [ABC]/g, 'L'))
      .toEqual(absent.text.replace(/[0-9a-f-]{36}/g, 'ID').replace(/Library \d+ — Mine [ABC]/g, 'L'))
    expect(proposalRequests(off.requests)).toHaveLength(0)
    expect(off.result.queue.map((t) => t.trackId)).toEqual(off.before.map((t) => t.trackId))
    expect(off.text).toContain(namedArtistsNotFoundNotice(['Kendrick Lamar']))
  })
})

const titleCompleteNone = (async () => '[]') as unknown as DjDeps['titleComplete']
const jazzier = { themes: 'jazzier', genres: ['jazz'] }

describe('propose first edits: budget, spares and dedupe', () => {
  it('several short requests stay inside the curation cap: some land, the rest are short, the turn never fails', async () => {
    const { db, session, before } = await standingMix()
    const call = { name: 'edit_queue', input: { ops: [2, 4, 6, 8].map((position) => ({ op: 'swap', position, intent: jazzier })) } }
    const { result, requests, text } = await editTurn(db, session.id, call,
      { proposed: jazz(6), confirmed: jazz(6), deps: { titleComplete: titleCompleteNone }, brief: 'swap songs 2, 4, 6 and 8 for something jazzier' })

    // Swaps sharing an intent cost one curation (main 18cf872), so the four
    // swaps are one request: one library curation and one proposal call,
    // well inside the cap, and every swap lands a song of its own.
    expect(requests.filter((r) => r.tools.length === 0).length).toBeLessThanOrEqual(6)
    expect(proposalRequests(requests)).toHaveLength(1)
    const swapped = [2, 4, 6, 8].filter((i) => result.queue[i].trackId !== before[i].trackId)
    expect(swapped).toHaveLength(4)
    for (const i of swapped) expect(result.queue[i].title).toMatch(/^Jazz /)
    expect(new Set(swapped.map((i) => result.queue[i].title)).size).toBe(4)
    expect(text).not.toContain(genreCheckNotice({ dropped: 2, genres: ['jazz'], failed: false }))
    expect(text).not.toMatch(/could not be found in their music/)
  })

  it('several short requests with their own intents stay inside the curation cap and the turn never fails', async () => {
    const { db, session } = await standingMix()
    const themes = ['jazzier', 'smoky jazz', 'late night jazz', 'cool jazz']
    const call = { name: 'edit_queue', input: { ops: [2, 4, 6, 8].map((position, k) => ({ op: 'swap', position, intent: { themes: themes[k], genres: ['jazz'] } })) } }
    const { result, requests, text } = await editTurn(db, session.id, call,
      { proposed: jazz(6), confirmed: jazz(6), deps: { titleComplete: titleCompleteNone }, brief: 'swap songs 2, 4, 6 and 8 for different kinds of jazz' })

    expect(requests.filter((r) => r.tools.length === 0).length).toBeLessThanOrEqual(6)
    expect(result.queue).toHaveLength(10)
    const landed = [2, 4, 6, 8].filter((i) => /^Jazz /.test(result.queue[i].title))
    expect(landed.length).toBeGreaterThan(0)
    expect(landed.length).toBeLessThan(4)
    expect(text).not.toMatch(/could not be found in their music/)
  })

  it('a proposal the sound check drops falls back to a spare', async () => {
    const { db, session } = await standingMix()
    const round = jazz(3)
    const call = { name: 'edit_queue', input: { ops: [{ op: 'extend', count: 1, intent: jazzier }] } }
    const { result, text } = await editTurn(db, session.id, call, {
      proposed: round, confirmed: round, deps: { titleComplete: titleCompleteNone },
      apple: { genre: (title) => (title === round[0].title ? 'Pop' : 'Jazz') },
    })
    expect(result.queue).toHaveLength(11)
    expect(result.queue[10].title).toBe(round[1].title)
    expect(text).not.toMatch(/failed the jazz check/)
    expect(text).not.toMatch(/could not be found in their music/)
  })

  it('a proposal by another artist is never searched for a named edit; a spare lands', async () => {
    const { db, session } = await standingMix()
    const round = [{ title: 'Other Song', artist: 'Drake', reason: 'x' }, ...kendrick(2)]
    const { result, searches } = await editTurn(db, session.id, swapKendrick(), { proposed: round, confirmed: round })
    expect(result.queue[1].artist).toBe('Kendrick Lamar')
    expect(searches.some((s) => s.includes('Drake'))).toBe(false)
  })

  it('two requests in one batch both land their own outside songs', async () => {
    const { db, session } = await standingMix()
    const call = { name: 'edit_queue', input: { ops: [1, 3].map((position) => ({ op: 'swap', position, intent: { themes: 'kendrick', namedArtists: ['Kendrick Lamar'] } })) } }
    const { result, text } = await editTurn(db, session.id, call, { proposed: kendrick(4), confirmed: kendrick(4) })
    expect(result.queue[1].artist).toBe('Kendrick Lamar')
    expect(result.queue[3].artist).toBe('Kendrick Lamar')
    expect(result.queue[1].title).not.toBe(result.queue[3].title)
    expect(text).toContain(outsidePicksNotice([1, 3]))
  })

  it('another release of a song this batch already landed is not landed twice', async () => {
    const { db, session } = await standingMix()
    const call = { name: 'edit_queue', input: { ops: [1, 3].map((position) => ({ op: 'swap', position, intent: { themes: 'kendrick', namedArtists: ['Kendrick Lamar'] } })) } }
    const { result } = await editTurn(db, session.id, call, { proposed: kendrick(4), confirmed: kendrick(4), apple: { freshIds: true } })
    const titles = result.queue.map((t) => t.title)
    expect(new Set(titles).size).toBe(titles.length)
    expect(result.queue[1].artist).toBe('Kendrick Lamar')
    expect(result.queue[3].artist).toBe('Kendrick Lamar')
  })

  it('a scoped and an unscoped shortfall are each said for what they were', async () => {
    const { db, session } = await standingMix()
    const call = { name: 'edit_queue', input: { ops: [
      { op: 'swap', position: 1, intent: { themes: 'kendrick', namedArtists: ['Kendrick Lamar'] } },
      { op: 'extend', count: 2, intent: jazzier },
    ] } }
    const { text } = await editTurn(db, session.id, call, { proposed: jazz(4), confirmed: [], deps: { titleComplete: titleCompleteNone } })
    expect(text).toContain(editOutsideShortNotice(1, ['Kendrick Lamar']))
    expect(text).toContain(editOutsideShortNotice(2, []))
    expect(text).not.toContain(editOutsideShortNotice(3, ['Kendrick Lamar']))
    // One gap, one notice: the library's genre drops were handed on.
    expect(text).not.toMatch(/failed the jazz check/)
  })

  it('outside songs the sound check drops are said as failing it, not as not found', async () => {
    const { db, session } = await standingMix()
    const call = { name: 'edit_queue', input: { ops: [{ op: 'extend', count: 1, intent: jazzier }] } }
    const { result, text } = await editTurn(db, session.id, call, {
      proposed: jazz(3), confirmed: jazz(3), deps: { titleComplete: titleCompleteNone }, apple: { genre: () => 'Pop' },
    })
    expect(result.queue).toHaveLength(10)
    expect(text).toContain(genreCheckNotice({ dropped: 1, genres: ['jazz'], failed: false }))
    expect(text).not.toMatch(/could not be found in their music/)
  })

  it('a remake turn\'s edit never goes outside', async () => {
    const { db, session } = await standingMix()
    await db.update(djSessions).set({ notPersonal: true }).where(eq(djSessions.id, session.id))
    const { requests, searches } = await editTurn(db, session.id, swapKendrick(), { proposed: kendrick(3), confirmed: kendrick(3), turn: { remake: true } })
    expect(proposalRequests(requests)).toHaveLength(0)
    expect(searches).toHaveLength(0)
  })
})
