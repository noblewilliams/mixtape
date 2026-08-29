import { describe, it, expect } from 'vitest'
import { curate, CurationTruncated } from '../../src/dj/curate'
import { intentSchema, type Intent } from '../../src/dj/contracts'
import type { LlmClient, LlmRequest, LlmTurn } from '../../src/dj/llm'
import type { PoolTrack } from '../../src/dj/pool'

function intent(partial: Partial<Intent> & { themes: string }): Intent {
  return intentSchema.parse(partial)
}

// Pool is already in score-DESC order (as buildPool returns it) — index 0 is
// the highest-scoring candidate, used as the deterministic backfill/fallback
// order throughout these tests.
function makePool(n: number): PoolTrack[] {
  return Array.from({ length: n }, (_, i) => ({
    trackId: `t${i}`,
    appleId: `apple${i}`,
    title: `Title ${i}`,
    artist: `Artist ${i}`,
    playCount: n - i,
    tempo: 120,
    energy: 0.5,
    valence: 0.5,
    releaseYear: 2000,
    durationMs: 200_000,
    score: n - i,
  }))
}

type ScriptedTurn = Partial<LlmTurn>

// A fake LlmClient that plays back a scripted sequence of turns (repeating the
// last one if called more times than scripted) and captures every request it
// was called with, for assertions on prompt shape / maxTokens / effort.
function scriptedLlm(turns: ScriptedTurn[]): { llm: LlmClient; requests: LlmRequest[] } {
  const requests: LlmRequest[] = []
  let call = 0
  const llm: LlmClient = async (req) => {
    requests.push(req)
    const scripted = turns[Math.min(call, turns.length - 1)]
    call += 1
    return {
      text: scripted.text ?? '',
      toolCalls: scripted.toolCalls ?? [],
      raw: scripted.raw ?? [],
      stopReason: scripted.stopReason ?? 'end_turn',
      usage: scripted.usage ?? null,
    }
  }
  return { llm, requests }
}

function textTurn(picks: Array<{ id: string; reason?: string }>, stopReason: string | null = 'end_turn'): ScriptedTurn {
  return { text: JSON.stringify(picks.map((p) => ({ id: p.id, reason: p.reason ?? '' }))), stopReason }
}

describe('curate', () => {
  it('returns an ordered 10-of-40 subset drawn only from the pool', async () => {
    const pool = makePool(40)
    const picks = [pool[3], pool[9], pool[0], pool[20], pool[15], pool[35], pool[1], pool[7], pool[12], pool[22]].map(
      (t) => ({ id: t.trackId, reason: `fits ${t.title}` }),
    )
    const { llm } = scriptedLlm([textTurn(picks)])

    const result = await curate(llm, pool, intent({ themes: 'x', targetCount: 10 }))

    expect(result).toEqual(picks.map((p) => ({ trackId: p.id, reason: p.reason })))
  })

  it('drops invalid ids and backfills from pool score order', async () => {
    const pool = makePool(20)
    const scripted = [
      { id: pool[0].trackId, reason: 'a' },
      { id: 'not-in-pool', reason: 'b' },
      { id: pool[5].trackId, reason: 'c' },
    ]
    const { llm } = scriptedLlm([textTurn(scripted)])

    const result = await curate(llm, pool, intent({ themes: 'x', targetCount: 5 }))

    expect(result).toHaveLength(5)
    expect(result[0]).toEqual({ trackId: pool[0].trackId, reason: 'a' })
    expect(result[1]).toEqual({ trackId: pool[5].trackId, reason: 'c' })
    // backfilled from pool score order, excluding already-picked tracks
    const backfilledIds = result.slice(2).map((r) => r.trackId)
    expect(backfilledIds).toEqual([pool[1].trackId, pool[2].trackId, pool[3].trackId])
  })

  it('backfills to targetCount when the LLM under-returns', async () => {
    const pool = makePool(10)
    const { llm } = scriptedLlm([textTurn([{ id: pool[4].trackId, reason: 'only one' }])])

    const result = await curate(llm, pool, intent({ themes: 'x', targetCount: 6 }))

    expect(result).toHaveLength(6)
    expect(result[0]).toEqual({ trackId: pool[4].trackId, reason: 'only one' })
    expect(result.slice(1).map((r) => r.trackId)).toEqual([
      pool[0].trackId,
      pool[1].trackId,
      pool[2].trackId,
      pool[3].trackId,
      pool[5].trackId,
    ])
  })

  it('truncates when the LLM over-returns', async () => {
    const pool = makePool(10)
    const scripted = pool.map((t) => ({ id: t.trackId, reason: 'x' }))
    const { llm } = scriptedLlm([textTurn(scripted)])

    const result = await curate(llm, pool, intent({ themes: 'x', targetCount: 4 }))

    expect(result).toHaveLength(4)
    expect(result.map((r) => r.trackId)).toEqual(pool.slice(0, 4).map((t) => t.trackId))
  })

  it('defaults an absent reason to empty string', async () => {
    const pool = makePool(3)
    const { llm } = scriptedLlm([{ text: JSON.stringify([{ id: pool[0].trackId }]), stopReason: 'end_turn' }])

    const result = await curate(llm, pool, intent({ themes: 'x', targetCount: 3 }))

    expect(result[0]).toEqual({ trackId: pool[0].trackId, reason: '' })
    // untouched picks (missing reason) and backfilled ones (no reason offered) both default the same way
    expect(result.every((r) => r.reason === '')).toBe(true)
  })

  it('caps an overlong reason to 140 chars', async () => {
    const pool = makePool(3)
    const longReason = 'x'.repeat(300)
    const { llm } = scriptedLlm([textTurn([{ id: pool[0].trackId, reason: longReason }])])

    const result = await curate(llm, pool, intent({ themes: 'x', targetCount: 3 }))

    expect(result[0].reason).toHaveLength(140)
    expect(result[0].reason).toBe(longReason.slice(0, 140))
  })

  it('sends the pool as a cacheable text block and the intent as a separate block', async () => {
    const pool = makePool(5)
    const { llm, requests } = scriptedLlm([textTurn([{ id: pool[0].trackId }])])

    await curate(llm, pool, intent({ themes: 'rainy night drive', targetCount: 3 }))

    expect(requests).toHaveLength(1)
    const [req] = requests
    expect(req.tools).toEqual([])
    const message = req.messages[0]
    if (message.role !== 'user' || typeof message.content === 'string') {
      throw new Error('expected a user message with content blocks')
    }
    const blocks = message.content as Array<{ type: string; text?: string; cache_control?: unknown }>
    expect(blocks).toHaveLength(2)
    expect(blocks[0].cache_control).toEqual({ type: 'ephemeral' })
    expect(blocks[0].text).toContain(pool[0].trackId)
    expect(blocks[1].cache_control).toBeUndefined()
    expect(blocks[1].text).toContain('rainy night drive')
  })

  it('appends sessionContext to the intent block when provided', async () => {
    const pool = makePool(3)
    const { llm, requests } = scriptedLlm([textTurn([{ id: pool[0].trackId }])])

    await curate(llm, pool, intent({ themes: 'x', targetCount: 3 }), 'we were just talking about road trips')

    const message = requests[0].messages[0]
    if (message.role !== 'user' || typeof message.content === 'string') throw new Error('expected content blocks')
    const blocks = message.content as Array<{ type: string; text?: string }>
    expect(blocks[1].text).toContain('we were just talking about road trips')
  })

  it('scales maxTokens with targetCount and sets effort to medium', async () => {
    const pool = makePool(50)
    const { llm, requests } = scriptedLlm([textTurn(pool.slice(0, 20).map((t) => ({ id: t.trackId })))])

    await curate(llm, pool, intent({ themes: 'x', targetCount: 20 }))

    expect(requests[0].effort).toBe('medium')
    expect(requests[0].maxTokens).toBe(1200 + 80 * 20)
  })

  it('caps maxTokens at 16000 even for a large targetCount', async () => {
    // targetCount 200 is beyond intentSchema's max (60) — curate's own scaling
    // formula has no ceiling of its own, so this constructs an Intent value
    // directly (bypassing zod) to exercise the MAX_TOKENS_CAP independently
    // of whatever bound the contract schema happens to enforce today.
    const pool = makePool(60)
    const bigIntent: Intent = { ...intent({ themes: 'x' }), targetCount: 200 }
    const { llm, requests } = scriptedLlm([textTurn(pool.map((t) => ({ id: t.trackId })))])

    await curate(llm, pool, bigIntent)

    expect(requests[0].maxTokens).toBe(16000)
  })

  it('retries once with doubled maxTokens on max_tokens truncation, succeeding on the retry', async () => {
    const pool = makePool(10)
    const picks = [pool[0], pool[1], pool[2]].map((t) => ({ id: t.trackId, reason: 'ok' }))
    const { llm, requests } = scriptedLlm([textTurn(picks, 'max_tokens'), textTurn(picks, 'end_turn')])

    const result = await curate(llm, pool, intent({ themes: 'x', targetCount: 3 }))

    expect(requests).toHaveLength(2)
    expect(requests[1].maxTokens).toBe((requests[0].maxTokens ?? 0) * 2)
    expect(result).toEqual(picks.map((p) => ({ trackId: p.id, reason: p.reason })))
  })

  it('throws CurationTruncated when max_tokens truncation persists through the retry', async () => {
    const pool = makePool(10)
    const picks = [pool[0], pool[1], pool[2]].map((t) => ({ id: t.trackId, reason: 'ok' }))
    const { llm, requests } = scriptedLlm([textTurn(picks, 'max_tokens'), textTurn(picks, 'max_tokens')])

    await expect(curate(llm, pool, intent({ themes: 'x', targetCount: 3 }))).rejects.toThrow(CurationTruncated)
    expect(requests).toHaveLength(2)
  })

  it('falls back to pure pool order, count honored, on malformed non-JSON output (no throw)', async () => {
    const pool = makePool(8)
    const { llm } = scriptedLlm([{ text: 'sorry, I cannot comply with that request today!', stopReason: 'end_turn' }])

    const result = await curate(llm, pool, intent({ themes: 'x', targetCount: 4 }))

    expect(result).toHaveLength(4)
    expect(result.map((r) => r.trackId)).toEqual(pool.slice(0, 4).map((t) => t.trackId))
    expect(result.every((r) => r.reason === '')).toBe(true)

    // deterministic: calling again with the same malformed output gives the same result
    const { llm: llm2 } = scriptedLlm([{ text: 'sorry, I cannot comply with that request today!', stopReason: 'end_turn' }])
    const result2 = await curate(llm2, pool, intent({ themes: 'x', targetCount: 4 }))
    expect(result2).toEqual(result)
  })
})
