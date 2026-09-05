import type { MusicSyncProgress, MusicSyncResult, MusicSyncService } from './music-sync-service'
import type { UploadGate } from './upload-gate'
import { MusicKitClientError } from '../musickit/client'

export type MusicSyncRunState =
  | { kind: 'idle' }
  | { kind: 'blocked'; owner: 'spotify' }
  | { kind: 'running'; progress: MusicSyncProgress | null }
  | { kind: 'cancelling'; progress: MusicSyncProgress | null }
  | { kind: 'result'; result: MusicSyncResult }
  | { kind: 'cancelled' }
  | { kind: 'error'; failure: 'session' | 'connection' | 'permission' | 'unavailable' }

export type MusicSyncRun = {
  getState(): MusicSyncRunState
  subscribe(listener: () => void): () => void
  start(): void
  check(): void
  cancel(): void
  reset(): void
  dispose(): void
}

type Deps = { service: MusicSyncService; gate: UploadGate; onPublished: () => Promise<void> | void }

export function createMusicSyncRun({ service, gate, onPublished }: Deps): MusicSyncRun {
  let state: MusicSyncRunState = { kind: 'idle' }
  let generation = 0
  let controller: AbortController | null = null
  let release: (() => void) | null = null
  const listeners = new Set<() => void>()
  const set = (next: MusicSyncRunState) => {
    state = next
    for (const listener of [...listeners]) listener()
  }
  const unlock = () => {
    const own = release
    release = null
    own?.()
  }

  async function settle(run: number, task: Promise<MusicSyncResult>) {
    try {
      const result = await task
      if (run !== generation) return
      controller = null
      set({ kind: 'result', result })
      if (result.kind !== 'unconfirmed') unlock()
      if (result.kind === 'complete' || result.kind === 'partial') {
        try {
          await onPublished()
        } catch {
          /* The published result remains authoritative. */
        }
      }
    } catch (error) {
      if (run !== generation) return
      const cancelled = controller?.signal.aborted
      controller = null
      unlock()
      const session = typeof error === 'object' && error !== null && 'status' in error && error.status === 401
      const musicError = error instanceof MusicKitClientError ? error.code : null
      const failure = session
        ? 'session'
        : musicError === 'authorization_cancelled' ||
            musicError === 'authorization_failed' ||
            musicError === 'not_connected'
          ? 'permission'
          : musicError === 'unavailable' || musicError === 'configuration_failed'
            ? 'unavailable'
            : 'connection'
      set(cancelled ? { kind: 'cancelled' } : { kind: 'error', failure })
    }
  }

  function launch(
    task: (options: {
      signal: AbortSignal
      onProgress: (progress: MusicSyncProgress) => void
    }) => Promise<MusicSyncResult>,
  ) {
    const run = ++generation
    const own = new AbortController()
    controller = own
    set({ kind: 'running', progress: null })
    void settle(
      run,
      task({
        signal: own.signal,
        onProgress: (progress) => {
          if (run === generation && state.kind === 'running') set({ kind: 'running', progress })
        },
      }),
    )
  }

  return {
    getState: () => state,
    subscribe(listener) {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    },
    start() {
      if (
        state.kind === 'running' ||
        state.kind === 'cancelling' ||
        (state.kind === 'result' && state.result.kind === 'unconfirmed')
      )
        return
      release = gate.acquire('apple')
      if (!release) {
        if (gate.getOwner() === 'spotify') set({ kind: 'blocked', owner: 'spotify' })
        return
      }
      launch((options) => service.sync(options))
    },
    check() {
      if (state.kind !== 'result' || state.result.kind !== 'unconfirmed' || controller) return
      const pending = state.result
      launch((options) => pending.check(options))
    },
    cancel() {
      if (state.kind !== 'running') return
      set({ kind: 'cancelling', progress: state.progress })
      controller?.abort()
    },
    reset() {
      if (
        state.kind === 'running' ||
        state.kind === 'cancelling' ||
        (state.kind === 'result' && state.result.kind === 'unconfirmed')
      )
        return
      generation += 1
      unlock()
      set({ kind: 'idle' })
    },
    dispose() {
      generation += 1
      controller?.abort()
      controller = null
      unlock()
      set({ kind: 'idle' })
      listeners.clear()
    },
  }
}
