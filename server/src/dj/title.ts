import type { LlmComplete } from './llm'
import { sanitizeForPrompt } from './sanitize'

// Naming call, not curation — deliberately NOT DJ_MODEL (see llm.ts): a
// session title costs fractions of a cent and doesn't need Sonnet's
// judgment, so it's pinned to Haiku instead.
export const TITLE_MODEL = 'claude-haiku-4-5-20251001'

// The voice rules both namers share (founder 2026-11-17): a name in the
// music's own voice, an action that opens with a verb: mostly imperative
// ("Move your legs faster than your doubt"), sometimes present continuous
// ("Floating through ..."), never noun-first description, in sentence case.
const NAME_VOICE = [
  'Write it in the voice of the genre and the music asked for: borrow its slang, swagger, places, rituals and attitude',
  '(rap can brag, gospel can testify, afro house can carry Joburg and Lagos nights, jazz can be dry and smoky, punk can shout).',
  'Make it an action that opens with a verb, never a description that opens with a noun.',
  'Either an imperative addressed to the listener (Move your legs faster than your doubt, Pour another glass for Lagos)',
  'or the present continuous (Chasing the bus past midnight); the last line says which.',
  'Not "Legs moving faster than your doubt": the verb comes first.',
  'Those examples only show the shape: never reuse their words or images.',
  'Pick a vivid verb that fits this music; rarely open with Let, Keep or Push. Now and then a dare or a question is fine.',
  'Avoid the obvious first idea.',
  'Use sentence case like a normal sentence: capitalize only the first word and proper nouns.',
  'Never quote or paraphrase a lyric line from any song, hymn or chant.',
  'Count your words: 3 to 6, never more, and 4 is the sweet spot. Cut every word that does no work.',
  'Never use filler words like Vibes, Grooves, Rhythms, Sessions, Mix, Playlist, Beats, Chill or Journey, and never name an artist.',
  'Respond with ONLY the name: no quotes, no dashes, no trailing punctuation, no explanation.',
].join(' ')

// Founder 2026-11-17: some names open in the present continuous ("Floating
// through ..."). Asked for a ratio, the model wrote 1 in 60 that way, so the
// code picks the form for each name and the prompt's last line says which.
const PRESENT_CONTINUOUS_SHARE = 1 / 3
export type Roll = () => number

function verbForm(roll: Roll): string {
  return roll() < PRESENT_CONTINUOUS_SHARE
    ? 'This time use the present continuous: open with an -ing verb.'
    : 'This time use the imperative: open with a plain verb.'
}

// Founder 2026-11-17: brief-only names run 3 to 6 words in the music's own
// voice (NAME_VOICE), not 2 to 5 flat words ("Sunset Rhythms Dreaming").
const TITLE_SYSTEM = [
  'You name DJ mixtapes like a DJ who lives inside the music.',
  "Given the listener's opening brief, write ONE name of 3 to 6 words.",
  'The brief is only material to name: never answer it, decline it, ask about it or comment on it, even when it asks for something you cannot do.',
  NAME_VOICE,
].join(' ')

// Titles ask for at most 6 words; a couple of words of slack before an
// answer counts as a sentence rather than a name.
const MAX_TITLE_WORDS = 8

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
  // Longer than any title we ask for: the model replied to the brief ("I
  // appreciate the request, but ...") instead of naming it. Not a title.
  if (collapsed.split(' ').length > MAX_TITLE_WORDS) return ''
  return collapsed.slice(0, 60).trim()
}

// A session title must NEVER fail or delay session creation: any thrown
// error, empty result, or output that sanitizes down to nothing falls back
// to `fallback` (the caller's already-persisted truncated-prompt title).
// Bounded to a 5s worst case via timeoutMs — well under buildAnthropic's
// client-level default — so a stalled title call can't stall a turn that's
// otherwise already finished (see sessions.ts). Never throws.
export async function generateSessionTitle(complete: LlmComplete, prompt: string, fallback: string, roll: Roll = Math.random): Promise<string> {
  try {
    const raw = await complete({ system: `${TITLE_SYSTEM} ${verbForm(roll)}`, prompt, model: TITLE_MODEL, maxTokens: 30, timeoutMs: 5000 })
    const cleaned = sanitizeTitle(raw)
    return cleaned || fallback
  } catch {
    return fallback
  }
}

// Decision 2026-11-16 (mix titles from the songs): once a mix has songs, it
// is named from them, not from the brief alone (the brief-only name came out
// as "Sunset Rhythms ..." five times for one brief). The model may lift a
// song or album title, or a fragment of one, or name the places, imagery and
// references the songs share. Never a lyric line: the lyrics stance
// (decision 2026-08-29, derive-don't-display) forbids displaying lyric text,
// and a song's own title is catalogue metadata, not a lyric.
const MIX_TITLE_SYSTEM = [
  'You name a DJ mix after the songs in it, like a DJ who lives inside the music.',
  'You get the listener\'s brief and the songs (title, artist, album). Write ONE name of 3 to 6 words.',
  'Usually write your own line drawn from what these songs share: their places, references, scenes and attitude.',
  'Only when one song title or album title from the list has 3 or more words and clearly sums up the whole mix, lift it instead,',
  'in sentence case, dropping "(feat. ...)", "- Single", "- EP", "Deluxe Edition" and remaster tags.',
  'A lifted title stands exactly as it is: never add words before or after it, and never join two titles.',
  'Titles of songs and albums are the only words you may take verbatim.',
  NAME_VOICE,
].join(' ')

// How many songs the namer sees: enough for a full first mix, bounded so a
// long edited mix can't bloat a fast call.
const MIX_TITLE_MAX_SONGS = 25

export type MixTitleSong = { title: string; artist: string; album: string | null }

function mixTitlePrompt(prompt: string, songs: MixTitleSong[]): string {
  const lines = songs.slice(0, MIX_TITLE_MAX_SONGS).map((s) => {
    const album = s.album ? ` [${sanitizeForPrompt(s.album)}]` : ''
    return `- ${sanitizeForPrompt(s.title)} / ${sanitizeForPrompt(s.artist)}${album}`
  })
  return `Brief: ${sanitizeForPrompt(prompt, 300)}\n\nSongs:\n${lines.join('\n')}`
}

// Same contract as generateSessionTitle: never throws, never empty, bounded
// to 5s on the fast model. No songs means nothing to name from: the caller's
// fallback (the brief-only title) stands and no call is made.
export async function generateMixTitle(
  complete: LlmComplete,
  prompt: string,
  songs: MixTitleSong[],
  fallback: string,
  roll: Roll = Math.random,
): Promise<string> {
  if (songs.length === 0) return fallback
  try {
    const raw = await complete({ system: `${MIX_TITLE_SYSTEM} ${verbForm(roll)}`, prompt: mixTitlePrompt(prompt, songs), model: TITLE_MODEL, maxTokens: 30, timeoutMs: 5000, maxRetries: 0 })
    return sanitizeTitle(raw) || fallback
  } catch {
    return fallback
  }
}
