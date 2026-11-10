import type { LlmClient, LlmMessage, LlmRequest } from './llm'
import { outsideCap, type PoolTrack } from './pool'
import type { Intent } from './contracts'
import { sanitizeForPrompt, stripEmDashes } from './sanitize'
import { isScratchNote } from './notes'

export type CuratedTrack = { trackId: string; reason: string }

// A display string, never a fact about the track — cap it hard so one
// verbose LLM turn can't blow up a queue-list UI. 200, not 140, since notes
// became one or two sentences of 12 to 28 words (spec 2026-11-09
// every-song-earns-its-place, decision 7): 28 words run to about 170
// characters, and the cap should cut only a runaway note, never a good one.
export const MAX_REASON_LENGTH = 200

// Sonnet 5 runs adaptive thinking by default and its thinking tokens count
// against max_tokens. A 300-line corpus pool drew 2,400 and then 4,800
// tokens of truncated output on 2026-10-21 (both calls hit the cap), so the
// budget leaves room for the reasoning as well as the JSON. The per-track
// share rose from 200 to 250 when notes grew from a two-to-six-word fragment
// (under 10 tokens) to a sentence or two of up to 200 characters (about 45
// tokens): the extra keeps the thinking room each pick had before. 15 tracks
// get 9,750 and the retry doubles to the cap.
const BASE_MAX_TOKENS = 6000
const PER_TRACK_TOKENS = 250
export const MAX_TOKENS_CAP = 16000

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
// from an under-return, which stands as returned — zero picks means the
// parse itself failed, and silently handing back a pure-pool-order queue
// would look like a considered curation when nothing was actually curated.
// Message is deliberately content-free (never echoes the LLM's raw text).
export class CurationUnparseable extends Error {
  constructor() {
    super('curation: no valid picks could be parsed from the LLM response')
    this.name = 'CurationUnparseable'
  }
}

// The curator's own answer that nothing in the pool fits the brief: a bare
// empty array, which the fit rule (SYSTEM_RULES) makes a legitimate reply
// rather than a parse failure. A subclass, so a caller that has no use for
// the difference (an edit's artist path, the route's error mapping) still
// treats it as CurationUnparseable; generateFromBrief (dj/loop.ts) catches
// it to fill the whole mix from outside the library (spec 2026-11-09
// every-song-earns-its-place, decision 2).
export class CurationNothingFits extends CurationUnparseable {
  constructor() {
    super()
    this.name = 'CurationNothingFits'
  }
}

export function scaledMaxTokens(targetCount: number): number {
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
  'id | title — artist | play count | bpm | energy 0-1 | valence 0-1 (bleak→bright) | release year | genre\n' +
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
    // Catalogue data, but sanitized like the title: it lands in the prompt.
    t.genre ? sanitizeForPrompt(t.genre) : '-',
    ...(t.outside ? ['new'] : []),
  ].join(' | ')
}

export function arcInstruction(arc: Intent['energyArc']): string {
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

// The reason rules, shared with the proposal call (dj/propose.ts) so both
// paths write reasons in one register. Spec 2026-11-09
// every-song-earns-its-place, decision 7, reversing the two-to-six-word
// fragment: that register produced arc narration ("tempo climbs toward the
// peak") and, after an edit, the same line four songs running. A note now
// makes the case for one song. Lyrics are described, never quoted: the
// project never stores or displays lyric text (docs/decisions.md). The
// examples are invented for the register, not drawn from any real song.
export const REASON_RULE =
  'Reasons: each pick carries a note shown to the listener under the track title, making the case for that ' +
    'song at that point in the mix. Write one or two sentences, 12 to 28 words in all, in sentence case, with no ' +
    'em dashes. Say one concrete thing about the song itself (its sound, its production, the feeling or theme of ' +
    "its lyric, the artist's delivery) and why it sits where it does. Never quote a lyric; describe its feeling " +
    'or theme instead. Never name the track or the artist; the listener can already see those. Never restate the ' +
    'request back at them: "matches your vibe", "fits the mood", "great choice" are failures, and so is a bare ' +
    'arc label such as "the peak hits" or "the comedown". Every note is different; never repeat one. The ' +
    'register: "Brushed drums and a muted trumpet keep the room low, so it opens the evening without asking for ' +
    'attention." "Her voice stays close to the mic over a sparse guitar, a warm turn after the busier song ' +
    'before it." "A song about leaving home that never sounds sad, and its bright horns lift the energy into the ' +
    'second half."'

const SYSTEM_RULES = [
  'Selection:\n' +
    '- Choose tracks ONLY by the ids listed in the pool. Never invent a track, an artist, or an id.\n' +
    '- Pick only tracks that truly fit the brief: its genre, its era, its mood, and any hard constraint such as ' +
    'no vocals (instrumentals only) or clean. Never use a track that contradicts the brief to make up the ' +
    'number.\n' +
    '- A genre or era named in the brief is a hard constraint, as binding as no vocals: a track must actually ' +
    'be that genre or from that era. Mood words (soft, rainy, chill, dark) choose which tracks of that genre ' +
    'to pick; they never stand in for the genre. A soft indie song is not soft jazz, and a 70s song is not a ' +
    '90s one.\n' +
    '- When the brief names a genre, each track\'s genre field is the evidence. Pick a track labelled with a ' +
    'different genre only when that song is itself widely known as the named genre; a track with no genre ' +
    '("-") needs the same certainty.\n' +
    '- The requested count is a ceiling, not a quota. Fill it when the pool holds that many tracks that fit; ' +
    'when it does not, return fewer. A shorter queue that fits beats a full one that does not.\n' +
    '- List the picks in the order they should play.\n' +
    '- Sequence is half the job: mind the handoff between consecutive tracks and follow the ' +
    'requested energy arc.\n' +
    '- Spread the artists — at most two tracks by any one artist, unless the request is about ' +
    'that artist.',
  REASON_RULE,
  'Output STRICT JSON ONLY: one array, [{"id":"<pool id>","reason":"<short reason>"}, ...], in ' +
    'play order. Begin your response with [ and end it with ]. No prose, no markdown, no code ' +
    'fences, nothing before or after the array.',
]

const SYSTEM_PROMPT = [SYSTEM_INTRO, ...SYSTEM_RULES].join('\n\n')
const SYSTEM_PROMPT_WITH_OUTSIDE = [OUTSIDE_SYSTEM_INTRO, ...SYSTEM_RULES].join('\n\n')

// Artist-only mixes (spec 2026-11-09 one-platform-play, decision 5): the
// pool holds only that artist's songs (dj/pool.ts onlyArtistKey), so the
// spread rule above is lifted. Said in the intent block, not the system
// prompt, so the cached prefix stays one string for every mix.
export const ONLY_ARTIST_RULE_PREFIX = 'Artist-only mix: every pool track is by'

function onlyArtistLine(name: string): string {
  return `${ONLY_ARTIST_RULE_PREFIX} ${sanitizeForPrompt(name)} or features them, as the listener asked. ` +
    'The spread-the-artists rule does not apply; pick only from the pool.'
}

// Named-artist edits (spec 2026-11-09 every-song-earns-its-place, decision
// 3): "swap in some Kendrick" draws its pool from only the named artists'
// songs, so the spread rule is lifted the same way, in the intent block.
export const NAMED_ARTISTS_RULE_PREFIX = 'Named-artist pick: every pool track is by one of'

function namedArtistsLine(names: string[]): string {
  return `${NAMED_ARTISTS_RULE_PREFIX} ${names.map((n) => sanitizeForPrompt(n)).join(', ')} or features them, as the ` +
    'listener asked. The spread-the-artists rule does not apply; pick only from the pool.'
}

// `cap` is null when the pool holds no outside row, and the line is absent.
function buildIntentBlock(intent: Intent, sessionContext: string | undefined, cap: number | null, scope: ArtistScopeOptions = {}): string {
  // "up to": the count is a ceiling (SYSTEM_RULES), so the intent block
  // must not contradict it with a quota.
  const lines = [`Pick up to ${intent.targetCount} tracks.`]
  if (scope.onlyArtist) lines.push(onlyArtistLine(scope.onlyArtist))
  else if (scope.namedArtists && scope.namedArtists.length > 0) lines.push(namedArtistsLine(scope.namedArtists))
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
  scope: ArtistScopeOptions = {},
): LlmRequest {
  const poolBlock = (cap === null ? POOL_LEGEND : POOL_LEGEND_WITH_OUTSIDE) + pool.map(poolLine).join('\n')
  const message: LlmMessage = {
    role: 'user',
    content: [
      { type: 'text', text: poolBlock, cache_control: { type: 'ephemeral' } },
      { type: 'text', text: buildIntentBlock(intent, sessionContext, cap, scope) },
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
export function extractJsonArrayWhere(text: string, accept: (arr: unknown[]) => boolean): unknown[] | null {
  let searchFrom = 0
  for (;;) {
    const start = text.indexOf('[', searchFrom)
    if (start === -1) return null
    const candidate = scanBalancedArray(text, start)
    if (candidate !== null) {
      const parsed = tryParseArray(candidate)
      if (parsed && accept(parsed)) return parsed
    }
    searchFrom = start + 1
  }
}

function extractJsonArray(text: string): unknown[] | null {
  return extractJsonArrayWhere(text, looksLikePicks)
}

// The candidate at `start` cut back to its last complete top-level object and
// closed with `]`: scanned string-aware as scanBalancedArray does, keeping the
// prefix up to the last `}` that brings depth back to 1. Null when the
// candidate balances (it is not cut off; extractJsonArrayWhere judges those)
// or holds no complete object.
function cutArrayPrefix(text: string, start: number): string | null {
  let depth = 0
  let inString = false
  let escaped = false
  let lastObjectEnd = -1
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
      if (depth === 0) return null
      if (depth === 1 && ch === '}') lastObjectEnd = i
    }
  }
  return lastObjectEnd === -1 ? null : `${text.slice(start, lastObjectEnd + 1)}]`
}

// An end_turn answer can still stop mid-array: on 2026-11-10 a catalogue
// curation spent about 9,000 thinking tokens and its picks ended at "},\n{",
// which extractJsonArray cannot balance, so the whole turn failed. This keeps
// the complete picks before the cut, walking every `[` candidate in order as
// extractJsonArrayWhere does and accepting only a cut-off one that parses and
// looks like picks. Only reached when no balanced picks array exists, so a
// well-formed array, `[]` and prose brackets get exactly their old answers.
// Never used on a max_tokens stop: that path retries, then throws
// CurationTruncated (see curate).
function salvageCutPicks(text: string): unknown[] | null {
  let searchFrom = 0
  for (;;) {
    const start = text.indexOf('[', searchFrom)
    if (start === -1) return null
    const candidate = cutArrayPrefix(text, start)
    if (candidate !== null) {
      const parsed = tryParseArray(candidate)
      if (parsed && looksLikePicks(parsed)) return parsed
    }
    searchFrom = start + 1
  }
}

// A reason as the listener sees it: trimmed, em dashes out, then capped at
// MAX_REASON_LENGTH. Array.from(...).slice(...).join('') caps by CODE POINT,
// not UTF-16 code unit: a plain .slice could bisect a surrogate pair (emoji,
// rare scripts) and hand back a malformed half-character to the UI. Em
// dashes go before the cap, so the cap measures what the listener sees.
export function sanitizeReason(raw: unknown): string {
  if (typeof raw !== 'string') return ''
  const chars = Array.from(stripEmDashes(raw.trim())).slice(0, MAX_REASON_LENGTH)
  // Sentence case (REASON_RULE): the model sometimes starts a note lowercase,
  // proposals especially, and the listener reads it as a sentence.
  if (chars.length > 0) chars[0] = chars[0].toLocaleUpperCase()
  return chars.join('')
}

function normalizePicks(raw: unknown[], poolIds: Set<string>): CuratedTrack[] {
  const picks: CuratedTrack[] = []
  const seen = new Set<string>()
  for (const item of raw) {
    if (!item || typeof item !== 'object') continue
    const id = (item as Record<string, unknown>).id
    if (typeof id !== 'string' || !poolIds.has(id) || seen.has(id)) continue
    seen.add(id)
    const reason = sanitizeReason((item as Record<string, unknown>).reason)
    // The model's own aside in place of a note: it doubted the pick.
    if (isScratchNote(reason)) continue
    picks.push({ trackId: id, reason })
  }
  return picks
}

// The outside cap, enforced in code rather than trusted to the model: the
// first `cap` outside picks in play order stay, later ones are dropped and
// nothing takes their place.
function capOutside(picks: CuratedTrack[], outsideIds: Set<string>, cap: number): CuratedTrack[] {
  let kept = 0
  return picks.filter((p) => {
    if (!outsideIds.has(p.trackId)) return true
    kept += 1
    return kept <= cap
  })
}


type ArtistScopeOptions = { onlyArtist?: string; namedArtists?: string[] }

export type CurateOptions = {
  // Most outside picks this curation may keep (an edit passes what is left
  // of the queue's cap). Defaults to outsideCap(intent). Read only when the
  // pool holds an outside row.
  outsideCap?: number
  // The artist an artist-only pool is made of; lifts the spread rule.
  onlyArtist?: string
  // The artists a named-artist edit's pool is made of; lifts the spread
  // rule too. Ignored when onlyArtist is set.
  namedArtists?: string[]
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
  const request = buildRequest(pool, intent, sessionContext, maxTokens, cap, options)

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

  const rawPicks = extractJsonArray(turn.text) ?? (turn.stopReason === 'max_tokens' ? null : salvageCutPicks(turn.text))
  const picks = normalizePicks(rawPicks ?? [], poolIds)
  if (picks.length === 0 && pool.length > 0) {
    // No picks array at all, but an empty one: the model said nothing fits.
    if (rawPicks === null && extractJsonArrayWhere(turn.text, (arr) => arr.length === 0) !== null) {
      throw new CurationNothingFits()
    }
    throw new CurationUnparseable()
  }
  // Cut to the count, never padded up to it. The count is a ceiling (spec
  // 2026-11-09 every-song-earns-its-place, decision 1): fewer picks than
  // asked means the curator found only that many that fit, and topping the
  // list up from pool score order (as this once did) put back exactly the
  // off-brief library tracks the rule leaves out. A shortfall is the
  // caller's to fill or explain (dj/loop.ts).
  const kept = cap === null ? picks : capOutside(picks, outsideIds, cap)
  return kept.slice(0, intent.targetCount)
}
