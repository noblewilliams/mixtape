import type { LlmClient, LlmMessage, LlmRequest } from './llm'
import { outsideCap, type PoolTrack } from './pool'
import type { Intent } from './contracts'
import { sanitizeForPrompt, stripEmDashes } from './sanitize'

export type CuratedTrack = { trackId: string; reason: string }

// A short display string, never a fact about the track — cap it hard so one
// verbose LLM turn can't blow up a queue-list UI.
const MAX_REASON_LENGTH = 140

const BASE_MAX_TOKENS = 1200
const PER_TRACK_TOKENS = 80
const MAX_TOKENS_CAP = 16000

// Thrown when the LLM's curation output is STILL truncated (stopReason
// 'max_tokens') after one retry with doubled (capped) maxTokens. This is
// deliberately NOT swallowed into a silent pool-order fallback — a truncated
// response may have picked a biased/partial subset before running out of
// budget, and shipping that quietly would look like a considered curation
// when it isn't. The agent loop (Task 7) catches this and surfaces a DJ
// apology instead.
export class CurationTruncated extends Error {
  constructor() {
    super('curation: LLM output still truncated (max_tokens) after retrying with doubled maxTokens')
    this.name = 'CurationTruncated'
  }
}

// Thrown when NO valid picks could be recovered from the LLM's response at
// all (no parseable JSON array containing a real pool id). This is distinct
// from an under-return, which backfills quietly — zero picks means the
// parse itself failed, and silently handing back a pure-pool-order queue
// would look like a considered curation when nothing was actually curated.
// Message is deliberately content-free (never echoes the LLM's raw text).
export class CurationUnparseable extends Error {
  constructor() {
    super('curation: no valid picks could be parsed from the LLM response')
    this.name = 'CurationUnparseable'
  }
}

function scaledMaxTokens(targetCount: number): number {
  return Math.min(BASE_MAX_TOKENS + PER_TRACK_TOKENS * targetCount, MAX_TOKENS_CAP)
}

function fmt(v: number | null, digits?: number): string {
  if (v === null) return '-'
  return digits === undefined ? String(v) : v.toFixed(digits)
}

// Legend precedes the pool lines themselves — the model has no other way to
// know which raw float is energy vs. valence, or which direction valence
// runs, and the arc instruction (see SYSTEM_PROMPT) depends on it reading
// these correctly.
const POOL_LEGEND =
  'Candidate pool — one track per line, fields separated by |:\n' +
  'id | title — artist | play count | bpm | energy 0-1 | valence 0-1 (bleak→bright) | release year\n' +
  '"-" means unknown. Unknown is not a disqualifier.\n'

// Outside picks (spec 2026-10-03 Part C). Every variant below applies only
// when the pool handed to curate actually holds an outside row, so a pool
// without one (OUTSIDE_PICKS off, a comfort brief, an own-music-only brief)
// sends today's request byte for byte. Each is static so the cached prefix
// stays reusable; the per-request cap lives in the intent block.
export const OUTSIDE_LEGEND_LINE = 'A trailing "| new" field marks a song the listener does not own yet.'
const POOL_LEGEND_WITH_OUTSIDE = `${POOL_LEGEND}${OUTSIDE_LEGEND_LINE}\n`

function poolLine(t: PoolTrack): string {
  // title/artist are user-controlled data synced from the listener's own
  // library (routes/ingest.ts) and get woven straight into the curation
  // prompt — sanitized the same way loop.ts's session context is (control
  // chars/newlines stripped, length capped), so a crafted title can't inject
  // a fake instruction or break the one-track-per-line shape this prompt
  // depends on.
  return [
    t.trackId,
    `${sanitizeForPrompt(t.title)} — ${sanitizeForPrompt(t.artist)}`,
    fmt(t.playCount),
    fmt(t.tempo === null ? null : Math.round(t.tempo)),
    fmt(t.energy, 2),
    fmt(t.valence, 2),
    fmt(t.releaseYear),
    ...(t.outside ? ['new'] : []),
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

// Static across every call — this is the half of the prompt Anthropic's
// prompt cache can actually reuse turn to turn. Anything that varies by
// request (the actual target count, the actual arc, themes, etc.) lives in
// buildIntentBlock instead, which sits AFTER the pool block's cache
// breakpoint in the user turn — see buildRequest.
const SYSTEM_INTRO =
  "You are the DJ's ear. You build the running order for one listening queue, choosing only " +
    "from a pool of tracks pulled from this listener's own library — their music, not " +
    'recommendations. Assume they know these songs.'

// Replaces SYSTEM_INTRO when the pool holds outside rows: "assume they know
// these songs" is scoped to the unmarked rows.
export const OUTSIDE_SYSTEM_INTRO =
  "You are the DJ's ear. You build the running order for one listening queue, choosing only " +
  'from a pool of tracks. Unmarked tracks come from this listener\'s own library; assume they ' +
  'know those. Tracks marked new are songs they do not own yet: use one only where it truly ' +
  'belongs, never more than the intent allows, and never as filler.'

const SYSTEM_RULES = [
  'Selection:\n' +
    '- Choose tracks ONLY by the ids listed in the pool. Never invent a track, an artist, or an id.\n' +
    '- Honour the requested count exactly, and list the picks in the order they should play.\n' +
    '- Sequence is half the job: mind the handoff between consecutive tracks and follow the ' +
    'requested energy arc.\n' +
    '- Spread the artists — at most two tracks by any one artist, unless the request is about ' +
    'that artist.',
  'Reasons: each pick carries one short line shown to the listener under the track title. ' +
    'Write it the way a DJ leans over and says why this one, now: lowercase, two to six words, ' +
    'a fragment, no closing punctuation, no em dashes. Vary what each reason is about across the ' +
    'queue: the sound, the mood a lyric carries, why it follows the track before it, where it ' +
    'sits in the arc. Never repeat a reason. Never name the track or the artist; the listener ' +
    'can already see those. Never restate the request back at them: "matches your vibe", "fits ' +
    'the mood", "great choice" are failures. "slow burn opener", "keeps the pulse up", "the ' +
    'comedown", "lands after that chorus" are the register.',
  'Output STRICT JSON ONLY: one array, [{"id":"<pool id>","reason":"<short reason>"}, ...], in ' +
    'play order. Begin your response with [ and end it with ]. No prose, no markdown, no code ' +
    'fences, nothing before or after the array.',
]

const SYSTEM_PROMPT = [SYSTEM_INTRO, ...SYSTEM_RULES].join('\n\n')
const SYSTEM_PROMPT_WITH_OUTSIDE = [OUTSIDE_SYSTEM_INTRO, ...SYSTEM_RULES].join('\n\n')

// `cap` is null when the pool holds no outside row, and the line is absent.
function buildIntentBlock(intent: Intent, sessionContext: string | undefined, cap: number | null): string {
  const lines = [`Pick exactly ${intent.targetCount} tracks.`]
  if (cap !== null) lines.push(`Pick at most ${cap} ${cap === 1 ? 'song' : 'songs'} marked new.`)
  lines.push(arcInstruction(intent.energyArc), `Themes: ${intent.themes}`)
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

function buildRequest(
  pool: PoolTrack[],
  intent: Intent,
  sessionContext: string | undefined,
  maxTokens: number,
  cap: number | null,
): LlmRequest {
  const poolBlock = (cap === null ? POOL_LEGEND : POOL_LEGEND_WITH_OUTSIDE) + pool.map(poolLine).join('\n')
  const message: LlmMessage = {
    role: 'user',
    content: [
      { type: 'text', text: poolBlock, cache_control: { type: 'ephemeral' } },
      { type: 'text', text: buildIntentBlock(intent, sessionContext, cap) },
    ],
  }
  return {
    system: cap === null ? SYSTEM_PROMPT : SYSTEM_PROMPT_WITH_OUTSIDE,
    messages: [message],
    tools: [],
    maxTokens,
    effort: 'medium',
  }
}

// Scans forward from `start` for the position where bracket depth (counting
// both `[` and `{`) returns to zero, respecting string boundaries so a `]`
// or `[` inside a reason string can't end the scan early. Returns the
// balanced substring, or null if the text never re-balances (unterminated).
function scanBalancedArray(text: string, start: number): string | null {
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
      if (depth === 0) return text.slice(start, i + 1)
    }
  }
  return null
}

function tryParseArray(candidate: string): unknown[] | null {
  try {
    const parsed: unknown = JSON.parse(candidate)
    return Array.isArray(parsed) ? parsed : null
  } catch {
    return null
  }
}

function looksLikePicks(arr: unknown[]): boolean {
  return arr.some((item) => !!item && typeof item === 'object' && typeof (item as Record<string, unknown>).id === 'string')
}

// Extracts the real picks array from arbitrary LLM text. A single first-`[`
// lock-on is wrong: incidental brackets in prose (a footnote like
// "per your request [1], ...") can parse as a valid-but-wrong JSON array and
// get accepted silently. Instead this walks EVERY `[` candidate in order,
// balance-scans each one, and only accepts a candidate that both parses as
// JSON and contains at least one object with a string `id` — the shape a
// real picks array must have. Returns null once candidates are exhausted
// with nothing matching.
function extractJsonArray(text: string): unknown[] | null {
  let searchFrom = 0
  for (;;) {
    const start = text.indexOf('[', searchFrom)
    if (start === -1) return null
    const candidate = scanBalancedArray(text, start)
    if (candidate !== null) {
      const parsed = tryParseArray(candidate)
      if (parsed && looksLikePicks(parsed)) return parsed
    }
    searchFrom = start + 1
  }
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
    // Array.from(...).slice(...).join('') caps by CODE POINT, not UTF-16
    // code unit — a plain .slice could bisect a surrogate pair (emoji, rare
    // scripts) and hand back a malformed half-character to the UI.
    // Em dashes go before the cap, so the cap measures what the listener sees.
    const reason = typeof reasonRaw === 'string'
      ? Array.from(stripEmDashes(reasonRaw.trim())).slice(0, MAX_REASON_LENGTH).join('')
      : ''
    picks.push({ trackId: id, reason })
  }
  return picks
}

// The outside cap, enforced in code rather than trusted to the model: the
// first `cap` outside picks in play order stay, later ones are dropped (the
// backfill below then fills from personal rows only).
function capOutside(picks: CuratedTrack[], outsideIds: Set<string>, cap: number): CuratedTrack[] {
  let kept = 0
  return picks.filter((p) => {
    if (!outsideIds.has(p.trackId)) return true
    kept += 1
    return kept <= cap
  })
}

// Fills out `picks` to `targetCount` using the pool's own score order
// (already sorted DESC by buildPool), skipping tracks already picked. Only
// reached for a genuine partial under-return — zero picks is handled
// upstream as CurationUnparseable, not silently backfilled.
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

export type CurateOptions = {
  // Most outside picks this curation may keep (an edit passes what is left
  // of the queue's cap). Defaults to outsideCap(intent). Read only when the
  // pool holds an outside row.
  outsideCap?: number
}

export async function curate(
  llm: LlmClient,
  pool: PoolTrack[],
  intent: Intent,
  sessionContext?: string,
  options: CurateOptions = {},
): Promise<CuratedTrack[]> {
  const poolIds = new Set(pool.map((t) => t.trackId))
  const outsideIds = new Set(pool.filter((t) => t.outside).map((t) => t.trackId))
  const cap = outsideIds.size > 0 ? Math.max(0, options.outsideCap ?? outsideCap(intent)) : null
  const maxTokens = scaledMaxTokens(intent.targetCount)
  const request = buildRequest(pool, intent, sessionContext, maxTokens, cap)

  let turn = await llm(request)
  if (turn.stopReason === 'max_tokens') {
    // Truncation is a failure, not parse noise: retry once with the budget
    // doubled (capped at MAX_TOKENS_CAP — an uncapped retry at a high
    // targetCount can exceed the client's request timeout, turning a clean
    // CurationTruncated into an opaque LlmError instead) rather than
    // silently shipping whatever partial picks came through before the
    // model ran out of tokens.
    turn = await llm({ ...request, maxTokens: Math.min(maxTokens * 2, MAX_TOKENS_CAP) })
    if (turn.stopReason === 'max_tokens') {
      throw new CurationTruncated()
    }
  }

  const rawPicks = extractJsonArray(turn.text) ?? []
  const picks = normalizePicks(rawPicks, poolIds)
  if (picks.length === 0 && pool.length > 0) {
    throw new CurationUnparseable()
  }
  if (cap === null) return backfill(picks, pool, intent.targetCount)
  return backfill(capOutside(picks, outsideIds, cap), pool.filter((t) => !t.outside), intent.targetCount)
}
