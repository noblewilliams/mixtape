import { describe, expect, it } from 'vitest'
import { sharedMixToken } from './shared-route'

const token = '4fQ9xK2mZr7TbW1nLpY8sA'

describe('sharedMixToken', () => {
  it('reads the token from /m/<token>', () => {
    expect(sharedMixToken({ pathname: `/m/${token}` })).toBe(token)
  })

  it('accepts one trailing slash', () => {
    expect(sharedMixToken({ pathname: `/m/${token}/` })).toBe(token)
  })

  it.each([
    ['the app root', '/app/'],
    ['the landing page', '/'],
    ['a short token', `/m/${token.slice(1)}`],
    ['a long token', `/m/${token}x`],
    ['a token with punctuation', `/m/${token.slice(2)}-_`],
    ['a nested path', `/m/${token}/extra`],
    ['two slashes', `/m/${token}//`],
    ['no token', '/m/'],
    ['a prefixed path', `/app/m/${token}`],
  ])('is null for %s', (_label, pathname) => {
    expect(sharedMixToken({ pathname })).toBeNull()
  })
})
