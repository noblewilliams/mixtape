import { sanitizeForPrompt } from '../dj/sanitize'

// The name rule (spec 2026-11-02 profile name). One place, applied by the
// Better Auth user hooks on every create and update, so provider names, the
// name page and Account edits all store the same shape.
export const PROFILE_NAME_MAX = 40
// The anonymous plugin's generateName (create-auth.ts). Counts as no name.
export const ANONYMOUS_NAME = 'Listener'
const FIRST_NAME_MAX = 20

// Line and other whitespace controls become spaces (so "Ada\nLovelace" keeps
// its word break), then every remaining control (Cc), format (Cf: zero-width,
// bidi overrides, BOM) and lone surrogate (Cs) is dropped. Whitespace runs
// collapse to one space. The cap counts code points, so it never splits a
// surrogate pair, and the result is trimmed again in case it lands on a space.
export function normalizeProfileName(raw: string): string {
  const cleaned = raw
    .replace(/[\t\n\v\f\r\u0085]/g, ' ')
    .replace(/[\p{Cc}\p{Cf}\p{Cs}]/gu, '')
    .replace(/\s+/g, ' ')
    .trim()
  return Array.from(cleaned).slice(0, PROFILE_NAME_MAX).join('').trim()
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
  const clipped = Array.from(sanitizeForPrompt(word, Infinity)).slice(0, FIRST_NAME_MAX).join('')
  return clipped === '' ? null : clipped
}
