import { vi, type Mock } from 'vitest'
import type { CreateSessionResponse } from '../api/client'
import type { FirstRunServices } from '../components/first-run/services'
import type { ImportRun, ImportRunState } from '../import/import-run'
import type { MusicSyncRun, MusicSyncRunState } from '../sync/music-sync-run'

type Controllable<S> = { set(next: S): void }

export function fakeSyncRun(): MusicSyncRun & Controllable<MusicSyncRunState> & { start: Mock<() => void>; check: Mock<() => void> } {
  let state: MusicSyncRunState = { kind: 'idle' }
  const listeners = new Set<() => void>()
  return {
    getState: () => state,
    subscribe(listener) {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    },
    start: vi.fn<() => void>(() => {
      state = { kind: 'running', progress: null }
      for (const listener of [...listeners]) listener()
    }),
    check: vi.fn<() => void>(),
    cancel: vi.fn(),
    reset: vi.fn(),
    dispose: vi.fn(),
    set(next) {
      state = next
      for (const listener of [...listeners]) listener()
    },
  }
}

export function fakeImportRun(): ImportRun & Controllable<ImportRunState> {
  let state: ImportRunState = { kind: 'pick' }
  const listeners = new Set<() => void>()
  return {
    getState: () => state,
    subscribe(listener) {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    },
    take: vi.fn(),
    setSelection: vi.fn(),
    setIncludePrivate: vi.fn(),
    upload: vi.fn(),
    retry: vi.fn(),
    reviewAgain: vi.fn(),
    cancel: vi.fn(),
    tryAgain: vi.fn(),
    reset: vi.fn(),
    dispose: vi.fn(),
    set(next) {
      state = next
      for (const listener of [...listeners]) listener()
    },
  }
}

export function syncResult(songs: number): MusicSyncRunState {
  return {
    kind: 'result',
    result: {
      kind: 'complete',
      songs,
      catalogResolved: songs,
      playCountsObserved: 0,
      recentTracks: 0,
      playlists: 0,
      entries: 0,
      resolvedEntries: 0,
      unresolvedEntries: 0,
      excludedLibrarySongs: 0,
      recentCatalogIds: [],
    },
  }
}

export function createdSession(id: string): CreateSessionResponse {
  return { session: { id } } as unknown as CreateSessionResponse
}

/** Services whose every call is recorded in one ordered log. */
export function fakeServices() {
  const log: string[] = []
  const syncRun = fakeSyncRun()
  const importRun = fakeImportRun()
  const api = {
    createSession: vi.fn(async (prompt: string) => {
      log.push(`createSession:${prompt}`)
      return createdSession('session-new')
    }),
    putArtistSeeds: vi.fn(async (names: string[]) => {
      log.push(`putArtistSeeds:${names.join('|')}`)
      return { seeds: [] }
    }),
    postFunnelEvent: vi.fn(async (event: { type: string }) => {
      log.push(`postFunnelEvent:${event.type}`)
      return { ok: true as const }
    }),
  }
  const ensureSession = vi.fn(async () => {
    log.push('ensureSession')
  })
  const services = { api, syncRun, importRun, ensureSession } as unknown as FirstRunServices
  return { services, api, syncRun, importRun, ensureSession, log }
}
