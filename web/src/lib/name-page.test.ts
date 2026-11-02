import { afterEach, describe, expect, it, vi } from 'vitest'
import { mayAskName, markNamePageSettled } from './name-page'

afterEach(() => {
  localStorage.clear()
  vi.restoreAllMocks()
})

describe('mayAskName (whether to hold the workspace for GET /me)', () => {
  it('holds only a signed-in account whose session name is not usable', () => {
    expect(mayAskName({ id: 'u', name: '' })).toBe(true)
    expect(mayAskName({ id: 'u', name: '  ​ ' })).toBe(true)
    expect(mayAskName({ id: 'u', name: 'Listener' })).toBe(true)
    expect(mayAskName({ id: 'u', name: 'Ada' })).toBe(false)
    expect(mayAskName({ id: 'u', name: '', isAnonymous: true })).toBe(false)
  })

  it('stops holding once this browser saw the page settled for that account', () => {
    markNamePageSettled('u')
    expect(mayAskName({ id: 'u', name: '' })).toBe(false)
    expect(mayAskName({ id: 'v', name: '' })).toBe(true)
  })

  it('holds when storage is blocked, and never throws', () => {
    vi.spyOn(Storage.prototype, 'getItem').mockImplementation(() => { throw new Error('blocked') })
    vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => { throw new Error('blocked') })
    expect(() => markNamePageSettled('u')).not.toThrow()
    expect(mayAskName({ id: 'u', name: '' })).toBe(true)
  })
})
