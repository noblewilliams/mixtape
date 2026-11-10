// Repeated DJ notes (spec 2026-11-09 every-song-earns-its-place, decision 7).
// The curator is told never to repeat a note, but it writes each result
// without seeing every note already in the queue: after "make it more
// chill" four songs in a row read "the comedown after that run". A note the
// listener can already see on another song says nothing, so a repeat is
// written as no note at all. Applied in dj/queue-store.ts, the one place
// every DJ queue write (generate, swap, extend, proposals) passes through.

// Punctuation and symbols by Unicode class, so a trailing full stop, a
// comma or a hyphen never makes two notes look different. Apostrophes go
// without a trace ("it's" is "its"); every other mark becomes a space
// ("slow-burn" is "slow burn").
const APOSTROPHES = /['\u2018\u2019\u02bc]/gu
const PUNCTUATION = /[\p{P}\p{S}]/gu
const WHITESPACE = /\s+/gu

/** A note folded for comparison: case, punctuation and runs of whitespace ignored. '' for no note. */
export function noteKey(note: string | null | undefined): string {
  if (!note) return ''
  return note
    .normalize('NFKC')
    .toLowerCase()
    .replace(APOSTROPHES, '')
    .replace(PUNCTUATION, ' ')
    .replace(WHITESPACE, ' ')
    .trim()
}

/**
 * `rows` in play order with any note that repeats an `existing` one, or an
 * earlier row's, replaced by ''. Empty and null notes are left as they are
 * and never count as a repeat. Pure: returns new rows, input untouched.
 */
export function dropRepeatedNotes<T extends { reason: string | null }>(
  rows: readonly T[],
  existing: Iterable<string | null | undefined> = [],
): T[] {
  const seen = new Set<string>()
  for (const note of existing) {
    const key = noteKey(note)
    if (key !== '') seen.add(key)
  }
  return rows.map((row) => {
    const key = noteKey(row.reason)
    if (key === '') return row
    if (seen.has(key)) return { ...row, reason: '' }
    seen.add(key)
    return row
  })
}

// The model's own working notes, written where a listener's note goes (live,
// 2026-11-10: a proposed D'Angelo song's note read "Wait, remove if era
// wrong"). Such a note is not for the listener, and it says the model
// doubted the song, so the song goes with it (curate.ts normalizePicks,
// propose.ts normalizeProposals): every song earns its place. Narrow on
// purpose: an aside that opens the note, or a phrase no note about a song
// would use.
const SCRATCH_OPENERS = /^(wait|hmm+|actually|oops|todo|tbd|note to self|placeholder|remove|replace|drop this|swap this|not sure|unsure|double[- ]check)\b/iu
const SCRATCH_PHRASES = /\b((remove|replace|drop|swap|cut)( (this|it|the track|the song))? if|not sure (if|it|this|whether)|double[- ]check|(doesn'?t|does not|may not|might not) (really |quite )?fit|placeholder|verify (the|its|era|year|genre))\b/iu

/** True when a note reads as the model's working aside, not a note for the listener. */
export function isScratchNote(note: string | null | undefined): boolean {
  if (!note) return false
  const text = note.normalize('NFKC').trim()
  return SCRATCH_OPENERS.test(text) || SCRATCH_PHRASES.test(text)
}
