import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { App } from './App'
import type { SessionDetailResponse } from './api/client'
import type { AccountBridge } from './components/AccountDialog'
import type { MusicKitClient } from './musickit/client'
import { createFakeApi } from './test/fake-api'

const user = { id: 'user-1', name: 'Noble', email: 'noble@example.com' }

function createFakeMusicKit(overrides: Partial<MusicKitClient> = {}): MusicKitClient {
  return {
    connect: vi.fn(async () => undefined),
    snapshot: vi.fn(async () => ({
      storefront: 'ng',
      songs: [],
      playlists: [],
      playlistEntries: [],
      recentCatalogIds: [],
      excludedLibrarySongs: 0,
    })),
    play: vi.fn(async () => undefined),
    pause: vi.fn(async () => undefined),
    createPlaylist: vi.fn(async () => undefined),
    ...overrides,
  }
}

function createFakeAccountAuth(): AccountBridge {
  return {
    listAccounts: vi.fn(async () => [{ id: 'apple-account', providerId: 'apple' }]),
    linkProvider: vi.fn(async () => ({})),
    unlinkAccount: vi.fn(async () => ({})),
  }
}

function renderApp(
  options: {
    api?: ReturnType<typeof createFakeApi>
    accountAuth?: AccountBridge
    musicKit?: MusicKitClient
  } = {},
) {
  const api = options.api ?? createFakeApi()
  const accountAuth = options.accountAuth ?? createFakeAccountAuth()
  const musicKit = options.musicKit ?? createFakeMusicKit()
  render(
    <App
      api={api}
      accountAuth={accountAuth}
      lastSignInProvider="apple"
      musicKit={musicKit}
      user={user}
      onSignOut={vi.fn()}
    />,
  )
  return { api, accountAuth, musicKit }
}

afterEach(cleanup)

it('preserves an inline rename when an older session read arrives', async () => {
  const base = createFakeApi()
  const old = await base.getSession('blue-hour')
  let resolve!: (detail: SessionDetailResponse) => void
  const api = createFakeApi({
    getSession: () =>
      new Promise((r) => {
        resolve = r
      }),
  })
  renderApp({ api })
  fireEvent.click(await screen.findByRole('button', { name: 'Open Blue hour, windows down' }))
  const title = await screen.findAllByRole('button', { name: 'Rename Blue hour, windows down' })
  fireEvent.click(title[0])
  fireEvent.change(screen.getByRole('textbox', { name: 'Mix name' }), { target: { value: 'My new name' } })
  fireEvent.keyDown(screen.getByRole('textbox', { name: 'Mix name' }), { key: 'Enter' })
  await screen.findAllByRole('button', { name: 'Rename My new name' })
  await act(async () => resolve(old))
  expect(screen.queryByRole('button', { name: 'Rename Blue hour, windows down' })).not.toBeInTheDocument()
  expect(screen.getAllByRole('button', { name: 'Rename My new name' })).toHaveLength(1)
})

it('archives and restores metadata without sending queue operations', async () => {
  const { api } = renderApp()
  fireEvent.click(await screen.findByRole('button', { name: 'Open Blue hour, windows down' }))
  await screen.findByRole('button', { name: 'Tape options' })
  fireEvent.click(screen.getByRole('button', { name: 'Tape options' }))
  fireEvent.click(screen.getByRole('button', { name: 'Archive' }))
  fireEvent.click(await screen.findByRole('button', { name: 'Undo' }))
  await screen.findAllByRole('button', { name: 'Open Blue hour, windows down' })
  const writes = api.calls.filter((c) => c.method === 'updateSession')
  expect(writes).toHaveLength(2)
  expect(api.calls.filter((c) => c.method === 'applyQueueOps')).toHaveLength(0)
})

it('retains a saved tape colour when a queue reorder returns a new snapshot', async () => {
  const { api } = renderApp()
  fireEvent.click(await screen.findByRole('button', { name: 'Open Blue hour, windows down' }))
  await screen.findByRole('button', { name: 'Move Sweetest Taboo, track 1' })
  fireEvent.click(screen.getByRole('button', { name: 'Tape options' }))
  fireEvent.click(screen.getByRole('button', { name: 'Tape settings' }))
  fireEvent.click(screen.getByRole('button', { name: 'Cherry' }))
  await waitFor(() => expect(screen.getByRole('button', { name: 'Cherry' })).toHaveAttribute('aria-pressed', 'true'))
  fireEvent.click(screen.getByRole('button', { name: 'Done' }))
  fireEvent.keyDown(screen.getByRole('button', { name: 'Move Sweetest Taboo, track 1' }), { key: 'ArrowDown' })
  await waitFor(() => expect(api.calls.some(call => call.method === 'applyQueueOps')).toBe(true))
  fireEvent.click(screen.getByRole('button', { name: 'Mixes' }))
  await waitFor(() => expect((document.querySelector('.home-panel .cassette') as HTMLElement).style.getPropertyValue('--cassette-case')).toBe('#b84755'))
  expect(api.calls.find(call => call.method === 'updateSession')?.args[1]).toEqual({ caseColor: '#b84755' })
})

it('points a failed archive undo at the Archived tab', async () => {
  const base = createFakeApi()
  const update = base.updateSession
  let fail = false
  const api = { ...base, updateSession: vi.fn(async (id: string, changes: Parameters<typeof update>[1]) => { if (fail) throw new Error('offline'); return update(id, changes) }) } as typeof base
  renderApp({ api })
  fireEvent.click(await screen.findByRole('button', { name: 'Open Blue hour, windows down' }))
  fireEvent.click(await screen.findByRole('button', { name: 'Tape options' }))
  fireEvent.click(screen.getByRole('button', { name: 'Archive' }))
  fail = true
  fireEvent.click(await screen.findByRole('button', { name: 'Undo' }))
  expect(await screen.findByText('Couldn’t restore the mix. Open Archived to retry.')).toBeInTheDocument()
})
