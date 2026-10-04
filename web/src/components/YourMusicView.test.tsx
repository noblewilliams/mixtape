import { WorkspaceRestoreProvider } from '../lib/workspace-restore'
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import type { ComponentProps } from 'react'
import { YourMusicView } from './YourMusicView'
import { createFakeApi } from '../test/fake-api'
import { createUploadGate } from '../sync/upload-gate'

// Import and sync actions are opened by navigation; they never run on this surface.
function props(): ComponentProps<typeof YourMusicView> {
  const state = { kind: 'idle' } as const
  return {
    api: createFakeApi(), section: 'sources', onSection: vi.fn(),
    syncRun: { getState: () => state, subscribe: () => () => {}, start: vi.fn(), check: vi.fn(), cancel: vi.fn(), reset: vi.fn(), dispose: vi.fn() },
    importRun: {} as ComponentProps<typeof YourMusicView>['importRun'],
    uploadGate: createUploadGate(), connected: true, revision: 0, interviewStatus: '',
    onRefresh: vi.fn(), onOpenInterview: vi.fn(), onNewTape: vi.fn(), onRemoveSource: vi.fn(), onSessionExpired: vi.fn(),
  }
}
afterEach(cleanup)

it('keeps source actions available and the connected badge beside the Library heading', async () => {
  const input = props()
  render(<YourMusicView {...input} />)
  const header = screen.getByRole('heading', { name: 'Library' }).closest('header')!
  expect(within(header).getByRole('button', { name: 'Apple Music Connected' })).toBeVisible()
  await waitFor(() => expect(screen.getByRole('button', { name: 'Connect Apple Music' })).toBeEnabled())
  fireEvent.click(screen.getByRole('button', { name: 'Connect Apple Music' }))
  expect(input.onSection).toHaveBeenLastCalledWith('apple')
  fireEvent.click(screen.getByRole('button', { name: 'Import Spotify' }))
  expect(input.onSection).toHaveBeenLastCalledWith('spotify')
  expect(screen.getByRole('heading', { name: 'Apple Music' }).closest('article')).toHaveTextContent('Connected')
})

it('keeps provider labels and disabled actions stable while checking sources', () => {
  const input = props()
  input.api = createFakeApi({ getMusicCollectionSummary: () => new Promise(() => {}) })
  render(<YourMusicView {...input} />)
  expect(screen.getByRole('heading', { name: 'Apple Music' })).toBeVisible()
  expect(screen.getByRole('heading', { name: 'Spotify' })).toBeVisible()
  expect(screen.getByRole('button', { name: 'Connect Apple Music' })).toBeDisabled()
  expect(screen.getByRole('button', { name: 'Import Spotify' })).toBeDisabled()
})

it('restores source summary without blanking it while the session is checked', async () => {
  sessionStorage.clear()
  const input = props()
  const summary = vi.fn().mockResolvedValue({ apple: { songs: 42, playlists: 3, librarySyncedAt: '2026-10-02T10:00:00Z' }, spotify: { playlists: 0 } })
  input.api = createFakeApi({ getMusicCollectionSummary: summary })
  const view = (restoring: boolean) => <WorkspaceRestoreProvider userId="source-reader" restoring={restoring}><YourMusicView {...input} /></WorkspaceRestoreProvider>
  const first = render(view(false))
  await screen.findByRole('button', { name: 'Manage Apple Music' })
  first.unmount()
  summary.mockClear()
  const restored = render(view(true))
  expect(screen.getByRole('heading', { name: 'Apple Music' }).closest('article')).toHaveTextContent('42 songs · 3 playlists')
  expect(summary).not.toHaveBeenCalled()
  summary.mockRejectedValue(new Error('offline'))
  restored.rerender(view(false))
  await screen.findByText(/Couldn’t refresh your sources/)
  expect(screen.getByRole('heading', { name: 'Apple Music' }).closest('article')).toHaveTextContent('42 songs · 3 playlists')
  expect(screen.queryByLabelText('Loading sources')).not.toBeInTheDocument()
})

it('starts automatic Library navigation on Playlists before sources finish loading', async () => {
  const input = props()
  input.api = createFakeApi({ getMusicCollectionSummary: () => new Promise(() => {}) })
  render(<YourMusicView {...input} section="auto" />)
  expect(screen.getByRole('button', { name: 'Playlists' })).toHaveAttribute('aria-current', 'page')
  expect(screen.getByRole('textbox', { name: 'Search playlists' })).toBeVisible()
  expect(screen.queryByLabelText('Loading sources')).not.toBeInTheDocument()
})
