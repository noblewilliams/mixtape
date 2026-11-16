import { describe, it, expect, vi } from 'vitest'
import { createTestDb, type TestDb } from '../helpers/db'
import { djSessions, trackFeatures, trackMeanings, tracks, user, userArtistSeeds, userTracks } from '../../src/db/schema'
import { runDjTurn, type DjDeps } from '../../src/dj/loop'
import { PROPOSE_SYSTEM_PROMPT, PROPOSE_SYSTEM_PROMPT_PERSONAL } from '../../src/dj/propose'
import {
  ARTIST_ASK,
  ARTIST_PER_MIX,
  ARTIST_SYSTEM_PROMPT,
  ARTIST_TOP_SONGS,
  ARTIST_TOP_SONGS_INSTRUMENTAL,
  proposeArtists,
} from '../../src/dj/artist-pool'
import type { FillDeps } from '../../src/dj/catalogue-fill'
import type { CatalogSong } from '../../src/musickit/catalog'
import { MOOD_CHECK_SYSTEM } from '../../src/dj/genre-check'
import type { LlmClient, LlmRequest, LlmTurn } from '../../src/dj/llm'
import type { Intent } from '../../src/dj/contracts'

// Genre briefs draw from artists' real songs (2026-11-16): with propose
// first, a personal genre blend asks the model for artists, not song
// titles, and takes their top songs from Apple. Structural assertions only.

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

async function seedLibrary(db: TestDb, n: number, owner = 'u1', genre = 'Soul') {
  const artists = ['Mine A', 'Mine B', 'Mine C']
  for (let i = 0; i < n; i++) {
    const [t] = await db.insert(tracks).values({ appleId: `lib-${owner}-${i}`, title: `Library ${i}`, artist: artists[i % 3], genre, durationMs: 200_000 }).returning()
    await db.insert(trackFeatures).values({ trackId: t.id, tempo: 100, energy: 0.5, valence: 0.5, source: 'reccobeats' })
    await db.insert(trackMeanings).values({ trackId: t.id, embedding: UNIT, lyricsSource: 'lrclib' })
    await db.insert(userTracks).values({ userId: owner, trackId: t.id, inLibrary: true })
  }
}

const ARTISTS = Array.from({ length: 12 }, (_, i) => `Afro ${String.fromCharCode(65 + i)}`)
const artistReason = (name: string) => `Warm log drums and patient chords from ${name.split(' ')[1]} keep the room swaying.`
const artistAnswer = (names: string[]) => names.map((artist) => ({ artist, reason: artistReason(artist) }))

const songTitle = (artist: string, j: number) => `${artist} Hit ${j}`

// Apple knows every artist in `known`; each has `songsPer` top songs,
// labelled by `genreOf`. Song searches (the song-proposal path) confirm
// every title asked for, so a fallback still lands.
type Proposed = { title: string; artist: string; reason: string }

type AppleOpts = {
  songsPer?: number
  genreOf?: (artist: string, j: number) => string
  // Apple's every genre name but "Music", and hasLyrics; absent when unset.
  genresOf?: (artist: string, j: number) => string[]
  lyricsOf?: (artist: string, j: number) => boolean | null
  shape?: (artist: string, own: CatalogSong[]) => CatalogSong[]
  proposals?: Proposed[]
}

function fakeApple(known: string[], opts: AppleOpts = {}) {
  const artistSearches: string[] = []
  const topSongs: string[] = []
  const limits: number[] = []
  const songSearches: string[] = []
  const catalog: FillDeps['catalog'] = {
    async searchArtists(_sf, term) {
      artistSearches.push(term)
      return known.includes(term) ? [{ id: `ar-${term}`, name: term, genres: [] }] : []
    },
    async artistTopSongs(_sf, id, limit) {
      const name = id.replace(/^ar-/, '')
      topSongs.push(name)
      limits.push(limit)
      const own = Array.from({ length: opts.songsPer ?? 10 }, (_, j) => ({
        appleId: `ap-${name}-${j}`, isrc: null, title: songTitle(name, j), artist: name, album: 'Album', artwork: null,
        durationMs: 200_000, genre: opts.genreOf ? opts.genreOf(name, j) : 'Dance', releaseYear: 2020, explicit: false,
        ...(opts.genresOf ? { genres: opts.genresOf(name, j) } : {}),
        ...(opts.lyricsOf ? { hasLyrics: opts.lyricsOf(name, j) } : {}),
      } satisfies CatalogSong))
      return (opts.shape ? opts.shape(name, own) : own).slice(0, limit)
    },
    async searchSongs(_sf, term) {
      songSearches.push(term)
      const p = (opts.proposals ?? []).find((s) => `${s.title} ${s.artist}` === term)
      return p ? [{ appleId: `s-${term}`, isrc: null, title: p.title, artist: p.artist, album: 'A', artwork: null, durationMs: 200_000, genre: 'Dance', releaseYear: 2020, explicit: false }] : []
    },
  }
  const fill: FillDeps = {
    catalog,
    defaultStorefront: 'us',
    enrich: { storefront: 'us', itunes: async () => null, features: async () => null, lyrics: async () => null, embed: async () => UNIT },
  }
  return { fill, artistSearches, topSongs, songSearches, limits }
}

const isSongProposal = (req: LlmRequest) => req.system === PROPOSE_SYSTEM_PROMPT || req.system === PROPOSE_SYSTEM_PROMPT_PERSONAL
const isArtistCall = (req: LlmRequest) => req.system === ARTIST_SYSTEM_PROMPT

function textTurn(text: string): LlmTurn {
  return { text, toolCalls: [], raw: [{ type: 'text', text }], stopReason: 'end_turn', usage: null }
}

function curationCount(req: LlmRequest): number {
  return Number(((req.messages[0].content as Array<{ text?: string }>)[1]?.text ?? '').match(/Pick up to (\d+) tracks/)?.[1] ?? NaN)
}

type Script = { artists?: () => Promise<string> | string; proposed?: Proposed[] }

function scriptedLlm(generateInput: Record<string, unknown>, script: Script) {
  const requests: LlmRequest[] = []
  let conv = 0
  const llm: LlmClient = async (req) => {
    requests.push(req)
    if (isArtistCall(req)) return textTurn(await (script.artists ?? (() => JSON.stringify(artistAnswer(ARTISTS))))())
    if (isSongProposal(req)) return textTurn(JSON.stringify(script.proposed ?? []))
    if (req.tools.length === 0) {
      const blocks = req.messages[0].content as Array<{ text?: string }>
      const ids = Array.from((blocks[0]?.text ?? '').matchAll(/^([0-9a-f-]{36}) \|/gm)).map((m) => m[1])
      return textTurn(JSON.stringify(ids.slice(0, curationCount(req)).map((id) => ({ id, reason: 'fits' }))))
    }
    conv += 1
    if (conv === 1) {
      const c = { id: 'c1', name: 'generate_queue', input: { themes: 'slow living, instrumental', ...generateInput } }
      return { text: '', toolCalls: [c], raw: [{ type: 'tool_use', ...c }], stopReason: 'tool_use', usage: null }
    }
    return textTurn('here you go.')
  }
  return { llm, requests }
}

// The sound check passes titles `passes` accepts. The artist pool's mood
// check (MOOD_CHECK_SYSTEM) answers genre by `passes` and mood by `passes`
// and `mood`.
function checker(passes: (title: string) => boolean, mood: (title: string) => boolean = () => true) {
  const prompts: string[] = []
  const moodPrompts: string[] = []
  const titleComplete = async (opts: { prompt: string; system: string }) => {
    prompts.push(opts.prompt)
    const lines = Array.from(opts.prompt.matchAll(/^(\d+) \| (.+?) — /gm))
    if (opts.system === MOOD_CHECK_SYSTEM) {
      moodPrompts.push(opts.prompt)
      const genre = lines.filter((m) => passes(m[2])).map((m) => Number(m[1]))
      const fits = lines.filter((m) => passes(m[2]) && mood(m[2])).map((m) => Number(m[1]))
      return JSON.stringify({ genre, mood: fits })
    }
    return JSON.stringify(lines.filter((m) => passes(m[2])).map((m) => Number(m[1])))
  }
  return { prompts, moodPrompts, titleComplete: titleComplete as unknown as DjDeps['titleComplete'] }
}

function toolResults(requests: LlmRequest[]): string[] {
  const last = requests.filter((r) => r.tools.length > 0).at(-1)!
  return last.messages
    .filter((m) => m.role === 'user' && Array.isArray(m.content) && (m.content[0] as { type?: string }).type === 'tool_result')
    .map((m) => (m.content as Array<{ content: string }>)[0].content)
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

const isHit = (title: string) => / Hit \d+$/.test(title)

async function genreTurn(opts: {
  targetCount?: number
  genres?: string[] | null
  known?: string[]
  songsPer?: number
  genreOf?: (artist: string, j: number) => string
  script?: Script
  passes?: (title: string) => boolean
  mood?: (title: string) => boolean
  genresOf?: AppleOpts['genresOf']
  lyricsOf?: AppleOpts['lyricsOf']
  deps?: Partial<DjDeps>
  library?: number
  before?: (db: TestDb) => Promise<void>
  shape?: (artist: string, own: CatalogSong[]) => CatalogSong[]
  input?: Record<string, unknown>
}) {
  const db = await createTestDb()
  await seedUser(db)
  await seedLibrary(db, opts.library ?? 30)
  await opts.before?.(db)
  const session = await seedSession(db)
  const apple = fakeApple(opts.known ?? ARTISTS, {
    songsPer: opts.songsPer, genreOf: opts.genreOf, genresOf: opts.genresOf, lyricsOf: opts.lyricsOf, shape: opts.shape, proposals: opts.script?.proposed,
  })
  const check = checker(opts.passes ?? isHit, opts.mood)
  const genres = opts.genres === null ? {} : { genres: opts.genres ?? ['afro house', 'lofi'] }
  const { llm, requests } = scriptedLlm({ targetCount: opts.targetCount ?? 15, ...genres, ...opts.input }, opts.script ?? {})
  const deps: DjDeps = { llm, embed: embedFake, fill: apple.fill, neverRefuse: true, proposeFirst: true, titleComplete: check.titleComplete, ...opts.deps }
  const { value: result, logged } = await withLog(() => runDjTurn(db, deps, { id: session.id, userId: 'u1' }, 'lofi afro house slow living great instrumentals'))
  const [text] = toolResults(requests)
  return { db, session, result, requests, text, logged, checks: check.prompts, moodChecks: check.moodPrompts, ...apple }
}

const perArtist = (queue: Array<{ artist: string }>) => {
  const counts = new Map<string, number>()
  for (const t of queue) counts.set(t.artist, (counts.get(t.artist) ?? 0) + 1)
  return counts
}

describe('proposeArtists', () => {
  const intent = { targetCount: 15, familiarity: 'mix', allowExplicit: true, themes: 'slow living', genres: ['afro house', 'lofi'] } as unknown as Intent

  it('one call, thinking off, a static system prompt, up to 12 artists, genre-true in the user turn', async () => {
    const requests: LlmRequest[] = []
    const llm: LlmClient = async (req) => { requests.push(req); return textTurn(JSON.stringify(artistAnswer(ARTISTS))) }
    const artists = await proposeArtists(llm, { brief: 'lofi afro house\u0007 slow living', intent, seeds: ['Seed One'], topArtists: ['Top One'], storefront: 'us' })
    expect(artists).toHaveLength(12)
    expect(requests).toHaveLength(1)
    const [req] = requests
    expect(req.system).toBe(ARTIST_SYSTEM_PROMPT)
    expect(req.thinking).toBe('off')
    expect(req.tools).toEqual([])
    expect(ARTIST_SYSTEM_PROMPT).not.toMatch(/afro/i)
    expect(ARTIST_SYSTEM_PROMPT).not.toContain('—')
    const block = req.messages[0].content as string
    expect(block).toContain(`Name up to ${ARTIST_ASK} artists.`)
    expect(block).toMatch(/afro house, lofi/)
    expect(block).toContain('any one of them')
    expect(block).toContain('Top One')
    expect(block).toContain('Seed One')
    // Control characters in the listener's words are cleaned.
    expect(block).not.toContain('\u0007')
  })

  it('keeps valid artists once each, at most 12, with sanitised reasons', async () => {
    const raw = [
      { artist: 'Afro A', reason: 'warm — drums' },
      { artist: 'afro a', reason: 'dupe' },
      { artist: '', reason: 'nameless' },
      { name: 'Afro B', reason: 'name field' },
      'junk',
      ...artistAnswer(Array.from({ length: 20 }, (_, i) => `Extra ${i}`)),
    ]
    const llm: LlmClient = async () => textTurn(`here: ${JSON.stringify(raw)}`)
    const artists = await proposeArtists(llm, { brief: 'x', intent, seeds: [], storefront: 'us' })
    expect(artists).toHaveLength(ARTIST_ASK)
    expect(artists[0].name).toBe('Afro A')
    expect(artists[0].reason).not.toContain('—')
    expect(artists[0].reason[0]).toBe('W')
    expect(artists.filter((a) => a.name.toLowerCase() === 'afro a')).toHaveLength(1)
    expect(artists[1].name).toBe('Afro B')
  })

  it('unparseable output is no artists, not an error', async () => {
    const llm: LlmClient = async () => textTurn('sorry, no')
    expect(await proposeArtists(llm, { brief: 'x', intent, seeds: [], storefront: 'us' })).toEqual([])
  })
})

describe('a propose-first genre brief draws from its artists\' real songs', () => {
  it('golden: one artist call and no song proposals, top songs per artist, a full mix of real songs, three per artist at most, one check', async () => {
    const { result, requests, artistSearches, topSongs, songSearches, checks, text } = await genreTurn({})
    expect(requests.filter(isArtistCall)).toHaveLength(1)
    expect(requests.filter(isSongProposal)).toHaveLength(0)
    expect(artistSearches.sort()).toEqual([...ARTISTS].sort())
    expect(topSongs.sort()).toEqual([...ARTISTS].sort())
    expect(songSearches).toHaveLength(0)
    expect(result.queue).toHaveLength(15)
    // Library songs fail the check here; every song is an artist's real top song.
    for (const t of result.queue) {
      expect(isHit(t.title)).toBe(true)
      expect(ARTISTS).toContain(t.artist)
    }
    for (const n of perArtist(result.queue).values()) expect(n).toBeLessThanOrEqual(ARTIST_PER_MIX)
    // The artist pool goes to the sound check in one call.
    expect(checks.filter((p) => / Hit \d+ — /.test(p))).toHaveLength(1)
    expect(text).not.toMatch(/this mix is \d+ of the \d+ songs asked for/)
    expect(text).not.toMatch(/lean adjacent/)
  })

  it('takes Apple\'s popularity order round-robin across artists', async () => {
    const { result } = await genreTurn({})
    const titles = new Set(result.queue.map((t) => t.title))
    // Twelve artists, fifteen songs: every artist's top song, then three seconds.
    for (const a of ARTISTS) expect(titles.has(songTitle(a, 0))).toBe(true)
    expect([...titles].filter((t) => t.endsWith(' Hit 1'))).toHaveLength(3)
    expect([...titles].some((t) => / Hit [2-9]$/.test(t))).toBe(false)
  })

  it('with few artists, still never more than three of any one', async () => {
    const four = ARTISTS.slice(0, 4)
    const { result, requests } = await genreTurn({ known: four, script: { artists: () => JSON.stringify(artistAnswer(four)) } })
    expect(requests.filter(isSongProposal)).toHaveLength(0)
    expect(result.queue).toHaveLength(12)
    for (const n of perArtist(result.queue).values()) expect(n).toBe(3)
  })

  it('each artist\'s first song carries its reason; the queue\'s repeat rule blanks the rest', async () => {
    const { db, session } = await genreTurn({})
    const rows = (await db.execute(`SELECT t.artist, q.reason FROM queue_tracks q JOIN tracks t ON t.id = q.track_id
      WHERE q.session_id = '${session.id}' AND q.state = 'active'`)).rows as Array<{ artist: string; reason: string }>
    expect(rows.length).toBe(15)
    for (const r of rows) expect([artistReason(r.artist), '']).toContain(r.reason)
    for (const a of ARTISTS) expect(rows.filter((r) => r.reason === artistReason(a))).toHaveLength(1)
  })

  it('songs the listener owns, album glue and second releases of one song stay out of the artist pool', async () => {
    const { checks } = await genreTurn({
      before: async (db) => {
        const [t] = await db.insert(tracks).values({ appleId: 'ap-Afro A-0', title: songTitle('Afro A', 0), artist: 'Afro A', genre: 'Soul', durationMs: 200_000 }).returning()
        await db.insert(userTracks).values({ userId: 'u1', trackId: t.id, inLibrary: true })
      },
      shape: (artist, own) => artist === 'Afro B'
        ? [
          { ...own[0], appleId: 'glue-b', title: 'Intro' },
          own[0],
          { ...own[0], appleId: 'dupe-b', title: `${songTitle(artist, 0)} (Radio Edit)` },
          ...own.slice(1),
        ]
        : own,
    })
    const pool = checks.find((p) => p.includes(`${songTitle('Afro B', 0)} — `))!
    expect(pool).not.toContain(`${songTitle('Afro A', 0)} — Afro A`)
    expect(pool).toContain(`${songTitle('Afro A', 1)} — Afro A`)
    expect(pool).not.toMatch(/Intro — Afro B/)
    expect(pool).not.toMatch(/Radio Edit/)
    expect(pool).toContain(`${songTitle('Afro B', 1)} — Afro B`)
  })

  it('an explicit-free brief keeps explicit top songs out', async () => {
    const { checks } = await genreTurn({
      input: { allowExplicit: false },
      shape: (artist, own) => [{ ...own[0], appleId: `x-${artist}`, title: `${artist} Rude`, explicit: true }, ...own],
    })
    const pool = checks.find((p) => p.includes(`${songTitle('Afro B', 0)} — `))!
    expect(pool).not.toMatch(/ Rude — /)
  })

  it('the floor refills from the artist pool\'s rejects before the library\'s', async () => {
    // Only Afro A's songs pass: three kept, floor 10, seven refilled.
    const { result, text } = await genreTurn({ passes: (t) => t.startsWith('Afro A ') })
    expect(result.queue).toHaveLength(10)
    expect(result.queue.every((t) => isHit(t.title))).toBe(true)
    expect(result.queue.filter((t) => t.artist === 'Afro A')).toHaveLength(3)
    expect(text).toContain('note: 7 of these songs lean adjacent to afro house or lofi')
    for (const n of perArtist(result.queue).values()) expect(n).toBeLessThanOrEqual(ARTIST_PER_MIX)
  })

  it('the turn log counts the artists, songs and Apple calls, nothing else', async () => {
    const { logged } = await genreTurn({})
    const propose = logged.propose as Record<string, unknown>
    expect(propose.artists).toEqual({ asked: 12, used: 12, songs: 12 * ARTIST_PER_MIX, apple: 24, instrumental: 0, moodPassed: 12 * ARTIST_PER_MIX })
    expect(JSON.stringify(propose)).not.toMatch(/Afro|Hit/)
  })

  it('asks Apple for about ten songs per artist', async () => {
    let limit = 0
    const apple = fakeApple(ARTISTS)
    const top = apple.fill.catalog.artistTopSongs
    apple.fill.catalog.artistTopSongs = async (sf, id, l) => { limit = l; return top(sf, id, l) }
    expect(ARTIST_TOP_SONGS).toBe(10)
    const db = await createTestDb()
    await seedUser(db)
    await seedLibrary(db, 10)
    const session = await seedSession(db)
    const { llm } = scriptedLlm({ targetCount: 15, genres: ['afro house'] }, {})
    await runDjTurn(db, { llm, embed: embedFake, fill: apple.fill, neverRefuse: true, proposeFirst: true, titleComplete: checker(isHit).titleComplete },
      { id: session.id, userId: 'u1' }, 'afro house')
    expect(limit).toBe(ARTIST_TOP_SONGS)
  })
})

// Mood words steer the pool (2026-11-16): live, "lofi afro house slow
// living great instrumentals" came back as afro house vocal hits.
describe('the artist pool honours instrumental and mood', () => {
  const lineTitles = (prompt: string) => Array.from(prompt.matchAll(/^\d+ \| (.+?) — /gm)).map((m) => m[1])
  const instrumentalTitle = (t: string) => / Hit (1|3|5|7|9|11|13|15|17|19)$/.test(t)

  it('an instrumental brief asks Apple for twenty songs per artist and tells the artist call', async () => {
    const { limits, requests } = await genreTurn({ input: { instrumental: true }, songsPer: 20 })
    expect(ARTIST_TOP_SONGS_INSTRUMENTAL).toBe(20)
    expect(limits.length).toBe(12)
    expect(limits.every((l) => l === ARTIST_TOP_SONGS_INSTRUMENTAL)).toBe(true)
    const block = requests.find(isArtistCall)!.messages[0].content as string
    expect(block).toMatch(/instrumental/i)
    expect(ARTIST_SYSTEM_PROMPT).not.toMatch(/Instrumental:/)
  })

  it('a brief without instrumental keeps ten per artist and an unchanged artist call', async () => {
    const { limits, requests } = await genreTurn({})
    expect(limits.every((l) => l === ARTIST_TOP_SONGS)).toBe(true)
    const block = requests.find(isArtistCall)!.messages[0].content as string
    expect(block).not.toMatch(/Instrumental:/)
  })

  it('keeps songs without lyrics and drops songs with lyrics when enough remain for the floor', async () => {
    // Odd-numbered songs are instrumentals: Apple's top two are vocal.
    const { result, moodChecks, logged } = await genreTurn({
      input: { instrumental: true }, songsPer: 20, lyricsOf: (_a, j) => j % 2 === 0,
    })
    const pool = lineTitles(moodChecks[0])
    expect(pool).toHaveLength(36)
    expect(pool.every(instrumentalTitle)).toBe(true)
    expect(result.queue).toHaveLength(15)
    expect(result.queue.every((t) => instrumentalTitle(t.title))).toBe(true)
    for (const n of perArtist(result.queue).values()) expect(n).toBeLessThanOrEqual(ARTIST_PER_MIX)
    expect((logged.propose as { artists: { instrumental: number } }).artists.instrumental).toBe(36)
  })

  it('keeps songs with lyrics, last, when too few instrumentals remain for the floor; unknown sits between', async () => {
    // Afro A to C have one instrumental each (song 5), Afro D one song of unknown lyrics (song 6); the rest are vocal.
    const lyricsOf = (a: string, j: number) => (['Afro A', 'Afro B', 'Afro C'].includes(a) && j === 5 ? false : a === 'Afro D' && j === 6 ? null : true)
    const { result, moodChecks } = await genreTurn({ input: { instrumental: true }, songsPer: 20, lyricsOf })
    const pool = lineTitles(moodChecks[0])
    expect(pool.slice(0, 3).sort()).toEqual(['Afro A Hit 5', 'Afro B Hit 5', 'Afro C Hit 5'])
    expect(pool[3]).toBe('Afro D Hit 6')
    expect(pool).toHaveLength(36)
    expect(result.queue).toHaveLength(15)
    const titles = result.queue.map((t) => t.title)
    for (const t of ['Afro A Hit 5', 'Afro B Hit 5', 'Afro C Hit 5', 'Afro D Hit 6']) expect(titles).toContain(t)
    for (const n of perArtist(result.queue).values()) expect(n).toBeLessThanOrEqual(ARTIST_PER_MIX)
  })

  it('a song labelled the genre in any of its genre names passes as genre, and is still checked for mood', async () => {
    // The model calls nothing genre; every song's names hold Afro House.
    const { result, moodChecks } = await genreTurn({
      passes: () => false,
      genresOf: () => ['Dance', 'African', 'Afro House'],
      // Mood alone cannot pass a song the check calls off-genre, so the
      // fake's mood list is empty; label matches then fail mood.
    })
    expect(moodChecks).toHaveLength(1)
    // Label matches were sent to the call.
    expect(lineTitles(moodChecks[0])).toHaveLength(36)
    expect(moodChecks[0]).toContain('| Dance, African, Afro House |')
    // Genre-true by label, failed mood: they refill the floor first.
    expect(result.queue).toHaveLength(10)
    expect(result.queue.every((t) => isHit(t.title))).toBe(true)
  })

  it('one mood check for the pool, with the brief mood, and the mix takes mood passes first', async () => {
    const moodOk = (t: string) => / Hit [12]$/.test(t)
    const { result, moodChecks, logged } = await genreTurn({ mood: moodOk })
    expect(moodChecks).toHaveLength(1)
    expect(moodChecks[0]).toContain('Mood asked for: slow living, instrumental')
    // 24 pass mood; the mix (15, all from the pool) takes only them.
    expect(result.queue).toHaveLength(15)
    expect(result.queue.every((t) => moodOk(t.title))).toBe(true)
    expect((logged.propose as { artists: { moodPassed: number } }).artists.moodPassed).toBe(24)
  })

  it('mood-failing genre-true songs refill the floor before other rejects', async () => {
    // Only Afro A passes mood; Afro B and C are genre-true; everyone else fails genre.
    const { result } = await genreTurn({
      passes: (t) => /^Afro [ABC] /.test(t),
      mood: (t) => t.startsWith('Afro A '),
    })
    expect(result.queue).toHaveLength(10)
    const artists = perArtist(result.queue)
    expect(artists.get('Afro A')).toBe(3)
    expect(artists.get('Afro B')).toBe(3)
    expect(artists.get('Afro C')).toBe(3)
  })
})

describe('the artist pool falls back to song proposals', () => {
  const songProposals = Array.from({ length: 30 }, (_, i) => ({ title: `Proposed ${i}`, artist: `Prop ${i % 6}`, reason: `reason ${i}` }))

  it('an artist call that fails: one song-proposal call, the mix still lands, the log says why', async () => {
    const { result, requests, logged } = await genreTurn({
      script: { artists: () => { throw new Error('model down') }, proposed: songProposals },
      passes: () => true,
    })
    expect(requests.filter(isSongProposal)).toHaveLength(1)
    expect(result.queue.length).toBe(15)
    expect((logged.propose as { artists?: { fallback?: string } }).artists?.fallback).toBe('call')
  })

  it('fewer than three artists: song proposals instead', async () => {
    const two = ARTISTS.slice(0, 2)
    const { requests, logged, topSongs } = await genreTurn({ script: { artists: () => JSON.stringify(artistAnswer(two)), proposed: songProposals }, passes: () => true })
    expect(requests.filter(isSongProposal)).toHaveLength(1)
    expect(topSongs).toHaveLength(0)
    expect((logged.propose as { artists?: { fallback?: string } }).artists?.fallback).toBe('artists')
  })

  it('Apple finding too few of their songs: song proposals instead', async () => {
    const { requests, logged } = await genreTurn({ known: ARTISTS.slice(0, 2), script: { proposed: songProposals }, passes: () => true })
    expect(requests.filter(isSongProposal)).toHaveLength(1)
    const artists = (logged.propose as { artists?: { fallback?: string; used?: number } }).artists
    expect(artists?.fallback).toBe('songs')
    expect(artists?.used).toBe(2)
  })
})

describe('everything else is unchanged', () => {
  it('a brief with no genre makes no artist call', async () => {
    const { requests, topSongs } = await genreTurn({ genres: null, script: { proposed: [] } })
    expect(requests.filter(isArtistCall)).toHaveLength(0)
    expect(topSongs).toHaveLength(0)
    expect(requests.filter(isSongProposal)).toHaveLength(1)
  })

  it('flag off makes no artist call', async () => {
    const { requests, topSongs } = await genreTurn({ deps: { proposeFirst: false } })
    expect(requests.filter(isArtistCall)).toHaveLength(0)
    expect(topSongs).toHaveLength(0)
  })

  it('an own-music brief makes no artist call', async () => {
    const { requests } = await genreTurn({ input: { allowOutside: false } })
    expect(requests.filter(isArtistCall)).toHaveLength(0)
  })

  it('a corpus genre mix makes no artist call', async () => {
    const db = await createTestDb()
    await seedUser(db)
    await seedUser(db, 'other')
    await seedLibrary(db, 27, 'other')
    for (const name of ['Mine A', 'Mine B', 'Mine C']) await db.insert(userArtistSeeds).values({ userId: 'u1', name, source: 'interview' })
    const session = await seedSession(db)
    const apple = fakeApple(ARTISTS)
    const { llm, requests } = scriptedLlm({ targetCount: 15, genres: ['afro house'] }, {})
    await runDjTurn(db, { llm, embed: embedFake, fill: apple.fill, neverRefuse: true, proposeFirst: true, titleComplete: checker(isHit).titleComplete },
      { id: session.id, userId: 'u1' }, 'afro house')
    expect(requests.filter(isArtistCall)).toHaveLength(0)
    expect(apple.topSongs).toHaveLength(0)
  })
})

describe('artist prompt with several genres', () => {
  it('balances named genres so a texture-like genre never crowds out the others', () => {
    expect(ARTIST_SYSTEM_PROMPT).toMatch(/where they meet/)
    expect(ARTIST_SYSTEM_PROMPT).toMatch(/never crowds out the others/)
  })
})
