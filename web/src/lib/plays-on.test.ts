import { act, renderHook } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { markSpotifyIntroSeen, readPlaysOn, spotifyIntroSeen, usePlaysOn, writePlaysOn } from './plays-on'

beforeEach(() => localStorage.clear())
afterEach(() => vi.restoreAllMocks())

describe('where mixes play', () => {
  it('is nothing until chosen, then remembers the choice on this device', () => {
    expect(readPlaysOn()).toBeNull()
    writePlaysOn('spotify')
    expect(readPlaysOn()).toBe('spotify')
    writePlaysOn('apple')
    expect(readPlaysOn()).toBe('apple')
  })

  it('ignores a value it did not write', () => {
    localStorage.setItem('mixtape.plays-on', 'tidal')
    expect(readPlaysOn()).toBeNull()
  })

  it('tells every reader when it changes', () => {
    const { result } = renderHook(() => usePlaysOn())
    expect(result.current).toBeNull()
    act(() => writePlaysOn('spotify'))
    expect(result.current).toBe('spotify')
  })

  it('remembers the Spotify explainer as seen', () => {
    expect(spotifyIntroSeen()).toBe(false)
    markSpotifyIntroSeen()
    expect(spotifyIntroSeen()).toBe(true)
  })

  it('survives blocked storage: nothing remembered, nothing thrown', () => {
    vi.spyOn(Storage.prototype, 'getItem').mockImplementation(() => { throw new Error('blocked') })
    vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => { throw new Error('blocked') })
    expect(readPlaysOn()).toBeNull()
    expect(() => writePlaysOn('spotify')).not.toThrow()
    expect(spotifyIntroSeen()).toBe(false)
    expect(() => markSpotifyIntroSeen()).not.toThrow()
  })
})
