import { describe, expect, it } from 'vitest'
import { appReturnUrl } from './app-url'

describe('app return destination', () => {
  it('returns sign-in to the application rather than the marketing page', () => {
    expect(appReturnUrl('https://miixtape.netlify.app', '/app/')).toBe('https://miixtape.netlify.app/app/')
  })
  it('keeps account linking and error query strings on the app', () => {
    expect(appReturnUrl('https://miixtape.netlify.app', '/app/', { account: 'linked', provider: 'google' })).toBe('https://miixtape.netlify.app/app/?account=linked&provider=google')
    expect(appReturnUrl('https://miixtape.netlify.app', '/', { auth_error: 'apple' })).toBe('https://miixtape.netlify.app/?auth_error=apple')
  })
})
