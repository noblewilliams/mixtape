import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { ApiMusicSource, OnboardingResponse } from '../api/client'
import type { AddMusicPlatform } from '../lib/add-music-route'
import type { MusicSyncProgress } from '../sync/music-sync-service'
import type { MusicSyncRunState } from '../sync/music-sync-run'
import doorCss from './music-door.css?raw'
import { MusicDoor, musicDoorState, syncProgress, type MusicDoorInput } from './MusicDoor'

const blank: OnboardingResponse = {
  userId: 'user-1',
  sources: [],
  hasLibrary: false,
  chosenService: null,
  markedRequestedAt: null,
  interviewCompletedAt: null,
  importCompletedAt: null,
  interview: null,
  musicReady: false,
}
const ready: OnboardingResponse = { ...blank, musicReady: true }
// Spotify chosen, the data export requested, nothing landed yet.
const waiting: OnboardingResponse = { ...blank, chosenService: 'spotify', markedRequestedAt: '2026-11-08T09:00:00.000Z' }
const landedPackage: ApiMusicSource = {
  source: 'spotify_export',
  connectedAt: '2026-11-08T09:00:00.000Z',
  lastImportedAt: '2026-11-09T09:00:00.000Z',
  ledgerFrom: null,
  ledgerTo: null,
  packages: ['spotify_account'],
}

const idle: MusicSyncRunState = { kind: 'idle' }
const running = (completed = 0, total?: number): MusicSyncRunState => ({
  kind: 'running',
  progress: { stage: 'uploading_library', completed, total },
})
const at = (progress: MusicSyncProgress): MusicSyncRunState => ({ kind: 'running', progress })
const failed: MusicSyncRunState = { kind: 'error', failure: 'connection' }
const refused: MusicSyncRunState = { kind: 'error', failure: 'permission' }

/** A sync run the test moves by hand. */
function fakeRun(initial: MusicSyncRunState) {
  let state = initial
  const listeners = new Set<() => void>()
  return {
    getState: () => state,
    subscribe(listener: () => void) {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    },
    set(next: MusicSyncRunState) {
      state = next
      for (const listener of [...listeners]) listener()
    },
  }
}

const CATALOG_LINE = 'From Mixtape’s catalog for now. With your music, the DJ picks from what you actually play.'

function renderDoor(
  over: Partial<MusicDoorInput> & { notPersonal?: boolean; layout?: 'line' | 'banner'; sync?: MusicSyncRunState } = {},
) {
  const { sync = idle, notPersonal = true, layout, ...input } = over
  const run = fakeRun(sync)
  const onAddMusic = vi.fn()
  const onRemake = vi.fn()
  const props: MusicDoorInput = {
    onboarding: blank,
    syncRun: run,
    platform: null,
    onAddMusic,
    onRemake,
    ...input,
  }
  const view = render(<MusicDoor {...props} notPersonal={notPersonal} layout={layout} />)
  return { ...view, run, onAddMusic, onRemake, props }
}

const door = () => screen.getByRole('status')
/** What a screen reader gets from the live region: the text of everything not hidden from it, in order. */
function spoken(element: HTMLElement) {
  const copy = element.cloneNode(true) as HTMLElement
  copy.querySelectorAll('[aria-hidden="true"], [hidden]').forEach((node) => node.remove())
  const walker = document.createTreeWalker(copy, NodeFilter.SHOW_TEXT)
  const words: string[] = []
  while (walker.nextNode()) words.push(walker.currentNode.textContent ?? '')
  return words.join(' ').replace(/\s+/g, ' ').trim()
}

describe('musicDoorState', () => {
  const state = (over: Partial<Parameters<typeof musicDoorState>[0]>) =>
    musicDoorState({ notPersonal: true, onboarding: blank, sync: idle, platform: null, ...over })

  it('is remade once the mix is personal, whatever else is true', () => {
    expect(state({ notPersonal: false })).toBe('remade')
    expect(state({ notPersonal: false, onboarding: ready, sync: running(10, 100) })).toBe('remade')
  })

  it('is musicIn when the music is ready, even while a sync still runs', () => {
    expect(state({ onboarding: ready })).toBe('musicIn')
    expect(state({ onboarding: ready, sync: running(10, 100) })).toBe('musicIn')
    expect(state({ onboarding: { ...ready, markedRequestedAt: waiting.markedRequestedAt } })).toBe('musicIn')
  })

  it('is syncing while an Apple sync runs, stops, or its onboarding read is landing', () => {
    expect(state({ sync: running() })).toBe('syncing')
    expect(state({ sync: { kind: 'cancelling', progress: null } })).toBe('syncing')
    expect(state({ sync: { kind: 'result', result: { kind: 'complete', songs: 10, playlists: 1, entries: 1, excludedLibrarySongs: 0, recentCatalogIds: [] } as never }, syncLanding: true })).toBe('syncing')
    expect(state({ sync: running(), onboarding: waiting })).toBe('syncing')
  })

  it('is syncFailed after a failed, partial or unconfirmed sync, on Apple Music or an unknown platform', () => {
    expect(state({ sync: failed })).toBe('syncFailed')
    expect(state({ sync: failed, platform: 'apple' })).toBe('syncFailed')
    expect(state({ sync: { kind: 'error', failure: 'unavailable' } })).toBe('syncFailed')
    expect(state({ sync: { kind: 'error', failure: 'session' } })).toBe('syncFailed')
    expect(state({ sync: { kind: 'result', result: { kind: 'partial' } as never } })).toBe('syncFailed')
    expect(state({ sync: { kind: 'result', result: { kind: 'unconfirmed' } as never } })).toBe('syncFailed')
  })

  it('lets a failed sync beat the Spotify wait only on Apple Music or an unknown platform', () => {
    expect(state({ sync: failed, onboarding: waiting, platform: 'apple' })).toBe('syncFailed')
    expect(state({ sync: failed, onboarding: waiting, platform: null })).toBe('syncFailed')
    expect(state({ sync: failed, onboarding: waiting, platform: 'spotify' })).toBe('spotifyWaiting')
  })

  it('never says a sync failed on a Spotify device', () => {
    expect(state({ sync: failed, platform: 'spotify' })).toBe('noMusic')
    expect(state({ sync: { kind: 'result', result: { kind: 'partial' } as never }, platform: 'spotify' })).toBe('noMusic')
  })

  it('reads a refused authorisation or a cancelled sync as no music, not a failure', () => {
    expect(state({ sync: refused })).toBe('noMusic')
    expect(state({ sync: { kind: 'cancelled' } })).toBe('noMusic')
    expect(state({ sync: { kind: 'blocked', owner: 'spotify' } })).toBe('noMusic')
  })

  it('is spotifyWaiting while the requested data export has not landed', () => {
    expect(state({ onboarding: waiting })).toBe('spotifyWaiting')
    expect(state({ onboarding: waiting, sync: refused })).toBe('spotifyWaiting')
    expect(state({ onboarding: { ...waiting, sources: [landedPackage] } })).toBe('noMusic')
  })

  it('is noMusic for everything else, including an onboarding not read yet', () => {
    expect(state({})).toBe('noMusic')
    expect(state({ onboarding: null })).toBe('noMusic')
    expect(state({ sync: { kind: 'result', result: { kind: 'complete' } as never } })).toBe('noMusic')
  })
})

describe('syncProgress', () => {
  it('counts the whole run, reading included, from 0 to 100 without stepping back between stages', () => {
    const steps: MusicSyncProgress[] = [
      { stage: 'authorizing', completed: 0 },
      { stage: 'library_songs', completed: 0, total: 400 },
      { stage: 'library_songs', completed: 400, total: 400 },
      { stage: 'playlists', completed: 0, total: 10 },
      { stage: 'playlists', completed: 10, total: 10 },
      { stage: 'playlist_tracks', completed: 30 },
      { stage: 'recent_tracks', completed: 30, total: 30 },
      { stage: 'uploading_library', completed: 0, total: 400 },
      { stage: 'uploading_library', completed: 400, total: 400 },
      { stage: 'saving_library', completed: 0 },
      { stage: 'uploading_playlists', completed: 0, total: 30 },
      { stage: 'uploading_playlists', completed: 30, total: 30 },
      { stage: 'saving_playlists', completed: 0 },
      { stage: 'complete', completed: 1, total: 1 },
    ]
    const values = steps.map((progress) => syncProgress(at(progress))!)
    expect(values[0]).toBe(0)
    expect(values.at(-1)).toBe(100)
    values.forEach((value, index) => expect(value).toBeGreaterThanOrEqual(values[index - 1] ?? 0))
  })

  it('moves through the library read when its total is known', () => {
    expect(syncProgress(at({ stage: 'library_songs', completed: 210, total: 400 }))).toBe(21)
    expect(syncProgress(at({ stage: 'library_songs', completed: 210 }))).toBe(0)
    expect(syncProgress(at({ stage: 'uploading_library', completed: 42, total: 100 }))).toBeCloseTo(62.6)
  })

  it('is null when no sync runs, and full while a published sync lands', () => {
    expect(syncProgress(idle)).toBeNull()
    expect(syncProgress(failed)).toBeNull()
    expect(syncProgress({ kind: 'result', result: { kind: 'complete' } as never }, true)).toBe(100)
  })
})

describe('MusicDoor', () => {
  afterEach(cleanup)

  it('draws nothing for a remade mix', () => {
    const { container } = renderDoor({ notPersonal: false, onboarding: ready })
    expect(container).toBeEmptyDOMElement()
  })

  it.each<[AddMusicPlatform, string, boolean]>([
    ['apple', 'Sync Apple Music', true],
    ['spotify', 'Add Spotify music', true],
    [null, 'Add your music', false],
  ])('noMusic on %s: the catalog line, then "%s"', (platform, label, marked) => {
    const { onAddMusic } = renderDoor({ platform })
    expect(within(door()).getByText(CATALOG_LINE)).toBeInTheDocument()
    const action = within(door()).getByRole('button', { name: label })
    expect(action.querySelector('svg') !== null).toBe(marked)
    expect(within(door()).getAllByRole('button')).toHaveLength(1)
    fireEvent.click(action)
    expect(onAddMusic).toHaveBeenCalledWith('door')
  })

  it('marks Apple Music and Spotify with their own service marks', () => {
    renderDoor({ platform: 'apple' })
    const apple = screen.getByRole('button', { name: 'Sync Apple Music' }).querySelector('svg')!.innerHTML
    cleanup()
    renderDoor({ platform: 'spotify' })
    const spotify = screen.getByRole('button', { name: 'Add Spotify music' }).querySelector('svg')!.innerHTML
    expect(apple).not.toBe(spotify)
  })

  it('syncing with a percent: the bold lead with it, the tail, a thin bar and no action', () => {
    renderDoor({ platform: 'apple', sync: running(42, 100) })
    expect(door()).toHaveTextContent('Syncing Apple Music… 62%. You can keep chatting while it runs.')
    expect(door().querySelector('strong')).toHaveTextContent('Syncing Apple Music…')
    expect(within(door()).queryByRole('button')).toBeNull()
    const bar = door().querySelector('.music-door-bar') as HTMLElement
    expect(bar).toHaveAttribute('aria-hidden', 'true')
    expect((bar.firstElementChild as HTMLElement).style.width).toBe('62%')
  })

  it('shows the library read moving, not a bar stuck at nothing', () => {
    renderDoor({ platform: 'apple', sync: at({ stage: 'library_songs', completed: 210, total: 400 }) })
    expect(door()).toHaveTextContent('Syncing Apple Music… 21%.')
    expect((door().querySelector('.music-door-bar > i') as HTMLElement).style.width).toBe('21%')
  })

  it('never moves the bar backwards, even when a stage’s total grows', () => {
    const { run } = renderDoor({ platform: 'apple', sync: at({ stage: 'library_songs', completed: 300, total: 400 }) })
    expect(door()).toHaveTextContent('30%.')
    act(() => run.set(at({ stage: 'library_songs', completed: 300, total: 1000 })))
    expect(door()).toHaveTextContent('30%.')
    expect((door().querySelector('.music-door-bar > i') as HTMLElement).style.width).toBe('30%')
    act(() => run.set(at({ stage: 'library_songs', completed: 900, total: 1000 })))
    expect(door()).toHaveTextContent('36%.')
  })

  it('syncing with no percent known: the lead alone', () => {
    renderDoor({ platform: 'apple', sync: at({ stage: 'authorizing', completed: 0 }) })
    expect(door()).toHaveTextContent(/^Syncing Apple Music… You can keep chatting while it runs\.$/)
    expect(door()).not.toHaveTextContent('%')
  })

  it('keeps the percent out of the live region, so a moving count is never re-announced', () => {
    const { run } = renderDoor({ platform: 'apple', sync: running(10, 100) })
    expect(door()).toHaveTextContent('53%')
    const before = spoken(door())
    expect(before).toBe('Syncing Apple Music… You can keep chatting while it runs.')
    act(() => run.set(running(42, 100)))
    expect(door()).toHaveTextContent('62%')
    expect(spoken(door())).toBe(before)
  })

  it('announces the sync at its start and its end, in words', () => {
    const { run } = renderDoor({ platform: 'apple' })
    expect(spoken(door())).toContain(CATALOG_LINE)
    act(() => run.set(running(5, 100)))
    expect(spoken(door())).toBe('Syncing Apple Music… You can keep chatting while it runs.')
    act(() => run.set(failed))
    expect(spoken(door())).toBe('Sync didn’t finish. Try again')
  })

  it('syncFailed: the line in error ink, then Try again to retry the sync', () => {
    const { onAddMusic } = renderDoor({ platform: 'apple', sync: failed })
    expect(within(door()).getByText('Sync didn’t finish.')).toBeInTheDocument()
    expect(door()).toHaveClass('music-door--err')
    fireEvent.click(within(door()).getByRole('button', { name: 'Try again' }))
    expect(onAddMusic).toHaveBeenCalledWith('retrySync')
  })

  it('shows a Spotify device the first state, never Sync didn’t finish.', () => {
    renderDoor({ platform: 'spotify', sync: failed })
    expect(within(door()).getByText(CATALOG_LINE)).toBeInTheDocument()
    expect(within(door()).getByRole('button', { name: 'Add Spotify music' })).toBeInTheDocument()
    expect(screen.queryByText('Sync didn’t finish.')).toBeNull()
  })

  it('reads a refused Apple Music authorisation as the first state again', () => {
    renderDoor({ platform: 'apple', sync: refused })
    expect(within(door()).getByText(CATALOG_LINE)).toBeInTheDocument()
    expect(within(door()).getByRole('button', { name: 'Sync Apple Music' })).toBeInTheDocument()
  })

  it('spotifyWaiting: the waiting line, then Choose files', () => {
    const { onAddMusic } = renderDoor({ platform: 'spotify', onboarding: waiting })
    expect(within(door()).getByText('Waiting on your Spotify data. It can take a few days.')).toBeInTheDocument()
    fireEvent.click(within(door()).getByRole('button', { name: 'Choose files' }))
    expect(onAddMusic).toHaveBeenCalledWith('door')
  })

  it('musicIn: the bold lead, the tail, and the primary Remake with my music', () => {
    const { onRemake } = renderDoor({ platform: 'spotify', onboarding: ready })
    expect(door().querySelector('.music-door-line')).toHaveTextContent(/^Your music is in\. This mix was made before it\.$/)
    expect(door().querySelector('strong')).toHaveTextContent('Your music is in.')
    expect(spoken(door())).toBe('Your music is in. This mix was made before it. Remake with my music')
    const remake = within(door()).getByRole('button', { name: 'Remake with my music' })
    expect(remake).toHaveClass('album-play')
    expect(remake).toHaveAccessibleDescription('Makes a new version from your music.')
    fireEvent.click(remake)
    expect(onRemake).toHaveBeenCalledTimes(1)
  })

  it('holds Remake while a turn is in flight', () => {
    const { onRemake } = renderDoor({ onboarding: ready, busy: true })
    const remake = screen.getByRole('button', { name: 'Remake with my music' })
    expect(remake).toBeDisabled()
    fireEvent.click(remake)
    expect(onRemake).not.toHaveBeenCalled()
  })

  it('steps aside while a remake is on its way, mounted but hidden, and comes back with Remake enabled', () => {
    const { rerender, props } = renderDoor({ onboarding: ready, pending: true })
    expect(screen.queryByRole('status')).toBeNull()
    expect(screen.queryByRole('button', { name: 'Remake with my music' })).toBeNull()
    const hidden = document.querySelector('.music-door') as HTMLElement
    expect(hidden).toHaveAttribute('hidden')
    rerender(<MusicDoor {...props} pending={false} notPersonal />)
    expect(document.querySelector('.music-door')).toBe(hidden)
    expect(screen.getByRole('button', { name: 'Remake with my music' })).toBeEnabled()
  })

  it('uses real buttons for every action', () => {
    renderDoor({ platform: 'apple' })
    expect(screen.getByRole('button', { name: 'Sync Apple Music' }).tagName).toBe('BUTTON')
    expect(screen.getByRole('button', { name: 'Sync Apple Music' })).toHaveAttribute('type', 'button')
  })

  it('keeps the banner line readable: a darker amber at 11px, 4.5:1 on the banner', () => {
    const rule = doorCss.match(/\.banner--door \.music-door-line\s*{([^}]*)}/)?.[1] ?? ''
    expect(rule).toMatch(/color:\s*#806232;/)
    expect(rule).toMatch(/font-size:\s*var\(--type-meta-size\);/)
  })

  describe('as the phone shell’s banner', () => {
    it('carries the label, the full line and the action', () => {
      const { onAddMusic } = renderDoor({ layout: 'banner', platform: 'spotify' })
      expect(door()).toHaveClass('banner')
      expect(within(door()).getByText('Not personal yet')).toBeInTheDocument()
      expect(within(door()).getByText(CATALOG_LINE)).toBeInTheDocument()
      fireEvent.click(within(door()).getByRole('button', { name: 'Add Spotify music' }))
      expect(onAddMusic).toHaveBeenCalledWith('door')
    })

    it('follows the same states and copy as the line', () => {
      const { run } = renderDoor({ layout: 'banner', platform: 'apple', sync: running(42, 100) })
      expect(door()).toHaveTextContent('Not personal yetSyncing Apple Music… 62%. You can keep chatting while it runs.')
      expect(spoken(door())).toBe('Not personal yet Syncing Apple Music… You can keep chatting while it runs.')
      act(() => run.set(failed))
      expect(within(door()).getByText('Sync didn’t finish.')).toBeInTheDocument()
      expect(within(door()).getByRole('button', { name: 'Try again' })).toBeInTheDocument()
      cleanup()
      renderDoor({ layout: 'banner', onboarding: ready })
      expect(within(door()).getByRole('button', { name: 'Remake with my music' })).toBeInTheDocument()
    })
  })
})
