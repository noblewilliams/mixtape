import { describe, it, expect } from 'vitest'
import { eq } from 'drizzle-orm'
import { createTestDb } from '../helpers/db'
import { trackFeatures, trackMeanings, tracks } from '../../src/db/schema'
import {
  matchesProposal,
  pickHit,
  MIN_VERIFIED,
  PROPOSE_EXTRA,
  PROPOSE_SYSTEM_PROMPT,
  PROPOSE_SYSTEM_PROMPT_PERSONAL,
  proposalCount,
  proposeSongs,
  titleKey,
  unitEstimate,
  verifyProposals,
  VERIFY_DEADLINE_MS,
  VERIFY_CONCURRENCY,
  VERIFY_MAX,
  type Proposal,
} from '../../src/dj/propose'
import { CurationTruncated, MAX_TOKENS_CAP, REASON_RULE, scaledMaxTokens } from '../../src/dj/curate'
import { FILL_QUEUE_BOOST } from '../../src/dj/catalogue-fill'
import { intentSchema } from '../../src/dj/contracts'
import { AppleCatalogError, type AppleCatalogSearchClient, type CatalogSong } from '../../src/musickit/catalog'
import type { LlmClient, LlmRequest, LlmTurn } from '../../src/dj/llm'

const EM = '—'

function turn(text: string, stopReason = 'end_turn'): LlmTurn {
  return { text, toolCalls: [], raw: [{ type: 'text', text }], stopReason, usage: null }
}

function scripted(...replies: LlmTurn[]): { llm: LlmClient; requests: LlmRequest[] } {
  const requests: LlmRequest[] = []
  let i = 0
  const llm: LlmClient = async (req) => {
    requests.push(req)
    return replies[Math.min(i++, replies.length - 1)]
  }
  return { llm, requests }
}

const intent = (extra: Record<string, unknown> = {}) => intentSchema.parse({ themes: 'sunday morning', targetCount: 5, ...extra })

function userBlock(req: LlmRequest): string {
  return req.messages[0].content as string
}

function song(appleId: string, title: string, artist: string, extra: Partial<CatalogSong> = {}): CatalogSong {
  return { appleId, isrc: null, title, artist, album: 'Album', artwork: null, durationMs: 200_000, genre: 'Pop', releaseYear: 2015, explicit: false, ...extra }
}

function fakeSearch(results: Record<string, CatalogSong[] | Error>, onSearch?: () => void) {
  const terms: string[] = []
  const catalog: AppleCatalogSearchClient = {
    async searchSongs(_sf, term, limit) {
      terms.push(term)
      onSearch?.()
      expect(limit).toBe(5)
      const r = results[term]
      if (r instanceof Error) throw r
      return r ?? []
    },
  }
  return { catalog, terms }
}

const p = (title: string, artist: string, reason = 'warm opener'): Proposal => ({ title, artist, reason })

describe('proposeSongs', () => {
  it('asks for targetCount + PROPOSE_EXTRA songs in one strict-JSON call with the scaled token budget', async () => {
    const { llm, requests } = scripted(turn('[]'))
    await proposeSongs(llm, {
      brief: 'something for a slow sunday',
      intent: intent({ namedSongs: [{ title: 'Essence', artist: 'Wizkid' }] }),
      seeds: ['Asa', 'Bez'],
      storefront: 'ng',
    })
    expect(requests).toHaveLength(1)
    const [req] = requests
    expect(req.system).toBe(PROPOSE_SYSTEM_PROMPT)
    expect(req.tools).toEqual([])
    expect(req.maxTokens).toBe(scaledMaxTokens(5 + PROPOSE_EXTRA))
    const block = userBlock(req)
    expect(block).toContain(`Propose up to ${5 + PROPOSE_EXTRA} songs.`)
    expect(block).toContain('Storefront: ng')
    expect(block).toContain('Request: something for a slow sunday')
    expect(block).toContain('Artists the listener named or loves: Asa, Bez')
    expect(block).toContain('Songs the listener named: Essence by Wizkid')
    expect(block).not.toContain('Already tried')
  })

  it('never asks for more than can be verified', () => {
    expect(proposalCount({ targetCount: 5 })).toBe(13)
    expect(proposalCount({ targetCount: 60 })).toBe(VERIFY_MAX)
  })

  it('the system prompt carries the rules: real songs on Apple Music, play order, mainstream, artist spread, strict JSON', () => {
    expect(PROPOSE_SYSTEM_PROMPT).toMatch(/exist|are on Apple Music/)
    expect(PROPOSE_SYSTEM_PROMPT).toMatch(/order they should play/)
    expect(PROPOSE_SYSTEM_PROMPT).toMatch(/mainstream/i)
    expect(PROPOSE_SYSTEM_PROMPT).toMatch(/Never two songs by the same artist in a row, and at most three/)
    expect(PROPOSE_SYSTEM_PROMPT).toMatch(/STRICT JSON ONLY/)
    expect(PROPOSE_SYSTEM_PROMPT).toMatch(/Never name the track or the artist/)
    expect(PROPOSE_SYSTEM_PROMPT).toContain(REASON_RULE)
    expect(PROPOSE_SYSTEM_PROMPT).toMatch(/em dash/i)
    expect(PROPOSE_SYSTEM_PROMPT).not.toContain(EM)
  })

  // Spec 2026-11-09 every-song-earns-its-place, decisions 1 and 2: a
  // proposal for "no vocals" must be an instrumental, and the count is a
  // ceiling, not a quota.
  it('the system prompt carries the fit rule: only songs that truly fit, fewer rather than one that contradicts', () => {
    expect(PROPOSE_SYSTEM_PROMPT).toMatch(/truly fit/)
    expect(PROPOSE_SYSTEM_PROMPT).toMatch(/no vocals \(instrumentals only\)/)
    expect(PROPOSE_SYSTEM_PROMPT).toMatch(/ceiling/)
    expect(PROPOSE_SYSTEM_PROMPT).not.toMatch(/Propose exactly/)
    expect(PROPOSE_SYSTEM_PROMPT).toMatch(/genre or era named in the request is a hard constraint/)
  })

  it('parses past prose, drops malformed, duplicate and excluded items', async () => {
    const items = [
      { title: 'Essence', artist: 'Wizkid', reason: 'opens soft' },
      { title: 'essence', artist: 'WizKid', reason: 'dupe' },
      { title: 'Ye', artist: 'Burna Boy', reason: 'tried already' },
      { title: '', artist: 'Tems', reason: 'no title' },
      { artist: 'Tems' },
      'junk',
      { title: 'Joro', artist: 'Wizkid', reason: 'a' },
      { title: 'Ojuelegba', artist: 'Wizkid', reason: 'b' },
      { title: 'Free Mind', artist: 'Tems', reason: 'c' },
    ]
    const { llm } = scripted(turn(`sure [1] here you go: ${JSON.stringify(items)} enjoy`))
    const out = await proposeSongs(llm, { brief: '', intent: intent(), seeds: [], storefront: 'ng', exclude: [{ title: 'Ye', artist: 'Burna Boy' }] })
    expect(out.map((s) => s.title)).toEqual(['Essence', 'Joro', 'Ojuelegba', 'Free Mind'])
  })

  // Live 2026-11-10: a proposal noted "Wait, remove if era wrong". The
  // model doubted the song, so it goes, note and all (notes.ts isScratchNote).
  it('drops a proposal whose note is the model talking to itself', async () => {
    const items = [
      { title: 'Essence', artist: 'Wizkid', reason: 'A slow, sunlit groove.' },
      { title: 'Untitled', artist: "D'Angelo", reason: 'Wait, remove if era wrong' },
      { title: 'Joro', artist: 'Wizkid', reason: 'Warm, patient and close.' },
    ]
    const { llm } = scripted(turn(JSON.stringify(items)))
    const out = await proposeSongs(llm, { brief: '', intent: intent(), seeds: [], storefront: 'ng' })
    expect(out.map((s) => s.title)).toEqual(['Essence', 'Joro'])
  })

  // Decision 6 (spec 2026-11-09 every-song-earns-its-place) on the
  // proposal path: album glue never lands unless the listener named it.
  it('drops intros, interludes, skits and outros unless the listener named that song', async () => {
    const items = [
      { title: 'Intro', artist: 'J. Cole', reason: 'a' },
      { title: 'Free Mind (Interlude)', artist: 'Tems', reason: 'b' },
      { title: 'Essence', artist: 'Wizkid', reason: 'c' },
      { title: 'Introduction', artist: 'Someone', reason: 'd' },
      { title: 'Outro', artist: 'Tems', reason: 'e' },
    ]
    const { llm } = scripted(turn(JSON.stringify(items)))
    const out = await proposeSongs(llm, { brief: '', intent: intent({ namedSongs: [{ title: 'Free Mind' }] }), seeds: [], storefront: 'ng' })
    expect(out.map((s) => s.title)).toEqual(['Free Mind (Interlude)', 'Essence', 'Introduction'])
  })

  // A personal listener's shortfall (spec 2026-11-09 every-song-earns-its-
  // place, decision 2): the songs join a library mix, so the prompt must not
  // say they have no music, nor lean mainstream, and it carries their taste.
  it('a personal listener gets the personal intro, their taste and no mainstream lean', async () => {
    const { llm, requests } = scripted(turn('[]'))
    await proposeSongs(llm, { brief: '', intent: intent(), seeds: [], storefront: 'ng', listener: 'personal', topArtists: ['Sade', 'Lauryn Hill'] })
    expect(requests[0].system).toBe(PROPOSE_SYSTEM_PROMPT_PERSONAL)
    expect(PROPOSE_SYSTEM_PROMPT_PERSONAL).not.toContain('no music of their own')
    expect(PROPOSE_SYSTEM_PROMPT_PERSONAL).not.toContain('Lean mainstream')
    expect(PROPOSE_SYSTEM_PROMPT_PERSONAL).toContain(REASON_RULE)
    expect(userBlock(requests[0])).toContain('Artists this listener plays most: Sade, Lauryn Hill')
  })

  it('a listener with no library keeps today\'s prompt', async () => {
    const { llm, requests } = scripted(turn('[]'))
    await proposeSongs(llm, { brief: '', intent: intent(), seeds: [], storefront: 'ng' })
    expect(requests[0].system).toBe(PROPOSE_SYSTEM_PROMPT)
    expect(userBlock(requests[0])).not.toContain('plays most')
  })

  it('lists the excluded songs back to the model', async () => {
    const { llm, requests } = scripted(turn('[]'))
    await proposeSongs(llm, { brief: '', intent: intent(), seeds: [], storefront: 'gb', exclude: [{ title: 'Ye', artist: 'Burna Boy' }], count: 4 })
    const block = userBlock(requests[0])
    expect(block).toContain('Propose up to 4 songs.')
    expect(block).toContain('Already tried, never propose these again:\n- Ye by Burna Boy')
  })

  it('cuts to the count asked for', async () => {
    const items = Array.from({ length: 30 }, (_, i) => ({ title: `Song ${i}`, artist: `Artist ${i}`, reason: 'x' }))
    const { llm } = scripted(turn(JSON.stringify(items)))
    const out = await proposeSongs(llm, { brief: '', intent: intent(), seeds: [], storefront: 'ng' })
    expect(out).toHaveLength(5 + PROPOSE_EXTRA)
  })

  it('sanitises reasons: em dashes out, then 200 characters', async () => {
    const long = 'x'.repeat(300)
    const items = [
      { title: 'A', artist: 'One', reason: `  Slow burn ${EM} then the drop ` },
      { title: 'B', artist: 'Two', reason: long },
      { title: 'C', artist: 'Three', reason: 42 },
    ]
    const { llm } = scripted(turn(JSON.stringify(items)))
    const out = await proposeSongs(llm, { brief: '', intent: intent(), seeds: [], storefront: 'ng' })
    expect(out[0].reason).toBe('Slow burn, then the drop')
    expect(out[1].reason).toHaveLength(200)
    expect(out[2].reason).toBe('')
  })

  it('retries once with the budget doubled on max_tokens', async () => {
    const { llm, requests } = scripted(turn('[{"title":"A"', 'max_tokens'), turn('[{"title":"A","artist":"One","reason":"r"}]'))
    const out = await proposeSongs(llm, { brief: '', intent: intent(), seeds: [], storefront: 'ng' })
    expect(out).toHaveLength(1)
    expect(requests).toHaveLength(2)
    expect(requests[1].maxTokens).toBe(Math.min(scaledMaxTokens(13) * 2, MAX_TOKENS_CAP))
  })

  it('throws CurationTruncated when the retry is cut off too', async () => {
    const { llm, requests } = scripted(turn('[', 'max_tokens'))
    await expect(proposeSongs(llm, { brief: '', intent: intent(), seeds: [], storefront: 'ng' })).rejects.toBeInstanceOf(CurationTruncated)
    expect(requests).toHaveLength(2)
  })

  // Plan 2026-11-16 propose-first, S3: the model's own estimate of how each
  // recording feels, a fallback where no measured features exist.
  it('both prompts are still static constants and ask for energy and valence estimates', () => {
    for (const prompt of [PROPOSE_SYSTEM_PROMPT, PROPOSE_SYSTEM_PROMPT_PERSONAL]) {
      expect(typeof prompt).toBe('string')
      expect(prompt).toMatch(/"energy"/)
      expect(prompt).toMatch(/"valence"/)
      expect(prompt).toMatch(/your best estimate of how the recording feels/)
      expect(prompt).not.toContain(EM)
    }
  })

  it('keeps energy and valence when they are numbers from 0 to 1', async () => {
    const items = [
      { title: 'Essence', artist: 'Wizkid', reason: 'a', energy: 0.42, valence: 0.7 },
      { title: 'Joro', artist: 'Wizkid', reason: 'b', energy: 0, valence: 1 },
    ]
    const { llm } = scripted(turn(JSON.stringify(items)))
    const out = await proposeSongs(llm, { brief: '', intent: intent(), seeds: [], storefront: 'ng' })
    expect(out).toEqual([
      { title: 'Essence', artist: 'Wizkid', reason: 'A', energy: 0.42, valence: 0.7 },
      { title: 'Joro', artist: 'Wizkid', reason: 'B', energy: 0, valence: 1 },
    ])
  })

  it('drops a missing, non-numeric or out-of-range estimate, never the proposal', async () => {
    const raw = '[' + [
      '{"title":"A","artist":"One","reason":"r","energy":"0.5","valence":0.3}',
      '{"title":"B","artist":"Two","reason":"r","energy":1.4,"valence":-0.1}',
      '{"title":"C","artist":"Three","reason":"r","energy":null,"valence":true}',
      '{"title":"D","artist":"Four","reason":"r","valence":0.6}',
    ].join(',') + ']'
    const { llm } = scripted(turn(raw))
    const out = await proposeSongs(llm, { brief: '', intent: intent(), seeds: [], storefront: 'ng' })
    expect(out.map((s) => s.title)).toEqual(['A', 'B', 'C', 'D'])
    expect(out[0].energy).toBeUndefined()
    expect(out[0].valence).toBe(0.3)
    expect(out[1].energy).toBeUndefined()
    expect(out[1].valence).toBeUndefined()
    expect(out[2]).not.toHaveProperty('energy')
    expect(out[2]).not.toHaveProperty('valence')
    expect(out[3].energy).toBeUndefined()
    expect(out[3].valence).toBe(0.6)
  })

  it('unitEstimate: a finite number from 0 to 1, else undefined', () => {
    expect(unitEstimate(0)).toBe(0)
    expect(unitEstimate(0.55)).toBe(0.55)
    expect(unitEstimate(1)).toBe(1)
    for (const bad of [NaN, Infinity, -Infinity, 1.4, -0.1, '0.5', null, undefined, true, {}, []]) {
      expect(unitEstimate(bad)).toBeUndefined()
    }
  })

  it('drops an estimate that overflows to Infinity in the reply', async () => {
    const { llm } = scripted(turn('[{"title":"A","artist":"One","reason":"r","energy":1e999,"valence":0.2}]'))
    const out = await proposeSongs(llm, { brief: '', intent: intent(), seeds: [], storefront: 'ng' })
    expect(out).toEqual([{ title: 'A', artist: 'One', reason: 'R', valence: 0.2 }])
  })

  it('an old-shape reply without estimates still parses', async () => {
    const { llm } = scripted(turn('[{"title":"A","artist":"One","reason":"r"}]'))
    const out = await proposeSongs(llm, { brief: '', intent: intent(), seeds: [], storefront: 'ng' })
    expect(out).toEqual([{ title: 'A', artist: 'One', reason: 'R' }])
    expect(out[0]).not.toHaveProperty('energy')
  })

  it('unparseable output is an empty list', async () => {
    const { llm } = scripted(turn('I would suggest some Wizkid.'))
    expect(await proposeSongs(llm, { brief: '', intent: intent(), seeds: [], storefront: 'ng' })).toEqual([])
  })
})

describe('matchesProposal', () => {
  it.each([
    ['Essence (feat. Tems)', 'Wizkid', 'Essence', 'Wizkid', true],
    ['Essence', 'Wizkid & Tems', 'Essence', 'Tems', true],
    ['Essence', 'WizKid', 'essence', 'wizkid', true],
    ['Essence [Remastered]', 'Wizkid', 'Essence', 'Wizkid feat. Tems', true],
    // A title-only match by another artist is a different song.
    ['Essence', 'Some Cover Band', 'Essence', 'Wizkid', false],
    // Covers, live and remixed versions are other recordings.
    ['Essence - Live', 'Wizkid', 'Essence', 'Wizkid', false],
    ['Essence (Live at the O2)', 'Wizkid', 'Essence', 'Wizkid', false],
    ['Essence (Remix)', 'Wizkid', 'Essence', 'Wizkid', false],
    ['Essence (Karaoke Version)', 'Wizkid', 'Essence', 'Wizkid', false],
    ['Essence (Cover)', 'Wizkid', 'Essence', 'Wizkid', false],
    ['Essence (Remix)', 'Wizkid', 'Essence (Remix)', 'Wizkid', true],
    ['Another Song', 'Wizkid', 'Essence', 'Wizkid', false],
  ] as const)('%s by %s for %s by %s: %s', (hitTitle, hitArtist, title, artist, expected) => {
    expect(matchesProposal({ title: hitTitle, artist: hitArtist }, { title, artist })).toBe(expected)
  })

  it('titleKey strips bracketed and dash-suffixed segments, keeps a bracket-only title', () => {
    expect(titleKey('Essence (feat. Tems) - Single')).toBe('essence')
    expect(titleKey('(Untitled)')).toBe('untitled')
  })
})

describe('pickHit: two passes', () => {
  const hit = (title: string, artist = 'Taylor Swift', explicit = false) => ({ title, artist, explicit })

  it.each([
    ['(Sped Up)', 'Cruel Summer (Sped Up)'],
    ['- Acoustic', 'Cruel Summer - Acoustic'],
    ['(Slowed + Reverb)', 'Cruel Summer (Slowed + Reverb)'],
    ['(Instrumental)', 'Cruel Summer (Instrumental)'],
    ['(Demo)', 'Cruel Summer (Demo)'],
    ['(A Cappella)', 'Cruel Summer (A Cappella)'],
    ['(Club Mix)', 'Cruel Summer (Club Mix)'],
  ])('rejects %s ahead of the plain recording later in the list', (_label, version) => {
    const found = [hit(version), hit('Cruel Summer')]
    expect(pickHit(found, { title: 'Cruel Summer', artist: 'Taylor Swift' })?.title).toBe('Cruel Summer')
    expect(pickHit([hit(version)], { title: 'Cruel Summer', artist: 'Taylor Swift' })).toBeUndefined()
  })

  // Spike 2026-11-16 (docs/testing/2026-11-16-propose-first-spike.md): a
  // plain proposal verified to a dub and an alternate take, and "Valerie" to
  // its "Version Revisited".
  it.each([
    ['Baby Doll (Dub)', 'Baby Doll', 'Soft Cell'],
    ['Love Galore (Alt Version)', 'Love Galore', 'SZA'],
    ['Love Galore (Alternate Version)', 'Love Galore', 'SZA'],
    ['Love Galore (Alternative Version)', 'Love Galore', 'SZA'],
    ['Love Galore (Alternate Take)', 'Love Galore', 'SZA'],
    ['Valerie (Version Revisited)', 'Valerie', 'Mark Ronson'],
    ['Valerie (Revisited)', 'Valerie', 'Mark Ronson'],
    ['Valerie (Reworked)', 'Valerie', 'Mark Ronson'],
  ])('rejects %s for a proposal of the plain song', (version, title, artist) => {
    expect(pickHit([hit(version, artist)], { title, artist })).toBeUndefined()
    expect(pickHit([hit(version, artist), hit(title, artist)], { title, artist })?.title).toBe(title)
  })

  it('a dub or alternate version the proposal names still verifies', () => {
    expect(pickHit([hit('Baby Doll (Dub)', 'Soft Cell')], { title: 'Baby Doll (Dub)', artist: 'Soft Cell' })).toBeDefined()
    expect(pickHit([hit('Love Galore (Alternate Version)', 'SZA')], { title: 'Love Galore (Alt Version)', artist: 'SZA' })).toBeDefined()
  })

  it('a title word that is only part of another word is no version marker', () => {
    expect(pickHit([hit('Dubai Nights', 'Wizkid')], { title: 'Dubai Nights', artist: 'Wizkid' })).toBeDefined()
    expect(pickHit([hit('Alternative Ulster', 'Stiff Little Fingers')], { title: 'Alternative Ulster', artist: 'Stiff Little Fingers' })).toBeDefined()
  })

  it("takes the plain title over \"(Taylor's Version)\" when both are returned", () => {
    const found = [hit("Love Story (Taylor's Version)"), hit('Love Story')]
    expect(pickHit(found, { title: 'Love Story', artist: 'Taylor Swift' })?.title).toBe('Love Story')
  })

  it('accepts the re-recording when it is the only hit and the proposal names it', () => {
    const found = [hit("Love Story (Taylor's Version)")]
    expect(pickHit(found, { title: "Love Story (Taylor's Version)", artist: 'Taylor Swift' })?.title).toBe("Love Story (Taylor's Version)")
  })

  it('a version word the proposal names is not a reason to reject', () => {
    expect(pickHit([hit('Cruel Summer - Acoustic')], { title: 'Cruel Summer (Acoustic)', artist: 'Taylor Swift' })).toBeDefined()
  })

  // House and electronic releases on Apple are titled "(Original Mix)" or
  // "(Extended Mix)": the canonical recording, not another version.
  it.each([
    ['Drive (Original Mix)'],
    ['Drive (Extended Mix)'],
    ['Drive - Original Mix'],
  ])('a plain proposal verifies to %s', (title) => {
    expect(matchesProposal({ title, artist: 'Black Coffee' }, { title: 'Drive', artist: 'Black Coffee' })).toBe(true)
    expect(pickHit([hit(title, 'Black Coffee')], { title: 'Drive', artist: 'Black Coffee' })?.title).toBe(title)
  })

  it.each([
    ['Drive (Club Mix)'],
    ['Drive (Dub Mix)'],
    ['Drive (Remix)'],
    ['Drive (Radio Mix)'],
    ['Drive (Original Club Mix)'],
  ])('a mix that is another version, %s, is still rejected', (title) => {
    expect(matchesProposal({ title, artist: 'Black Coffee' }, { title: 'Drive', artist: 'Black Coffee' })).toBe(false)
    expect(pickHit([hit(title, 'Black Coffee')], { title: 'Drive', artist: 'Black Coffee' })).toBeUndefined()
  })

  it('the exact title wins, then the original mix over the extended one', () => {
    const artist = 'Black Coffee'
    expect(pickHit([hit('Drive (Original Mix)', artist), hit('Drive', artist)], { title: 'Drive', artist })?.title).toBe('Drive')
    expect(pickHit([hit('Drive (Extended Mix)', artist), hit('Drive (Original Mix)', artist)], { title: 'Drive', artist })?.title).toBe('Drive (Original Mix)')
    expect(pickHit([hit('Drive (Original Mix)', artist), hit('Drive (Extended Mix)', artist)], { title: 'Drive (Extended Mix)', artist })?.title).toBe('Drive (Extended Mix)')
  })

  it('explicit off skips an explicit hit for a clean one further down', () => {
    const found = [hit('Cruel Summer', 'Taylor Swift', true), hit('Cruel Summer')]
    expect(pickHit(found, { title: 'Cruel Summer', artist: 'Taylor Swift' }, false)).toBe(found[1])
  })
})

describe('verifyProposals', () => {
  it('keeps confirmed songs in proposal order with their reasons, and drops what Apple cannot confirm', async () => {
    const db = await createTestDb()
    const { catalog, terms } = fakeSearch({
      'Essence Wizkid': [song('a1', 'Essence (feat. Tems)', 'Wizkid')],
      'Made Up Song Wizkid': [],
      'Free Mind Tems': [song('a2', 'Free Mind', 'Tems')],
    })
    const proposals = [p('Essence', 'Wizkid', 'opens soft'), p('Made Up Song', 'Wizkid'), p('Free Mind', 'Tems', 'the lift')]
    const out = await verifyProposals(db, catalog, { proposals, storefront: 'ng', budget: VERIFY_MAX, deadlineMs: VERIFY_DEADLINE_MS })
    expect(terms).toEqual(['Essence Wizkid', 'Made Up Song Wizkid', 'Free Mind Tems'])
    expect(out.searches).toBe(3)
    expect(out.verified.map((v) => [v.title, v.reason])).toEqual([['Essence (feat. Tems)', 'opens soft'], ['Free Mind', 'the lift']])
    expect(out.misses.map((m) => m.title)).toEqual(['Made Up Song'])
  })

  it('carries the model\'s energy and valence onto the verified song as its estimate, omitted when there is none', async () => {
    const db = await createTestDb()
    const { catalog } = fakeSearch({
      'Essence Wizkid': [song('e1', 'Essence', 'Wizkid')],
      'Free Mind Tems': [song('e2', 'Free Mind', 'Tems')],
      'Joro Wizkid': [song('e3', 'Joro', 'Wizkid')],
    })
    const proposals: Proposal[] = [
      { ...p('Essence', 'Wizkid'), energy: 0.4, valence: 0.8 },
      p('Free Mind', 'Tems'),
      { ...p('Joro', 'Wizkid'), valence: 0.5 },
    ]
    const out = await verifyProposals(db, catalog, { proposals, storefront: 'ng', budget: VERIFY_MAX, deadlineMs: VERIFY_DEADLINE_MS })
    expect(out.verified.map((v) => v.title)).toEqual(['Essence', 'Free Mind', 'Joro'])
    expect(out.verified[0].estimate).toEqual({ energy: 0.4, valence: 0.8 })
    expect(out.verified[1]).not.toHaveProperty('estimate')
    expect(out.verified[2].estimate).toEqual({ valence: 0.5 })
    expect(out.verified[2].estimate).not.toHaveProperty('energy')
  })

  it('a hit Apple titles as an interlude is a miss unless the listener named it', async () => {
    const db = await createTestDb()
    const { catalog } = fakeSearch({
      'Free Mind Tems': [song('a1', 'Free Mind (Interlude)', 'Tems')],
      'Essence Wizkid': [song('a2', 'Essence', 'Wizkid')],
    })
    const proposals = [p('Free Mind', 'Tems'), p('Essence', 'Wizkid')]
    const out = await verifyProposals(db, catalog, { proposals, storefront: 'ng', budget: VERIFY_MAX, deadlineMs: VERIFY_DEADLINE_MS })
    expect(out.verified.map((v) => v.title)).toEqual(['Essence'])
    expect(out.misses.map((m) => m.title)).toEqual(['Free Mind'])

    const named = await verifyProposals(db, catalog, { proposals, storefront: 'ng', budget: VERIFY_MAX, deadlineMs: VERIFY_DEADLINE_MS,
      namedSongs: [{ title: 'Free Mind', artist: 'Tems' }] })
    expect(named.verified.map((v) => v.title)).toEqual(['Free Mind (Interlude)', 'Essence'])
  })

  it('rejects a title-only match and a cover, live or explicit version, taking the first hit that matches', async () => {
    const db = await createTestDb()
    const { catalog } = fakeSearch({
      'Essence Wizkid': [song('c1', 'Essence', 'Cover Band'), song('c2', 'Essence - Live', 'Wizkid'), song('c3', 'Essence', 'Wizkid'), song('c4', 'Essence', 'Wizkid')],
      'Ye Burna Boy': [song('c5', 'Ye', 'Burna Boy', { explicit: true })],
    })
    const out = await verifyProposals(db, catalog, {
      proposals: [p('Essence', 'Wizkid'), p('Ye', 'Burna Boy')], storefront: 'ng', budget: VERIFY_MAX, deadlineMs: VERIFY_DEADLINE_MS, allowExplicit: false,
    })
    const [row] = await db.select({ appleId: tracks.appleId }).from(tracks).where(eq(tracks.id, out.verified[0].trackId))
    expect(row.appleId).toBe('c3')
    expect(out.misses.map((m) => m.title)).toEqual(['Ye'])
  })

  it('stops at the budget', async () => {
    const db = await createTestDb()
    const { catalog, terms } = fakeSearch({})
    const out = await verifyProposals(db, catalog, { proposals: [p('A', 'One'), p('B', 'Two'), p('C', 'Three')], storefront: 'ng', budget: 2, deadlineMs: VERIFY_DEADLINE_MS })
    expect(terms).toHaveLength(2)
    expect(out.searches).toBe(2)
  })

  it('stops at the deadline, checked before each batch, on an injected clock', async () => {
    const db = await createTestDb()
    let clock = 0
    const { catalog, terms } = fakeSearch({}, () => { clock += 3_000 })
    const proposals = Array.from({ length: 9 }, (_, i) => p(`S${i}`, 'One'))
    const out = await verifyProposals(db, catalog, { proposals, storefront: 'ng', budget: VERIFY_MAX, deadlineMs: VERIFY_DEADLINE_MS, now: () => clock })
    // The first batch of four starts at 0; by its end the clock reads 12 s.
    expect(terms).toHaveLength(VERIFY_CONCURRENCY)
    expect(out.timedOut).toBe(true)
  })

  // Latency, 2026-11-10: one search at a time spent 12s on a 15-song shortfall.
  it('runs up to VERIFY_CONCURRENCY searches at once, and keeps proposal order', async () => {
    const db = await createTestDb()
    let inFlight = 0
    let most = 0
    const songs = Object.fromEntries(Array.from({ length: 8 }, (_, i) => [`S${i} One`, [song(`k${i}`, `S${i}`, 'One')]]))
    const base = fakeSearch(songs).catalog
    const catalog = { ...base, async searchSongs(sf: string, term: string, limit?: number) {
      inFlight += 1
      most = Math.max(most, inFlight)
      // Later proposals answer first.
      await new Promise((r) => setTimeout(r, 20 - Number(term.slice(1, 2)) * 2))
      inFlight -= 1
      return base.searchSongs(sf, term, limit ?? 5)
    } }
    const proposals = Array.from({ length: 8 }, (_, i) => p(`S${i}`, 'One'))
    const out = await verifyProposals(db, catalog, { proposals, storefront: 'ng', budget: VERIFY_MAX, deadlineMs: VERIFY_DEADLINE_MS })
    expect(most).toBe(VERIFY_CONCURRENCY)
    expect(out.verified.map((v) => v.title)).toEqual(proposals.map((x) => x.title))
  })

  it('stops once `want` songs have verified', async () => {
    const db = await createTestDb()
    const { catalog, terms } = fakeSearch({ 'A One': [song('w1', 'A', 'One')], 'B Two': [song('w2', 'B', 'Two')] })
    const out = await verifyProposals(db, catalog, { proposals: [p('A', 'One'), p('B', 'Two'), p('C', 'Three')], storefront: 'ng', budget: VERIFY_MAX, deadlineMs: VERIFY_DEADLINE_MS, want: 2 })
    expect(terms).toHaveLength(2)
    expect(out.verified).toHaveLength(2)
  })

  it('an Apple 429 stops further searches; another failure is a miss', async () => {
    const db = await createTestDb()
    const { catalog, terms } = fakeSearch({
      'A One': new AppleCatalogError('response', 500),
      'B Two': new AppleCatalogError('rate_limit', 429),
    })
    const proposals = [p('A', 'One'), p('B', 'Two'), p('C', 'Three'), p('D', 'Four'), p('E', 'Five'), p('F', 'Six')]
    const out = await verifyProposals(db, catalog, { proposals, storefront: 'ng', budget: VERIFY_MAX, deadlineMs: VERIFY_DEADLINE_MS })
    // The 429 lands in the first batch; no later batch starts.
    expect(terms).toEqual(['A One', 'B Two', 'C Three', 'D Four'])
    expect(out.misses).toHaveLength(4)
    expect(out.appleError).toBe('rate_limit')
  })

  it('inserts verified songs once, with the fill boost, reuses held rows, and never enriches them', async () => {
    const db = await createTestDb()
    const [held] = await db.insert(tracks).values({ appleId: 'held-1', isrc: 'NGABC000001', title: 'Joro', artist: 'Wizkid', durationMs: 200_000 }).returning()
    const { catalog } = fakeSearch({
      'Essence Wizkid': [song('n1', 'Essence', 'Wizkid', { isrc: 'ngabc000002' })],
      // The same recording proposed under another spelling.
      'essence WIZKID': [song('n1', 'Essence', 'Wizkid', { isrc: 'ngabc000002' })],
      // Held under another Apple id with the same ISRC.
      'Joro Wizkid': [song('other-id', 'Joro', 'Wizkid', { isrc: 'NGABC000001' })],
    })
    const out = await verifyProposals(db, catalog, {
      proposals: [p('Essence', 'Wizkid'), p('essence', 'WIZKID'), p('Joro', 'Wizkid')], storefront: 'ng', budget: VERIFY_MAX, deadlineMs: VERIFY_DEADLINE_MS,
    })
    expect(out.misses).toHaveLength(0)
    expect(out.verified).toHaveLength(2)
    expect(out.verified[1].trackId).toBe(held.id)
    const rows = await db.select().from(tracks)
    expect(rows).toHaveLength(2)
    const fresh = rows.find((r) => r.appleId === 'n1')!
    expect(fresh.id).toBe(out.verified[0].trackId)
    expect(fresh.enrichPriority).toBeGreaterThanOrEqual(FILL_QUEUE_BOOST)
    expect(rows.find((r) => r.id === held.id)!.enrichPriority).toBeGreaterThanOrEqual(FILL_QUEUE_BOOST)
    // The new row waits for a library or a recurrence before its lyrics
    // embedding; the held row keeps the flag it had.
    expect(fresh.meaningDeferred).toBe(true)
    expect(rows.find((r) => r.id === held.id)!.meaningDeferred).toBe(false)
    expect(await db.select().from(trackFeatures)).toHaveLength(0)
    expect(await db.select().from(trackMeanings)).toHaveLength(0)
  })

  it('nothing verified inserts nothing', async () => {
    const db = await createTestDb()
    const { catalog } = fakeSearch({})
    const out = await verifyProposals(db, catalog, { proposals: [p('A', 'One')], storefront: 'ng', budget: VERIFY_MAX, deadlineMs: VERIFY_DEADLINE_MS })
    expect(out.verified).toEqual([])
    expect(await db.select().from(tracks)).toHaveLength(0)
  })

  it('MIN_VERIFIED is below a default mix', () => {
    expect(MIN_VERIFIED).toBe(8)
  })
})
