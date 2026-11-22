/**
 * Quoting songs back to the DJ (decision 2026-11-22, same format as iOS).
 *
 * A quote is a song from the tape pinned above the composer ("Terminator ·
 * Asake"), so "this feels out of place" says which song without typing its
 * name. It travels inside the message text as a leading `> Title — Artist`
 * line: the DJ reads it as a quote with no server change, the transcript
 * stores it like any other turn, and the conversation draws it back as a quote
 * rather than as markup.
 */

export type QuotedSong = {
  title: string
  artist: string
  /** The tape row it came from; a quote read back out of a sent message has none. */
  trackId?: string
}

const PREFIX = '> '
const SEPARATOR = ' — '

/** `> Terminator — Asake`. */
export function quoteLine(song: QuotedSong) {
  return `${PREFIX}${song.title}${SEPARATOR}${song.artist}`
}

/** "Terminator · Asake": what the chip and the transcript show. */
export function quoteLabel(song: QuotedSong) {
  return song.artist ? `${song.title} · ${song.artist}` : song.title
}

/** The song a `> Title — Artist` line quotes, or null for any other line. */
export function parseQuoteLine(line: string): QuotedSong | null {
  if (!line.startsWith(PREFIX)) return null
  const body = line.slice(PREFIX.length).trim()
  if (!body) return null
  const split = body.lastIndexOf(SEPARATOR)
  if (split <= 0) return { title: body, artist: '' }
  return { title: body.slice(0, split).trim(), artist: body.slice(split + SEPARATOR.length).trim() }
}

export function sameSong(a: QuotedSong, b: QuotedSong) {
  return a.trackId && b.trackId ? a.trackId === b.trackId : a.title === b.title && a.artist === b.artist
}

/** One quote line per song, then the listener's own words. No quotes leaves the words as they are. */
export function composeQuotedMessage(quotes: QuotedSong[], text: string) {
  const body = text.trim()
  if (quotes.length === 0) return body
  return [...quotes.map(quoteLine), ...(body ? [body] : [])].join('\n')
}

/** The quotes a sent message opens with, and the words after them. */
export function splitQuotedMessage(message: string): { quotes: QuotedSong[]; text: string } {
  const lines = message.split('\n')
  const quotes: QuotedSong[] = []
  let i = 0
  for (; i < lines.length; i++) {
    const quote = parseQuoteLine(lines[i])
    if (!quote) break
    quotes.push(quote)
  }
  if (quotes.length === 0) return { quotes: [], text: message }
  return { quotes, text: lines.slice(i).join('\n').trim() }
}
