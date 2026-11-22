import { describe, expect, it } from 'vitest'
import { FAILED_LINES, failedCopy, readyCopy } from '../../src/push/copy'

describe('readyCopy', () => {
  it('puts the cleaned mix title under "Your mix is ready"', () => {
    expect(readyCopy('  Late\u0000 night   drive ')).toEqual({ title: 'Your mix is ready', body: 'Late night drive' })
  })

  it('caps the title at 40 characters', () => {
    expect(readyCopy('x'.repeat(80)).body).toBe('x'.repeat(40))
  })

  it('falls back to "Tap to play it." for an empty or missing title', () => {
    expect(readyCopy('').body).toBe('Tap to play it.')
    expect(readyCopy(' \u0007 \n').body).toBe('Tap to play it.')
    expect(readyCopy(null).body).toBe('Tap to play it.')
    expect(readyCopy(undefined).body).toBe('Tap to play it.')
  })
})

describe('failedCopy', () => {
  it('has three lines, each title opening with "Oops"', () => {
    expect(FAILED_LINES).toHaveLength(3)
    for (const line of FAILED_LINES) expect(line.title.startsWith('Oops')).toBe(true)
  })

  it('picks the same line for the same seed', () => {
    const seed = '6f1c1c9e-2b7a-4d38-9a57-4b8f6f0f1e2d'
    expect(failedCopy(seed)).toEqual(failedCopy(seed))
  })

  it('returns one of the spec lines, and seeds spread across all three', () => {
    const seen = new Set<string>()
    for (let i = 0; i < 60; i += 1) {
      const copy = failedCopy(`turn-${i}`)
      expect(FAILED_LINES).toContainEqual(copy)
      seen.add(copy.title)
    }
    expect(seen.size).toBe(3)
  })
})
