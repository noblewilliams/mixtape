import { renderHook } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

type FakeSession = {
  data: { user: { id: string; name: string; email: string; image: null; isAnonymous: boolean }; session: { token: string } } | null
  isPending: boolean
  error: Error | null
  refetch: () => void
}

const fake = vi.hoisted(() => ({
  session: { data: null, isPending: false, error: null, refetch: () => undefined } as FakeSession,
  signOut: vi.fn(async () => ({})),
  anonymous: vi.fn(),
}))

vi.mock('better-auth/react', () => ({
  createAuthClient: () => ({
    useSession: () => fake.session,
    signOut: fake.signOut,
    signIn: { anonymous: fake.anonymous },
  }),
}))

function withToken(token: string, isPending = false): FakeSession {
  return {
    data: { user: { id: 'anon-1', name: 'Listener', email: 'a@anonymous.mixtape.invalid', image: null, isAnonymous: true }, session: { token } },
    isPending, error: null, refetch: () => undefined,
  }
}
const empty = (isPending: boolean): FakeSession => ({ data: null, isPending, error: null, refetch: () => undefined })

async function load() {
  const { browserAuth } = await import('./auth-client')
  const { sessionTokenStore } = await import('./session-token')
  const { ensureSession } = await import('./anonymous-session')
  return { browserAuth, sessionTokenStore, ensureSession }
}

describe('browser auth token handling', () => {
  beforeEach(() => {
    vi.resetModules()
    localStorage.clear()
    sessionStorage.clear()
    fake.session = empty(false)
    fake.anonymous.mockImplementation(async (options: { fetchOptions?: { onSuccess?: (context: { response: Response }) => void } }) => {
      options.fetchOptions?.onSuccess?.({ response: new Response(null, { headers: { 'set-auth-token': 'signed-anon-token' } }) })
      return { data: { token: 'raw-anon-token', user: { id: 'anon-1' } }, error: null }
    })
  })
  afterEach(() => {
    fake.anonymous.mockReset()
    fake.signOut.mockClear()
  })

  it('keeps a token ensureSession stored through renders with no session data, pending or not', async () => {
    const { browserAuth, sessionTokenStore, ensureSession } = await load()
    const { rerender } = renderHook(() => browserAuth.useSession())

    await ensureSession()
    expect(sessionTokenStore.read()).toBe('signed-anon-token')

    fake.session = empty(true)
    rerender()
    expect(sessionTokenStore.read()).toBe('signed-anon-token')

    fake.session = empty(false)
    rerender()
    expect(sessionTokenStore.read()).toBe('signed-anon-token')
  })

  it('clears an observed token once the session is gone and the check is not pending', async () => {
    const { browserAuth, sessionTokenStore } = await load()
    fake.session = withToken('session-token')
    const { rerender } = renderHook(() => browserAuth.useSession())
    expect(sessionTokenStore.read()).toBe('session-token')

    fake.session = empty(true)
    rerender()
    expect(sessionTokenStore.read()).toBe('session-token')

    fake.session = empty(false)
    rerender()
    expect(sessionTokenStore.read()).toBeNull()
  })

  it('signOut clears the store and forgets the observed token', async () => {
    const { browserAuth, sessionTokenStore } = await load()
    fake.session = withToken('session-token')
    const { rerender } = renderHook(() => browserAuth.useSession())

    await browserAuth.signOut()
    expect(fake.signOut).toHaveBeenCalledOnce()
    expect(sessionTokenStore.read()).toBeNull()

    // A later token from ensureSession is not treated as the observed one.
    sessionTokenStore.write('next-anon-token')
    fake.session = empty(false)
    rerender()
    expect(sessionTokenStore.read()).toBe('next-anon-token')
  })

  it('never writes the token to browser storage', async () => {
    const { browserAuth, ensureSession } = await load()
    fake.session = withToken('session-token')
    renderHook(() => browserAuth.useSession())
    expect(localStorage.length).toBe(0)
    expect(sessionStorage.length).toBe(0)

    vi.resetModules()
    fake.session = empty(false)
    const fresh = await load()
    renderHook(() => fresh.browserAuth.useSession())
    await ensureSession()
    await fresh.ensureSession()
    expect(localStorage.length).toBe(0)
    expect(sessionStorage.length).toBe(0)
  })
})
