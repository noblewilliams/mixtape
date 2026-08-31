import { afterEach, describe, expect, it, vi } from 'vitest'
import { ApiError, createMixtapeApi } from './client'

const fetchMock = vi.fn<typeof fetch>()

describe('Mixtape API client', () => {
  afterEach(() => {
    fetchMock.mockReset()
    vi.unstubAllGlobals()
  })

  it('loads sessions with credentialed requests', async () => {
    fetchMock.mockResolvedValue(
      new Response(
        JSON.stringify({
          sessions: [
            {
              id: 'session-1',
              title: 'Blue hour',
              status: 'active',
              queueVersion: 2,
              updatedAt: '2026-08-30T18:00:00.000Z',
              trackCount: 12,
              durationMs: 2_400_000,
            },
          ],
        }),
        { status: 200, headers: { 'content-type': 'application/json' } },
      ),
    )
    vi.stubGlobal('fetch', fetchMock)

    const api = createMixtapeApi('https://api.mixtape.test')
    const result = await api.listSessions()

    expect(result.sessions[0].trackCount).toBe(12)
    expect(fetchMock).toHaveBeenCalledWith(
      'https://api.mixtape.test/sessions',
      expect.objectContaining({ credentials: 'include' }),
    )
  })

  it('authenticates direct API requests with the current session token', async () => {
    fetchMock.mockResolvedValue(
      new Response(JSON.stringify({ sessions: [] }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const api = createMixtapeApi('https://api.mixtape.test', () => 'session-token')
    await api.listSessions()

    const request = fetchMock.mock.calls[0][1]
    const headers = new Headers(request?.headers)
    expect(headers.get('authorization')).toBe('Bearer session-token')
  })

  it('omits the authorization header before a session is available', async () => {
    fetchMock.mockResolvedValue(
      new Response(JSON.stringify({ sessions: [] }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const api = createMixtapeApi('https://api.mixtape.test', () => null)
    await api.listSessions()

    const request = fetchMock.mock.calls[0][1]
    const headers = new Headers(request?.headers)
    expect(headers.has('authorization')).toBe(false)
  })

  it('posts a DJ message as JSON', async () => {
    fetchMock.mockResolvedValue(
      new Response(
        JSON.stringify({
          djMessage: {
            id: 'message-2',
            role: 'dj',
            content: 'I moved the brighter songs forward.',
            queueVersion: 3,
            createdAt: '2026-08-30T18:00:04.000Z',
          },
          queue: [],
          queueVersion: 3,
        }),
        { status: 200, headers: { 'content-type': 'application/json' } },
      ),
    )
    vi.stubGlobal('fetch', fetchMock)

    const api = createMixtapeApi('https://api.mixtape.test/')
    await api.sendMessage('session-1', 'Move the brighter songs forward.')

    expect(fetchMock).toHaveBeenCalledWith(
      'https://api.mixtape.test/sessions/session-1/messages',
      expect.objectContaining({
        method: 'POST',
        body: JSON.stringify({ text: 'Move the brighter songs forward.' }),
      }),
    )
  })

  it('loads a short-lived MusicKit token with the signed-in browser session', async () => {
    fetchMock.mockResolvedValue(
      new Response(JSON.stringify({ developerToken: 'developer-token', expiresAt: 1_788_138_000 }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const api = createMixtapeApi('https://api.mixtape.test')
    const result = await api.getMusicKitToken()

    expect(result).toEqual({ developerToken: 'developer-token', expiresAt: 1_788_138_000 })
    expect(fetchMock).toHaveBeenCalledWith(
      'https://api.mixtape.test/musickit/token',
      expect.objectContaining({ credentials: 'include' }),
    )
  })

  it('marks an expired browser session as unauthorized', async () => {
    fetchMock.mockResolvedValue(
      new Response(JSON.stringify({ error: 'unauthorized' }), {
        status: 401,
        headers: { 'content-type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const api = createMixtapeApi('https://api.mixtape.test')

    const request = api.listSessions()
    await expect(request).rejects.toBeInstanceOf(ApiError)
    await expect(request).rejects.toMatchObject({ status: 401, code: 'unauthorized' })
  })
})
