import { afterEach, describe, expect, it } from 'vitest'
import { sessionTokenStore } from './session-token'

describe('session token store', () => {
  afterEach(() => sessionTokenStore.clear())

  it('keeps the current token in memory', () => {
    sessionTokenStore.write('session-token')
    expect(sessionTokenStore.read()).toBe('session-token')
  })

  it('clears the token without browser storage', () => {
    sessionTokenStore.write('session-token')
    sessionTokenStore.clear()
    expect(sessionTokenStore.read()).toBeNull()
  })
})
