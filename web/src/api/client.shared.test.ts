import { afterEach, describe, expect, it, vi } from 'vitest'
import { ApiError, createMixtapeApi, EmptyMixError, ShareNameRequiredError, SharedMixGoneError } from './client'
import { MalformedResponseError } from './mappers'

const fetchMock = vi.fn<typeof fetch>()
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } })
const empty = () => new Response(null, { status: 204 })
const token = '4fQ9xK2mZr7TbW1nLpY8sA'
const shared = {
  token, title: 'Late drive', caseColor: '#bc5734', sharerName: 'Ada', sharedAt: '2026-11-13T09:00:00.000Z', isOwner: false,
  tracks: [{ title: 'Midnight City', artist: 'M83', album: null, durationMs: 243_000, artwork: null, appleId: '1', isrc: null }],
}

function api(accessToken: string | null = null) {
  vi.stubGlobal('fetch', fetchMock)
  return createMixtapeApi('https://api.mixtape.test', () => accessToken)
}
function lastCall() {
  const [url, init] = fetchMock.mock.calls.at(-1)!
  return { url: String(url), method: init?.method ?? 'GET', headers: new Headers(init?.headers) }
}

describe('shared mix client', () => {
  afterEach(() => {
    fetchMock.mockReset()
    vi.unstubAllGlobals()
  })

  it('reads a share without a session and maps it strictly', async () => {
    fetchMock.mockResolvedValue(json(shared))
    const mix = await api().getSharedMix(token)
    expect(lastCall()).toMatchObject({ url: `https://api.mixtape.test/shared/${token}`, method: 'GET' })
    expect(lastCall().headers.has('authorization')).toBe(false)
    expect(mix.tracks[0]).toEqual({ title: 'Midnight City', artist: 'M83', durationMs: 243_000, appleId: '1' })
  })

  it('sends the session when there is one, so the server can tell the owner', async () => {
    fetchMock.mockResolvedValue(json({ ...shared, isOwner: true, sessionId: 's-1' }))
    const mix = await api('session-token').getSharedMix(token)
    expect(lastCall().headers.get('authorization')).toBe('Bearer session-token')
    expect(mix).toMatchObject({ isOwner: true, sessionId: 's-1' })
  })

  it.each([
    [404, 'not_found'],
    [410, 'revoked'],
  ] as const)('turns %i %s into SharedMixGoneError', async (status, error) => {
    fetchMock.mockResolvedValue(json({ error }, status))
    const failure = await api().getSharedMix(token).catch((e: unknown) => e)
    expect(failure).toBeInstanceOf(SharedMixGoneError)
    expect(failure).toBeInstanceOf(ApiError)
    expect((failure as SharedMixGoneError).reason).toBe(error)
  })

  it('leaves a rate limit as a plain ApiError', async () => {
    fetchMock.mockResolvedValue(json({ error: 'rate_limited' }, 429))
    const failure = await api().getSharedMix(token).catch((e: unknown) => e)
    expect(failure).toBeInstanceOf(ApiError)
    expect(failure).not.toBeInstanceOf(SharedMixGoneError)
    expect((failure as ApiError).code).toBe('rate_limited')
  })

  it('rejects a malformed share body', async () => {
    fetchMock.mockResolvedValue(json({ ...shared, tracks: 'none' }))
    await expect(api().getSharedMix(token)).rejects.toBeInstanceOf(MalformedResponseError)
  })

  it('escapes the token in the path', async () => {
    fetchMock.mockResolvedValue(json({ error: 'not_found' }, 404))
    await api().getSharedMix('a/b').catch(() => undefined)
    expect(lastCall().url).toBe('https://api.mixtape.test/shared/a%2Fb')
  })

  it('saves and removes a share', async () => {
    fetchMock.mockResolvedValue(empty())
    const client = api('t')
    await client.saveSharedMix(token)
    expect(lastCall()).toMatchObject({ url: `https://api.mixtape.test/shared/${token}/save`, method: 'POST' })
    fetchMock.mockResolvedValue(empty())
    await client.removeSharedMix(token)
    expect(lastCall()).toMatchObject({ url: `https://api.mixtape.test/shared/${token}/save`, method: 'DELETE' })
  })

  it('turns a gone share on save into SharedMixGoneError', async () => {
    fetchMock.mockResolvedValue(json({ error: 'revoked' }, 410))
    await expect(api('t').saveSharedMix(token)).rejects.toBeInstanceOf(SharedMixGoneError)
  })

  it('lists saved shares strictly', async () => {
    fetchMock.mockResolvedValue(json({ mixes: [{ token, title: 'Late drive', caseColor: '#bc5734', sharerName: 'Ada', savedAt: '2026-11-13T09:00:00.000Z', trackCount: 1, durationMs: 243_000, artwork: null }] }))
    const rows = await api('t').listSharedMixes()
    expect(lastCall()).toMatchObject({ url: 'https://api.mixtape.test/me/shared-mixes', method: 'GET' })
    expect(rows).toEqual([{ token, title: 'Late drive', caseColor: '#bc5734', sharerName: 'Ada', savedAt: '2026-11-13T09:00:00.000Z', trackCount: 1, durationMs: 243_000 }])
    fetchMock.mockResolvedValue(json({ mixes: [{ token }] }))
    await expect(api('t').listSharedMixes()).rejects.toBeInstanceOf(MalformedResponseError)
  })

  it('shares a session and returns its link', async () => {
    fetchMock.mockResolvedValue(json({ token, url: `https://miixtape.netlify.app/m/${token}` }))
    await expect(api('t').shareSession('s-1')).resolves.toEqual({ token, url: `https://miixtape.netlify.app/m/${token}` })
    expect(lastCall()).toMatchObject({ url: 'https://api.mixtape.test/sessions/s-1/share', method: 'POST' })
  })

  it('turns 409 name_required and 422 empty_mix into their own errors', async () => {
    fetchMock.mockResolvedValue(json({ error: 'name_required' }, 409))
    await expect(api('t').shareSession('s-1')).rejects.toBeInstanceOf(ShareNameRequiredError)
    fetchMock.mockResolvedValue(json({ error: 'empty_mix' }, 422))
    await expect(api('t').shareSession('s-1')).rejects.toBeInstanceOf(EmptyMixError)
  })

  it('rejects a share response without a token or url', async () => {
    fetchMock.mockResolvedValue(json({ token }))
    await expect(api('t').shareSession('s-1')).rejects.toBeInstanceOf(MalformedResponseError)
  })

  it('stops sharing a session', async () => {
    fetchMock.mockResolvedValue(empty())
    await api('t').stopSharing('s-1')
    expect(lastCall()).toMatchObject({ url: 'https://api.mixtape.test/sessions/s-1/share', method: 'DELETE' })
  })
})
