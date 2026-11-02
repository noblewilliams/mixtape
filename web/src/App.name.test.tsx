import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { App } from './App'
import type { MeResponse, MergedMode } from './api/client'
import type { AccountBridge } from './components/AccountDialog'
import type { AuthUser } from './components/AuthGate'
import type { AuthPreferenceStore } from './lib/auth-provider'
import type { MusicKitClient } from './musickit/client'
import { createFakeApi } from './test/fake-api'

vi.setConfig({ testTimeout: 15_000 })

const unnamed: AuthUser = { id: 'user-1', name: '', email: 'ada@example.com' }
const named: AuthUser = { id: 'user-2', name: 'Ada', email: 'ada@example.com' }
const anonymous: AuthUser = { id: 'anon-1', name: 'Listener', email: 'anon-1@anonymous.mixtape.invalid', isAnonymous: true }

function deferred<T>() {
  let resolve!: (value: T) => void
  let reject!: (error: Error) => void
  const promise = new Promise<T>((done, fail) => { resolve = done; reject = fail })
  return { promise, resolve, reject }
}

function musicKit(): MusicKitClient {
  return {
    connect: vi.fn(async () => undefined),
    snapshot: vi.fn(async () => ({ storefront: 'ng', songs: [], playlists: [], playlistEntries: [], recentCatalogIds: [], excludedLibrarySongs: 0 })),
    play: vi.fn(async () => undefined),
    playAlbum: vi.fn(async () => undefined),
    pause: vi.fn(async () => undefined),
    createPlaylist: vi.fn(async () => undefined),
  }
}

const preferences: AuthPreferenceStore = { lastUsed: () => null, begin: vi.fn(), promotePending: () => null, clearPending: vi.fn(), forget: vi.fn() }

const me = (askName: boolean, merged: MergedMode | null = null, id = unnamed.id): MeResponse =>
  ({ user: { id, isAnonymous: false }, merged, albumPicks: false, neverRefuse: false, askName })

type Options = {
  user?: AuthUser
  getMe?: () => Promise<MeResponse>
  updateName?: AccountBridge['updateName']
  markNamePrompted?: AccountBridge['markNamePrompted']
}

function renderApp(options: Options = {}) {
  const getMe = vi.fn(options.getMe ?? (async () => me(true)))
  const api = createFakeApi({ getMe })
  const accountAuth: AccountBridge = {
    listAccounts: vi.fn(async () => []),
    linkProvider: vi.fn(async () => ({})),
    unlinkAccount: vi.fn(async () => ({})),
    updateName: options.updateName ?? vi.fn(async () => undefined),
    markNamePrompted: options.markNamePrompted ?? vi.fn(async () => undefined),
  }
  const refetchSession = vi.fn(async () => undefined)
  const view = render(
    <App
      api={api}
      accountAuth={accountAuth}
      lastSignInProvider={null}
      musicKit={musicKit()}
      user={options.user ?? unnamed}
      onSignOut={vi.fn()}
      signInAuth={{ signIn: vi.fn(async () => ({})) }}
      signInPreferences={preferences}
      refetchSession={refetchSession}
    />,
  )
  return { api, getMe, accountAuth, refetchSession, view }
}

const namePage = () => screen.queryByRole('heading', { level: 1, name: 'What should we call you?' })
const hold = () => screen.queryByTestId('name-page-hold')
const shell = () => document.querySelector('.app-shell')!

beforeEach(() => {
  sessionStorage.clear()
  localStorage.clear()
  window.history.replaceState(null, '', '/')
})
afterEach(() => {
  cleanup()
  document.title = ''
})

describe('the name page', () => {
  it('covers the workspace from the first paint while GET /me decides, then asks', async () => {
    const answer = deferred<MeResponse>()
    const { getMe } = renderApp({ getMe: () => answer.promise })

    expect(hold()).toBeInTheDocument()
    expect(shell()).toHaveAttribute('inert')
    expect(namePage()).not.toBeInTheDocument()

    await waitFor(() => expect(getMe).toHaveBeenCalledOnce())
    await act(async () => answer.resolve(me(true)))
    expect(namePage()).toBeInTheDocument()
    expect(hold()).not.toBeInTheDocument()
    expect(shell()).toHaveAttribute('inert')
  })

  it('lets the workspace through when GET /me says not to ask, or fails', async () => {
    renderApp({ getMe: async () => me(false) })
    await waitFor(() => expect(hold()).not.toBeInTheDocument())
    expect(namePage()).not.toBeInTheDocument()
    expect(shell()).not.toHaveAttribute('inert')

    cleanup()
    renderApp({ getMe: async () => { throw new Error('offline') } })
    await waitFor(() => expect(hold()).not.toBeInTheDocument())
    expect(namePage()).not.toBeInTheDocument()
  })

  it('never holds a listener whose session already carries a usable name', async () => {
    renderApp({ user: named, getMe: async () => me(false, null, named.id) })
    expect(hold()).not.toBeInTheDocument()
    expect(shell()).not.toHaveAttribute('inert')
  })

  it('still asks a named session when the server says so', async () => {
    renderApp({ user: named, getMe: async () => me(true, null, named.id) })
    expect(await screen.findByRole('heading', { level: 1, name: 'What should we call you?' })).toBeInTheDocument()
  })

  it('is never shown to an anonymous listener', async () => {
    const { getMe } = renderApp({ user: anonymous, getMe: async () => me(true, null, anonymous.id) })
    expect(hold()).not.toBeInTheDocument()
    await screen.findByRole('heading', { name: 'Home' })
    await new Promise((resolve) => setTimeout(resolve, 0))
    expect(getMe).not.toHaveBeenCalled()
    expect(namePage()).not.toBeInTheDocument()
  })

  it('Continue writes the name and the flag, re-reads the session, then opens the workspace', async () => {
    const { accountAuth, refetchSession } = renderApp()
    await screen.findByRole('heading', { level: 1, name: 'What should we call you?' })

    fireEvent.change(screen.getByRole('textbox', { name: 'Your name' }), { target: { value: ' Ada  Okafor ' } })
    fireEvent.click(screen.getByRole('button', { name: 'Continue' }))

    expect(accountAuth.updateName).toHaveBeenCalledWith('Ada Okafor')
    await waitFor(() => expect(namePage()).not.toBeInTheDocument())
    expect(refetchSession).toHaveBeenCalled()
    expect(shell()).not.toHaveAttribute('inert')
    expect(accountAuth.markNamePrompted).not.toHaveBeenCalled()
  })

  it('Skip writes only the flag and moves on, even when that write fails', async () => {
    const markNamePrompted = vi.fn(async () => { throw new Error('offline') })
    const { accountAuth } = renderApp({ markNamePrompted })
    await screen.findByRole('heading', { level: 1, name: 'What should we call you?' })

    fireEvent.click(screen.getByRole('button', { name: 'Skip' }))

    expect(markNamePrompted).toHaveBeenCalledOnce()
    expect(accountAuth.updateName).not.toHaveBeenCalled()
    await waitFor(() => expect(namePage()).not.toBeInTheDocument())
    expect(shell()).not.toHaveAttribute('inert')
  })

  it('does not hold the next launch once this browser saw it answered', async () => {
    renderApp()
    await screen.findByRole('heading', { level: 1, name: 'What should we call you?' })
    fireEvent.click(screen.getByRole('button', { name: 'Skip' }))
    await waitFor(() => expect(namePage()).not.toBeInTheDocument())
    cleanup()

    renderApp({ getMe: async () => me(false) })
    expect(hold()).not.toBeInTheDocument()
  })

  it('holds the merge notice until the page is answered', async () => {
    renderApp({ getMe: async () => me(true, 'library_kept') })
    await screen.findByRole('heading', { level: 1, name: 'What should we call you?' })
    const notice = 'This account already had a library, so we kept that one.'
    expect(screen.queryByText(notice)).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: 'Skip' }))
    expect(await screen.findByText(notice)).toBeInTheDocument()
  })
})
