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
  proposalCount,
  proposeSongs,
  titleKey,
  verifyProposals,
  VERIFY_DEADLINE_MS,
  VERIFY_MAX,
  type Proposal,
} from '../../src/dj/propose'
import { CurationTruncated, MAX_TOKENS_CAP, scaledMaxTokens } from '../../src/dj/curate'
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
    expect(block).toContain(`Propose exactly ${5 + PROPOSE_EXTRA} songs.`)
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
    expect(PROPOSE_SYSTEM_PROMPT).toMatch(/em dash/i)
    expect(PROPOSE_SYSTEM_PROMPT).not.toContain(EM)
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

  it('lists the excluded songs back to the model', async () => {
    const { llm, requests } = scripted(turn('[]'))
    await proposeSongs(llm, { brief: '', intent: intent(), seeds: [], storefront: 'gb', exclude: [{ title: 'Ye', artist: 'Burna Boy' }], count: 4 })
    const block = userBlock(requests[0])
    expect(block).toContain('Propose exactly 4 songs.')
    expect(block).toContain('Already tried, never propose these again:\n- Ye by Burna Boy')
  })

  it('cuts to the count asked for', async () => {
    const items = Array.from({ length: 30 }, (_, i) => ({ title: `Song ${i}`, artist: `Artist ${i}`, reason: 'x' }))
    const { llm } = scripted(turn(JSON.stringify(items)))
    const out = await proposeSongs(llm, { brief: '', intent: intent(), seeds: [], storefront: 'ng' })
    expect(out).toHaveLength(5 + PROPOSE_EXTRA)
  })

  it('sanitises reasons: em dashes out, then 140 characters', async () => {
    const long = 'x'.repeat(200)
    const items = [
      { title: 'A', artist: 'One', reason: `  slow burn ${EM} then the drop ` },
      { title: 'B', artist: 'Two', reason: long },
      { title: 'C', artist: 'Three', reason: 42 },
    ]
    const { llm } = scripted(turn(JSON.stringify(items)))
    const out = await proposeSongs(llm, { brief: '', intent: intent(), seeds: [], storefront: 'ng' })
    expect(out[0].reason).toBe('slow burn, then the drop')
    expect(out[1].reason).toHaveLength(140)
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

  it('stops at the deadline, on an injected clock', async () => {
    const db = await createTestDb()
    let clock = 0
    const { catalog, terms } = fakeSearch({}, () => { clock += 4_000 })
    const out = await verifyProposals(db, catalog, {
      proposals: [p('A', 'One'), p('B', 'Two'), p('C', 'Three'), p('D', 'Four')], storefront: 'ng', budget: VERIFY_MAX, deadlineMs: VERIFY_DEADLINE_MS, now: () => clock,
    })
    // 0, 4 s and 8 s start a search; at 12 s the deadline has passed.
    expect(terms).toHaveLength(3)
    expect(out.timedOut).toBe(true)
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
    const out = await verifyProposals(db, catalog, { proposals: [p('A', 'One'), p('B', 'Two'), p('C', 'Three')], storefront: 'ng', budget: VERIFY_MAX, deadlineMs: VERIFY_DEADLINE_MS })
    expect(terms).toEqual(['A One', 'B Two'])
    expect(out.misses).toHaveLength(2)
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
