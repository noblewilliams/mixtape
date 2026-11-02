// The profile name rule (spec 2026-11-02 profile name), mirrored from
// server/src/auth/profile-name.ts so the fields show what the server will
// store. The server applies it again on every write; keep the two in step.
export const PROFILE_NAME_MAX = 40

// Line and other whitespace controls become spaces; every other control (Cc),
// lone surrogate (Cs) and format character (Cf) is dropped, except ZWNJ and
// ZWJ, which joined emoji and Persian or Indic spelling need.
const WHITESPACE_CONTROLS = /[\t\n\v\f\r\u0085]/g
const DROPPED = /[\p{Cc}\p{Cs}]|(?![‌‍])\p{Cf}/gu

/** The stored shape: cleaned, whitespace collapsed, trimmed, capped in whole characters. */
export function normalizeProfileName(raw: string): string {
  const cleaned = cleanNameInput(raw).replace(/\s+/g, ' ').trim()
  return capWhole(cleaned, PROFILE_NAME_MAX).trim()
}

/** What a field accepts while typing: the character rule only, no trim or collapse, so the caret never jumps. */
export function cleanNameInput(raw: string): string {
  return raw.replace(WHITESPACE_CONTROLS, ' ').replace(DROPPED, '')
}

/** Length as the server counts it: code points. */
export function nameLength(text: string): number {
  return Array.from(text).length
}

// At most max code points, taken in whole user-perceived characters so a
// flag, a joined emoji or a letter and its accent is kept or dropped whole.
const graphemes = new Intl.Segmenter(undefined, { granularity: 'grapheme' })

export function capWhole(text: string, max: number): string {
  let out = ''
  let used = 0
  for (const { segment } of graphemes.segment(text)) {
    const size = nameLength(segment)
    if (used + size > max) break
    out += segment
    used += size
  }
  return out
}

const isHighSurrogate = (unit: number) => unit >= 0xd800 && unit <= 0xdbff
const isLowSurrogate = (unit: number) => unit >= 0xdc00 && unit <= 0xdfff

export type NameEditResult = { value: string; caret: number; cut: boolean }

/**
 * A hard stop at 40 for an edit from `prev` to `next`, where `caret` is the
 * selection end after the edit (the end of the inserted text). Only the
 * inserted text is cleaned and trimmed to fit; the text around it is kept,
 * and an insert with no room is refused with the caret left where it was.
 */
export function applyNameEdit(prev: string, next: string, caret: number | null): NameEditResult {
  let suffix = 0
  if (caret !== null && caret <= next.length && prev.endsWith(next.slice(caret))) {
    suffix = next.length - caret
  } else {
    while (suffix < prev.length && suffix < next.length && prev[prev.length - 1 - suffix] === next[next.length - 1 - suffix]) suffix++
  }
  // The scans compare UTF-16 units: never start the kept suffix on the low
  // half of a pair, or end the kept prefix on the high half.
  if (suffix > 0 && isLowSurrogate(prev.charCodeAt(prev.length - suffix))) suffix--
  const limit = Math.min(prev.length - suffix, next.length - suffix)
  let prefix = 0
  while (prefix < limit && prev[prefix] === next[prefix]) prefix++
  if (prefix > 0 && isHighSurrogate(prev.charCodeAt(prefix - 1))) prefix--

  const before = prev.slice(0, prefix)
  const after = prev.slice(prev.length - suffix)
  const removed = prev.slice(prefix, prev.length - suffix)
  const inserted = cleanNameInput(next.slice(prefix, next.length - suffix))
  const room = Math.max(0, PROFILE_NAME_MAX - nameLength(before) - nameLength(after))
  const kept = capWhole(inserted, room)
  const cut = kept.length < inserted.length
  if (cut && kept === '' && removed === '') return { value: prev, caret: prefix, cut }
  return { value: before + kept + after, caret: prefix + kept.length, cut }
}
