import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { AppleMusicSyncPanel } from './AppleMusicSyncPanel'
import type { MusicSyncRun, MusicSyncRunState } from '../sync/music-sync-run'
import type { MusicSyncResult } from '../sync/music-sync-service'

afterEach(cleanup)
const complete: MusicSyncResult = {
  kind: 'complete',
  songs: 0,
  catalogResolved: 0,
  playCountsObserved: 0,
  recentTracks: 0,
  playlists: 0,
  entries: 0,
  resolvedEntries: 0,
  unresolvedEntries: 0,
  excludedLibrarySongs: 0,
  recentCatalogIds: [],
}
function panel(state: MusicSyncRunState, owner: 'spotify' | 'apple' | null = null) {
  const run: MusicSyncRun = {
    getState: () => state,
    subscribe: () => () => undefined,
    start: vi.fn(),
    check: vi.fn(),
    cancel: vi.fn(),
    reset: vi.fn(),
    dispose: vi.fn(),
  }
  const onBrowse = vi.fn()
  const onSources = vi.fn()
  render(
    <AppleMusicSyncPanel
      run={run}
      owner={owner}
      connected={false}
      summary={null}
      onBrowse={onBrowse}
      onSpotify={vi.fn()}
      onSources={onSources}
      onSignIn={vi.fn()}
    />,
  )
  return { run, onBrowse, onSources }
}

it.each<{ state: MusicSyncRunState; heading: string }>([
  { state: { kind: 'idle' }, heading: 'Connect when you’re ready' },
  { state: { kind: 'cancelled' }, heading: 'Sync cancelled' },
  { state: { kind: 'error', failure: 'permission' }, heading: 'Apple Music wasn’t connected' },
  { state: { kind: 'error', failure: 'unavailable' }, heading: 'Apple Music couldn’t load' },
  { state: { kind: 'error', failure: 'session' }, heading: 'Sign in again to sync' },
  { state: { kind: 'error', failure: 'connection' }, heading: 'Connection lost' },
  { state: { kind: 'result', result: complete }, heading: 'Your music is in' },
  {
    state: {
      kind: 'result',
      result: {
        kind: 'partial',
        library: { songs: 5, catalogResolved: 5, playCountsObserved: 0, recentTracks: 0 },
        reason: 'failed',
        failure: 'connection',
        excludedLibrarySongs: 0,
        recentCatalogIds: [],
      },
    },
    heading: 'Songs saved. Playlists need another try.',
  },
])('renders the recovery contract: $heading', ({ state, heading }) => {
  panel(state)
  expect(screen.getByRole('heading', { name: heading })).toBeVisible()
  expect(screen.queryByRole('progressbar')).not.toBeInTheDocument()
})

it('does not invent a percentage while reading and sends cancel to the app-owned run', () => {
  const { run } = panel({ kind: 'running', progress: { stage: 'playlist_tracks', completed: 17 } }, 'apple')
  expect(screen.getByText('17 playlist entries read · total not known yet')).toBeVisible()
  expect(screen.queryByRole('progressbar')).not.toBeInTheDocument()
  fireEvent.click(screen.getByRole('button', { name: 'Cancel sync' }))
  expect(run.cancel).toHaveBeenCalledOnce()
})

it('labels a known percentage as one upload stage', () => {
  panel({ kind: 'running', progress: { stage: 'uploading_library', completed: 20, total: 80 } }, 'apple')
  expect(screen.getByRole('progressbar', { name: 'songs uploaded' })).toHaveAttribute('value', '20')
  expect(screen.getByText('20 of 80 songs uploaded · 25% of songs')).toBeVisible()
})

it('checks an unconfirmed result instead of offering a fresh upload', () => {
  const { run } = panel(
    {
      kind: 'result',
      result: {
        kind: 'unconfirmed',
        stage: 'library',
        library: null,
        failure: 'connection',
        recentCatalogIds: [],
        excludedLibrarySongs: 0,
        check: async () => complete,
      },
    },
    'apple',
  )
  expect(screen.getByText('Checking what was saved')).toBeVisible()
  expect(screen.queryByText(/nothing was saved/i)).not.toBeInTheDocument()
  fireEvent.click(screen.getByRole('button', { name: 'Check again' }))
  expect(run.check).toHaveBeenCalledOnce()
  expect(run.start).not.toHaveBeenCalled()
})

it('explains the other upload and leaves browsing available', () => {
  panel({ kind: 'idle' }, 'spotify')
  expect(screen.getByText('Spotify is importing right now')).toBeVisible()
  expect(screen.getByRole('button', { name: 'Connect Apple Music' })).toBeDisabled()
  expect(screen.getByRole('button', { name: 'Browse saved music' })).toBeEnabled()
})

it.each([
  ['Browse playlists', 'browse'],
  ['Back to sources', 'sources'],
] as const)('acknowledges a complete result through %s', (action, destination) => {
  const { run, onBrowse, onSources } = panel({ kind: 'result', result: complete })

  fireEvent.click(screen.getByRole('button', { name: action }))

  expect(run.reset).toHaveBeenCalledOnce()
  expect(destination === 'browse' ? onBrowse : onSources).toHaveBeenCalledOnce()
  expect(screen.queryByRole('button', { name: 'Browse saved music' })).not.toBeInTheDocument()
})
