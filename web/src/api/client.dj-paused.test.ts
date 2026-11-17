import { afterEach, describe, expect, it, vi } from 'vitest'
import { ApiError, createMixtapeApi, isAiConsentRequired, isDjPaused } from './client'

const fetchMock = vi.fn<typeof fetch>()
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } })

describe('the DJ pause switch', () => {
  afterEach(() => {
    fetchMock.mockReset()
    vi.unstubAllGlobals()
  })

  it('reads djPaused from /health, and an older server (no field) as open', async () => {
    vi.stubGlobal('fetch', fetchMock)
    fetchMock.mockResolvedValueOnce(json({ ok: true, service: 'mixtape-api', neverRefuse: false, djPaused: true }))
    fetchMock.mockResolvedValueOnce(json({ ok: true, service: 'mixtape-api', neverRefuse: true }))
    fetchMock.mockResolvedValueOnce(json({ ok: true, service: 'mixtape-api', djPaused: 'yes' }))
    const api = createMixtapeApi('https://api.mixtape.test')

    expect(await api.getConfig()).toEqual({ neverRefuse: false, djPaused: true })
    expect(await api.getConfig()).toEqual({ neverRefuse: true, djPaused: false })
    // Only a real true pauses.
    expect(await api.getConfig()).toEqual({ neverRefuse: false, djPaused: false })
  })

  it('tells a dj_paused 503 apart from other refusals', async () => {
    vi.stubGlobal('fetch', fetchMock)
    fetchMock.mockResolvedValueOnce(json({ error: 'dj_paused' }, 503))
    const api = createMixtapeApi('https://api.mixtape.test')
    const refused = await api.createSession('Late night drive').catch((error: unknown) => error)

    expect(refused).toBeInstanceOf(ApiError)
    expect(isDjPaused(refused)).toBe(true)
    expect(isAiConsentRequired(refused)).toBe(false)
    expect(isDjPaused(new ApiError(503, { error: 'overloaded' }))).toBe(false)
    expect(isDjPaused(new ApiError(500, { error: 'dj_paused' }))).toBe(false)
    expect(isDjPaused(new Error('dj_paused'))).toBe(false)
  })
})
