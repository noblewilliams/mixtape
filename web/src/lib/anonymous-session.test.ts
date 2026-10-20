import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { sessionTokenStore } from './session-token'

const fetchMock = vi.fn<typeof fetch>()

function requestUrl(input: Parameters<typeof fetch>[0]): string {
  return input instanceof Request ? input.url : String(input)
}

function anonymousCalls() {
  return fetchMock.mock.calls.filter(([input]) => requestUrl(input).endsWith('/sign-in/anonymous'))
}

describe('anonymous session', () => {
  beforeEach(() => {
    vi.resetModules()
    sessionTokenStore.clear()
    fetchMock.mockImplementation(async (input) => {
      if (requestUrl(input).endsWith('/sign-in/anonymous')) {
        await new Promise((resolve) => setTimeout(resolve, 5))
        return new Response(JSON.stringify({ token: 'body-token', user: { id: 'anon-1', isAnonymous: true } }), {
          status: 200,
          headers: { 'content-type': 'application/json', 'set-auth-token': 'anon-token' },
        })
      }
      return new Response('null', { status: 200, headers: { 'content-type': 'application/json' } })
    })
    vi.stubGlobal('fetch', fetchMock)
  })
  afterEach(() => {
    fetchMock.mockReset()
    vi.unstubAllGlobals()
    sessionTokenStore.clear()
  })

  it('makes no request when the module loads', async () => {
    await import('./anonymous-session')
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it('signs in anonymously once when called three times at once and stores the token', async () => {
    const { ensureSession } = await import('./anonymous-session')
    const { sessionTokenStore: tokens } = await import('./session-token')

    await Promise.all([ensureSession(), ensureSession(), ensureSession()])

    expect(anonymousCalls()).toHaveLength(1)
    const [, init] = anonymousCalls()[0]
    expect(init?.method ?? (anonymousCalls()[0][0] as Request).method).toBe('POST')
    expect(tokens.read()).toBe('anon-token')
  })

  it('does not sign in again when a session token is already held', async () => {
    const { ensureSession } = await import('./anonymous-session')
    const { sessionTokenStore: tokens } = await import('./session-token')
    tokens.write('existing-token')

    await ensureSession()

    expect(anonymousCalls()).toHaveLength(0)
    expect(tokens.read()).toBe('existing-token')
  })

  it('lets a later call retry after a failed anonymous sign-in', async () => {
    const { ensureSession } = await import('./anonymous-session')
    const { sessionTokenStore: tokens } = await import('./session-token')
    fetchMock.mockImplementationOnce(async () => new Response(JSON.stringify({ message: 'Too many requests' }), {
      status: 429, headers: { 'content-type': 'application/json' },
    }))

    await expect(ensureSession()).rejects.toThrow()
    expect(tokens.read()).toBeNull()

    await ensureSession()
    expect(anonymousCalls()).toHaveLength(2)
    expect(tokens.read()).toBe('anon-token')
  })

  it('fails clearly when the sign-in response has no set-auth-token header', async () => {
    const { ensureSession } = await import('./anonymous-session')
    const { sessionTokenStore: tokens } = await import('./session-token')
    fetchMock.mockImplementationOnce(async () => new Response(JSON.stringify({ token: 'raw-token', user: { id: 'anon-1' } }), {
      status: 200, headers: { 'content-type': 'application/json' },
    }))

    await expect(ensureSession()).rejects.toThrow('set-auth-token')
    expect(tokens.read()).toBeNull()
  })
})
