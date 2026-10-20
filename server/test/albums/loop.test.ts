import { describe, it, expect, vi } from 'vitest'
import { asc, eq } from 'drizzle-orm'
import { createTestDb, type TestDb } from '../helpers/db'
import {
  runAlbumTurn,
  AlbumTurnError,
  ALBUM_PERSONA,
  EMPTY_SHELF_REPLY,
  EMPTY_SHELF_SUGGESTIONS,
  NOTHING_VERIFIED_NOTE,
  NOTHING_VERIFIED_SUGGESTIONS,
  PICK_FALLBACK_TEXT,
  CATALOGUE_APOLOGY,
  type AlbumDeps,
} from '../../src/albums/loop'
import { choosePick, upsertAlbums, writePickVersion } from '../../src/albums/store'
import { ALBUM_TOOLS } from '../../src/albums/contracts'
import type { LlmClient, LlmRequest, LlmToolCall, LlmTurn } from '../../src/dj/llm'
import { AppleCatalogError, type AppleCatalogAlbumClient, type CatalogAlbum } from '../../src/musickit/catalog'
import { albumPicks, albums, djMessages, djSessions, listenLater, tracks, trackMeanings, userMusicProfiles, userTracks, user } from '../../src/db/schema'
import type { Embedder } from '../../src/enrich/embedder'

const DIMS = 1024
const BRIEF = (() => { const v = new Array(DIMS).fill(0); v[0] = 1; return v })()
const fakeEmbed: Embedder = async () => BRIEF

async function seedUser(db: TestDb, id = 'u1', storefront: string | null = 'us') {
  await db.insert(user).values({ id, name: id, email: `${id}@example.com`, emailVerified: false, createdAt: new Date(), updatedAt: new Date() })
  await db.insert(userMusicProfiles).values({ userId: id, appleStorefront: storefront })
}

async function seedSession(db: TestDb, userId = 'u1', kind: 'mix' | 'album' = 'album') {
  const [s] = await db.insert(djSessions).values({ userId, title: 'session', kind }).returning()
  return { id: s.id, userId }
}

let counter = 0

// A shelf album: four library songs sharing artist and album (SHELF_MIN_SONGS).
async function seedShelfAlbum(db: TestDb, userId: string, artist: string, album: string, songs = 4) {
  for (let i = 0; i < songs; i++) {
    counter += 1
    const [t] = await db.insert(tracks).values({ appleId: `lib-${counter}`, title: `song ${counter}`, artist, album, durationMs: 200_000 }).returning()
    await db.insert(trackMeanings).values({ trackId: t.id, embedding: BRIEF, lyricsSource: 'lrclib' })
    await db.insert(userTracks).values({ userId, trackId: t.id, playCount: 3, inLibrary: true })
  }
}

let appleCounter = 9000
function catalogAlbum(artist: string, title: string, over: Partial<CatalogAlbum> = {}): CatalogAlbum {
  appleCounter += 1
  return {
    appleId: String(appleCounter), upc: null, title, artist, releaseYear: 1990, trackCount: 10, durationMs: null,
    isSingle: false, isCompilation: false, genre: null, artwork: null, ...over,
  }
}

// Answers a search for "{artist} {title}" with the album registered under it.
function fakeCatalog(known: CatalogAlbum[]) {
  const byTerm = new Map(known.map((a) => [`${a.artist} ${a.title}`, a]))
  const searchAlbums = vi.fn(async (_market: string, term: string, _limit: number) => {
    const hit = byTerm.get(term)
    return hit ? [hit] : []
  })
  const getAlbums = vi.fn(async (_market: string, ids: readonly string[]) =>
    new Map(known.filter((a) => ids.includes(a.appleId)).map((a) => [a.appleId, { ...a, durationMs: 2_400_000 }])))
  const client: AppleCatalogAlbumClient = { searchAlbums, getAlbums }
  return { client, searchAlbums, getAlbums }
}

type Scripted = { text?: string; toolCalls?: LlmToolCall[] }

function makeFakeLlm(script: Scripted[]): { llm: LlmClient; requests: LlmRequest[] } {
  const requests: LlmRequest[] = []
  let call = 0
  const llm: LlmClient = async (req) => {
    requests.push(req)
    const s = script[Math.min(call, script.length - 1)]
    call += 1
    const raw: LlmTurn['raw'] = []
    if (s.text) raw.push({ type: 'text', text: s.text })
    for (const tc of s.toolCalls ?? []) raw.push({ type: 'tool_use', id: tc.id, name: tc.name, input: tc.input })
    return { text: s.text ?? '', toolCalls: s.toolCalls ?? [], raw, stopReason: 'end_turn', usage: null }
  }
  return { llm, requests }
}

function toolCall(id: string, name: string, input: unknown): LlmToolCall {
  return { id, name, input }
}

function recommend(id: string, familiarity: string, candidates: Array<Record<string, unknown>>) {
  return toolCall(id, 'recommend_album', {
    familiarity,
    candidates: candidates.map((c) => ({ type: 'album', why: 'it fits', ...c })),
  })
}

// Every tool_result in the last request, parsed, keyed by tool_use_id.
function toolResults(requests: LlmRequest[]): Record<string, any> {
  const out: Record<string, any> = {}
  for (const req of requests) {
    for (const m of req.messages) {
      if (m.role !== 'user' || !Array.isArray(m.content)) continue
      for (const block of m.content as Array<{ type: string; tool_use_id?: string; content?: string }>) {
        if (block.type === 'tool_result') out[block.tool_use_id!] = JSON.parse(block.content!)
      }
    }
  }
  return out
}

function deps(llm: LlmClient, catalog: AppleCatalogAlbumClient): AlbumDeps {
  return { llm, embed: fakeEmbed, catalog, defaultStorefront: 'us' }
}

describe('runAlbumTurn', () => {
  it('returns a pick only from a verified album, drops the rest and tells the model how many', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const session = await seedSession(db)
    const blue = catalogAlbum('Joni Mitchell', 'Blue')
    const { client } = fakeCatalog([blue])
    const { llm, requests } = makeFakeLlm([
      { toolCalls: [recommend('r1', 'mix', [{ artist: 'Made Up', title: 'Not A Record' }, { artist: 'Joni Mitchell', title: 'Blue' }])] },
      { text: 'Blue, start to finish.' },
    ])
    const result = await runAlbumTurn(db, deps(llm, client), session, 'something for a grey morning')
    expect(result.pick).not.toBeNull()
    expect(result.pick!.appleId).toBe(blue.appleId)
    expect(result.runnersUp).toEqual([])
    expect(result.version).toBe(1)
    expect(result.djMessage.queueVersion).toBe(1)
    expect(result.suggestions).toBeUndefined()
    const tr = toolResults(requests).r1
    expect(tr.dropped).toBe(1)
    expect(tr.chosen.title).toBe('Blue')
    expect(requests[0].tools).toBe(ALBUM_TOOLS)
    expect(requests[0].system).toBe(ALBUM_PERSONA)
  })

  it('a brief that verifies nothing gets the plain reply, the refinement pills and no pick', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const session = await seedSession(db)
    const { client } = fakeCatalog([])
    const { llm, requests } = makeFakeLlm([
      { toolCalls: [recommend('r1', 'mix', [{ artist: 'Made Up', title: 'Nope' }])] },
      { text: 'I could not find that one on Apple Music.' },
    ])
    const result = await runAlbumTurn(db, deps(llm, client), session, 'something obscure')
    expect(result.pick).toBeNull()
    expect(result.version).toBe(0)
    expect(result.djMessage.queueVersion).toBeNull()
    expect(result.djMessage.content).toBe('I could not find that one on Apple Music.')
    expect(result.suggestions).toEqual(NOTHING_VERIFIED_SUGGESTIONS)
    expect(toolResults(requests).r1).toEqual({ verified: [], dropped: 1, note: NOTHING_VERIFIED_NOTE })
    expect(NOTHING_VERIFIED_NOTE).toBe('Nothing verified. Name no album in your reply; say what to loosen instead.')
  })

  it('comfort yields shelf albums only', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedShelfAlbum(db, 'u1', 'Sade', 'Love Deluxe')
    const session = await seedSession(db)
    const sade = catalogAlbum('Sade', 'Love Deluxe')
    const blue = catalogAlbum('Joni Mitchell', 'Blue')
    const { client, searchAlbums } = fakeCatalog([sade, blue])
    const { llm, requests } = makeFakeLlm([
      { toolCalls: [recommend('r1', 'comfort', [{ artist: 'Joni Mitchell', title: 'Blue' }, { artist: 'Sade', title: 'Love Deluxe', fromShelf: true }])] },
      { text: 'One you know.' },
    ])
    const result = await runAlbumTurn(db, deps(llm, client), session, 'something I know')
    expect(result.pick!.appleId).toBe(sade.appleId)
    expect(result.pick!.newToThem).toBe(false)
    expect(result.runnersUp).toEqual([])
    expect(searchAlbums).toHaveBeenCalledTimes(1)
    // The shelf is in the context block, at user altitude.
    const context = requests[0].messages[0].content as string
    expect(context).toContain('Love Deluxe')
    expect(context).toMatch(/listener data/i)
    expect(requests[0].system).not.toContain('Love Deluxe')
  })

  it('comfort with an empty shelf returns the honest message and its pills with no catalogue call', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const session = await seedSession(db)
    const { client, searchAlbums, getAlbums } = fakeCatalog([catalogAlbum('Joni Mitchell', 'Blue')])
    const { llm, requests } = makeFakeLlm([
      { toolCalls: [recommend('r1', 'comfort', [{ artist: 'Joni Mitchell', title: 'Blue' }])] },
      { text: 'should never be said' },
    ])
    const result = await runAlbumTurn(db, deps(llm, client), session, 'one I already know')
    expect(result.djMessage.content).toBe(EMPTY_SHELF_REPLY)
    expect(EMPTY_SHELF_REPLY).toBe('You asked for a record you already know, and I do not see whole albums in your music yet, only scattered songs. Add more of your music and I will pick from your shelf, or let me choose something new.')
    expect(result.suggestions).toEqual(EMPTY_SHELF_SUGGESTIONS)
    expect(EMPTY_SHELF_SUGGESTIONS).toEqual(['Add my music', 'Something new is fine'])
    expect(result.pick).toBeNull()
    expect(searchAlbums).not.toHaveBeenCalled()
    expect(getAlbums).not.toHaveBeenCalled()
    expect(requests).toHaveLength(1)
  })

  it('adventurous puts a verified catalogue album at rank 0 when one exists', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedShelfAlbum(db, 'u1', 'Sade', 'Love Deluxe')
    const session = await seedSession(db)
    const sade = catalogAlbum('Sade', 'Love Deluxe')
    const blue = catalogAlbum('Joni Mitchell', 'Blue')
    const { client } = fakeCatalog([sade, blue])
    const { llm } = makeFakeLlm([
      { toolCalls: [recommend('r1', 'adventurous', [{ artist: 'Sade', title: 'Love Deluxe', fromShelf: true }, { artist: 'Joni Mitchell', title: 'Blue' }])] },
      { text: 'Something new.' },
    ])
    const result = await runAlbumTurn(db, deps(llm, client), session, 'something new')
    expect(result.pick!.appleId).toBe(blue.appleId)
    expect(result.pick!.newToThem).toBe(true)
    expect(result.runnersUp.map((r) => r.appleId)).toEqual([sade.appleId])
    expect(result.runnersUp[0].newToThem).toBe(false)
  })

  it("stores Apple's type over the model's label", async () => {
    const db = await createTestDb()
    await seedUser(db)
    const session = await seedSession(db)
    const hits = catalogAlbum('Various', 'Hits', { isCompilation: true })
    const { client } = fakeCatalog([hits])
    const { llm } = makeFakeLlm([
      { toolCalls: [recommend('r1', 'mix', [{ artist: 'Various', title: 'Hits', type: 'live' }])] },
      { text: 'Hits.' },
    ])
    const result = await runAlbumTurn(db, deps(llm, client), session, 'hits')
    expect(result.pick!.type).toBe('compilation')
    const [row] = await db.select().from(albums).where(eq(albums.appleId, hits.appleId))
    expect(row.type).toBe('compilation')
    expect(row.durationMs).toBe(2_400_000)
  })

  it('marks a catalogue album new unless the listener holds its songs', async () => {
    const db = await createTestDb()
    await seedUser(db)
    // Two held songs: not a shelf group, but the album is not new to them.
    await seedShelfAlbum(db, 'u1', 'Joni Mitchell', 'Blue', 2)
    const session = await seedSession(db)
    const blue = catalogAlbum('Joni Mitchell', 'Blue')
    const hejira = catalogAlbum('Joni Mitchell', 'Hejira')
    const { client } = fakeCatalog([blue, hejira])
    const { llm } = makeFakeLlm([
      { toolCalls: [recommend('r1', 'mix', [{ artist: 'Joni Mitchell', title: 'Blue' }, { artist: 'Joni Mitchell', title: 'Hejira' }])] },
      { text: 'Joni.' },
    ])
    const result = await runAlbumTurn(db, deps(llm, client), session, 'joni')
    const byId = new Map([result.pick!, ...result.runnersUp].map((a) => [a.appleId, a]))
    expect(byId.get(blue.appleId)!.newToThem).toBe(false)
    expect(byId.get(hejira.appleId)!.newToThem).toBe(true)
  })

  it('ranks passed-over and Listen later albums last', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const session = await seedSession(db)
    const passedAlbum = catalogAlbum('A', 'Passed')
    const current = catalogAlbum('B', 'Current')
    const saved = catalogAlbum('C', 'Saved')
    const fresh = catalogAlbum('D', 'Fresh')
    const verifiedOf = (a: CatalogAlbum) => ({ ...a, type: 'album' as const, why: 'x', fromShelf: false, modelOrder: 0, storefront: 'us' })
    const rows = await upsertAlbums(db, [passedAlbum, current, saved].map(verifiedOf))
    const id = (a: CatalogAlbum) => rows.get(a.appleId)!.id
    await writePickVersion(db, { sessionId: session.id, userId: 'u1', picks: [{ albumId: id(passedAlbum), reason: 'r', newToThem: true }] })
    await writePickVersion(db, { sessionId: session.id, userId: 'u1', picks: [{ albumId: id(current), reason: 'r', newToThem: true }] })
    await db.insert(listenLater).values({ userId: 'u1', albumId: id(saved), sessionId: session.id })
    const { client } = fakeCatalog([passedAlbum, saved, fresh])
    const { llm } = makeFakeLlm([
      { toolCalls: [recommend('r1', 'mix', [
        { artist: 'A', title: 'Passed' }, { artist: 'C', title: 'Saved' }, { artist: 'D', title: 'Fresh' },
      ])] },
      { text: 'Another.' },
    ])
    const result = await runAlbumTurn(db, deps(llm, client), session, 'another')
    expect(result.pick!.appleId).toBe(fresh.appleId)
    expect(result.runnersUp.map((r) => r.appleId).sort()).toEqual([passedAlbum.appleId, saved.appleId].sort())
    expect(result.version).toBe(3)
    // passedAlbum is a runner-up again, so it is listed there only, never twice.
    expect(result.passed.map((p) => p.appleId)).toEqual([current.appleId])
  })

  it('makes at most six catalogue calls and refuses a second recommend_album', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const session = await seedSession(db)
    const known = Array.from({ length: 5 }, (_, i) => catalogAlbum(`Artist ${i}`, `Record ${i}`))
    const { client, searchAlbums, getAlbums } = fakeCatalog(known)
    const five = known.map((a) => ({ artist: a.artist, title: a.title }))
    const { llm, requests } = makeFakeLlm([
      { toolCalls: [recommend('r1', 'mix', five)] },
      { toolCalls: [recommend('r2', 'mix', five)] },
      { text: 'Done.' },
    ])
    const result = await runAlbumTurn(db, deps(llm, client), session, 'five please')
    expect(searchAlbums).toHaveBeenCalledTimes(5)
    expect(getAlbums).toHaveBeenCalledTimes(1)
    expect(searchAlbums.mock.calls.length + getAlbums.mock.calls.length).toBeLessThanOrEqual(6)
    expect(toolResults(requests).r2).toEqual({ error: 'already_recommended' })
    expect(result.runnersUp).toHaveLength(2)
    expect(result.version).toBe(1)
  })

  it('strips em dashes from the reply, and falls back when nothing is left', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const session = await seedSession(db)
    const blue = catalogAlbum('Joni Mitchell', 'Blue')
    const { client } = fakeCatalog([blue])
    const first = makeFakeLlm([
      { toolCalls: [recommend('r1', 'mix', [{ artist: 'Joni Mitchell', title: 'Blue' }])] },
      { text: 'Blue — the whole thing — start to finish.' },
    ])
    const result = await runAlbumTurn(db, deps(first.llm, client), session, 'blue')
    expect(result.djMessage.content).not.toMatch(/—/)
    expect(result.djMessage.content).toContain('Blue')

    const session2 = await seedSession(db)
    const second = makeFakeLlm([
      { toolCalls: [recommend('r1', 'mix', [{ artist: 'Joni Mitchell', title: 'Blue' }])] },
      { text: '—' },
    ])
    const fallback = await runAlbumTurn(db, deps(second.llm, client), session2, 'blue')
    expect(fallback.djMessage.content).toBe(PICK_FALLBACK_TEXT)
    expect(PICK_FALLBACK_TEXT).not.toMatch(/—/)
  })

  it('surfaces a rename as sessionTitle', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const session = await seedSession(db)
    const { client } = fakeCatalog([])
    const { llm } = makeFakeLlm([
      { toolCalls: [toolCall('n1', 'rename_session', { title: 'Grey Mornings' })] },
      { text: 'Renamed.' },
    ])
    const result = await runAlbumTurn(db, deps(llm, client), session, 'call this Grey Mornings')
    expect(result.sessionTitle).toBe('Grey Mornings')
    const [row] = await db.select().from(djSessions).where(eq(djSessions.id, session.id))
    expect(row.title).toBe('Grey Mornings')
  })

  it('refuses a mix session', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const session = await seedSession(db, 'u1', 'mix')
    const { client } = fakeCatalog([])
    const { llm } = makeFakeLlm([{ text: 'hi' }])
    const err = await runAlbumTurn(db, deps(llm, client), session, 'hi').catch((e) => e)
    expect(err).toBeInstanceOf(AlbumTurnError)
    expect(err.kind).toBe('wrong_kind')
  })

  it('fails the turn naming the catalogue step when a search fails, keeping the listener message', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const session = await seedSession(db)
    const client: AppleCatalogAlbumClient = {
      searchAlbums: vi.fn(async () => { throw new AppleCatalogError('timeout') }),
      getAlbums: vi.fn(async () => new Map()),
    }
    const { llm } = makeFakeLlm([
      { toolCalls: [recommend('r1', 'mix', [{ artist: 'Joni Mitchell', title: 'Blue' }])] },
      { text: 'never' },
    ])
    const err = await runAlbumTurn(db, deps(llm, client), session, 'blue').catch((e) => e)
    expect(err).toBeInstanceOf(AlbumTurnError)
    expect(err.kind).toBe('catalogue')
    expect(err.step).toBe('checking Apple Music')
    expect(err.message).toBe(CATALOGUE_APOLOGY)
    expect(CATALOGUE_APOLOGY).toBe('Could not reach Apple Music to check the album. Your ask is still here.')
    expect(err.message).not.toMatch(/—/)
    const messages = await db.select().from(djMessages).where(eq(djMessages.sessionId, session.id)).orderBy(asc(djMessages.seq))
    expect(messages.map((m) => m.role)).toEqual(['user'])
  })

  it('with no market to check in, verifies nothing and makes no catalogue call', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1', null)
    const session = await seedSession(db)
    const { client, searchAlbums } = fakeCatalog([catalogAlbum('Joni Mitchell', 'Blue')])
    const { llm, requests } = makeFakeLlm([
      { toolCalls: [recommend('r1', 'mix', [{ artist: 'Joni Mitchell', title: 'Blue' }])] },
      { text: 'I cannot check Apple Music for you yet.' },
    ])
    const result = await runAlbumTurn(db, { llm, embed: fakeEmbed, catalog: client }, session, 'blue')
    expect(searchAlbums).not.toHaveBeenCalled()
    expect(toolResults(requests).r1).toEqual({ error: 'no_market' })
    expect(result.pick).toBeNull()
    expect(result.suggestions).toEqual(NOTHING_VERIFIED_SUGGESTIONS)
  })
  it('strips em dashes from the why before it is stored as the reason', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const session = await seedSession(db)
    const blue = catalogAlbum('Joni Mitchell', 'Blue')
    const { client } = fakeCatalog([blue])
    const { llm } = makeFakeLlm([
      { toolCalls: [recommend('r1', 'mix', [{ artist: 'Joni Mitchell', title: 'Blue', why: 'quiet — and warm —' }])] },
      { text: 'Blue.' },
    ])
    const result = await runAlbumTurn(db, deps(llm, client), session, 'blue')
    expect(result.pick!.reason).not.toMatch(/—/)
    expect(result.pick!.reason).toContain('quiet')
    const rows = await db.select().from(albumPicks).where(eq(albumPicks.sessionId, session.id))
    expect(rows.every((r) => !r.reason.includes('—'))).toBe(true)
  })

  it('adventurous ranks by ownership: an album they hold songs of is not the pick when a new one verifies', async () => {
    const db = await createTestDb()
    await seedUser(db)
    // Two held songs: not on the shelf listing, but owned.
    await seedShelfAlbum(db, 'u1', 'Joni Mitchell', 'Blue', 2)
    const session = await seedSession(db)
    const blue = catalogAlbum('Joni Mitchell', 'Blue')
    const pinkMoon = catalogAlbum('Nick Drake', 'Pink Moon')
    const { client } = fakeCatalog([blue, pinkMoon])
    const { llm } = makeFakeLlm([
      { toolCalls: [recommend('r1', 'adventurous', [{ artist: 'Joni Mitchell', title: 'Blue' }, { artist: 'Nick Drake', title: 'Pink Moon' }])] },
      { text: 'New.' },
    ])
    const result = await runAlbumTurn(db, deps(llm, client), session, 'something new')
    expect(result.pick!.appleId).toBe(pinkMoon.appleId)
    expect(result.pick!.newToThem).toBe(true)
    expect(result.runnersUp.map((r) => [r.appleId, r.newToThem])).toEqual([[blue.appleId, false]])
  })

  it('credits "Artist feat. Someone" rows to the album artist for affinity and ownership', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedShelfAlbum(db, 'u1', 'Sade', 'Love Deluxe')
    // Six songs credited with a feature, on two albums: no shelf group, affinity 6.
    await seedShelfAlbum(db, 'u1', 'Artist feat. Someone', 'Record', 3)
    await seedShelfAlbum(db, 'u1', 'Artist feat. Someone', 'Other', 3)
    const session = await seedSession(db)
    const sade = catalogAlbum('Sade', 'Love Deluxe')
    const record = catalogAlbum('Artist', 'Record')
    const { client } = fakeCatalog([sade, record])
    const { llm } = makeFakeLlm([
      { toolCalls: [recommend('r1', 'mix', [{ artist: 'Sade', title: 'Love Deluxe', fromShelf: true }, { artist: 'Artist', title: 'Record' }])] },
      { text: 'This one.' },
    ])
    const result = await runAlbumTurn(db, deps(llm, client), session, 'something')
    // Same slot (first of each source): affinity 6 beats the shelf album's 4.
    expect(result.pick!.appleId).toBe(record.appleId)
    expect(result.pick!.newToThem).toBe(false)
    expect(result.runnersUp.map((r) => r.appleId)).toEqual([sade.appleId])
  })

  it('mix interleaves shelf and catalogue by model order within each source', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedShelfAlbum(db, 'u1', 'Sade', 'Love Deluxe')
    await seedShelfAlbum(db, 'u1', 'Portishead', 'Dummy')
    const session = await seedSession(db)
    const sade = catalogAlbum('Sade', 'Love Deluxe')
    const dummy = catalogAlbum('Portishead', 'Dummy')
    const c1 = catalogAlbum('Nick Drake', 'Pink Moon')
    const c2 = catalogAlbum('Talk Talk', 'Laughing Stock')
    const { client } = fakeCatalog([sade, dummy, c1, c2])
    const { llm } = makeFakeLlm([
      { toolCalls: [recommend('r1', 'mix', [
        { artist: 'Nick Drake', title: 'Pink Moon' }, { artist: 'Talk Talk', title: 'Laughing Stock' },
        { artist: 'Sade', title: 'Love Deluxe', fromShelf: true }, { artist: 'Portishead', title: 'Dummy', fromShelf: true },
      ])] },
      { text: 'Mixed.' },
    ])
    const result = await runAlbumTurn(db, deps(llm, client), session, 'a mix')
    // Slot 0: Sade (affinity 4) beats Pink Moon (0) at the tie; slot 1 starts with Dummy.
    expect([result.pick!, ...result.runnersUp].map((a) => a.appleId)).toEqual([sade.appleId, c1.appleId, dummy.appleId])
  })

  it('mix: at the same slot, affinity puts a catalogue album ahead of a shelf album', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedShelfAlbum(db, 'u1', 'Sade', 'Love Deluxe')
    await seedShelfAlbum(db, 'u1', 'Portishead', 'Dummy')
    await seedShelfAlbum(db, 'u1', 'Joni Mitchell', 'Court and Spark', 6)
    const session = await seedSession(db)
    const sade = catalogAlbum('Sade', 'Love Deluxe')
    const dummy = catalogAlbum('Portishead', 'Dummy')
    const hejira = catalogAlbum('Joni Mitchell', 'Hejira')
    const other = catalogAlbum('Nobody', 'Thing')
    const { client } = fakeCatalog([sade, dummy, hejira, other])
    const { llm } = makeFakeLlm([
      { toolCalls: [recommend('r1', 'mix', [
        { artist: 'Sade', title: 'Love Deluxe', fromShelf: true }, { artist: 'Portishead', title: 'Dummy', fromShelf: true },
        { artist: 'Joni Mitchell', title: 'Hejira' }, { artist: 'Nobody', title: 'Thing' },
      ])] },
      { text: 'Mixed.' },
    ])
    const result = await runAlbumTurn(db, deps(llm, client), session, 'a mix')
    expect([result.pick!, ...result.runnersUp].map((a) => a.appleId)).toEqual([hejira.appleId, sade.appleId, dummy.appleId])
  })

  it('comfort with a shelf but no shelf candidate verifies nothing and offers the pills', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedShelfAlbum(db, 'u1', 'Sade', 'Love Deluxe')
    const session = await seedSession(db)
    const { client, searchAlbums } = fakeCatalog([catalogAlbum('Joni Mitchell', 'Blue')])
    const { llm, requests } = makeFakeLlm([
      { toolCalls: [recommend('r1', 'comfort', [{ artist: 'Joni Mitchell', title: 'Blue' }])] },
      { text: 'Nothing on your shelf fits that. Loosen it a little?' },
    ])
    const result = await runAlbumTurn(db, deps(llm, client), session, 'one I know')
    expect(searchAlbums).not.toHaveBeenCalled()
    expect(result.pick).toBeNull()
    expect(result.djMessage.content).toBe('Nothing on your shelf fits that. Loosen it a little?')
    expect(result.suggestions).toEqual(NOTHING_VERIFIED_SUGGESTIONS)
    expect(toolResults(requests).r1).toEqual({ verified: [], dropped: 1, note: NOTHING_VERIFIED_NOTE })
  })

  it('fails the turn with conflict when the pick changes before the tool writes, keeping only the listener message', async () => {
    const db = await createTestDb()
    await seedUser(db)
    const session = await seedSession(db)
    const a = catalogAlbum('A', 'First')
    const b = catalogAlbum('B', 'Second')
    const fresh = catalogAlbum('D', 'Fresh')
    const rows = await upsertAlbums(db, [a, b].map((x) => ({ ...x, type: 'album' as const, why: 'x', fromShelf: false, modelOrder: 0, storefront: 'us' })))
    const bId = rows.get(b.appleId)!.id
    await writePickVersion(db, { sessionId: session.id, userId: 'u1', picks: [
      { albumId: rows.get(a.appleId)!.id, reason: 'r', newToThem: true },
      { albumId: bId, reason: 'r', newToThem: true },
    ] })
    const { client, searchAlbums } = fakeCatalog([fresh])
    const search = searchAlbums.getMockImplementation()!
    // The listener taps a runner-up while the turn is checking Apple Music.
    searchAlbums.mockImplementationOnce(async (market, term, limit) => {
      await choosePick(db, { sessionId: session.id, userId: 'u1', albumId: bId })
      return search(market, term, limit)
    })
    const { llm } = makeFakeLlm([
      { toolCalls: [recommend('r1', 'mix', [{ artist: 'D', title: 'Fresh' }])] },
      { text: 'never' },
    ])
    const err = await runAlbumTurn(db, deps(llm, client), session, 'another').catch((e) => e)
    expect(err).toBeInstanceOf(AlbumTurnError)
    expect(err.kind).toBe('conflict')
    const messages = await db.select().from(djMessages).where(eq(djMessages.sessionId, session.id))
    expect(messages.map((m) => m.role)).toEqual(['user'])
    const [s] = await db.select().from(djSessions).where(eq(djSessions.id, session.id))
    expect(s.queueVersion).toBe(2)
  })
})
