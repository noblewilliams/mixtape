import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { WorkspaceRestoreProvider } from '../lib/workspace-restore'
import { createFakeApi } from '../test/fake-api'
import { PlaybackController } from '../playback/controller'
import type { MusicKitClient } from '../musickit/client'
import type { MixtapeApi } from '../api/client'
import { AppSettings } from './AppSettings'
import { HomeComposer } from './HomeComposer'
import { MemoryControls } from './MemoryControls'
import { RoutineSuggestions } from './RoutineSuggestions'

afterEach(() => { cleanup(); sessionStorage.clear() })
const suggestion = { id: 'moment', title: 'An easy evening', prompt: 'Make a gentle mix', reason: 'From recent listening' }
function content(api: MixtapeApi, playback: PlaybackController, restoring: boolean) {
  return <WorkspaceRestoreProvider userId="restore-listener" restoring={restoring}>
    <HomeComposer onSubmit={vi.fn()} transcribe={vi.fn()} />
    <RoutineSuggestions api={api} onCreate={vi.fn()} />
    <MemoryControls api={api} onClose={vi.fn()} onSessionExpired={vi.fn()} />
    <AppSettings api={api} playback={playback} userName="Listener" signInMethod="google" onAccount={vi.fn()} onMemories={vi.fn()} onSignOut={vi.fn()} />
  </WorkspaceRestoreProvider>
}

it('restores the visible Home and Settings content without restoring a destructive confirmation or fetching before auth', async () => {
  const api = createFakeApi({
    getSuggestions: async () => ({ enabled: true, suggestion, dismissed: false }),
    listMemories: async () => ({ memories: [{ id: 'note', note: 'Gentle mornings', createdAt: '2026-09-08' }] }),
  })
  const playback = new PlaybackController(api, {} as MusicKitClient, 'restore-listener')
  await playback.initialize()
  const first = render(content(api, playback, false))
  await screen.findByText(suggestion.title)
  await screen.findByText('Gentle mornings')
  await waitFor(() => expect(screen.getByRole('checkbox', { name: /Recommend mixes/ })).toBeChecked())
  fireEvent.change(screen.getByRole('textbox', { name: 'Describe your mix' }), { target: { value: 'A quiet drive home' } })
  fireEvent.click(screen.getByRole('button', { name: 'Forget' }))
  expect(screen.getByRole('alertdialog')).toBeInTheDocument()
  first.unmount()

  const getSuggestions = vi.fn(() => new Promise<never>(() => {}))
  const listMemories = vi.fn(() => new Promise<never>(() => {}))
  const pendingApi = createFakeApi({ getSuggestions, listMemories })
  const restored = render(content(pendingApi, playback, true))
  expect(screen.getByRole('textbox', { name: 'Describe your mix' })).toHaveValue('A quiet drive home')
  expect(screen.getByText(suggestion.title)).toBeInTheDocument()
  expect(screen.getByText('Gentle mornings')).toBeInTheDocument()
  expect(screen.getByRole('checkbox', { name: /Recommend mixes/ })).toBeChecked()
  expect(screen.getByRole('checkbox', { name: /Recommend mixes/ })).toBeDisabled()
  expect(screen.queryByRole('alertdialog')).not.toBeInTheDocument()
  expect(getSuggestions).not.toHaveBeenCalled()
  expect(listMemories).not.toHaveBeenCalled()

  restored.rerender(content(pendingApi, playback, false))
  await waitFor(() => expect(getSuggestions).toHaveBeenCalledTimes(2))
  expect(listMemories).toHaveBeenCalledTimes(1)
  expect(screen.getByText(suggestion.title)).toBeInTheDocument()
  expect(screen.getByText('Gentle mornings')).toBeInTheDocument()
  expect(screen.getByRole('checkbox', { name: /Recommend mixes/ })).toBeChecked()
  restored.unmount()
  playback.dispose()
})
