import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createDeferredFunnel, funnelFlagKey, hasPostedFunnelEvent, postFunnelEventOnce } from './funnel-once'

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

describe('first-run funnel events before a session exists', () => {
  beforeEach(() => localStorage.clear())

  it('holds events in memory until the session exists, then posts each once in order', async () => {
    const postFunnelEvent = vi.fn(async (_event: { type: string; surface: 'web' }) => ({ ok: true as const }))
    const funnel = createDeferredFunnel({ postFunnelEvent })
    funnel.record('first_run_opened')
    funnel.record('chose_add_music')
    funnel.record('first_run_opened')
    expect(postFunnelEvent).not.toHaveBeenCalled()

    funnel.flush()
    funnel.record('chose_service')
    funnel.record('chose_add_music')
    funnel.flush()
    await settled()

    expect(postFunnelEvent.mock.calls.map(([event]) => event)).toEqual([
      { type: 'first_run_opened', surface: 'web' },
      { type: 'chose_add_music', surface: 'web' },
      { type: 'chose_service', surface: 'web' },
    ])
  })

  it('never posts when the session never comes', async () => {
    const postFunnelEvent = vi.fn(async () => ({ ok: true as const }))
    const funnel = createDeferredFunnel({ postFunnelEvent })
    funnel.record('first_run_opened')
    await settled()
    expect(postFunnelEvent).not.toHaveBeenCalled()
  })

  it('reports whether this user already posted an event', async () => {
    const postFunnelEvent = vi.fn(async () => ({ ok: true as const }))
    expect(hasPostedFunnelEvent('user-1', 'first_mix_made')).toBe(false)
    postFunnelEventOnce({ postFunnelEvent }, 'user-1', 'first_mix_made')
    await settled()
    expect(hasPostedFunnelEvent('user-1', 'first_mix_made')).toBe(true)
    expect(hasPostedFunnelEvent('user-2', 'first_mix_made')).toBe(false)
  })
})
