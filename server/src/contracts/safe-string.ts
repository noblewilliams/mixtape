import { z } from 'zod'

// The one input-side string guard for every user-supplied text field. It
// refuses only what Postgres cannot hold as sent: a NUL byte (rejected by
// text columns) and a lone UTF-16 surrogate (no UTF-8 encoding — the driver
// would store U+FFFD in its place). Everything else is stored as typed and
// sanitized where it is rendered (dj/sanitize.ts), never on the way in.
export function hasValidUnicodeScalars(value: string): boolean {
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index)
    if (code >= 0xd800 && code <= 0xdbff) {
      if (index + 1 >= value.length) return false
      const next = value.charCodeAt(index + 1)
      if (next < 0xdc00 || next > 0xdfff) return false
      index += 1
    } else if (code >= 0xdc00 && code <= 0xdfff) {
      return false
    }
  }
  return true
}

export const safeString = (schema: z.ZodString) => schema.refine(
  (value) => !value.includes('\0') && hasValidUnicodeScalars(value),
)
