import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { AuthGate, type AuthBridge, type AuthSessionState } from './AuthGate'
import { rememberIdentity, clearWorkspaceRestore } from '../lib/workspace-restore'
import type { AuthPreferenceStore } from '../lib/auth-provider'
import { fakeServices } from '../test/first-run-fakes'
import type { CreateSessionResponse } from '../api/client'

function preferences(lastUsed: 'apple' | 'google' | null = null): AuthPreferenceStore {
  return {
    lastUsed: vi.fn(() => lastUsed),
    begin: vi.fn(),
    promotePending: vi.fn(() => null),
    clearPending: vi.fn(),
  }
}

function bridge(overrides: Partial<AuthBridge> = {}): AuthBridge {
  return {
    useSession: () => ({ data: null, isPending: false, error: null, refetch: vi.fn() }),
    signIn: vi.fn(async () => ({})),
    signOut: vi.fn(async () => ({})),
    ...overrides,
  }
}

/** The sign-in page sits behind the welcome page's foot link. */
function openSignIn() {
  fireEvent.click(screen.getByRole('button', { name: 'Sign in.' }))
}

describe('authentication gate', () => {
  afterEach(() => {
    cleanup()
    clearWorkspaceRestore()
    window.history.replaceState({}, '', '/')
  })

  it('opens on the first run, with the approved compact sign-in page behind its foot link', () => {
    render(<AuthGate auth={bridge()}>{() => <p>Signed in</p>}</AuthGate>)

    expect(screen.getByRole('heading', { name: 'What do you want to hear?' })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /Continue with/ })).not.toBeInTheDocument()
    openSignIn()

    expect(screen.getByRole('heading', { name: 'Your music, mixed for right now.' })).toBeInTheDocument()
    expect(
      screen.getByText('Start with a mood, a memory, or one song. Mixtape builds a mix from music you already love.'),
    ).toBeInTheDocument()
    expect(screen.getByText('Sign in to start a mix and keep your taste in sync.')).toBeInTheDocument()
    expect(screen.queryByText('Your personal DJ')).not.toBeInTheDocument()
    expect(screen.queryByText('A tape for right now.')).not.toBeInTheDocument()
    expect(screen.queryByText('Sign in to find your tapes and keep listening.')).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Continue with Apple' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Continue with Google' })).toBeInTheDocument()
    expect(screen.queryByText('Signed in')).not.toBeInTheDocument()
  })

  it('keeps an accessible redirecting state while Apple opens', async () => {
    const signIn = vi.fn(() => new Promise<{ error?: string }>(() => undefined))
    render(<AuthGate auth={bridge({ signIn })} preferences={preferences()}>{() => <p>Signed in</p>}</AuthGate>)
    openSignIn()

    fireEvent.click(screen.getByRole('button', { name: 'Continue with Apple' }))

    expect(await screen.findByRole('status')).toHaveTextContent('Opening Apple sign-in')
    expect(screen.getByRole('button', { name: 'Opening Apple…' })).toBeDisabled()
    expect(screen.getByRole('button', { name: 'Continue with Google' })).toBeDisabled()
    expect(signIn).toHaveBeenCalledWith('apple')
  })

  it('marks only the remembered provider as last used', () => {
    render(<AuthGate auth={bridge()} preferences={preferences('google')}>{() => <p>Signed in</p>}</AuthGate>)
    openSignIn()

    expect(screen.getByRole('button', { name: 'Continue with Google' })).toHaveAccessibleDescription('last used')
    expect(screen.getByText('last used')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Continue with Apple' })).not.toHaveAccessibleDescription()
  })

  it('remembers a provider only after its redirect returns with a session', async () => {
    const store = preferences('apple')
    store.promotePending = vi.fn(() => 'google' as const)
    const auth = bridge({
      useSession: () => ({
        data: { user: { id: 'user-1', name: 'Noble', email: 'noble@example.com' } },
        isPending: false,
        error: null,
        refetch: vi.fn(),
      }),
    })

    render(<AuthGate auth={auth} preferences={store}>{(_user, provider) => <p>Signed in with {provider}</p>}</AuthGate>)

    await waitFor(() => expect(screen.getByText('Signed in with google')).toBeInTheDocument())
    expect(store.promotePending).toHaveBeenCalledOnce()
  })

  it('keeps the control in place and explains a sign-in failure', async () => {
    const signIn = vi.fn(async () => ({ error: 'Apple sign-in did not finish.' }))
    render(<AuthGate auth={bridge({ signIn })}>{() => <p>Signed in</p>}</AuthGate>)
    openSignIn()

    fireEvent.click(screen.getByRole('button', { name: 'Continue with Apple' }))

    await waitFor(() => expect(screen.getByRole('alert')).toHaveTextContent('Apple sign-in did not finish.'))
    expect(screen.getByRole('button', { name: 'Continue with Apple' })).toBeInTheDocument()
  })

  it('explains how to recover when a Google identity is not linked', () => {
    window.history.replaceState({}, '', '/?auth_error=google&error=account_not_linked')

    render(<AuthGate auth={bridge()} preferences={preferences()}>{() => <p>Signed in</p>}</AuthGate>)

    expect(screen.getByRole('alert')).toHaveTextContent(
      'That Google account is not linked yet. Sign in with your usual method, then link Google from Account.',
    )
  })

  it('renders the application when a session is present', () => {
    const auth = bridge({
      useSession: () => ({
        data: { user: { id: 'user-1', name: 'Noble', email: 'noble@example.com' } },
        isPending: false,
        error: null,
        refetch: vi.fn(),
      }),
    })

    render(<AuthGate auth={auth}>{(user) => <p>Welcome {user.name}</p>}</AuthGate>)

    expect(screen.getByText('Welcome Noble')).toBeInTheDocument()
  })
})


describe('session restoration', () => {
  afterEach(() => { cleanup(); clearWorkspaceRestore() })
  it('shows neither welcome nor protected content until the session check completes', () => {
    let state: AuthSessionState = { data: null, isPending: true, error: null, refetch: vi.fn() }
    const auth = bridge({ useSession: () => state })
    const view = render(<AuthGate auth={auth}>{() => <p>My mixes</p>}</AuthGate>)
    expect(screen.getByRole('status')).toHaveTextContent('Checking your session')
    expect(screen.queryByRole('heading', { name: 'Your music, mixed for right now.' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /Continue with/ })).not.toBeInTheDocument()
    expect(screen.queryByText('My mixes')).not.toBeInTheDocument()
    state = { ...state, isPending: false, data: { user: { id: 'u', name: 'Listener', email: 'test@example.test' } } }
    view.rerender(<AuthGate auth={auth}>{() => <p>My mixes</p>}</AuthGate>)
    expect(screen.getByText('My mixes')).toBeInTheDocument()
    state = { ...state, data: null }
    view.rerender(<AuthGate auth={auth}>{() => <p>My mixes</p>}</AuthGate>)
    expect(screen.getByRole('heading', { name: 'What do you want to hear?' })).toBeInTheDocument()
  })
  it('offers session retry instead of treating a network failure as signed out', () => {
    const refetch = vi.fn()
    render(<AuthGate auth={bridge({ useSession: () => ({ data: null, isPending: false, error: new Error('offline'), refetch }) })}>{() => <p>My mixes</p>}</AuthGate>)
    expect(screen.getByRole('alert')).toHaveTextContent('couldn’t check your session')
    expect(screen.queryByRole('button', { name: /Continue with/ })).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Retry' }))
    expect(refetch).toHaveBeenCalledOnce()
  })
})


it('retains cached content with a floating status until the session is verified', () => {
  clearWorkspaceRestore()
  rememberIdentity({ id: 'u', name: 'Listener', email: 'test@example.test' })
  let state: AuthSessionState = { data: null, isPending: true, error: null, refetch: vi.fn() }
  const auth = bridge({ useSession: () => state })
  const view = render(<AuthGate auth={auth}>{(_user, _provider, restoring) => <p>{restoring ? 'Saved Library' : 'Live Library'}</p>}</AuthGate>)
  expect(screen.getByText('Saved Library')).toBeInTheDocument()
  expect(screen.getByRole('status')).toHaveTextContent('Refreshing')
  expect(screen.getByText('Saved Library').closest('[inert]')).not.toBeNull()
  state = { ...state, isPending: false, data: { user: { id: 'u', name: 'Listener', email: 'test@example.test' } } }
  view.rerender(<AuthGate auth={auth}>{(_user, _provider, restoring) => <p>{restoring ? 'Saved Library' : 'Live Library'}</p>}</AuthGate>)
  expect(screen.getByText('Live Library')).toBeInTheDocument()
  expect(screen.queryByRole('status')).not.toBeInTheDocument()
  cleanup(); clearWorkspaceRestore()
})
it('clears the saved page after a confirmed signed-out response', () => {
  clearWorkspaceRestore()
  rememberIdentity({ id: 'u', name: 'Listener', email: 'test@example.test' })
  render(<AuthGate auth={bridge()}>{() => <p>Saved Library</p>}</AuthGate>)
  expect(screen.queryByText('Saved Library')).not.toBeInTheDocument()
  expect(sessionStorage.getItem('mixtape.workspace.v1:identity')).toBeNull()
  cleanup()
})


describe('anonymous sessions', () => {
  afterEach(() => { cleanup(); clearWorkspaceRestore() })

  it('passes isAnonymous through to the signed-in content', () => {
    const auth = bridge({
      useSession: () => ({
        data: { user: { id: 'anon-1', name: 'Listener', email: 'a@anonymous.mixtape.invalid', isAnonymous: true } },
        isPending: false, error: null, refetch: vi.fn(),
      }),
    })
    render(<AuthGate auth={auth}>{(user) => <p>anonymous {String(user.isAnonymous)}</p>}</AuthGate>)
    expect(screen.getByText('anonymous true')).toBeInTheDocument()
  })

  it('remembers the anonymous flag with the cached identity', () => {
    const auth = bridge({
      useSession: () => ({
        data: { user: { id: 'anon-1', name: 'Listener', email: 'a@anonymous.mixtape.invalid', isAnonymous: true } },
        isPending: false, error: null, refetch: vi.fn(),
      }),
    })
    render(<AuthGate auth={auth}>{() => <p>Mixes</p>}</AuthGate>)
    expect(JSON.parse(sessionStorage.getItem('mixtape.workspace.v1:identity') ?? 'null')).toMatchObject({
      user: { id: 'anon-1', isAnonymous: true },
    })
  })

  it('shows the first run with no session', () => {
    render(<AuthGate auth={bridge()}>{() => <p>Mixes</p>}</AuthGate>)
    expect(screen.getByTestId('first-run')).toBeInTheDocument()
    expect(screen.queryByText('Mixes')).not.toBeInTheDocument()
  })
})


describe('first-run flow', () => {
  afterEach(() => { cleanup(); clearWorkspaceRestore(); window.history.replaceState({}, '', '/') })
  const anonymous: AuthSessionState = {
    data: { user: { id: 'anon-1', name: 'Listener', email: 'a@anonymous.mixtape.invalid', isAnonymous: true } },
    isPending: false, error: null, refetch: vi.fn(),
  }

  it('keeps the first run mounted when an anonymous session arrives mid-flow', () => {
    let state: AuthSessionState = { data: null, isPending: false, error: null, refetch: vi.fn() }
    const auth = bridge({ useSession: () => state })
    const view = render(<AuthGate auth={auth}>{() => <p>Shell</p>}</AuthGate>)
    expect(screen.getByTestId('first-run')).toBeInTheDocument()

    state = anonymous
    view.rerender(<AuthGate auth={auth}>{() => <p>Shell</p>}</AuthGate>)
    expect(screen.getByTestId('first-run')).toBeInTheDocument()
    expect(screen.queryByText('Shell')).not.toBeInTheDocument()
  })

  it('keeps the first run mounted when the first check was pending and found no session', () => {
    let state: AuthSessionState = { data: null, isPending: true, error: null, refetch: vi.fn() }
    const auth = bridge({ useSession: () => state })
    const view = render(<AuthGate auth={auth}>{() => <p>Shell</p>}</AuthGate>)
    state = { ...state, isPending: false }
    view.rerender(<AuthGate auth={auth}>{() => <p>Shell</p>}</AuthGate>)
    state = anonymous
    view.rerender(<AuthGate auth={auth}>{() => <p>Shell</p>}</AuthGate>)
    expect(screen.getByTestId('first-run')).toBeInTheDocument()
    expect(screen.queryByText('Shell')).not.toBeInTheDocument()
  })

  it('switches to the shell with the new mix when the first run finishes', async () => {
    let state: AuthSessionState = { data: null, isPending: false, error: null, refetch: vi.fn() }
    const auth = bridge({ useSession: () => state })
    const { services, ensureSession } = fakeServices()
    // ensureSession() is what makes the anonymous session appear.
    ensureSession.mockImplementation(async () => { state = anonymous })
    const factory = vi.fn(() => services)
    const shell = (_user: unknown, _provider: unknown, _restoring: unknown, created: CreateSessionResponse | null) => <p>Shell opens {created?.session.id}</p>
    render(<AuthGate auth={auth} firstRunServices={factory}>{shell}</AuthGate>)

    fireEvent.change(screen.getByRole('textbox', { name: 'Describe your mix' }), { target: { value: 'late night drive' } })
    fireEvent.click(screen.getByRole('button', { name: 'Make a mix' }))
    for (const [label, name] of [['First artist', 'Burna Boy'], ['Second artist', 'Tems'], ['Third artist', 'Sade']]) {
      fireEvent.change(await screen.findByRole('textbox', { name: label }), { target: { value: name } })
    }
    fireEvent.click(screen.getByRole('button', { name: 'Continue' }))

    expect(await screen.findByText('Shell opens session-new')).toBeInTheDocument()
    expect(screen.queryByTestId('first-run')).not.toBeInTheDocument()
    expect(factory).toHaveBeenCalledOnce()
  })

  it('renders the shell directly for an anonymous session present at load', () => {
    render(<AuthGate auth={bridge({ useSession: () => anonymous })}>{() => <p>Shell</p>}</AuthGate>)
    expect(screen.getByText('Shell')).toBeInTheDocument()
    expect(screen.queryByTestId('first-run')).not.toBeInTheDocument()
  })

  it('renders the shell for an anonymous session found by a pending check at load', () => {
    let state: AuthSessionState = { data: null, isPending: true, error: null, refetch: vi.fn() }
    const auth = bridge({ useSession: () => state })
    const view = render(<AuthGate auth={auth}>{() => <p>Shell</p>}</AuthGate>)
    state = anonymous
    view.rerender(<AuthGate auth={auth}>{() => <p>Shell</p>}</AuthGate>)
    expect(screen.getByText('Shell')).toBeInTheDocument()
  })
})

describe('sign-in error from the URL', () => {
  afterEach(() => { cleanup(); clearWorkspaceRestore(); window.history.replaceState({}, '', '/') })

  it('clears the error once a session appears so it does not come back after sign-out', () => {
    window.history.replaceState({}, '', '/?auth_error=apple')
    let state: AuthSessionState = { data: null, isPending: false, error: null, refetch: vi.fn() }
    const auth = bridge({ useSession: () => state })
    const view = render(<AuthGate auth={auth} preferences={preferences()}>{() => <p>Shell</p>}</AuthGate>)
    expect(screen.getByRole('alert')).toHaveTextContent('Apple sign-in did not finish.')

    state = { ...state, data: { user: { id: 'u', name: 'Listener', email: 'l@example.test' } } }
    view.rerender(<AuthGate auth={auth} preferences={preferences()}>{() => <p>Shell</p>}</AuthGate>)
    state = { ...state, data: null }
    view.rerender(<AuthGate auth={auth} preferences={preferences()}>{() => <p>Shell</p>}</AuthGate>)
    openSignIn()

    expect(screen.getByRole('button', { name: 'Continue with Apple' })).toBeInTheDocument()
    expect(screen.queryByText('Apple sign-in did not finish.')).not.toBeInTheDocument()
  })

  it('clears the error when a sign-in starts so a failed session check shows Retry again', () => {
    window.history.replaceState({}, '', '/?auth_error=google')
    const signIn = vi.fn(() => new Promise<{ error?: string }>(() => undefined))
    const auth = bridge({ signIn, useSession: () => ({ data: null, isPending: false, error: new Error('offline'), refetch: vi.fn() }) })
    render(<AuthGate auth={auth} preferences={preferences()}>{() => <p>Shell</p>}</AuthGate>)
    expect(screen.getByRole('alert')).toHaveTextContent('Google sign-in did not finish.')

    fireEvent.click(screen.getByRole('button', { name: 'Continue with Google' }))

    expect(screen.getByRole('alert')).toHaveTextContent('couldn’t check your session')
    expect(screen.getByRole('button', { name: 'Retry' })).toBeInTheDocument()
  })
})
