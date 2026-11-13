import { describe, it, expect } from 'vitest'
import { firstName, generateShareToken, isShareToken } from '../../src/shares/store'
import { buildShares } from '../../src/index'

describe('generateShareToken', () => {
  it('makes 22-char base62 tokens that differ', () => {
    const tokens = new Set(Array.from({ length: 200 }, () => generateShareToken()))
    expect(tokens.size).toBe(200)
    for (const t of tokens) expect(t).toMatch(/^[A-Za-z0-9]{22}$/)
  })

  it('rejects bytes at or above 248 so every character is equally likely', () => {
    // First fill: 22 bytes of 255 (all rejected) then 22 of 0 → all "0"-th char.
    let call = 0
    const fill = (buf: Uint8Array) => {
      buf.fill(call++ === 0 ? 255 : 61)
      return buf
    }
    const token = generateShareToken(fill)
    expect(token).toHaveLength(22)
    expect(new Set(token).size).toBe(1)
    expect(call).toBe(2)
  })

  it('isShareToken accepts only the 22-char base62 shape', () => {
    expect(isShareToken('AbCdEfGhIjKlMnOpQrStU9')).toBe(true)
    expect(isShareToken('AbCdEfGhIjKlMnOpQrStU')).toBe(false)
    expect(isShareToken('AbCdEfGhIjKlMnOpQrStU-')).toBe(false)
  })
})

describe('firstName', () => {
  it('takes the first whitespace-delimited word, trimmed', () => {
    expect(firstName('Ada Lovelace')).toBe('Ada')
    expect(firstName('  Grace\tBrewster  Hopper ')).toBe('Grace')
    expect(firstName('Cher')).toBe('Cher')
  })

  it('is null for null, empty or blank names', () => {
    expect(firstName(null)).toBeNull()
    expect(firstName(undefined)).toBeNull()
    expect(firstName('')).toBeNull()
    expect(firstName('   ')).toBeNull()
  })

  it('is null for the anonymous placeholder and capped like the DJ sees it', () => {
    expect(firstName('Listener')).toBeNull()
    expect(firstName(`${'A'.repeat(200)} B`)!.length).toBeLessThan(200)
  })
})

describe('buildShares (env → deps)', () => {
  const limiter = { limit: async () => ({ success: true }) }

  it('wires the base url and the limiter binding', () => {
    const shares = buildShares({ SHARE_BASE_URL: 'https://miixtape.netlify.app/', SHARE_READ_LIMITER: limiter })
    expect(shares.baseUrl).toBe('https://miixtape.netlify.app')
    expect(shares.limiter).toBe(limiter)
  })

  it('fails fast without SHARE_BASE_URL', () => {
    expect(() => buildShares({ SHARE_READ_LIMITER: limiter })).toThrow(/SHARE_BASE_URL/)
    expect(() => buildShares({ SHARE_BASE_URL: 'not a url', SHARE_READ_LIMITER: limiter })).toThrow(/SHARE_BASE_URL/)
  })

  it('fails fast without the rate-limit binding, never running unlimited', () => {
    expect(() => buildShares({ SHARE_BASE_URL: 'https://miixtape.netlify.app' })).toThrow(/SHARE_READ_LIMITER/)
  })
})
