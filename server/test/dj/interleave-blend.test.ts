import { describe, it, expect } from 'vitest'
import { interleaveBlend } from '../../src/dj/loop'

describe('interleaveBlend', () => {
  const c = ['c0', 'c1', 'c2', 'c3', 'c4', 'c5']

  it('spreads half proposed evenly, never side by side', () => {
    expect(interleaveBlend(c, ['p0', 'p1', 'p2'], 6)).toEqual(['c0', 'p0', 'c1', 'p1', 'c2', 'p2'])
  })

  it('a short proposal share leaves the rest to the catalogue, in its order', () => {
    expect(interleaveBlend(c, ['p0'], 6)).toEqual(['c0', 'c1', 'c2', 'c3', 'c4', 'p0'])
  })

  it('a short catalogue keeps every song both sides have, never past the total', () => {
    expect(interleaveBlend(['c0', 'c1'], ['p0', 'p1', 'p2'], 6)).toEqual(['c0', 'p0', 'c1', 'p1', 'p2'])
    expect(interleaveBlend(['c0', 'c1'], ['p0', 'p1', 'p2'], 3)).toEqual(['p0', 'p1', 'p2'])
  })

  it('no proposals is the catalogue cut to the total', () => {
    expect(interleaveBlend(c, [], 4)).toEqual(['c0', 'c1', 'c2', 'c3'])
  })
})
