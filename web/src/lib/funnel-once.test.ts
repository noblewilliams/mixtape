import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { funnelFlagKey, postFunnelEventOnce } from './funnel-once'

const settled = () => new Promise((resolve) => setTimeout(resolve, 0))

describe('once-per-user funnel events', () => {
  beforeEach(() => localStorage.clear())
  afterEach(() => vi.restoreAllMocks())

  it('posts the event and remembers it for this user once the post has landed', async () => {
    const postFunnelEvent = vi.fn(async () => ({ ok: true as const }))

    expect(postFunnelEventOnce({ postFunnelEvent }, 'user-1', 'first_output')).toBe(true)
    await settled()
    expect(postFunnelEventOnce({ postFunnelEvent }, 'user-1', 'first_output')).toBe(false)

    expect(postFunnelEvent).toHaveBeenCalledTimes(1)
    expect(postFunnelEvent).toHaveBeenCalledWith({ type: 'first_output', surface: 'web' })
    expect(localStorage.getItem(funnelFlagKey('first_output', 'user-1'))).toBeTruthy()
  })

  it('keeps the flag per user and per event type', () => {
    const postFunnelEvent = vi.fn(async () => ({ ok: true as const }))

    postFunnelEventOnce({ postFunnelEvent }, 'user-1', 'first_output')
    postFunnelEventOnce({ postFunnelEvent }, 'user-2', 'first_output')
    postFunnelEventOnce({ postFunnelEvent }, 'user-1', 'first_personal_mix')

    expect(postFunnelEvent).toHaveBeenCalledTimes(3)
  })

  it('leaves no flag behind a failed post, so the next occasion posts again', async () => {
    let offline = true
    const postFunnelEvent = vi.fn(async () => {
      if (offline) throw new Error('offline')
      return { ok: true as const }
    })
    const key = funnelFlagKey('first_personal_mix', 'user-1')

    expect(postFunnelEventOnce({ postFunnelEvent }, 'user-1', 'first_personal_mix')).toBe(true)
    await settled()
    expect(localStorage.getItem(key)).toBeNull()

    offline = false
    expect(postFunnelEventOnce({ postFunnelEvent }, 'user-1', 'first_personal_mix')).toBe(true)
    await settled()
    expect(postFunnelEvent).toHaveBeenCalledTimes(2)
    expect(localStorage.getItem(key)).toBeTruthy()
    expect(postFunnelEventOnce({ postFunnelEvent }, 'user-1', 'first_personal_mix')).toBe(false)
  })

  it('never throws when the post fails or storage is blocked', async () => {
    const postFunnelEvent = vi.fn(async () => {
      throw new Error('offline')
    })
    vi.spyOn(Storage.prototype, 'getItem').mockImplementation(() => {
      throw new Error('blocked')
    })
    vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => {
      throw new Error('blocked')
    })

    expect(postFunnelEventOnce({ postFunnelEvent }, 'user-1', 'first_output')).toBe(true)
    expect(postFunnelEventOnce({ postFunnelEvent }, 'user-1', 'first_output')).toBe(true)
    await Promise.resolve()
    expect(postFunnelEvent).toHaveBeenCalledTimes(2)
  })
})
