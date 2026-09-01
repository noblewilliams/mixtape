import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { AuthGate, type AuthBridge } from './AuthGate'
import type { AuthPreferenceStore } from '../lib/auth-provider'

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

describe('authentication gate', () => {
  afterEach(() => {
    cleanup()
    window.history.replaceState({}, '', '/')
  })

  it('shows the approved compact signed-out state', () => {
    render(<AuthGate auth={bridge()}>{() => <p>Signed in</p>}</AuthGate>)

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

    fireEvent.click(screen.getByRole('button', { name: 'Continue with Apple' }))

    expect(await screen.findByRole('status')).toHaveTextContent('Opening Apple sign-in')
    expect(screen.getByRole('button', { name: 'Opening Apple…' })).toBeDisabled()
    expect(screen.getByRole('button', { name: 'Continue with Google' })).toBeDisabled()
    expect(signIn).toHaveBeenCalledWith('apple')
  })

  it('marks only the remembered provider as last used', () => {
    render(<AuthGate auth={bridge()} preferences={preferences('google')}>{() => <p>Signed in</p>}</AuthGate>)

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
