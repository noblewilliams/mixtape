import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { AppSettings } from './AppSettings'
import type { MixtapeApi, SuggestionsResponse } from '../api/client'
import type { MusicKitClient } from '../musickit/client'
import { PlaybackController } from '../playback/controller'
import { createFakeApi } from '../test/fake-api'

const controllers: PlaybackController[] = []
afterEach(() => { cleanup(); controllers.splice(0).forEach(controller => controller.dispose()) })
const preferences = (enabled: boolean): SuggestionsResponse => ({ enabled, suggestion: null, dismissed: false })
async function setup(api: MixtapeApi) {
  const playback = new PlaybackController(api, {} as MusicKitClient, 'settings-test')
  controllers.push(playback)
  await playback.initialize()
  return render(<AppSettings api={api} playback={playback} userName="Test listener" signInMethod="google" onAccount={vi.fn()} onMemories={vi.fn()} onSignOut={vi.fn()} />)
}
const recommendationToggle = () => screen.getByRole('checkbox', { name: /Recommend mixes/ })

it('reads and saves recommendation preferences from Settings', async () => {
  const save = vi.fn().mockResolvedValue({ enabled: false })
  await setup(createFakeApi({ getSuggestions: async () => preferences(true), saveSuggestionPreference: save }))
  await waitFor(() => expect(recommendationToggle()).toBeChecked())
  fireEvent.click(recommendationToggle())
  await waitFor(() => expect(save).toHaveBeenCalledWith(false))
  await screen.findByText('Listening preferences saved.')
  expect(recommendationToggle()).not.toBeChecked()
})

it('disables changes until the initial preference read resolves', async () => {
  let resolve!: (result: SuggestionsResponse) => void
  const save = vi.fn()
  await setup(createFakeApi({ getSuggestions: () => new Promise(done => { resolve = done }), saveSuggestionPreference: save }))
  expect(recommendationToggle()).toBeDisabled()
  recommendationToggle().click()
  expect(save).not.toHaveBeenCalled()
  await act(async () => resolve(preferences(true)))
  expect(recommendationToggle()).toBeEnabled()
  expect(recommendationToggle()).toBeChecked()
})

it('retries an unavailable preference read before allowing a change', async () => {
  const read = vi.fn().mockRejectedValueOnce(new Error('offline')).mockResolvedValueOnce(preferences(false))
  await setup(createFakeApi({ getSuggestions: read }))
  await screen.findByText('Couldn’t load recommendation preferences.')
  expect(recommendationToggle()).toBeDisabled()
  fireEvent.click(screen.getByRole('button', { name: 'Retry' }))
  await waitFor(() => expect(recommendationToggle()).toBeEnabled())
  expect(recommendationToggle()).not.toBeChecked()
  expect(screen.queryByRole('alert')).not.toBeInTheDocument()
})

it('retains the confirmed preference after a save error and blocks stale changes while retrying', async () => {
  let resolveRetry!: (result: SuggestionsResponse) => void
  const read = vi.fn().mockResolvedValueOnce(preferences(true)).mockImplementationOnce(() => new Promise(done => { resolveRetry = done }))
  const save = vi.fn().mockRejectedValue(new Error('connection lost'))
  await setup(createFakeApi({ getSuggestions: read, saveSuggestionPreference: save }))
  await waitFor(() => expect(recommendationToggle()).toBeChecked())
  fireEvent.click(recommendationToggle())
  await screen.findByText('Couldn’t confirm the change. Retry to check your current preferences.')
  expect(recommendationToggle()).toBeChecked()
  fireEvent.click(screen.getByRole('button', { name: 'Retry' }))
  expect(recommendationToggle()).toBeDisabled()
  recommendationToggle().click()
  expect(save).toHaveBeenCalledTimes(1)
  // The server may have accepted the write even when its response was lost.
  await act(async () => resolveRetry(preferences(false)))
  expect(recommendationToggle()).toBeEnabled()
  expect(recommendationToggle()).not.toBeChecked()
})

it('does not offer a competing retry while listening preferences are saving', async () => {
  let finish!: (result: { enabled: boolean; revision: number }) => void
  await setup(createFakeApi({ savePlaybackPreference: () => new Promise(resolve => { finish = resolve }) }))
  fireEvent.click(screen.getByRole('checkbox', { name: /Learn from my listening/ }))
  expect(screen.queryByText('Listening preferences are unavailable.')).not.toBeInTheDocument()
  expect(screen.queryByRole('button', { name: 'Retry' })).not.toBeInTheDocument()
  await act(async () => finish({ enabled: true, revision: 1 }))
  expect(screen.getByRole('checkbox', { name: /Learn from my listening/ })).toBeChecked()
})

it('restores the last learning preference for display without treating it as live authorization', async () => {
  const { WorkspaceRestoreProvider } = await import('../lib/workspace-restore')
  const api = createFakeApi({ playbackPreferences: async () => ({ enabled: true, revision: 1 }) })
  const live = new PlaybackController(api, {} as MusicKitClient, 'settings-cache-test')
  controllers.push(live)
  await live.initialize()
  const props = { api, userName: 'Listener', signInMethod: 'google', onAccount: vi.fn(), onMemories: vi.fn(), onSignOut: vi.fn() }
  const view = render(<WorkspaceRestoreProvider userId="settings-cache-test" restoring={false}><AppSettings {...props} playback={live}/></WorkspaceRestoreProvider>)
  expect(screen.getByRole('checkbox', { name: /Learn from my listening/ })).toBeChecked()
  view.unmount()
  const failedApi = createFakeApi({ playbackPreferences: async () => { throw new Error('offline') } })
  const pending = new PlaybackController(failedApi, {} as MusicKitClient, 'settings-cache-test')
  controllers.push(pending)
  const restored = render(<WorkspaceRestoreProvider userId="settings-cache-test" restoring><AppSettings {...props} playback={pending}/></WorkspaceRestoreProvider>)
  expect(screen.getByRole('checkbox', { name: /Learn from my listening/ })).toBeChecked()
  expect(screen.getByRole('checkbox', { name: /Learn from my listening/ })).toBeDisabled()
  expect(screen.queryByText('Listening preferences are unavailable.')).not.toBeInTheDocument()
  await act(async () => pending.initialize())
  restored.rerender(<WorkspaceRestoreProvider userId="settings-cache-test" restoring={false}><AppSettings {...props} playback={pending}/></WorkspaceRestoreProvider>)
  expect(screen.getByRole('checkbox', { name: /Learn from my listening/ })).toBeDisabled()
  expect(screen.getByText('Listening preferences are unavailable.')).toBeInTheDocument()
  sessionStorage.clear()
})
