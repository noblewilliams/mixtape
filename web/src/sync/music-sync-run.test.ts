import { describe, expect, it, vi } from 'vitest'
import { createMusicSyncRun } from './music-sync-run'
import { createUploadGate } from './upload-gate'
import type { MusicSyncOptions, MusicSyncResult } from './music-sync-service'

const complete: MusicSyncResult = {
  kind: 'complete',
  songs: 2,
  catalogResolved: 2,
  playCountsObserved: 0,
  recentTracks: 0,
  playlists: 1,
  entries: 2,
  resolvedEntries: 2,
  unresolvedEntries: 0,
  excludedLibrarySongs: 0,
  recentCatalogIds: [],
}
function deferred<T>() {
  let resolve!: (value: T) => void
  const promise = new Promise<T>((done) => {
    resolve = done
  })
  return { promise, resolve }
}
const flush = () => new Promise((resolve) => setTimeout(resolve, 0))

describe('app-owned music sync', () => {
  it('survives view subscribers leaving, blocks competing uploads, and refreshes once', async () => {
    const pending = deferred<MusicSyncResult>()
    const service = { sync: vi.fn(() => pending.promise) }
    const gate = createUploadGate()
    const onPublished = vi.fn()
    const run = createMusicSyncRun({ service, gate, onPublished })
    const leave = run.subscribe(vi.fn())
    run.start()
    run.start()
    leave()
    expect(gate.acquire('spotify')).toBeNull()
    expect(service.sync).toHaveBeenCalledOnce()
    pending.resolve(complete)
    await flush()
    expect(run.getState()).toMatchObject({ kind: 'result', result: complete })
    expect(gate.getOwner()).toBeNull()
    expect(onPublished).toHaveBeenCalledOnce()
  })

  it('keeps the shared gate while publication is unknown and checks only once', async () => {
    const check = vi.fn(async () => complete)
    const gate = createUploadGate()
    const run = createMusicSyncRun({
      gate,
      service: {
        sync: async () => ({
          kind: 'unconfirmed',
          stage: 'library',
          library: null,
          failure: 'connection',
          excludedLibrarySongs: 0,
          recentCatalogIds: [],
          check,
        }),
      },
      onPublished: vi.fn(),
    })
    run.start()
    await flush()
    expect(gate.getOwner()).toBe('apple')
    run.start()
    run.check()
    run.check()
    await flush()
    expect(check).toHaveBeenCalledOnce()
    expect(gate.getOwner()).toBeNull()
  })

  it('disposal aborts and forgets private data, ignoring late completion and progress', async () => {
    const pending = deferred<MusicSyncResult>()
    let options!: MusicSyncOptions
    const gate = createUploadGate()
    const onPublished = vi.fn()
    const run = createMusicSyncRun({
      gate,
      service: {
        sync: (value) => {
          options = value
          return pending.promise
        },
      },
      onPublished,
    })
    run.start()
    run.dispose()
    expect(options.signal.aborted).toBe(true)
    options.onProgress({ stage: 'library_songs', completed: 50 })
    pending.resolve(complete)
    await flush()
    expect(run.getState()).toEqual({ kind: 'idle' })
    expect(gate.getOwner()).toBeNull()
    expect(onPublished).not.toHaveBeenCalled()
  })

  it('does not start while Spotify owns the gate and old releases cannot unlock a new run', async () => {
    const gate = createUploadGate()
    const release = gate.acquire('spotify')!
    const service = { sync: vi.fn(async () => complete) }
    const run = createMusicSyncRun({ gate, service, onPublished: vi.fn() })
    run.start()
    expect(service.sync).not.toHaveBeenCalled()
    release()
    const next = gate.acquire('apple')!
    release()
    expect(gate.getOwner()).toBe('apple')
    next()
    expect(gate.getOwner()).toBeNull()
  })
})
