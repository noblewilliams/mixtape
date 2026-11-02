import { sanitizeForPrompt } from '../dj/sanitize'

// The name rule (spec 2026-11-02 profile name). One place, applied by the
// Better Auth user hooks on every create and update, so provider names, the
// name page and Account edits all store the same shape.
export const PROFILE_NAME_MAX = 40
// The anonymous plugin's generateName (create-auth.ts). Counts as no name.
export const ANONYMOUS_NAME = 'Listener'
const FIRST_NAME_MAX = 20

// Line and other whitespace controls become spaces (so "Ada\nLovelace" keeps
// its word break), then every remaining control (Cc), lone surrogate (Cs) and
// format character (Cf: zero-width space, bidi embeddings, overrides,
// isolates and marks, BOM) is dropped, except ZWNJ and ZWJ, which joined
// emoji and Persian or Indic spelling need. Whitespace runs collapse to one
// space. The result is trimmed again after the cap in case it lands on a space.
const DROPPED = /[\p{Cc}\p{Cs}]|(?![\u200c\u200d])\p{Cf}/gu

export function normalizeProfileName(raw: string): string {
  const cleaned = raw
    .replace(/[\t\n\v\f\r\u0085]/g, ' ')
    .replace(DROPPED, '')
    .replace(/\s+/g, ' ')
    .trim()
  return capWhole(cleaned, PROFILE_NAME_MAX).trim()
}

// At most max code points (storage stays bounded however many combining
// marks a character carries), taken in whole user-perceived characters so a
// flag, a joined emoji or a letter and its accent is kept whole or dropped
// whole, never cut. Intl.Segmenter is available on Workers.
const graphemes = new Intl.Segmenter(undefined, { granularity: 'grapheme' })

function capWhole(text: string, max: number): string {
  let out = ''
  let used = 0
  for (const { segment } of graphemes.segment(text)) {
    const size = Array.from(segment).length
    if (used + size > max) break
    out += segment
    used += size
  }
  return out
}

export function isUsableName(name: string | null | undefined): boolean {
  if (typeof name !== 'string') return false
  const normalized = normalizeProfileName(name)
  return normalized !== '' && normalized !== ANONYMOUS_NAME
}

// What the DJ may call the listener: the first word of a usable name, through
// the DJ's prompt sanitiser, capped by code point. Null means no line at all.
export function firstName(name: string | null | undefined): string | null {
  if (!isUsableName(name)) return null
  const [word = ''] = normalizeProfileName(name!).split(' ')
  const clipped = capWhole(sanitizeForPrompt(word, Infinity), FIRST_NAME_MAX)
  return clipped === '' ? null : clipped
}
