import type { LlmComplete } from './llm'

// Naming call, not curation — deliberately NOT DJ_MODEL (see llm.ts): a
// session title costs fractions of a cent and doesn't need Sonnet's
// judgment, so it's pinned to Haiku instead.
export const TITLE_MODEL = 'claude-haiku-4-5-20251001'

const TITLE_SYSTEM = [
  'You name DJ listening sessions.',
  "Given the listener's opening prompt, respond with ONLY a short, evocative 2-5 word name for the session " +
    '— no quotes, no trailing punctuation, no explanation. Just the name.',
].join(' ')

// Matching open/close quote pairs a model might wrap its answer in —
// straight and curly, single and double.
const QUOTE_PAIRS: Array<[string, string]> = [
  ['"', '"'],
  ["'", "'"],
  ['“', '”'], // “ ”
  ['‘', '’'], // ‘ ’
]

// Strips one layer of surrounding quotes, but ONLY when the trailing quote
// actually matches the leading one — a lone leading quote is a legitimate
// music-title shape (`'Round Midnight`, `'Til I Get It Right`) and must
// survive untouched rather than losing its apostrophe.
function stripMatchingQuotes(s: string): string {
  for (const [open, close] of QUOTE_PAIRS) {
    if (s.length >= 2 && s.startsWith(open) && s.endsWith(close)) return s.slice(1, -1)
  }
  return s
}

// Guardrails on the model's raw output, treated as display text only, never
// trusted structurally: trims, strips one layer of MATCHING surrounding
// quotes (see stripMatchingQuotes) and any control characters/newlines (a
// crafted prompt could otherwise coax a fake multi-line title), collapses
// whitespace, and caps at 60 chars — the same cap routes/sessions.ts's
// titleFromPrompt fallback uses.
function sanitizeTitle(raw: string): string {
  const noQuotes = stripMatchingQuotes(raw.trim())
  const collapsed = noQuotes.replace(/\p{C}+/gu, ' ').trim().replace(/\s+/g, ' ')
  return collapsed.slice(0, 60).trim()
}

// A session title must NEVER fail or delay session creation: any thrown
// error, empty result, or output that sanitizes down to nothing falls back
// to `fallback` (the caller's already-persisted truncated-prompt title).
// Bounded to a 5s worst case via timeoutMs — well under buildAnthropic's
// client-level default — so a stalled title call can't stall a turn that's
// otherwise already finished (see sessions.ts). Never throws.
export async function generateSessionTitle(complete: LlmComplete, prompt: string, fallback: string): Promise<string> {
  try {
    const raw = await complete({ system: TITLE_SYSTEM, prompt, model: TITLE_MODEL, maxTokens: 20, timeoutMs: 5000 })
    const cleaned = sanitizeTitle(raw)
    return cleaned || fallback
  } catch {
    return fallback
  }
}
