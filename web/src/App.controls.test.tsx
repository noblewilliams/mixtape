import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { App } from './App'
import type { SessionDetailResponse } from './api/client'
import type { AccountBridge } from './components/AccountDialog'
import type { MusicKitClient } from './musickit/client'
import { ApiError } from './api/client'
import { createFakeApi } from './test/fake-api'

// Whole-app renders run long on a loaded machine; the default 5 s is too tight there.
vi.setConfig({ testTimeout: 15_000 })

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
    playAlbum: vi.fn(async () => undefined),
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

it('deletes ticked mixes from Mixes in one call, drops their rows and says so', async () => {
  const { api } = renderApp()
  fireEvent.click(await screen.findByRole('button', { name: 'Mixes' }))
  fireEvent.click(await screen.findByRole('button', { name: 'Select' }))
  fireEvent.click(screen.getByRole('checkbox', { name: 'Sunday kitchen radio' }))
  fireEvent.click(screen.getByRole('checkbox', { name: 'Soft landing after work' }))
  fireEvent.click(within(screen.getByRole('toolbar', { name: 'Selected mixes' })).getByRole('button', { name: 'Delete' }))
  fireEvent.click(within(screen.getByRole('alertdialog', { name: 'Delete 2 mixes?' })).getByRole('button', { name: 'Delete 2 mixes' }))
  expect(await screen.findByText('2 mixes deleted')).toBeInTheDocument()
  expect(api.calls.filter((c) => c.method === 'deleteSessions').map((c) => c.args[0])).toEqual([['sunday-kitchen', 'soft-landing']])
  expect(screen.queryByRole('button', { name: 'Open Sunday kitchen radio' })).not.toBeInTheDocument()
  expect(screen.queryByRole('button', { name: 'Open Soft landing after work' })).not.toBeInTheDocument()
  expect(screen.queryByRole('checkbox')).not.toBeInTheDocument()
})

it('archives ticked mixes from Mixes in parallel', async () => {
  const { api } = renderApp()
  fireEvent.click(await screen.findByRole('button', { name: 'Mixes' }))
  fireEvent.click(await screen.findByRole('button', { name: 'Select' }))
  fireEvent.click(screen.getByRole('checkbox', { name: 'Sunday kitchen radio' }))
  fireEvent.click(screen.getByRole('checkbox', { name: 'Soft landing after work' }))
  fireEvent.click(within(screen.getByRole('toolbar', { name: 'Selected mixes' })).getByRole('button', { name: 'Archive' }))
  await waitFor(() => expect(screen.queryByRole('checkbox')).not.toBeInTheDocument())
  const writes = api.calls.filter((c) => c.method === 'updateSession')
  expect(writes.map((c) => c.args.slice(0, 2))).toEqual([['sunday-kitchen', { status: 'archived' }], ['soft-landing', { status: 'archived' }]])
  expect(screen.queryByRole('button', { name: 'Open Sunday kitchen radio' })).not.toBeInTheDocument()
})

it('asks for sign-in when the server refuses a delete with sign_in_required', async () => {
  const api = createFakeApi({ deleteSessions: async () => { throw new ApiError(403, { error: 'sign_in_required' }) } })
  renderApp({ api })
  fireEvent.click(await screen.findByRole('button', { name: 'Mixes' }))
  fireEvent.click(await screen.findByRole('button', { name: 'Select' }))
  fireEvent.click(screen.getByRole('checkbox', { name: 'Sunday kitchen radio' }))
  fireEvent.click(within(screen.getByRole('toolbar', { name: 'Selected mixes' })).getByRole('button', { name: 'Delete' }))
  fireEvent.click(within(screen.getByRole('alertdialog', { name: 'Delete this mix?' })).getByRole('button', { name: 'Delete mix' }))
  expect(await screen.findByRole('alertdialog', { name: 'Sign in to delete mixes' })).toBeInTheDocument()
  expect(screen.getByRole('checkbox', { name: 'Sunday kitchen radio', hidden: true })).toBeChecked()
})

it('warns about share links for a mix the list says is shared, without opening it', async () => {
  const base = createFakeApi()
  const list = base.listSessions
  const api = { ...base, listSessions: async () => {
    const result = await list()
    return { sessions: result.sessions.map((s) => ({ ...s, shared: s.id === 'sunday-kitchen' })) }
  } } as typeof base
  renderApp({ api })
  fireEvent.click(await screen.findByRole('button', { name: 'Mixes' }))
  fireEvent.click(await screen.findByRole('button', { name: 'Select' }))
  fireEvent.click(screen.getByRole('checkbox', { name: 'Sunday kitchen radio' }))
  fireEvent.click(within(screen.getByRole('toolbar', { name: 'Selected mixes' })).getByRole('button', { name: 'Delete' }))
  expect(screen.getByRole('alertdialog', { name: 'Delete this mix?' })).toHaveTextContent('Their share links will stop working.')
})

it('deletes in batches of 100 and counts only what the server deleted', async () => {
  const base = createFakeApi()
  const batches: string[][] = []
  const api = { ...base, deleteSessions: async (ids: string[]) => {
    batches.push(ids)
    return { deleted: ids.filter((id) => id !== 'soft-landing') }
  } } as typeof base
  renderApp({ api })
  fireEvent.click(await screen.findByRole('button', { name: 'Mixes' }))
  fireEvent.click(await screen.findByRole('button', { name: 'Select' }))
  fireEvent.click(screen.getByRole('checkbox', { name: 'Sunday kitchen radio' }))
  fireEvent.click(screen.getByRole('checkbox', { name: 'Soft landing after work' }))
  fireEvent.click(within(screen.getByRole('toolbar', { name: 'Selected mixes' })).getByRole('button', { name: 'Delete' }))
  fireEvent.click(within(screen.getByRole('alertdialog', { name: 'Delete 2 mixes?' })).getByRole('button', { name: 'Delete 2 mixes' }))
  // Soft landing was already gone (another device): it leaves the list too, but isn't counted.
  expect(await screen.findByText('Mix deleted')).toBeInTheDocument()
  expect(screen.queryByRole('button', { name: 'Open Soft landing after work' })).not.toBeInTheDocument()
  expect(batches).toEqual([['sunday-kitchen', 'soft-landing']])
})
