import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { App } from './App'
import type { MixtapeApi } from './api/client'
import type { MusicKitClient } from './musickit/client'
import { WorkspaceRestoreProvider } from './lib/workspace-restore'
import { createFakeApi } from './test/fake-api'

const user = { id: 'restore-user', name: 'Noble', email: 'noble@example.com' }
const musicKit: MusicKitClient = {
  connect: vi.fn(async () => undefined),
  snapshot: vi.fn(async () => ({ storefront: 'ng', songs: [], playlists: [], playlistEntries: [], recentCatalogIds: [], excludedLibrarySongs: 0 })),
  play: vi.fn(async () => undefined),
  pause: vi.fn(async () => undefined),
  createPlaylist: vi.fn(async () => undefined),
}
const accountAuth = {
  listAccounts: vi.fn(async () => [{ id: 'apple-account', providerId: 'apple' }]),
  linkProvider: vi.fn(async () => ({})),
  unlinkAccount: vi.fn(async () => ({})),
}
function workspace(api: MixtapeApi, restoring = false) {
  return <WorkspaceRestoreProvider userId={user.id} restoring={restoring}>
    <App api={api} accountAuth={accountAuth} lastSignInProvider="apple" musicKit={musicKit} user={user} onSignOut={vi.fn()} />
  </WorkspaceRestoreProvider>
}
function pending<T>() {
  let resolve!: (value: T) => void
  const promise = new Promise<T>(r => { resolve = r })
  return { resolve, promise }
}

afterEach(() => { cleanup(); sessionStorage.clear(); localStorage.clear() })

describe('workspace page restoration', () => {
  it('keeps the selected mix and cached conversation visible through refresh, then revalidates it', async () => {
    const original = createFakeApi()
    const first = render(workspace(original))
    fireEvent.click(await screen.findByRole('button', { name: 'Mixes' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Open Blue hour, windows down' }))
    await screen.findByText(/I kept the opening close/)
    first.unmount()

    const collection = pending<Awaited<ReturnType<MixtapeApi['listSessions']>>>()
    const detail = pending<Awaited<ReturnType<MixtapeApi['getSession']>>>()
    const getSession = vi.fn(() => detail.promise)
    const refreshed = createFakeApi({ listSessions: () => collection.promise, getSession })
    const second = render(workspace(refreshed, true))
    expect(screen.getByRole('heading', { name: 'Blue hour, windows down' })).toBeVisible()
    expect(screen.getByText(/I kept the opening close/)).toBeVisible()
    expect(screen.getByText('Sweetest Taboo')).toBeVisible()
    expect(screen.getByRole('button', { name: 'Mixes' })).toHaveAttribute('aria-current', 'page')
    expect(getSession).not.toHaveBeenCalled()

    second.rerender(workspace(refreshed, false))
    await waitFor(() => expect(getSession).toHaveBeenCalledWith('blue-hour'))
    expect(screen.getByText(/I kept the opening close/)).toBeVisible()
    const fresh = await original.getSession('blue-hour')
    fresh.messages[1].content = 'Fresh conversation from the server.'
    await act(async () => {
      detail.resolve(fresh)
      collection.resolve(await original.listSessions())
    })
    expect(screen.getByText('Fresh conversation from the server.')).toBeVisible()
  })

  it.each(['message', 'queue edit'] as const)('ignores stale refreshed detail after a %s', async action => {
    const original = createFakeApi()
    const first = render(workspace(original))
    fireEvent.click(await screen.findByRole('button', { name: 'Mixes' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Open Blue hour, windows down' }))
    await screen.findByText(/I kept the opening close/)
    first.unmount()

    const stale = await original.getSession('blue-hour')
    const detail = pending<Awaited<ReturnType<MixtapeApi['getSession']>>>()
    const getSession = vi.fn(original.getSession).mockImplementationOnce(() => detail.promise)
    render(workspace(createFakeApi({ getSession })))
    await waitFor(() => expect(getSession).toHaveBeenCalledWith('blue-hour'))
    if (action === 'message') {
      fireEvent.change(screen.getByLabelText('Message your DJ'), { target: { value: 'Make the middle brighter.' } })
      fireEvent.click(screen.getByRole('button', { name: 'Send message' }))
      await screen.findByText(/reshaped the middle around that feeling/)
    } else {
      fireEvent.keyDown(screen.getByRole('button', { name: 'Move Sweetest Taboo, track 1' }), { key: 'ArrowDown' })
      await waitFor(() => expect(document.querySelector('.track-row .track-copy strong')).toHaveTextContent('Essence'))
    }
    await act(async () => detail.resolve(stale))
    if (action === 'message') {
      expect(screen.getByText('Make the middle brighter.')).toBeVisible()
      expect(screen.getByText(/reshaped the middle around that feeling/)).toBeVisible()
    } else {
      expect(document.querySelector('.track-row .track-copy strong')).toHaveTextContent('Essence')
    }
  })

  it('restores Library Sources instead of returning to Home', async () => {
    const first = render(workspace(createFakeApi()))
    fireEvent.click(await screen.findByRole('button', { name: 'Library' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Sources' }))
    await waitFor(() => expect(screen.getByRole('button', { name: 'Connect Apple Music' })).toBeEnabled())
    first.unmount()
    render(workspace(createFakeApi()))
    expect(screen.getByRole('heading', { name: 'Library' })).toBeVisible()
    expect(screen.getByRole('button', { name: 'Sources' })).toHaveAttribute('aria-current', 'page')
    expect(screen.getByRole('button', { name: 'Library' })).toHaveAttribute('aria-current', 'page')
  })

  it('restores the Mixes archive and closet selection', async () => {
    const first = render(workspace(createFakeApi()))
    fireEvent.click(await screen.findByRole('button', { name: 'Mixes' }))
    await screen.findByRole('button', { name: 'Open Blue hour, windows down' })
    fireEvent.click(screen.getByRole('button', { name: 'Closet view' }))
    fireEvent.click(screen.getByRole('button', { name: 'Archived' }))
    first.unmount()
    render(workspace(createFakeApi({ listSessions: () => new Promise(() => undefined) })))
    expect(screen.getByRole('heading', { level: 1, name: 'Mixes' })).toBeVisible()
    expect(screen.getByRole('button', { name: 'Archived' })).toHaveAttribute('aria-current', 'page')
    expect(screen.getByRole('button', { name: 'Closet view' })).toHaveAttribute('aria-pressed', 'true')
    expect(screen.getByRole('status', { name: 'Loading mixes' }).querySelectorAll('.rack-ghost')).toHaveLength(3)
  })

  it('restores the grid view and survives an unknown stored view', async () => {
    const first = render(workspace(createFakeApi()))
    fireEvent.click(await screen.findByRole('button', { name: 'Mixes' }))
    await screen.findByRole('button', { name: 'Open Blue hour, windows down' })
    fireEvent.click(screen.getByRole('button', { name: 'Grid view' }))
    first.unmount()
    const second = render(workspace(createFakeApi()))
    expect(await screen.findByRole('region', { name: 'Mix grid' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Grid view' })).toHaveAttribute('aria-pressed', 'true')
    second.unmount()
    for (let i = 0; i < sessionStorage.length; i++) {
      const key = sessionStorage.key(i)!
      if (key.endsWith(':collectionView')) sessionStorage.setItem(key, JSON.stringify('shelf'))
    }
    render(workspace(createFakeApi()))
    expect(await screen.findByRole('region', { name: 'Tape list' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'List view' })).toHaveAttribute('aria-pressed', 'true')
  })
})
