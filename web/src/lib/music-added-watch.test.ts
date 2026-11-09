import { describe, expect, it, vi } from 'vitest'
import { createUploadGate } from '../sync/upload-gate'
import { fakeImportRun, fakeSyncRun, syncResult } from '../test/first-run-fakes'
import { createMusicAddedWatch } from './music-added-watch'

/** The watch, with the App's refresh standing in: each read reports `ready` back through observe. */
function setup() {
  const gate = createUploadGate()
  const syncRun = fakeSyncRun()
  const importRun = fakeImportRun()
  const record = vi.fn()
  const state = { ready: false }
  const pending: Array<() => void> = []
  let held = false
  const refresh = vi.fn(() => {
    const read = () => watch.observe(state.ready)
    if (!held) {
      read()
      return Promise.resolve()
    }
    return new Promise<void>((resolve) => pending.push(() => { read(); resolve() }))
  })
  const watch = createMusicAddedWatch({ gate, syncRun, importRun, refresh, record })
  return {
    gate, syncRun, importRun, record, refresh, watch, state,
    /** Holds every refresh until answer() lets the oldest one land. */
    hold: () => { held = true },
    answer: async () => { pending.shift()?.(); await Promise.resolve() },
  }
}

const settled = () => new Promise((resolve) => setTimeout(resolve, 0))

describe('music added from a mix', () => {
  it('records once for a router-opened run whose music lands', async () => {
    const { watch, record, state } = setup()
    const token = watch.arm(false)
    expect(token).not.toBeNull()
    watch.observe(false)
    expect(record).not.toHaveBeenCalled()

    state.ready = true
    watch.observe(true)
    watch.observe(true)
    watch.settle(token)
    await settled()
    expect(record).toHaveBeenCalledOnce()
  })

  it('reads onboarding again when the flow ends, and records from that read', async () => {
    const { watch, record, refresh, state } = setup()
    const token = watch.arm(false)
    state.ready = true
    watch.settle(token)
    await settled()
    expect(refresh).toHaveBeenCalledOnce()
    expect(record).toHaveBeenCalledOnce()
  })

  it('arms only on a known false: an unread or already-ready listener records nothing', async () => {
    const { watch, record } = setup()
    expect(watch.arm(undefined)).toBeNull()
    watch.observe(true)
    expect(watch.arm(true)).toBeNull()
    watch.observe(true)
    expect(record).not.toHaveBeenCalled()
  })

  it('records nothing for music added from Library', async () => {
    const { watch, record } = setup()
    watch.arm(false)
    // Library's Add your music opens: whatever lands is not from a mix.
    watch.clear()
    watch.observe(true)
    expect(record).not.toHaveBeenCalled()
  })

  it('disarms when the flow ends with nothing running and nothing landed', async () => {
    const { watch, record } = setup()
    const token = watch.arm(false)
    watch.settle(token)
    await settled()
    // Music added later, some other way, is not counted.
    watch.observe(true)
    expect(record).not.toHaveBeenCalled()
  })

  it('keeps watching a sync that outlives the page, and records when it lands', async () => {
    const { watch, record, gate, syncRun, refresh, state } = setup()
    const token = watch.arm(false)
    const release = gate.acquire('apple')!
    syncRun.set({ kind: 'running', progress: null })
    watch.settle(token)
    await settled()
    expect(record).not.toHaveBeenCalled()

    state.ready = true
    syncRun.set(syncResult(40))
    release()
    await settled()
    expect(refresh).toHaveBeenCalledTimes(2)
    expect(record).toHaveBeenCalledOnce()
  })

  it('disarms after a failed sync, without waiting for a publish', async () => {
    const { watch, record, gate, syncRun, refresh } = setup()
    const token = watch.arm(false)
    const release = gate.acquire('apple')!
    syncRun.set({ kind: 'running', progress: null })
    watch.settle(token)
    await settled()

    syncRun.set({ kind: 'error', failure: 'connection' })
    release()
    await settled()
    expect(refresh).toHaveBeenCalledOnce()
    watch.observe(true)
    expect(record).not.toHaveBeenCalled()
  })

  it('disarms after a cancelled sync', async () => {
    const { watch, record, gate, syncRun } = setup()
    const token = watch.arm(false)
    gate.acquire('apple')
    syncRun.set({ kind: 'running', progress: null })
    watch.settle(token)
    syncRun.set({ kind: 'cancelling', progress: null })
    syncRun.set({ kind: 'cancelled' })
    watch.observe(true)
    expect(record).not.toHaveBeenCalled()
  })

  it('follows an upload the same way: a failed one disarms, a finished one records', async () => {
    const failed = setup()
    const first = failed.watch.arm(false)
    failed.gate.acquire('spotify')
    failed.importRun.set({ kind: 'uploading' } as never)
    failed.watch.settle(first)
    failed.importRun.set({ kind: 'upload-failed' } as never)
    failed.watch.observe(true)
    expect(failed.record).not.toHaveBeenCalled()

    const landed = setup()
    const second = landed.watch.arm(false)
    landed.gate.acquire('spotify')
    landed.importRun.set({ kind: 'uploading' } as never)
    landed.watch.settle(second)
    landed.state.ready = true
    landed.importRun.set({ kind: 'done' } as never)
    await settled()
    expect(landed.record).toHaveBeenCalledOnce()
  })

  it('lets a late read from an earlier finish disarm only its own run', async () => {
    const { watch, record, hold, answer, state } = setup()
    hold()
    const earlier = watch.arm(false)
    watch.settle(earlier)
    // The listener opens the door again before the first finish's read lands.
    watch.arm(false)
    await answer()
    await settled()
    state.ready = true
    watch.observe(true)
    expect(record).toHaveBeenCalledOnce()
  })

  it('stops following an earlier run once a new one is armed', async () => {
    const { watch, record, gate, syncRun } = setup()
    const earlier = watch.arm(false)
    gate.acquire('apple')
    syncRun.set({ kind: 'running', progress: null })
    watch.settle(earlier)
    const later = watch.arm(false)
    syncRun.set({ kind: 'error', failure: 'connection' })
    watch.observe(true)
    expect(later).not.toBeNull()
    expect(record).toHaveBeenCalledOnce()
  })
})
