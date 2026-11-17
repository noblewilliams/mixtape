import { describe, it, expect } from 'vitest'
import { createHash } from 'node:crypto'
import { curate } from '../../src/dj/curate'
import { DJ_TOOLS, DJ_TOOLS_WITH_OUTSIDE, intentSchema } from '../../src/dj/contracts'
import { FILL_PERSONA_LINE, HONEST_LISTING_PERSONA_LINE, PERSONA_PROMPT, PERSONA_PROMPT_WITH_FILL, runDjTurn } from '../../src/dj/loop'
import { createTestDb } from '../helpers/db'
import { djSessions, user } from '../../src/db/schema'
import type { FillDeps } from '../../src/dj/catalogue-fill'
import { FIRST_NAME_PERSONA_LINE } from '../../src/dj/listener-name'
import type { LlmClient, LlmRequest } from '../../src/dj/llm'
import type { PoolTrack } from '../../src/dj/pool'

// PROPOSE_FIRST "off" is the kill switch back to the DJ before propose
// first, and what it sends must not drift: the same tool definitions, the
// same persona and the same curation request. These hashes were taken from
// the code as it stood before outside picks existed (2026-10-03); this file
// pinned OUTSIDE_PICKS "off" until that flag retired (propose first S10,
// 2026-11-17), and a pool without new songs still sends exactly that. A
// change here is a change to what the model sees, which is never
// incidental.
const sha = (s: string) => createHash('sha256').update(s).digest('hex')

const PINNED = {
  tools: 'e8e7182e2be15efbe3e740bc6a13d850d183125dac2a226fc08f944460f0f002',
  persona: '6afe70f49f5eb3d743b2dbd80647e6e1067ae1075318c68b6cd5a856b6dd1840',
  // Prompt parts only (system, messages, tools, effort); re-pinned 2026-10-21
  // when the token budget left the hash, see the curation test below, and
  // again 2026-11-09 for the fit rule, the count as a ceiling ("Pick up to")
  // and the sentence-length note rule (spec every-song-earns-its-place,
  // decisions 1 and 7): deliberate changes, flag on or off. Re-pinned the
  // same day for the genre-or-era hard-constraint line, after the live rerun
  // filled "soft jazz" with soft indie. Again for the genre field on each
  // pool line and the rule that it is the evidence for a named genre.
  curation: '81b2d4eb5df5878b9a1f612a2655601016a90eb3d46e2758043ee08c6a4b23b0',
}

function personalPool(n: number): PoolTrack[] {
  return Array.from({ length: n }, (_, i) => ({
    trackId: `t${i}`,
    appleId: `apple${i}`,
    spotifyId: null,
    title: `Title ${i}`,
    artist: `Artist ${i}`,
    playCount: n - i,
    tempo: 120,
    energy: 0.5,
    valence: 0.5,
    releaseYear: 2000,
    durationMs: 200_000,
    score: n - i,
  }) as PoolTrack)
}

describe('PROPOSE_FIRST off without the fill is byte-for-byte the plain DJ', () => {
  // generate_queue's namedArtists/namedSongs (2026-10-21 everyone gets a mix),
  // every intent's onlyArtist (2026-11-09 artist-only mixes) and every
  // intent's genres (2026-11-09 every-song-earns-its-place, decision 8: the
  // named genre each song is checked against) are deliberate changes to what
  // the model sees, whatever the flags; with them stripped, the plain tools
  // are still the pre-outside ones.
  it('sends the same tool definitions, bar the named artists and songs, the artist-only scope, the genres and instrumental', () => {
    const added = new Set(['namedArtists', 'namedSongs', 'onlyArtist', 'genres', 'instrumental'])
    const stripped = JSON.stringify(
      JSON.parse(JSON.stringify(DJ_TOOLS), (k, v) => (added.has(k) ? undefined : v)),
    )
    expect(sha(stripped)).toBe(PINNED.tools)
  })

  // The first-name rule (profile name spec 2026-11-02) and the honest-listing
  // rule (spec 2026-11-09 every-song-earns-its-place, decision 5) are
  // deliberate changes to the persona, whatever the flags; with them stripped,
  // the persona is still the pre-outside one.
  it('sends the same persona, bar the first-name and honest-listing rules', () => {
    const stripped = PERSONA_PROMPT.replace(`${FIRST_NAME_PERSONA_LINE}\n`, '').replace(`${HONEST_LISTING_PERSONA_LINE}\n`, '')
    expect(sha(stripped)).toBe(PINNED.persona)
  })

  it('sends the same curation request', async () => {
    const requests: LlmRequest[] = []
    const llm: LlmClient = async (req) => {
      requests.push(req)
      return { text: '[{"id":"t0","reason":"opener"}]', toolCalls: [], raw: [], stopReason: 'end_turn', usage: null }
    }
    const intent = intentSchema.parse({ themes: 'late night drive', tempoMin: 90, tempoMax: 120, energyArc: 'rise', eraFrom: 1990, eraTo: 2010, familiarity: 'mix', targetCount: 5 })
    await curate(llm, personalPool(8), intent, 'Current queue: empty.')
    const { system, messages, tools, maxTokens, effort } = requests[0]
    // The prompt parts are pinned byte-for-byte. The token budget is a knob
    // asserted on its own: fix(dj) 2026-10-21 raised it so Sonnet 5's
    // adaptive thinking fits (BASE 6000 + 200 per track), and 2026-11-09
    // to 250 per track for sentence-length notes.
    const promptHash = sha(JSON.stringify({ system, messages, tools, effort }))
    expect(promptHash).toBe(PINNED.curation)
    expect(maxTokens).toBe(6000 + 250 * 5)
  })
})

// A deliberate change (spec 2026-11-09 every-song-earns-its-place, decision
// 2): with NEVER_REFUSE on and the Apple fill wired, as production ships, a
// short mix is filled from outside the library even with PROPOSE_FIRST
// off, so the model gets allowOutside (DJ_TOOLS_WITH_OUTSIDE) and one more
// persona line, to say no for a listener who wants only their own music.
// The pins above still hold for what a turn sends without the fill; the
// fill variant is the plain persona plus that one line.
describe('PROPOSE_FIRST off with the shortfall fill wired', () => {
  it('without the fill, a turn sends the plain tools and persona', async () => {
    const db = await createTestDb()
    await db.insert(user).values({ id: 'u1', name: 'u1', email: 'u1@example.com', emailVerified: false, createdAt: new Date(), updatedAt: new Date() })
    const [session] = await db.insert(djSessions).values({ userId: 'u1', title: 's' }).returning()
    const requests: LlmRequest[] = []
    const llm: LlmClient = async (req) => {
      requests.push(req)
      return { text: 'hi.', toolCalls: [], raw: [{ type: 'text', text: 'hi.' }], stopReason: 'end_turn', usage: null }
    }
    await runDjTurn(db, { llm, embed: async () => [], proposeFirst: false }, { id: session.id, userId: 'u1' }, 'hello')

    expect(requests[0].tools).toBe(DJ_TOOLS)
    expect(requests[0].system).toBe(PERSONA_PROMPT)
  })

  it('sends the outside tools and today\'s persona plus the fill line, nothing else', async () => {
    expect(PERSONA_PROMPT_WITH_FILL.replace(`${FILL_PERSONA_LINE}\n`, '')).toBe(PERSONA_PROMPT)

    const db = await createTestDb()
    await db.insert(user).values({ id: 'u1', name: 'u1', email: 'u1@example.com', emailVerified: false, createdAt: new Date(), updatedAt: new Date() })
    const [session] = await db.insert(djSessions).values({ userId: 'u1', title: 's' }).returning()
    const requests: LlmRequest[] = []
    const llm: LlmClient = async (req) => {
      requests.push(req)
      return { text: 'hi.', toolCalls: [], raw: [{ type: 'text', text: 'hi.' }], stopReason: 'end_turn', usage: null }
    }
    const fill = { catalog: {}, defaultStorefront: 'us', enrich: {} } as unknown as FillDeps
    await runDjTurn(db, { llm, embed: async () => [], fill, neverRefuse: true, proposeFirst: false }, { id: session.id, userId: 'u1' }, 'hello')

    expect(requests[0].tools).toBe(DJ_TOOLS_WITH_OUTSIDE)
    expect(requests[0].system).toBe(PERSONA_PROMPT_WITH_FILL)
  })
})
