import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { App } from './App'
import { AnonymousCapError, type CreateSessionResponse, type MergedMode } from './api/client'
import type { AccountBridge } from './components/AccountDialog'
import type { AuthBridge, AuthUser } from './components/AuthGate'
import { CAP_LINE } from './components/AuthGate'
import { KEEP_SHEET_LINE } from './components/first-run/KeepSheet'
import type { AuthPreferenceStore } from './lib/auth-provider'
import type { MusicKitClient } from './musickit/client'
import { createFakeApi, type FakeApi } from './test/fake-api'
import type { ApiPlaylistSummary } from './api/client'

const kept = () => {
  const raw = sessionStorage.getItem('mixtape.kept-prompt')
  return raw ? JSON.parse(raw) : null
}
const keepRecord = (prompt: string) =>
  sessionStorage.setItem('mixtape.kept-prompt', JSON.stringify({ prompt, inspiration: null, shape: null }))

function deferred<T>() {
  let resolve!: (value: T) => void
  const promise = new Promise<T>((done) => { resolve = done })
  return { promise, resolve }
}

const playlist: ApiPlaylistSummary = {
  id: 'night-bus', name: 'Night bus', source: 'spotify_export', kind: 'user', origin: 'unknown', curatorName: null,
  artworkUrlTemplate: null, artworkBgColor: null, artworkWidth: null, artworkHeight: null, entryCount: 0,
  knownDurationMs: null, durationComplete: false, lastModifiedAt: null, syncedAt: null, inLibrary: true, capability: 'copy_only',
} as ApiPlaylistSummary

const anonymous: AuthUser = { id: 'anon-1', name: 'Listener', email: 'anon-1@anonymous.mixtape.invalid', isAnonymous: true }
const account: AuthUser = { id: 'user-1', name: 'Noble', email: 'noble@example.com' }

function musicKit(): MusicKitClient {
  return {
    connect: vi.fn(async () => undefined),
    snapshot: vi.fn(async () => ({ storefront: 'ng', songs: [], playlists: [], playlistEntries: [], recentCatalogIds: [], excludedLibrarySongs: 0 })),
    play: vi.fn(async () => undefined),
    pause: vi.fn(async () => undefined),
    createPlaylist: vi.fn(async () => undefined),
  }
}

const accountAuth: AccountBridge = {
  listAccounts: vi.fn(async () => []),
  linkProvider: vi.fn(async () => ({})),
  unlinkAccount: vi.fn(async () => ({})),
}

const preferences: AuthPreferenceStore = { lastUsed: () => null, begin: vi.fn(), promotePending: () => null, clearPending: vi.fn() }

type Options = {
  user?: AuthUser
  api?: FakeApi
  initialSession?: CreateSessionResponse
  signIn?: AuthBridge['signIn']
  refetchSession?: () => void
  signInError?: string
}

function renderApp(options: Options = {}) {
  const api = options.api ?? createFakeApi()
  const signIn = options.signIn ?? vi.fn(async () => ({}))
  const refetchSession = options.refetchSession ?? vi.fn()
  const view = render(
    <App
      api={api}
      accountAuth={accountAuth}
      lastSignInProvider={null}
      musicKit={musicKit()}
      user={options.user ?? anonymous}
      onSignOut={vi.fn()}
      initialSession={options.initialSession}
      signInAuth={{ signIn }}
      signInPreferences={preferences}
      refetchSession={refetchSession}
      signInError={options.signInError}
    />,
  )
  return { api, signIn, refetchSession, view }
}

async function mix(queued = true): Promise<CreateSessionResponse> {
  const created = await createFakeApi().createSession('Rainy commute')
  return queued ? created : { ...created, queue: [] }
}

const funnel = (api: FakeApi) =>
  api.calls.filter((call) => call.method === 'postFunnelEvent').map((call) => (call.args[0] as { type: string }).type)

function sendFromHome(prompt: string) {
  fireEvent.change(screen.getByRole('textbox', { name: 'Describe your mix' }), { target: { value: prompt } })
  fireEvent.click(screen.getByRole('button', { name: 'Make a mix' }))
}

const sheet = () => screen.queryByRole('dialog', { name: 'Keep this mix.' })

beforeEach(() => {
  sessionStorage.clear()
  localStorage.clear()
  window.history.replaceState(null, '', '/')
})
afterEach(() => {
  cleanup()
  document.title = ''
})

describe('Keep this mix sheet', () => {
  it('appears after an anonymous listener\'s first mix lands, with one pill and no provider buttons', async () => {
    const { api } = renderApp({ initialSession: await mix() })
    const dialog = await screen.findByRole('dialog', { name: 'Keep this mix.' })
    expect(within(dialog).getByRole('heading', { name: 'Keep this mix.' })).toHaveFocus()
    expect(within(dialog).getByText(KEEP_SHEET_LINE)).toBeInTheDocument()
    expect(within(dialog).getByRole('button', { name: 'Keep this mix' })).toBeInTheDocument()
    expect(within(dialog).getByRole('button', { name: 'Not now' })).toBeInTheDocument()
    expect(within(dialog).queryByRole('button', { name: /Continue with/ })).not.toBeInTheDocument()
    await waitFor(() => expect(funnel(api)).toEqual(['first_mix_made', 'keep_sheet_shown']))
  })

  it('does not appear after a refusal with no queue, and records the refusal once', async () => {
    const { api } = renderApp({ initialSession: await mix(false) })
    await screen.findByRole('heading', { name: 'Rainy commute' })
    expect(sheet()).not.toBeInTheDocument()
    await waitFor(() => expect(funnel(api)).toEqual(['first_mix_refused']))
  })

  it('never appears for an account and posts no first-run events', async () => {
    const { api } = renderApp({ user: account, initialSession: await mix() })
    await screen.findByRole('heading', { name: 'Rainy commute' })
    expect(sheet()).not.toBeInTheDocument()
    expect(funnel(api)).toEqual([])
  })

  it('appears when the first mix lands on a follow-up turn after a refusal', async () => {
    const api = createFakeApi({
      sendMessage: async () => {
        const created = await createFakeApi().createSession('Rainy commute')
        return { djMessage: { id: 'dj-2', role: 'dj', content: 'Here it is.', createdAt: new Date().toISOString() }, queue: created.queue, queueVersion: 2, sessionTitle: null } as never
      },
    })
    renderApp({ api, initialSession: await mix(false) })
    fireEvent.change(await screen.findByRole('textbox', { name: 'Message your DJ' }), { target: { value: 'Burna Boy, Tems, Sade' } })
    fireEvent.keyDown(screen.getByRole('textbox', { name: 'Message your DJ' }), { key: 'Enter' })
    expect(await screen.findByRole('dialog', { name: 'Keep this mix.' })).toBeInTheDocument()
    await waitFor(() => expect(funnel(api)).toEqual(['first_mix_refused', 'first_mix_made', 'keep_sheet_shown']))
  })

  it('opens the sign-in page with "Keep your mixes." from its pill', async () => {
    const { api } = renderApp({ initialSession: await mix() })
    fireEvent.click(await screen.findByRole('button', { name: 'Keep this mix' }))
    expect(sheet()).not.toBeInTheDocument()
    const page = screen.getByTestId('sign-in-over-shell')
    expect(within(page).getByRole('heading', { name: 'Keep your mixes.' })).toHaveFocus()
    expect(within(page).getByRole('button', { name: 'Continue with Apple' })).toBeInTheDocument()
    expect(within(page).getByRole('button', { name: 'Continue with Google' })).toBeInTheDocument()
    expect(within(page).queryByText(CAP_LINE)).not.toBeInTheDocument()
    expect(page.querySelector('.auth-page--graphic')?.getAttribute('style')).toContain('first-run/bg-sign-in.jpg')
    expect(document.title).toBe('Keep your mixes.')
    await waitFor(() => expect(funnel(api)).toContain('keep_sheet_signed_in'))
  })

  it('Not now dismisses for the session: the next mix shows no sheet', async () => {
    const { api } = renderApp({ initialSession: await mix() })
    fireEvent.click(await screen.findByRole('button', { name: 'Not now' }))
    expect(sheet()).not.toBeInTheDocument()
    expect(sessionStorage.getItem('mixtape.keep-sheet-seen')).not.toBeNull()
    await waitFor(() => expect(funnel(api)).toContain('keep_sheet_dismissed'))
    cleanup()

    renderApp({ initialSession: await mix() })
    await screen.findByRole('heading', { name: 'Rainy commute' })
    expect(sheet()).not.toBeInTheDocument()
  })

  it.each([
    ['Escape', () => fireEvent.keyDown(window, { key: 'Escape' })],
    ['the handle', () => fireEvent.click(screen.getByTestId('keep-sheet-handle'))],
    ['the backdrop', () => fireEvent.click(screen.getByTestId('keep-sheet-backdrop'))],
  ])('%s dismisses as Not now does', async (_label, dismiss) => {
    const { api } = renderApp({ initialSession: await mix() })
    await screen.findByRole('dialog', { name: 'Keep this mix.' })
    act(() => dismiss())
    expect(sheet()).not.toBeInTheDocument()
    expect(screen.queryByTestId('sign-in-over-shell')).not.toBeInTheDocument()
    await waitFor(() => expect(funnel(api)).toContain('keep_sheet_dismissed'))
  })
})

describe('the anonymous cap', () => {
  function cappedApi() {
    return createFakeApi({ createSession: vi.fn(async () => { throw new AnonymousCapError({ error: 'anonymous_cap', limit: 3 }) }) })
  }

  it('keeps the prompt, pushes the sign-in page with the cap line, and draws nothing in the composer', async () => {
    const api = cappedApi()
    renderApp({ api })
    await screen.findByRole('heading', { name: 'Home' })
    sendFromHome('late night drive')

    const page = await screen.findByTestId('sign-in-over-shell')
    expect(within(page).getByRole('heading', { name: 'Keep your mixes.' })).toBeInTheDocument()
    expect(within(page).getByText(CAP_LINE)).toBeInTheDocument()
    expect(within(page).queryByText('last used')).not.toBeInTheDocument()
    expect(screen.getByRole('textbox', { name: 'Describe your mix', hidden: true })).toHaveValue('late night drive')
    expect(screen.queryByText(/Couldn’t make your mix/)).not.toBeInTheDocument()
    expect(kept()).toEqual({ prompt: 'late night drive', inspiration: null, shape: null })
    await waitFor(() => expect(funnel(api)).toEqual(['cap_reached']))

    // A second capped send posts cap_reached no more.
    fireEvent.click(within(page).getByRole('button', { name: 'Back' }))
    await waitFor(() => expect(screen.queryByTestId('sign-in-over-shell')).not.toBeInTheDocument())
    fireEvent.click(screen.getByRole('button', { name: 'Make a mix' }))
    await screen.findByTestId('sign-in-over-shell')
    await new Promise((resolve) => setTimeout(resolve, 0))
    expect(funnel(api)).toEqual(['cap_reached'])
  })

  it('Back returns to Home with the prompt still in the field', async () => {
    renderApp({ api: cappedApi() })
    await screen.findByRole('heading', { name: 'Home' })
    sendFromHome('late night drive')
    fireEvent.click(within(await screen.findByTestId('sign-in-over-shell')).getByRole('button', { name: 'Back' }))

    await waitFor(() => expect(screen.queryByTestId('sign-in-over-shell')).not.toBeInTheDocument())
    expect(screen.getByRole('heading', { name: 'Home' })).toBeVisible()
    expect(screen.getByRole('textbox', { name: 'Describe your mix' })).toHaveValue('late night drive')
    expect(sessionStorage.getItem('mixtape.kept-prompt')).toBeNull()
  })

  it('the browser back closes the sign-in page the same way', async () => {
    renderApp({ api: cappedApi() })
    await screen.findByRole('heading', { name: 'Home' })
    sendFromHome('late night drive')
    await screen.findByTestId('sign-in-over-shell')
    act(() => window.history.back())
    await waitFor(() => expect(screen.queryByTestId('sign-in-over-shell')).not.toBeInTheDocument())
    expect(screen.getByRole('textbox', { name: 'Describe your mix' })).toHaveValue('late night drive')
  })

  it('refetches the session when sign-in returns, and the account sends the kept prompt once ready', async () => {
    const { signIn, refetchSession } = renderApp({ api: cappedApi() })
    await screen.findByRole('heading', { name: 'Home' })
    sendFromHome('late night drive')
    fireEvent.click(within(await screen.findByTestId('sign-in-over-shell')).getByRole('button', { name: 'Continue with Google' }))
    await waitFor(() => expect(refetchSession).toHaveBeenCalledOnce())
    expect(signIn).toHaveBeenCalledWith('google')
    expect(preferences.begin).toHaveBeenCalledWith('google')
    cleanup()

    // The session now reads as the account: the workspace remounts and sends it.
    const createSession = vi.fn(async (prompt: string) => createFakeApi().createSession(prompt))
    renderApp({ user: account, api: createFakeApi({ createSession }) })
    expect(await screen.findByRole('heading', { name: 'late night drive' })).toBeInTheDocument()
    expect(createSession).toHaveBeenCalledOnce()
    expect(createSession.mock.calls[0][0]).toBe('late night drive')
    expect(sessionStorage.getItem('mixtape.kept-prompt')).toBeNull()
  })

  it('an anonymous load drops a stale kept prompt without sending it', async () => {
    keepRecord('late night drive')
    const createSession = vi.fn(async (prompt: string) => createFakeApi().createSession(prompt))
    renderApp({ api: createFakeApi({ createSession }) })
    await screen.findByRole('heading', { name: 'Home' })
    await waitFor(() => expect(sessionStorage.getItem('mixtape.kept-prompt')).toBeNull())
    expect(createSession).not.toHaveBeenCalled()
  })
})

describe('the composer panel', () => {
  it('never renders provider buttons, for an anonymous listener or an account', async () => {
    for (const user of [anonymous, account]) {
      const { view } = renderApp({ user })
      await screen.findByRole('heading', { name: 'Home' })
      const composer = view.container.querySelector('.home-compose')
      expect(composer).not.toBeNull()
      expect(within(composer as HTMLElement).queryByRole('button', { name: /Continue with|Sign in/ })).not.toBeInTheDocument()
      cleanup()
    }
  })
})

describe('the account surface', () => {
  it('shows one sign-in row for an anonymous listener and no Sign out or account controls', async () => {
    renderApp()
    fireEvent.click(await screen.findByRole('button', { name: 'Settings' }))
    const row = await screen.findByRole('button', { name: 'Sign in to keep your mixes' })
    expect(screen.queryByRole('button', { name: 'Sign out' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Manage account' })).not.toBeInTheDocument()
    expect(screen.queryByText('Listener')).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /Continue with/ })).not.toBeInTheDocument()

    fireEvent.click(row)
    const page = screen.getByTestId('sign-in-over-shell')
    expect(within(page).getByRole('heading', { name: 'Keep your mixes.' })).toBeInTheDocument()
    expect(within(page).queryByText(CAP_LINE)).not.toBeInTheDocument()
  })

  it('keeps the identity block and Sign out for an account, with no sign-in row', async () => {
    renderApp({ user: account })
    fireEvent.click(await screen.findByRole('button', { name: 'Settings' }))
    expect(await screen.findByRole('button', { name: 'Sign out' })).toBeInTheDocument()
    expect(screen.getByText('Noble')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Sign in to keep your mixes' })).not.toBeInTheDocument()
  })
})

describe('the merge notice', () => {
  it.each<[MergedMode | null, string | null]>([
    ['mixes_only', 'Your mixes are in. This account already had a library, so we kept that one.'],
    ['library_kept', 'This account already had a library, so we kept that one.'],
    ['all', null],
    [null, null],
  ])('merged %s', async (merged, notice) => {
    const getMe = vi.fn(async () => ({ user: { id: account.id, isAnonymous: false }, merged, albumPicks: false }))
    renderApp({ user: account, api: createFakeApi({ getMe }) })
    await waitFor(() => expect(getMe).toHaveBeenCalledOnce())
    if (notice) {
      expect(await screen.findByText(notice)).toBeInTheDocument()
      expect(screen.getByText(notice).closest('.toast')).toHaveClass('toast--success')
    } else {
      await new Promise((resolve) => setTimeout(resolve, 0))
      expect(screen.queryByText(/already had a library/)).not.toBeInTheDocument()
    }
  })

  it('is not read for an anonymous listener', async () => {
    const getMe = vi.fn(async () => ({ user: { id: anonymous.id, isAnonymous: true }, merged: null, albumPicks: false }))
    renderApp({ api: createFakeApi({ getMe }) })
    await screen.findByRole('heading', { name: 'Home' })
    await new Promise((resolve) => setTimeout(resolve, 0))
    expect(getMe).not.toHaveBeenCalled()
  })

  it('stays up when the kept prompt\'s new tape arrives', async () => {
    keepRecord('late night drive')
    const made = deferred<CreateSessionResponse>()
    const createSession = vi.fn(() => made.promise)
    const getMe = vi.fn(async () => ({ user: { id: account.id, isAnonymous: false }, merged: 'mixes_only' as const, albumPicks: false }))
    renderApp({ user: account, api: createFakeApi({ getMe, createSession }) })
    const notice = 'Your mixes are in. This account already had a library, so we kept that one.'
    expect(await screen.findByText(notice)).toBeInTheDocument()
    expect(createSession).toHaveBeenCalledOnce()

    await act(async () => made.resolve(await createFakeApi().createSession('late night drive')))
    expect(await screen.findByRole('heading', { name: 'late night drive' })).toBeInTheDocument()
    expect(screen.getByText(notice)).toBeInTheDocument()
    expect(screen.queryByText('Your new tape is ready.')).not.toBeInTheDocument()
  })

  it('shows for six seconds', async () => {
    vi.useFakeTimers()
    try {
      const getMe = vi.fn(async () => ({ user: { id: account.id, isAnonymous: false }, merged: 'library_kept' as const, albumPicks: false }))
      renderApp({ user: account, api: createFakeApi({ getMe }) })
      const notice = 'This account already had a library, so we kept that one.'
      // Step the clock a millisecond at a time until the notice lands, so its 6 s starts here.
      for (let step = 0; step < 200 && !screen.queryByText(notice); step += 1) {
        await act(async () => { await vi.advanceTimersByTimeAsync(1) })
      }
      expect(screen.getByText(notice)).toBeInTheDocument()
      act(() => { vi.advanceTimersByTime(5900) })
      expect(screen.getByText(notice)).toBeInTheDocument()
      act(() => { vi.advanceTimersByTime(100) })
      expect(screen.queryByText(notice)).not.toBeInTheDocument()
    } finally {
      vi.useRealTimers()
    }
  })
})

describe('a sign-in that came back failed', () => {
  it('reopens the cap page with the error and puts the kept prompt back in the field', async () => {
    keepRecord('late night drive')
    const createSession = vi.fn(async (prompt: string) => createFakeApi().createSession(prompt))
    renderApp({ api: createFakeApi({ createSession }), signInError: 'Google sign-in did not finish.' })
    const page = await screen.findByTestId('sign-in-over-shell')
    expect(within(page).getByRole('heading', { name: 'Keep your mixes.' })).toBeInTheDocument()
    expect(within(page).getByText(CAP_LINE)).toBeInTheDocument()
    expect(within(page).getByRole('alert')).toHaveTextContent('Google sign-in did not finish.')
    await waitFor(() => expect(screen.getByRole('textbox', { name: 'Describe your mix', hidden: true })).toHaveValue('late night drive'))
    expect(kept()).toEqual({ prompt: 'late night drive', inspiration: null, shape: null })
    expect(createSession).not.toHaveBeenCalled()

    // Back from it: Home with the prompt, and the kept copy dropped.
    fireEvent.click(within(page).getByRole('button', { name: 'Back' }))
    await waitFor(() => expect(screen.queryByTestId('sign-in-over-shell')).not.toBeInTheDocument())
    expect(screen.getByRole('textbox', { name: 'Describe your mix' })).toHaveValue('late night drive')
    expect(kept()).toBeNull()
  })

  it('reopens the Keep variant with the error when nothing was kept', async () => {
    renderApp({ signInError: 'Apple sign-in did not finish.' })
    const page = await screen.findByTestId('sign-in-over-shell')
    expect(within(page).getByRole('heading', { name: 'Keep your mixes.' })).toBeInTheDocument()
    expect(within(page).queryByText(CAP_LINE)).not.toBeInTheDocument()
    expect(within(page).getByRole('alert')).toHaveTextContent('Apple sign-in did not finish.')
  })

  it('opens nothing without an error, and an account never sees one', async () => {
    renderApp()
    await screen.findByRole('heading', { name: 'Home' })
    expect(screen.queryByTestId('sign-in-over-shell')).not.toBeInTheDocument()
    cleanup()
    renderApp({ user: account, signInError: 'Apple sign-in did not finish.' })
    await screen.findByRole('heading', { name: 'Home' })
    expect(screen.queryByTestId('sign-in-over-shell')).not.toBeInTheDocument()
  })
})

describe('the cap from New mix', () => {
  it('closes the dialog, keeps the seed and shape, and re-sends them after sign-in', async () => {
    const api = createFakeApi({
      listPlaylists: async () => ({ playlists: [playlist], nextCursor: null, total: 1 }),
      getPlaylist: async () => ({ playlist, entries: [], nextEntryCursor: null }),
      createSession: vi.fn(async () => { throw new AnonymousCapError({ error: 'anonymous_cap', limit: 3 }) }),
    })
    renderApp({ api })
    fireEvent.click(await screen.findByRole('button', { name: /^Library/ }))
    fireEvent.click(await screen.findByRole('button', { name: 'Open Night bus' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Make a mix inspired by this' }))
    const dialog = await screen.findByRole('dialog', { name: 'Make a mix' })
    fireEvent.click(within(dialog).getByRole('button', { name: 'Energy journey' }))
    fireEvent.click(screen.getByRole('button', { name: 'Use this shape' }))
    fireEvent.change(within(dialog).getByLabelText('What should this tape feel like?'), { target: { value: 'Sunday' } })
    fireEvent.click(within(dialog).getByRole('button', { name: 'Start tape' }))

    await screen.findByTestId('sign-in-over-shell')
    expect(screen.queryByRole('dialog', { name: 'Make a mix' })).not.toBeInTheDocument()
    expect(kept()).toEqual({ prompt: 'Sunday', inspiration: { playlistId: 'night-bus', excludeSourceTracks: false }, shape: 'arc' })
    cleanup()

    const createSession = vi.fn(async (prompt: string) => createFakeApi().createSession(prompt))
    renderApp({ user: account, api: createFakeApi({ createSession }) })
    await waitFor(() => expect(createSession).toHaveBeenCalledOnce())
    expect(createSession.mock.calls[0]).toEqual(['Sunday', { playlistId: 'night-bus', excludeSourceTracks: false }, 'arc'])
  })
})

describe('the Keep sheet in history', () => {
  it('is a history entry: the browser back closes it as Not now', async () => {
    const api = createFakeApi()
    renderApp({ api })
    await screen.findByRole('heading', { name: 'Home' })
    sendFromHome('late night drive')
    await screen.findByRole('dialog', { name: 'Keep this mix.' })
    await waitFor(() => expect(window.history.state?.mixtapeKeepSheet).toBe(true))
    act(() => window.history.back())
    await waitFor(() => expect(sheet()).not.toBeInTheDocument())
    expect(screen.getByRole('heading', { name: 'late night drive' })).toBeInTheDocument()
    await waitFor(() => expect(funnel(api)).toContain('keep_sheet_dismissed'))
  })

  it('Not now folds its entry back', async () => {
    renderApp()
    await screen.findByRole('heading', { name: 'Home' })
    sendFromHome('late night drive')
    await screen.findByRole('dialog', { name: 'Keep this mix.' })
    await waitFor(() => expect(window.history.state?.mixtapeKeepSheet).toBe(true))
    const back = vi.spyOn(window.history, 'back')
    try {
      fireEvent.click(screen.getByRole('button', { name: 'Not now' }))
      expect(back).toHaveBeenCalledOnce()
    } finally {
      back.mockRestore()
    }
    await waitFor(() => expect(window.history.state?.mixtapeKeepSheet).toBeUndefined())
    expect(screen.getByRole('heading', { name: 'late night drive' })).toBeInTheDocument()
  })

  it('the pill turns the sheet\'s entry into the sign-in page\'s, so back returns to the mix', async () => {
    renderApp()
    await screen.findByRole('heading', { name: 'Home' })
    sendFromHome('late night drive')
    await screen.findByRole('dialog', { name: 'Keep this mix.' })
    await waitFor(() => expect(window.history.state?.mixtapeKeepSheet).toBe(true))
    const push = vi.spyOn(window.history, 'pushState')
    try {
      fireEvent.click(screen.getByRole('button', { name: 'Keep this mix' }))
      expect(push).not.toHaveBeenCalled()
    } finally {
      push.mockRestore()
    }
    expect(window.history.state?.mixtapeSignIn).toBe('keep')
    expect(window.history.state?.mixtapeKeepSheet).toBeUndefined()
    act(() => window.history.back())
    await waitFor(() => expect(screen.queryByTestId('sign-in-over-shell')).not.toBeInTheDocument())
    expect(screen.getByRole('heading', { name: 'late night drive' })).toBeInTheDocument()
  })

  it('waits for the first run\'s fold before pushing its entry', async () => {
    const push = vi.spyOn(window.history, 'pushState')
    try {
      renderApp({ initialSession: await mix() })
      await screen.findByRole('dialog', { name: 'Keep this mix.' })
      expect(push).not.toHaveBeenCalled()
      act(() => { window.dispatchEvent(new PopStateEvent('popstate', { state: null })) })
      expect(push).toHaveBeenCalledOnce()
      expect(sheet()).toBeInTheDocument()
    } finally {
      push.mockRestore()
    }
  })
})
