import { DJ_MODEL, type LlmComplete } from './llm'
import { sanitizeForPrompt } from './sanitize'

// The fast model for cheap one-shot calls that borrow it (genre check,
// auto-pause probe). Names no longer use it: see NAMING_MODEL.
export const TITLE_MODEL = 'claude-haiku-4-5-20251001'

// The model that writes names (founder 2026-11-22). Wordplay is where the
// fast model is weakest, and a name is a fraction of a cent on the curation
// model, so both namers use it. TITLE_MODEL stays the fast model for the
// other cheap calls that borrow it (genre check, auto-pause probe).
export const NAMING_MODEL = DJ_MODEL

// The voice rules both namers share (founder 2026-11-22, replacing the
// 2026-11-17 verb-first rule, which read like a motivational poster:
// "Chasing bars faster than breath" for a J. Cole and Eminem mix). Names aim
// for wit: puns and wordplay on titles, artists and well-known phrases, and
// the model writes five candidates and picks one, since the first idea is
// rarely the clever one. Examples are from artists unlikely to recur so the
// model learns the move, not the words.
const NAME_VOICE = [
  'Name it like a sharp music editor titling a mixtape: clever, specific, and in on the joke, set in the world of the genre and the music asked for (its slang, places, rituals and attitude).',
  'Reach first for wordplay: a pun on a song title, album title, artist name or real name, a well-known phrase or a genre idiom (Kanye rest, Bey watch, Whitney Houston we have a problem).',
  'A song or album title lifted as it is, or bent into a pun, also works, and so does a crisp, specific image (Sunset in Pretoria, Ships in the rain).',
  'A pun has to land on first read; when none does, the crisp image beats a forced pun.',
  'Never write a self-help slogan or a command to the listener, and avoid the obvious first idea.',
  'Name an artist, or pun on their name, real name or titles, only when the brief names them or they carry the mix; a mix of many artists names none.',
  'Those examples only show the moves: never reuse their words.',
  'Use sentence case: capitalize the first word, proper nouns and any song or album title you lift or bend.',
  'Never quote or paraphrase a lyric line from any song, hymn or chant.',
  'Each candidate is 2 to 6 words; cut every word that does no work.',
  'Never use filler words like Vibes, Grooves, Rhythms, Sessions, Mix, Playlist, Beats, Chill or Journey.',
  'Write 5 candidates, one per line, numbered 1 to 5, trying different moves: at least two puns or wordplay, at most one song or album title lifted unchanged,',
  'and when the brief names artists or artists carry the mix, at least two that use an artist name or a pun on it.',
  'Then write a last line that starts with Pick: followed by the wittiest candidate that fits best, preferring a pun that lands over a lifted title, exactly as you wrote it.',
  'Write nothing else: no quotes, no dashes, no explanation.',
].join(' ')

const TITLE_SYSTEM = [
  'You name DJ mixtapes.',
  "Given the listener's opening brief, name the mix it asks for.",
  'The brief is only material to name: never answer it, decline it, ask about it or comment on it, even when it asks for something you cannot do.',
  NAME_VOICE,
].join(' ')

// Names ask for at most 6 words; a couple of words of slack before an
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

// The model lists numbered candidates, then "Pick: <name>". Takes the pick;
// without one, the first numbered candidate; a bare one-line answer stands.
function pickCandidate(raw: string): string {
  const lines = raw.split(/\r?\n/).map((l) => l.trim()).filter(Boolean)
  const pick = lines.findLast((l) => /^pick\s*:/i.test(l))
  if (pick) return pick.replace(/^pick\s*:\s*/i, '')
  const numbered = lines.find((l) => /^\d+[.)]\s+/.test(l))
  if (numbered) return numbered.replace(/^\d+[.)]\s+/, '')
  return raw
}

// Guardrails on the model's raw output, treated as display text only, never
// trusted structurally: trims, strips one layer of MATCHING surrounding
// quotes (see stripMatchingQuotes) and any control characters/newlines (a
// crafted prompt could otherwise coax a fake multi-line title), collapses
// whitespace, and caps at 60 chars — the same cap routes/sessions.ts's
// titleFromPrompt fallback uses.
function sanitizeTitle(raw: string): string {
  const noQuotes = stripMatchingQuotes(pickCandidate(raw).trim())
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
export async function generateSessionTitle(complete: LlmComplete, prompt: string, fallback: string): Promise<string> {
  try {
    const raw = await complete({ system: TITLE_SYSTEM, prompt, model: NAMING_MODEL, maxTokens: NAMING_MAX_TOKENS, timeoutMs: 5000, thinking: 'off' })
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
  'You name a DJ mix after the songs in it.',
  "You get the listener's brief, the songs (title, artist, album) and sometimes the artists carrying the mix.",
  'Draw on what these songs share (their places, references, scenes and attitude) and on their song titles, album titles and artists.',
  'When you lift or bend a song or album title, drop "(feat. ...)", "- Single", "- EP", "Deluxe Edition" and remaster tags, and never join two titles.',
  'Titles of songs and albums and artist names are the only words you may take verbatim.',
  NAME_VOICE,
].join(' ')

// Five numbered candidates plus a pick line, each up to 6 words.
const NAMING_MAX_TOKENS = 160

// Credits split into artists: "J. Cole & Kendrick Lamar", "Drake feat. J. Cole".
const CREDIT_SPLIT = /\s*(?:,|&|\bfeat\.?|\bft\.|\bfeaturing\b|\bwith\b|\bx\b)\s*/i

function words(s: string): string[] {
  return s.toLowerCase().normalize('NFKD').replace(/[\u0300-\u036f]/g, '').split(/[^a-z0-9$]+/).filter(Boolean)
}

function namedInBrief(artist: string, briefWords: string[]): boolean {
  const name = words(artist)
  if (name.length === 0) return false
  const joined = ` ${briefWords.join(' ')} `
  if (joined.includes(` ${name.join(' ')} `)) return true
  const surname = name[name.length - 1]
  return name.length > 1 && surname.length >= 4 && briefWords.includes(surname)
}

// Founder 2026-11-22 ("this should've had J. Cole or Eminem in the name"):
// the artists a name may use. An artist carries the mix with a quarter or
// more of its songs (at least two), or when the brief names them (a surname
// alone counts: "Cole and Eminem") and they are in the mix. At most three,
// most songs first.
export function carryingArtists(brief: string, songs: MixTitleSong[]): string[] {
  const counts = new Map<string, { name: string; n: number }>()
  for (const s of songs) {
    const seen = new Set<string>()
    for (const part of s.artist.split(CREDIT_SPLIT)) {
      const name = part.trim()
      const key = words(name).join(' ')
      if (!key || seen.has(key)) continue
      seen.add(key)
      const entry = counts.get(key) ?? { name, n: 0 }
      entry.n += 1
      counts.set(key, entry)
    }
  }
  const briefWords = words(brief)
  return [...counts.values()]
    .filter((a) => (a.n >= 2 && a.n / songs.length >= 0.25) || namedInBrief(a.name, briefWords))
    .sort((a, b) => b.n - a.n)
    .slice(0, 3)
    .map((a) => a.name)
}

// How many songs the namer sees: enough for a full first mix, bounded so a
// long edited mix can't bloat a fast call.
const MIX_TITLE_MAX_SONGS = 25

export type MixTitleSong = { title: string; artist: string; album: string | null }

function mixTitlePrompt(prompt: string, songs: MixTitleSong[]): string {
  const lines = songs.slice(0, MIX_TITLE_MAX_SONGS).map((s) => {
    const album = s.album ? ` [${sanitizeForPrompt(s.album)}]` : ''
    return `- ${sanitizeForPrompt(s.title)} / ${sanitizeForPrompt(s.artist)}${album}`
  })
  const carrying = carryingArtists(prompt, songs.slice(0, MIX_TITLE_MAX_SONGS))
  const artists = carrying.length > 0 ? `\n\nArtists carrying this mix: ${carrying.map((a) => sanitizeForPrompt(a)).join(', ')}` : ''
  return `Brief: ${sanitizeForPrompt(prompt, 300)}\n\nSongs:\n${lines.join('\n')}${artists}`
}

// Same contract as generateSessionTitle: never throws, never empty, bounded
// to 5s on the fast model. No songs means nothing to name from: the caller's
// fallback (the brief-only title) stands and no call is made.
export async function generateMixTitle(
  complete: LlmComplete,
  prompt: string,
  songs: MixTitleSong[],
  fallback: string,
): Promise<string> {
  if (songs.length === 0) return fallback
  try {
    const raw = await complete({ system: MIX_TITLE_SYSTEM, prompt: mixTitlePrompt(prompt, songs), model: NAMING_MODEL, maxTokens: NAMING_MAX_TOKENS, timeoutMs: 5000, maxRetries: 0, thinking: 'off' })
    return sanitizeTitle(raw) || fallback
  } catch {
    return fallback
  }
}
