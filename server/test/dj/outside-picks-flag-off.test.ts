import { describe, it, expect } from 'vitest'
import { createHash } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { outsidePicksEnabled } from '../../src/index'
import { curate } from '../../src/dj/curate'
import { DJ_TOOLS, intentSchema } from '../../src/dj/contracts'
import { PERSONA_PROMPT } from '../../src/dj/loop'
import type { LlmClient, LlmRequest } from '../../src/dj/llm'
import type { PoolTrack } from '../../src/dj/pool'

// Outside picks ship behind OUTSIDE_PICKS, and "off" must be today's
// behaviour byte for byte: the same tool definitions, the same persona and
// the same curation request. These hashes were taken from the code as it
// stood before outside picks existed (2026-10-03). A change here is a change
// to what the model sees with the flag off, which is never incidental.
const sha = (s: string) => createHash('sha256').update(s).digest('hex')

const PINNED = {
  tools: 'e8e7182e2be15efbe3e740bc6a13d850d183125dac2a226fc08f944460f0f002',
  persona: '6afe70f49f5eb3d743b2dbd80647e6e1067ae1075318c68b6cd5a856b6dd1840',
  curation: '83fc6e4232f504f10c54a95bcf307af6ad52498154ace9edd13602fcf7a4bc7e',
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
    outside: false,
  }) as PoolTrack)
}

describe('flag off is byte-for-byte today', () => {
  it('sends the same tool definitions', () => {
    expect(sha(JSON.stringify(DJ_TOOLS))).toBe(PINNED.tools)
  })

  it('sends the same persona', () => {
    expect(sha(PERSONA_PROMPT)).toBe(PINNED.persona)
  })

  it('sends the same curation request for a pool with no outside rows', async () => {
    const requests: LlmRequest[] = []
    const llm: LlmClient = async (req) => {
      requests.push(req)
      return { text: '[{"id":"t0","reason":"opener"}]', toolCalls: [], raw: [], stopReason: 'end_turn', usage: null }
    }
    const intent = intentSchema.parse({ themes: 'late night drive', tempoMin: 90, tempoMax: 120, energyArc: 'rise', eraFrom: 1990, eraTo: 2010, familiarity: 'mix', targetCount: 5 })
    await curate(llm, personalPool(8), intent, 'Current queue: empty.')
    const { system, messages, tools, maxTokens, effort } = requests[0]
    expect(sha(JSON.stringify({ system, messages, tools, maxTokens, effort }))).toBe(PINNED.curation)
  })
})

describe('OUTSIDE_PICKS', () => {
  it('only the exact string "on" enables it; absent or anything else is off', () => {
    expect(outsidePicksEnabled({ OUTSIDE_PICKS: 'on' })).toBe(true)
    for (const value of [undefined, 'off', 'ON', ' on', 'true', '1', '']) {
      expect(outsidePicksEnabled({ OUTSIDE_PICKS: value })).toBe(false)
    }
  })

  it('ships off in wrangler.jsonc', () => {
    const config = readFileSync(new URL('../../wrangler.jsonc', import.meta.url), 'utf8')
    expect(config).toMatch(/"OUTSIDE_PICKS":\s*"off"/)
  })
})
