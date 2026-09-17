import { afterEach, expect, it, vi } from 'vitest'
import { ApiError, createMixtapeApi } from './client'

afterEach(() => vi.unstubAllGlobals())

it('preserves explicit inspiration when creating a mix', async () => {
  const fetch = vi.fn().mockResolvedValue(new Response(JSON.stringify({ session: { id: 's' } })))
  vi.stubGlobal('fetch', fetch)
  const seed = { playlistId: 'p', excludeSourceTracks: true }
  await createMixtapeApi('https://mixtape.test').createSession('Warm evening', seed)
  expect(JSON.parse(fetch.mock.calls[0][1].body)).toEqual({ prompt: 'Warm evening', playlistSeed: seed })
})

it('clears inspiration with its revision and surfaces conflicts without retrying', async () => {
  const fetch = vi.fn().mockResolvedValue(new Response(JSON.stringify({ error: 'stale' }), { status: 409 }))
  vi.stubGlobal('fetch', fetch)
  const controller = new AbortController()
  const api = createMixtapeApi('https://mixtape.test')
  const request = api.selectPlaylistSeed(
    'session/1',
    {
      playlistId: null,
      excludeSourceTracks: false,
      expectedRevision: 4,
    },
    controller.signal,
  )
  await expect(request).rejects.toBeInstanceOf(ApiError)
  expect(fetch).toHaveBeenCalledTimes(1)
  expect(fetch).toHaveBeenCalledWith(
    'https://mixtape.test/sessions/session%2F1/playlist-seed',
    expect.objectContaining({
      method: 'PUT',
      signal: controller.signal,
      body: JSON.stringify({ playlistId: null, excludeSourceTracks: false, expectedRevision: 4 }),
    }),
  )
})

it('removes only personal taste confirmation using the existing reversible contract', async () => {
  const fetch = vi.fn().mockResolvedValue(new Response(JSON.stringify({ ok: true })))
  vi.stubGlobal('fetch', fetch)
  const controller = new AbortController()
  await createMixtapeApi('https://mixtape.test').confirmPlaylistTaste('playlist/1', false, controller.signal)
  expect(fetch).toHaveBeenCalledTimes(1)
  expect(fetch).toHaveBeenCalledWith(
    'https://mixtape.test/playlists/playlist%2F1/taste-confirmation',
    expect.objectContaining({
      method: 'PUT',
      signal: controller.signal,
      body: JSON.stringify({ confirmed: false }),
    }),
  )
})
