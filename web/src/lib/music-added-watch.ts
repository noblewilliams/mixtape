// `music_added_from_mix` (spec 2026-11-09, decision 7): music landed in a run
// the mix's router opened. Each router open arms its own token, only when
// musicReady is known false. The watch records once, on the first onboarding
// read that says musicReady, and disarms when its run is over: at the flow's
// end, or, when a sync or upload outlives the page, when that run ends.
import type { ImportRun } from '../import/import-run'
import type { MusicSyncRun } from '../sync/music-sync-run'
import type { UploadGate } from '../sync/upload-gate'

export type MusicAddedToken = symbol

type Deps = {
  gate: Pick<UploadGate, 'getOwner'>
  syncRun: Pick<MusicSyncRun, 'getState' | 'subscribe'>
  importRun: Pick<ImportRun, 'getState' | 'subscribe'>
  /** Reads onboarding again; its result comes back through observe(). */
  refresh: () => Promise<void>
  /** Posts music_added_from_mix, fire-and-forget. */
  record: () => void
}

export type MusicAddedWatch = {
  /** A router-opened run starts: armed only when musicReady is known false. */
  arm: (musicReady: boolean | undefined) => MusicAddedToken | null
  /** Every onboarding read: records once if a watch is armed and music is ready. */
  observe: (musicReady: boolean) => void
  /**
   * The run's flow ended: onboarding is read again, then the watch disarms,
   * unless a sync or upload is still running; then it disarms when that run
   * fails or is cancelled, or after one more read when it lands.
   */
  settle: (token: MusicAddedToken | null) => void
  /** Music is being added another way (Library): nothing counts as from a mix. */
  clear: () => void
}

type Outcome = 'running' | 'landed' | 'failed'

export function createMusicAddedWatch({ gate, syncRun, importRun, refresh, record }: Deps): MusicAddedWatch {
  let armed: MusicAddedToken | null = null
  let unfollow: (() => void) | null = null

  const stopFollowing = () => {
    const stop = unfollow
    unfollow = null
    stop?.()
  }
  /** Only the run that armed a token may disarm it. */
  const disarm = (token: MusicAddedToken) => {
    if (armed !== token) return
    armed = null
    stopFollowing()
  }
  const readThenDisarm = (token: MusicAddedToken) => {
    void refresh().then(
      () => disarm(token),
      () => disarm(token),
    )
  }

  function syncOutcome(): Outcome {
    const state = syncRun.getState()
    if (state.kind === 'running' || state.kind === 'cancelling') return 'running'
    // Complete, partial, or unconfirmed (the server may have finished): read again.
    return state.kind === 'result' ? 'landed' : 'failed'
  }

  function importOutcome(): Outcome {
    const state = importRun.getState()
    if (state.kind === 'uploading') return 'running'
    return state.kind === 'done' || state.kind === 'partial' ? 'landed' : 'failed'
  }

  function follow(token: MusicAddedToken, owner: 'apple' | 'spotify') {
    stopFollowing()
    const outcome = owner === 'apple' ? syncOutcome : importOutcome
    const check = () => {
      if (armed !== token) return stopFollowing()
      const now = outcome()
      if (now === 'running') return
      stopFollowing()
      if (now === 'landed') readThenDisarm(token)
      else disarm(token)
    }
    unfollow = (owner === 'apple' ? syncRun : importRun).subscribe(check)
    check()
  }

  return {
    arm(musicReady) {
      stopFollowing()
      armed = musicReady === false ? Symbol('music-added-from-mix') : null
      return armed
    },
    observe(musicReady) {
      if (!armed || !musicReady) return
      armed = null
      stopFollowing()
      record()
    },
    settle(token) {
      const owner = gate.getOwner()
      if (!token || armed !== token) {
        void refresh()
        return
      }
      if (owner) {
        void refresh()
        follow(token, owner)
      } else readThenDisarm(token)
    },
    clear() {
      armed = null
      stopFollowing()
    },
  }
}
