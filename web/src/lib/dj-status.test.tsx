import { act, renderHook } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiError, type PublicConfig } from '../api/client'
import { DJ_RECHECK_OPEN_MS, DJ_RECHECK_PAUSED_MS, useDjStatusSource } from './dj-status'

const config = (djPaused: boolean): PublicConfig => ({ neverRefuse: false, djPaused })
const paused503 = new ApiError(503, { error: 'dj_paused' })

async function flush() {
  await act(async () => { await Promise.resolve() })
}

describe('useDjStatusSource', () => {
  beforeEach(() => { vi.useFakeTimers() })
  afterEach(() => { vi.useRealTimers() })

  it('reads /health on load and pauses when it says so', async () => {
    const getConfig = vi.fn(async () => config(true))
    const { result } = renderHook(() => useDjStatusSource({ getConfig }))
    expect(result.current.paused).toBe(false)
    await flush()
    expect(getConfig).toHaveBeenCalledOnce()
    expect(result.current.paused).toBe(true)
  })

  it('pauses at once on a dj_paused refusal, and only on that', async () => {
    const getConfig = vi.fn(async () => config(false))
    const { result } = renderHook(() => useDjStatusSource({ getConfig }))
    await flush()
    let reported = true
    act(() => { reported = result.current.report(new ApiError(500, { error: 'boom' })) })
    expect(reported).toBe(false)
    expect(result.current.paused).toBe(false)
    act(() => { reported = result.current.report(paused503) })
    expect(reported).toBe(true)
    expect(result.current.paused).toBe(true)
  })

  it('reopens by itself once /health says open again (every minute while paused)', async () => {
    const getConfig = vi.fn(async () => config(false))
    const { result } = renderHook(() => useDjStatusSource({ getConfig }))
    await flush()
    act(() => { result.current.report(paused503) })
    getConfig.mockResolvedValueOnce(config(true))
    await act(async () => { vi.advanceTimersByTime(DJ_RECHECK_PAUSED_MS) })
    await flush()
    expect(result.current.paused).toBe(true)
    await act(async () => { vi.advanceTimersByTime(DJ_RECHECK_PAUSED_MS) })
    await flush()
    expect(result.current.paused).toBe(false)
  })

  it('re-reads every five minutes while open, and on focus or a visible tab', async () => {
    const getConfig = vi.fn(async () => config(false))
    renderHook(() => useDjStatusSource({ getConfig }))
    await flush()
    expect(getConfig).toHaveBeenCalledTimes(1)
    await act(async () => { vi.advanceTimersByTime(DJ_RECHECK_OPEN_MS - 1) })
    expect(getConfig).toHaveBeenCalledTimes(1)
    await act(async () => { vi.advanceTimersByTime(1) })
    expect(getConfig).toHaveBeenCalledTimes(2)
    act(() => { window.dispatchEvent(new Event('focus')) })
    expect(getConfig).toHaveBeenCalledTimes(3)
    act(() => { document.dispatchEvent(new Event('visibilitychange')) })
    expect(getConfig).toHaveBeenCalledTimes(4)
  })

  it('a failed read never pauses and keeps the last known state', async () => {
    const getConfig = vi.fn(async (): Promise<PublicConfig> => { throw new TypeError('offline') })
    const { result } = renderHook(() => useDjStatusSource({ getConfig }))
    await flush()
    expect(result.current.paused).toBe(false)
    act(() => { result.current.report(paused503) })
    await act(async () => { vi.advanceTimersByTime(DJ_RECHECK_PAUSED_MS) })
    await flush()
    expect(result.current.paused).toBe(true)
  })

  it('a read already out when a send is refused cannot reopen it', async () => {
    let answer: (value: PublicConfig) => void = () => undefined
    const getConfig = vi.fn(() => new Promise<PublicConfig>((resolve) => { answer = resolve }))
    const { result } = renderHook(() => useDjStatusSource({ getConfig }))
    act(() => { result.current.report(paused503) })
    await act(async () => answer(config(false)))
    expect(result.current.paused).toBe(true)
  })

  it('lazy: reads nothing on load or focus until something pauses it', async () => {
    const getConfig = vi.fn(async () => config(false))
    const { result } = renderHook(() => useDjStatusSource({ getConfig }, { lazy: true }))
    await flush()
    act(() => { window.dispatchEvent(new Event('focus')) })
    await act(async () => { vi.advanceTimersByTime(DJ_RECHECK_OPEN_MS) })
    expect(getConfig).not.toHaveBeenCalled()
    act(() => { result.current.report(paused503) })
    await act(async () => { vi.advanceTimersByTime(DJ_RECHECK_PAUSED_MS) })
    await flush()
    expect(getConfig).toHaveBeenCalledOnce()
    expect(result.current.paused).toBe(false)
  })
})
