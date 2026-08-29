import type { LlmClient, LlmMessage, LlmRequest } from './llm'
import type { PoolTrack } from './pool'
import type { Intent } from './contracts'

export type CuratedTrack = { trackId: string; reason: string }

// A short display string, never a fact about the track — cap it hard so one
// verbose LLM turn can't blow up a queue-list UI.
const MAX_REASON_LENGTH = 140

const BASE_MAX_TOKENS = 1200
const PER_TRACK_TOKENS = 80
const MAX_TOKENS_CAP = 16000

// Thrown when the LLM's curation output is STILL truncated (stopReason
// 'max_tokens') after one retry with doubled maxTokens. This is deliberately
// NOT swallowed into a silent pool-order fallback — a truncated response may
// have picked a biased/partial subset before running out of budget, and
// shipping that quietly would look like a considered curation when it isn't.
// The agent loop (Task 7) catches this and surfaces a DJ apology instead.
export class CurationTruncated extends Error {
  constructor() {
    super('curation: LLM output still truncated (max_tokens) after retrying with doubled maxTokens')
    this.name = 'CurationTruncated'
  }
}

function scaledMaxTokens(targetCount: number): number {
  return Math.min(BASE_MAX_TOKENS + PER_TRACK_TOKENS * targetCount, MAX_TOKENS_CAP)
}

function fmt(v: number | null, digits?: number): string {
  if (v === null) return '-'
  return digits === undefined ? String(v) : v.toFixed(digits)
}

function poolLine(t: PoolTrack): string {
  return [
    t.trackId,
    `${t.title} — ${t.artist}`,
    String(t.playCount),
    fmt(t.tempo === null ? null : Math.round(t.tempo)),
    fmt(t.energy, 2),
    fmt(t.valence, 2),
    fmt(t.releaseYear),
  ].join(' | ')
}

function arcInstruction(arc: Intent['energyArc']): string {
  switch (arc) {
    case 'rise':
      return 'Sequence the picks on a RISING energy arc: start calmer, build energy toward the end.'
    case 'fall':
      return 'Sequence the picks on a FALLING energy arc: start with more energy, wind down toward the end.'
    case 'arc':
      return 'Sequence the picks on an ARC: build energy, peak around the middle, release toward the end.'
    case 'steady':
      return 'Sequence the picks to keep energy roughly STEADY throughout — no big peaks or dips.'
    default:
      return 'Sequence the picks so energy flows naturally from one track to the next.'
  }
}

function buildSystemPrompt(intent: Intent): string {
  return [
    "You are curating a listening queue from a candidate pool pulled from the listener's own library. " +
      'Choose tracks ONLY by their id from the pool below — never invent a track or an id that is not listed.',
    `Pick exactly ${intent.targetCount} tracks, ordered as they should play.`,
    arcInstruction(intent.energyArc),
    'For each pick, write ONE short reason (a brief phrase, not a sentence) for why it fits — this is a ' +
      'display string for the listener, not a factual claim about the track.',
    'Output STRICT JSON ONLY: an array shaped exactly like [{"id":"...","reason":"..."}], one entry per ' +
      'pick, in play order. No markdown, no code fences, no commentary before or after — the array is the ' +
      'entire response.',
  ].join('\n\n')
}

function buildIntentBlock(intent: Intent, sessionContext?: string): string {
  const lines = [`Themes: ${intent.themes}`, `Target count: ${intent.targetCount}`]
  if (intent.energyArc) lines.push(`Energy arc: ${intent.energyArc}`)
  if (intent.tempoMin !== undefined || intent.tempoMax !== undefined) {
    lines.push(`Tempo: ${intent.tempoMin ?? '-'}–${intent.tempoMax ?? '-'} bpm`)
  }
  if (intent.eraFrom !== undefined || intent.eraTo !== undefined) {
    lines.push(`Era: ${intent.eraFrom ?? '-'}–${intent.eraTo ?? '-'}`)
  }
  lines.push(`Familiarity: ${intent.familiarity}`)
  lines.push(`Allow explicit: ${intent.allowExplicit}`)
  if (sessionContext) lines.push(`Session context: ${sessionContext}`)
  return lines.join('\n')
}

function buildRequest(pool: PoolTrack[], intent: Intent, sessionContext: string | undefined, maxTokens: number): LlmRequest {
  const poolBlock = pool.map(poolLine).join('\n')
  const message: LlmMessage = {
    role: 'user',
    content: [
      { type: 'text', text: poolBlock, cache_control: { type: 'ephemeral' } },
      { type: 'text', text: buildIntentBlock(intent, sessionContext) },
    ],
  }
  return {
    system: buildSystemPrompt(intent),
    messages: [message],
    tools: [],
    maxTokens,
    effort: 'medium',
  }
}

// Extracts the first well-formed JSON array from arbitrary LLM text, scanning
// for balanced brackets while respecting string boundaries (so a `]` or `[`
// inside a reason string can't end the scan early). Returns null on anything
// that isn't a clean, complete JSON array — callers treat that as "no picks",
// not as an error.
function extractJsonArray(text: string): unknown[] | null {
  const start = text.indexOf('[')
  if (start === -1) return null
  let depth = 0
  let inString = false
  let escaped = false
  for (let i = start; i < text.length; i++) {
    const ch = text[i]
    if (inString) {
      if (escaped) escaped = false
      else if (ch === '\\') escaped = true
      else if (ch === '"') inString = false
      continue
    }
    if (ch === '"') {
      inString = true
      continue
    }
    if (ch === '[' || ch === '{') depth++
    else if (ch === ']' || ch === '}') {
      depth--
      if (depth === 0) {
        const candidate = text.slice(start, i + 1)
        try {
          const parsed: unknown = JSON.parse(candidate)
          return Array.isArray(parsed) ? parsed : null
        } catch {
          return null
        }
      }
    }
  }
  return null
}

function normalizePicks(raw: unknown[], poolIds: Set<string>): CuratedTrack[] {
  const picks: CuratedTrack[] = []
  const seen = new Set<string>()
  for (const item of raw) {
    if (!item || typeof item !== 'object') continue
    const id = (item as Record<string, unknown>).id
    if (typeof id !== 'string' || !poolIds.has(id) || seen.has(id)) continue
    seen.add(id)
    const reasonRaw = (item as Record<string, unknown>).reason
    const reason = typeof reasonRaw === 'string' ? reasonRaw.slice(0, MAX_REASON_LENGTH) : ''
    picks.push({ trackId: id, reason })
  }
  return picks
}

// Fills out `picks` to `targetCount` using the pool's own score order
// (already sorted DESC by buildPool), skipping tracks already picked. Used
// both for genuine under-return and for the malformed-output fallback (an
// empty `picks` array backfills to a pure pool-order queue).
function backfill(picks: CuratedTrack[], pool: PoolTrack[], targetCount: number): CuratedTrack[] {
  if (picks.length >= targetCount) return picks.slice(0, targetCount)
  const result = picks.slice()
  const already = new Set(result.map((p) => p.trackId))
  for (const t of pool) {
    if (result.length >= targetCount) break
    if (already.has(t.trackId)) continue
    already.add(t.trackId)
    result.push({ trackId: t.trackId, reason: '' })
  }
  return result
}

export async function curate(
  llm: LlmClient,
  pool: PoolTrack[],
  intent: Intent,
  sessionContext?: string,
): Promise<CuratedTrack[]> {
  const poolIds = new Set(pool.map((t) => t.trackId))
  const maxTokens = scaledMaxTokens(intent.targetCount)
  const request = buildRequest(pool, intent, sessionContext, maxTokens)

  let turn = await llm(request)
  if (turn.stopReason === 'max_tokens') {
    // Truncation is a failure, not parse noise: retry once with the budget
    // doubled rather than silently shipping whatever partial picks came
    // through before the model ran out of tokens.
    turn = await llm({ ...request, maxTokens: maxTokens * 2 })
    if (turn.stopReason === 'max_tokens') {
      throw new CurationTruncated()
    }
  }

  const rawPicks = extractJsonArray(turn.text) ?? []
  const picks = normalizePicks(rawPicks, poolIds)
  return backfill(picks, pool, intent.targetCount)
}
