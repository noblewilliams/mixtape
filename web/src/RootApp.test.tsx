import { cleanup, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { AuthSessionState, AuthUser } from './components/AuthGate'
import { clearWorkspaceRestore, rememberIdentity } from './lib/workspace-restore'

const auth = vi.hoisted(() => ({
  state: { data: null, isPending: false, error: null, refetch: () => undefined } as AuthSessionState,
  signInAnonymous: vi.fn(),
}))

vi.mock('./lib/auth-client', () => ({
  authClient: { signIn: { anonymous: auth.signInAnonymous } },
  browserAuth: {
    useSession: () => auth.state,
    signIn: vi.fn(async () => ({})),
    signOut: vi.fn(async () => ({})),
    listAccounts: vi.fn(async () => []),
    linkProvider: vi.fn(async () => ({})),
    unlinkAccount: vi.fn(async () => ({})),
  },
}))
vi.mock('./App', () => ({
  App: ({ user }: { user: AuthUser }) => <p>Signed in as {user.id}, anonymous {String(user.isAnonymous)}</p>,
}))
vi.mock('./musickit/client', () => ({ createMusicKitClient: () => ({}) }))

const { RootApp } = await import('./RootApp')

function signedIn(user: AuthUser): AuthSessionState {
  return { data: { user }, isPending: false, error: null, refetch: () => undefined }
}

describe('root switch', () => {
  afterEach(() => {
    cleanup()
    clearWorkspaceRestore()
    auth.state = { data: null, isPending: false, error: null, refetch: () => undefined }
    auth.signInAnonymous.mockReset()
    vi.unstubAllGlobals()
  })

  it('renders the first run with no session and makes no request on load', () => {
    const fetchMock = vi.fn<typeof fetch>()
    vi.stubGlobal('fetch', fetchMock)

    render(<RootApp />)

    expect(screen.getByTestId('first-run')).toBeInTheDocument()
    expect(screen.queryByText(/Signed in as/)).not.toBeInTheDocument()
    expect(auth.signInAnonymous).not.toHaveBeenCalled()
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it('renders the app for an anonymous session with isAnonymous true', () => {
    auth.state = signedIn({ id: 'anon-1', name: 'Listener', email: 'a@anonymous.mixtape.invalid', isAnonymous: true })

    render(<RootApp />)

    expect(screen.getByText('Signed in as anon-1, anonymous true')).toBeInTheDocument()
    expect(screen.queryByTestId('first-run')).not.toBeInTheDocument()
  })

  it('renders the app for a social session with isAnonymous false', () => {
    auth.state = signedIn({ id: 'user-1', name: 'Noble', email: 'noble@example.com', isAnonymous: false })

    render(<RootApp />)

    expect(screen.getByText('Signed in as user-1, anonymous false')).toBeInTheDocument()
  })

  it('restores a cached anonymous identity while the session is checked', () => {
    rememberIdentity({ id: 'anon-1', name: 'Listener', email: 'a@anonymous.mixtape.invalid', isAnonymous: true })
    auth.state = { data: null, isPending: true, error: null, refetch: () => undefined }

    render(<RootApp />)

    expect(screen.getByText('Signed in as anon-1, anonymous true')).toBeInTheDocument()
    expect(screen.queryByTestId('first-run')).not.toBeInTheDocument()
  })

  it('restores a cached signed-in identity while the session is checked', () => {
    rememberIdentity({ id: 'user-1', name: 'Noble', email: 'noble@example.com', isAnonymous: false })
    auth.state = { data: null, isPending: true, error: null, refetch: () => undefined }

    render(<RootApp />)

    expect(screen.getByText('Signed in as user-1, anonymous false')).toBeInTheDocument()
  })
})
