import { describe, it, expect } from 'vitest'
import { createTestDb, type TestDb } from '../helpers/db'
import { djSessions, trackFeatures, trackMeanings, tracks, user, userTracks } from '../../src/db/schema'
import {
  runDjTurn,
  editOutsideShortNotice,
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

// Apple confirms every song in `confirmed`, labelled Jazz; finds no artists.
function fakeApple(confirmed: Proposed[]) {
  const searches: string[] = []
  const songs = new Map(confirmed.map((s, i) => [`${s.title} ${s.artist}`, {
    appleId: `v-${i}`, isrc: null, title: s.title, artist: s.artist, album: 'Album', artwork: null, durationMs: 200_000, genre: 'Jazz', releaseYear: 1990, explicit: false,
  } satisfies CatalogSong]))
  const fill: FillDeps = {
    catalog: {
      async searchArtists() { return [] },
      async artistTopSongs() { return [] },
      async searchSongs(_sf, term) {
        searches.push(term)
        const hit = songs.get(term)
        return hit ? [hit] : []
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

async function editTurn(db: TestDb, sessionId: string, call: { name: string; input: unknown }, opts: { proposed: Proposed[]; confirmed: Proposed[]; deps?: Partial<DjDeps>; brief?: string }) {
  const { fill, searches } = fakeApple(opts.confirmed)
  const { llm, requests } = scriptedLlm([call], opts.proposed)
  const deps: DjDeps = { llm, embed: embedFake, fill, neverRefuse: true, proposeFirst: true, ...opts.deps }
  const result = await runDjTurn(db, deps, { id: sessionId, userId: 'u1' }, opts.brief ?? 'swap in some Kendrick')
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
    expect(searches).toHaveLength(2)
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
