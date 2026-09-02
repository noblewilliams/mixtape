import { describe, it, expect } from 'vitest'
import { z } from 'zod'
import { hasValidUnicodeScalars, safeString } from '../../src/contracts/safe-string'

describe('hasValidUnicodeScalars', () => {
  it('accepts the empty string, ASCII, BMP text, and well-formed surrogate pairs', () => {
    for (const value of ['', 'Wizkid', 'Tems — Essence', 'Ọmọ', '😀', 'a😀b', '👨‍👩‍👧']) {
      expect(hasValidUnicodeScalars(value), JSON.stringify(value)).toBe(true)
    }
  })

  it('rejects a lone high surrogate, a lone low surrogate, and a high surrogate not followed by a low one', () => {
    for (const value of ['\ud800', 'Wiz\ud800kid', 'a\ud800', '\udc00', 'a\udc00b', '\ud800a', '\ud800\ud800', '\udc00\ud800']) {
      expect(hasValidUnicodeScalars(value), JSON.stringify(value)).toBe(false)
    }
  })
})

describe('safeString', () => {
  const schema = safeString(z.string().trim().min(1).max(10))

  it('keeps the wrapped string rules (trim, min, max)', () => {
    expect(schema.safeParse('  Tems ').data).toBe('Tems')
    expect(schema.safeParse('   ').success).toBe(false)
    expect(schema.safeParse('x'.repeat(11)).success).toBe(false)
  })

  it('rejects a NUL byte and a lone surrogate, accepts a surrogate pair', () => {
    expect(schema.safeParse('Wiz\0kid').success).toBe(false)
    expect(schema.safeParse('Wiz\ud800kid').success).toBe(false)
    expect(schema.safeParse('\udc00').success).toBe(false)
    expect(schema.safeParse('Tems 😀').success).toBe(true)
  })
})
