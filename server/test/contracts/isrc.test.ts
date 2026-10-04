import { describe, expect, it } from 'vitest'
import { normalizeIsrc } from '../../src/contracts/isrc'

describe('normalizeIsrc', () => {
  it.each([
    ['USUG11904206', 'USUG11904206'],
    ['usug11904206', 'USUG11904206'],
    ['  usUG11904206\t', 'USUG11904206'],
  ])('keeps %j as %s', (input, expected) => {
    expect(normalizeIsrc(input)).toBe(expected)
  })

  it.each([
    ['a long s that uppercases into ASCII', 'ſSUG11904206'],
    ['a dotless i that uppercases into ASCII', 'USıG11904206'],
    ['full-width letters', 'ＵＳUG11904206'],
    ['too short', 'USUG1190420'],
    ['too long', 'USUG119042060'],
    ['letters in the designation', 'USUG1190420X'],
    ['punctuation', 'US-UG1-19-04206'],
    ['empty', ''],
    ['only spaces', '   '],
    ['an over-long string', 'U'.repeat(100_000)],
    ['null', null],
    ['undefined', undefined],
    ['a number', 123456789012],
    ['an object', { isrc: 'USUG11904206' }],
  ])('drops %s', (_case, input) => {
    expect(normalizeIsrc(input)).toBeNull()
  })
})
