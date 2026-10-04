// The clients' ISRC rule, exactly: trim, test the ASCII shape case-insensitively,
// and only then uppercase. Testing after uppercasing would let characters such
// as the long s (U+017F) turn into ASCII letters and pass. Anything else is
// absent, never an error, so one bad cell cannot fail an import or a catalogue
// write. The length guard keeps a huge string away from the regex.
const ISRC_ASCII_PATTERN = /^[A-Za-z]{2}[A-Za-z0-9]{3}[0-9]{7}$/
const MAX_RAW_LENGTH = 64

export function normalizeIsrc(value: unknown): string | null {
  if (typeof value !== 'string' || value.length > MAX_RAW_LENGTH) return null
  const trimmed = value.trim()
  if (trimmed.length !== 12 || !ISRC_ASCII_PATTERN.test(trimmed)) return null
  return trimmed.toUpperCase()
}
