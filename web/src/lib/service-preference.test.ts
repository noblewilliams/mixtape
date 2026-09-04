import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { clearServiceChoice, readServiceChoice, writeServiceChoice } from './service-preference'

describe('service preference', () => {
  beforeEach(() => localStorage.clear())
  afterEach(() => vi.restoreAllMocks())

  it('round-trips a choice per user and clears it', () => {
    expect(readServiceChoice('user-1')).toBeNull()

    writeServiceChoice('user-1', 'apple')
    expect(readServiceChoice('user-1')).toBe('apple')
    expect(readServiceChoice('user-2')).toBeNull()
    expect(localStorage.getItem('mixtape:service-choice:user-1')).toBe('apple')

    writeServiceChoice('user-1', 'spotify')
    expect(readServiceChoice('user-1')).toBe('spotify')

    clearServiceChoice('user-1')
    expect(readServiceChoice('user-1')).toBeNull()
    expect(localStorage.getItem('mixtape:service-choice:user-1')).toBeNull()
  })

  it('ignores a value it did not write', () => {
    localStorage.setItem('mixtape:service-choice:user-1', 'tidal')
    expect(readServiceChoice('user-1')).toBeNull()
  })

  it('treats a throwing storage as empty and never throws', () => {
    const blocked = () => {
      throw new Error('blocked')
    }
    vi.spyOn(Storage.prototype, 'getItem').mockImplementation(blocked)
    vi.spyOn(Storage.prototype, 'setItem').mockImplementation(blocked)
    vi.spyOn(Storage.prototype, 'removeItem').mockImplementation(blocked)

    expect(() => writeServiceChoice('user-1', 'apple')).not.toThrow()
    expect(readServiceChoice('user-1')).toBeNull()
    expect(() => clearServiceChoice('user-1')).not.toThrow()
  })
})
