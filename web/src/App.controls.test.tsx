import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
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
  const title = await screen.findAllByRole('button', { name: 'Rename Blue hour, windows down' })
  fireEvent.click(title[0])
  fireEvent.change(screen.getByRole('textbox', { name: 'Mix name' }), { target: { value: 'My new name' } })
  fireEvent.keyDown(screen.getByRole('textbox', { name: 'Mix name' }), { key: 'Enter' })
  await screen.findAllByRole('button', { name: 'Rename My new name' })
  await act(async () => resolve(old))
  expect(screen.queryByRole('button', { name: 'Rename Blue hour, windows down' })).not.toBeInTheDocument()
  expect(screen.getAllByRole('button', { name: 'Rename My new name' })).toHaveLength(2)
})

it('archives and restores metadata without sending queue operations', async () => {
  const { api } = renderApp()
  await screen.findByRole('button', { name: 'Tape options' })
  fireEvent.click(screen.getByRole('button', { name: 'Tape options' }))
  fireEvent.click(screen.getByRole('button', { name: 'Archive' }))
  fireEvent.click(await screen.findByRole('button', { name: 'Undo' }))
  await screen.findAllByRole('button', { name: 'Open Blue hour, windows down' })
  const writes = api.calls.filter((c) => c.method === 'updateSession')
  expect(writes).toHaveLength(2)
  expect(api.calls.filter((c) => c.method === 'applyQueueOps')).toHaveLength(0)
})
