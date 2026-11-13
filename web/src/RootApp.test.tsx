import { cleanup, render, screen, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { AuthSessionState, AuthUser } from './components/AuthGate'
import { clearWorkspaceRestore, rememberIdentity } from './lib/workspace-restore'
import { sessionTokenStore } from './lib/session-token'

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
    window.history.replaceState({}, '', '/')
    sessionTokenStore.clear()
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

  describe('a shared mix link', () => {
    const token = '4fQ9xK2mZr7TbW1nLpY8sA'
    const body = { token, title: 'Late drive', caseColor: '#bc5734', sharerName: 'Ada', sharedAt: '2026-11-13T09:00:00.000Z', isOwner: false, tracks: [] }
    const ok = (value: unknown) => new Response(JSON.stringify(value), { status: 200, headers: { 'content-type': 'application/json' } })

    it('renders the shared page outside the gate: no first run, no sign-in, only the public read', async () => {
      window.history.replaceState({}, '', `/m/${token}`)
      const fetchMock = vi.fn<typeof fetch>(async () => ok(body))
      vi.stubGlobal('fetch', fetchMock)

      render(<RootApp />)

      expect(await screen.findByText('Shared by Ada')).toBeInTheDocument()
      expect(screen.queryByTestId('first-run')).not.toBeInTheDocument()
      expect(auth.signInAnonymous).not.toHaveBeenCalled()
      expect(fetchMock.mock.calls.map(([url]) => new URL(String(url)).pathname)).toEqual([`/shared/${token}`])
    })

    it('renders the shared page for a signed-in listener instead of the app, and saves it once', async () => {
      window.history.replaceState({}, '', `/m/${token}/`)
      auth.state = signedIn({ id: 'user-1', name: 'Noble', email: 'noble@example.com', isAnonymous: false })
      sessionTokenStore.write('session-token')
      const fetchMock = vi.fn<typeof fetch>(async (url) => String(url).endsWith('/save') ? new Response(null, { status: 204 }) : ok(body))
      vi.stubGlobal('fetch', fetchMock)

      render(<RootApp />)

      expect(await screen.findByText('Shared by Ada')).toBeInTheDocument()
      expect(screen.queryByText(/Signed in as/)).not.toBeInTheDocument()
      await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2))
      expect(fetchMock.mock.calls.map(([url, init]) => `${init?.method ?? 'GET'} ${new URL(String(url)).pathname}`)).toEqual([`GET /shared/${token}`, `POST /shared/${token}/save`])
      expect(new Headers(fetchMock.mock.calls[1][1]?.headers).get('authorization')).toBe('Bearer session-token')
    })
  })
})
