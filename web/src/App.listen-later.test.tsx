import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { App } from './App'
import type { MixtapeApi } from './api/client'
import type { AccountBridge } from './components/AccountDialog'
import { demoShelfPreviewEntries } from './data/demo'
import type { MusicKitClient } from './musickit/client'
import { createFakeApi } from './test/fake-api'
import { WorkspaceRestoreProvider } from './lib/workspace-restore'

// Whole-app renders run long on a loaded machine; the default 5 s is too tight there.
vi.setConfig({ testTimeout: 15_000 })

const user = { id: 'user-1', name: 'Noble', email: 'noble@example.com' }
const accountAuth: AccountBridge = {
  listAccounts: vi.fn(async () => []),
  linkProvider: vi.fn(async () => ({})),
  unlinkAccount: vi.fn(async () => ({})),
}
const harbour = demoShelfPreviewEntries[3]

function createFakeMusicKit(): MusicKitClient {
  return {
    connect: vi.fn(async () => undefined),
    snapshot: vi.fn(async () => ({ storefront: 'ng', songs: [], playlists: [], playlistEntries: [], recentCatalogIds: [], excludedLibrarySongs: 0 })),
    play: vi.fn(async () => undefined),
    playAlbum: vi.fn(async () => undefined),
    pause: vi.fn(async () => undefined),
    createPlaylist: vi.fn(async () => undefined),
  }
}

function renderApp(api = createFakeApi({}, { listenLater: demoShelfPreviewEntries }), who: typeof user & { isAnonymous?: boolean } = user) {
  const musicKit = createFakeMusicKit()
  const view = render(<WorkspaceRestoreProvider userId={who.id} restoring={false}>
    <App api={api} accountAuth={accountAuth} lastSignInProvider="apple" musicKit={musicKit} user={who} onSignOut={vi.fn()} />
  </WorkspaceRestoreProvider>)
  return { api, musicKit, view }
}

const callsOf = (api: ReturnType<typeof createFakeApi>, method: keyof MixtapeApi) => api.calls.filter((call) => call.method === method)
const shelf = () => screen.getByRole('list', { name: 'Listen later' })
const titles = () => within(shelf()).getAllByRole('listitem').map((item) => item.querySelector('strong')?.textContent)

async function openShelf() {
  fireEvent.click(await screen.findByRole('button', { name: 'Mixes' }))
  fireEvent.click(await screen.findByRole('button', { name: 'Listen later' }))
  await screen.findByRole('list', { name: 'Listen later' })
}

function menuAction(title: string, action: string) {
  fireEvent.click(screen.getByRole('button', { name: `Album actions for ${title}` }))
  fireEvent.click(within(screen.getByRole('group', { name: 'Album actions' })).getByRole('button', { name: action }))
}

describe('Listen later in Mixes', () => {
  beforeEach(() => localStorage.clear())
  afterEach(() => {
    cleanup()
    sessionStorage.clear()
  })

  it('loads the shelf when the tab opens and draws its rows', async () => {
    const { api } = renderApp()
    await openShelf()
    expect(callsOf(api, 'listListenLater')).toHaveLength(1)
    expect(titles()).toEqual(demoShelfPreviewEntries.map((entry) => entry.title))
    expect(screen.getByText('4 albums saved · 2 listened')).toBeInTheDocument()
  })

  it('removes a row with an Undo toast, and Undo saves it back', async () => {
    const { api } = renderApp()
    await openShelf()
    menuAction(harbour.title, 'Remove')
    expect(screen.queryByText(harbour.title)).toBeNull()
    await waitFor(() => expect(callsOf(api, 'unsaveForLater')).toHaveLength(1))
    expect(callsOf(api, 'unsaveForLater')[0].args[0]).toBe(harbour.id)
    const toast = (await screen.findByText('Removed from Listen later.')).closest('.toast') as HTMLElement
    expect(screen.getByText('3 albums saved · 2 listened')).toBeInTheDocument()
    fireEvent.click(within(toast).getByRole('button', { name: 'Undo' }))
    await waitFor(() => expect(callsOf(api, 'saveForLater')).toHaveLength(1))
    expect(callsOf(api, 'saveForLater')[0].args.slice(0, 2)).toEqual([harbour.id, undefined])
    expect(await screen.findByText(harbour.title)).toBeInTheDocument()
    expect(screen.getByText('4 albums saved · 2 listened')).toBeInTheDocument()
  })

  it('rolls a failed removal back', async () => {
    renderApp(createFakeApi({ unsaveForLater: async () => { throw new Error('offline') } }, { listenLater: demoShelfPreviewEntries }))
    await openShelf()
    menuAction(harbour.title, 'Remove')
    expect(await screen.findByText('Couldn’t remove this album. Try again.')).toBeInTheDocument()
    expect(titles()).toEqual(demoShelfPreviewEntries.map((entry) => entry.title))
  })

  it('marks a row listened and moves it under Listened', async () => {
    const { api } = renderApp()
    await openShelf()
    menuAction('Slow Rooms', 'Mark listened')
    await waitFor(() => expect(callsOf(api, 'markListened')).toHaveLength(1))
    expect(callsOf(api, 'markListened')[0].args[0]).toBe(demoShelfPreviewEntries[2].id)
    expect(titles()).toEqual(['Low Tide Hours', 'Kitchen Radio Sessions', harbour.title, 'Slow Rooms', 'Nightshift Radio', 'Harbour Lights'])
    expect(screen.getByText('Slow Rooms').closest('.shelf-row')).toHaveClass('shelf-row--listened')
    expect(screen.getByText('3 albums saved · 3 listened')).toBeInTheDocument()
  })

  it('moves a row back when marking it fails', async () => {
    renderApp(createFakeApi({ markListened: async () => { throw new Error('offline') } }, { listenLater: demoShelfPreviewEntries }))
    await openShelf()
    menuAction('Slow Rooms', 'Mark listened')
    expect(await screen.findByText('Couldn’t mark this album. Try again.')).toBeInTheDocument()
    expect(titles()).toEqual(demoShelfPreviewEntries.map((entry) => entry.title))
  })

  it('plays a row by its Apple id', async () => {
    const { musicKit } = renderApp()
    await openShelf()
    fireEvent.click(screen.getByRole('button', { name: 'Play Slow Rooms' }))
    await waitFor(() => expect(musicKit.playAlbum).toHaveBeenCalledWith(demoShelfPreviewEntries[2].appleId))
  })

  it('opens Home with Album selected from the empty shelf', async () => {
    renderApp(createFakeApi())
    fireEvent.click(await screen.findByRole('button', { name: 'Mixes' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Listen later' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Find an album' }))
    expect(await screen.findByRole('heading', { level: 1, name: 'Home' })).toBeInTheDocument()
    expect(screen.getByRole('radio', { name: 'Album' })).toHaveAttribute('aria-checked', 'true')
    expect(screen.queryByText('Switched to Album for this prompt.', { exact: false })).toBeNull()
    // The seed is spent: coming back to Home later starts on Mix again.
    fireEvent.click(screen.getByRole('button', { name: 'Mixes' }))
    fireEvent.click(screen.getByRole('button', { name: 'Home' }))
    expect(await screen.findByRole('radio', { name: 'Mix' })).toHaveAttribute('aria-checked', 'true')
  })

  it('has no Listen later tab when album picks are off', async () => {
    const api = createFakeApi({ getMe: async () => ({ user: { id: 'listener-1', isAnonymous: false }, merged: null, albumPicks: false }) }, { listenLater: demoShelfPreviewEntries })
    renderApp(api)
    await waitFor(() => expect(callsOf(api, 'getMe')).toHaveLength(1))
    fireEvent.click(await screen.findByRole('button', { name: 'Mixes' }))
    await act(async () => { await new Promise((resolve) => setTimeout(resolve, 0)) })
    expect(screen.queryByRole('button', { name: 'Listen later' })).toBeNull()
    expect(callsOf(api, 'listListenLater')).toHaveLength(0)
  })

  it('never shows the shelf to an anonymous listener, whatever the server flag says', async () => {
    const api = createFakeApi({}, { listenLater: demoShelfPreviewEntries })
    renderApp(api, { ...user, isAnonymous: true })
    fireEvent.click(await screen.findByRole('button', { name: 'Mixes' }))
    const tabs = await screen.findByRole('navigation', { name: 'Mix sections' })
    await act(async () => { await new Promise((resolve) => setTimeout(resolve, 0)) })
    expect(within(tabs).getAllByRole('button').map((button) => button.textContent)).toEqual(['Active', 'Archived'])
    expect(callsOf(api, 'listListenLater')).toHaveLength(0)
  })

  it('restores a stored Listen later tab', async () => {
    const { view } = renderApp()
    await openShelf()
    view.unmount()
    const { api } = renderApp()
    await waitFor(() => expect(screen.getByRole('button', { name: 'Listen later' })).toHaveAttribute('aria-current', 'page'))
    expect(await screen.findByRole('list', { name: 'Listen later' })).toBeInTheDocument()
    expect(callsOf(api, 'listListenLater')).toHaveLength(1)
  })

  it('opens Mixes on Active from the sidebar', async () => {
    renderApp()
    await openShelf()
    fireEvent.click(screen.getByRole('button', { name: 'Home' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Mixes' }))
    expect(await screen.findByRole('button', { name: 'Active' })).toHaveAttribute('aria-current', 'page')
    expect(screen.queryByRole('list', { name: 'Listen later' })).toBeNull()
  })

  it('keeps the rows on screen when a later refresh fails', async () => {
    const base = createFakeApi({}, { listenLater: demoShelfPreviewEntries })
    let reads = 0
    const api = createFakeApi({
      listListenLater: async (signal) => {
        reads += 1
        if (reads > 1) throw new Error('offline')
        return base.listListenLater(signal)
      },
    })
    renderApp(api)
    await openShelf()
    fireEvent.click(screen.getByRole('button', { name: 'Active' }))
    fireEvent.click(screen.getByRole('button', { name: 'Listen later' }))
    await waitFor(() => expect(reads).toBe(2))
    await act(async () => { await new Promise((resolve) => setTimeout(resolve, 0)) })
    expect(titles()).toEqual(demoShelfPreviewEntries.map((entry) => entry.title))
    expect(screen.queryByText('Couldn’t load your shelf')).toBeNull()
  })

  it('waits for a pending request instead of dropping a second action on the row', async () => {
    let settle: () => void = () => {}
    const api = createFakeApi({ markListened: () => new Promise((_, reject) => { settle = () => reject(new Error('offline')) }) }, { listenLater: demoShelfPreviewEntries })
    renderApp(api)
    await openShelf()
    menuAction('Slow Rooms', 'Mark listened')
    fireEvent.click(screen.getByRole('button', { name: 'Album actions for Slow Rooms' }))
    expect(within(screen.getByRole('group', { name: 'Album actions' })).getByRole('button', { name: 'Remove' })).toBeDisabled()
    await act(async () => { settle() })
    expect(await screen.findByText('Couldn’t mark this album. Try again.')).toBeInTheDocument()
    expect(within(screen.getByRole('group', { name: 'Album actions' })).getByRole('button', { name: 'Remove' })).toBeEnabled()
  })

  it('opens an unknown stored tab on Active', async () => {
    sessionStorage.setItem('mixtape.workspace.v1:user-1:activeView', JSON.stringify('mixes'))
    sessionStorage.setItem('mixtape.workspace.v1:user-1:mixesTab', JSON.stringify('shelf'))
    renderApp()
    expect(await screen.findByRole('button', { name: 'Active' })).toHaveAttribute('aria-current', 'page')
  })
})
