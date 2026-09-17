import { afterEach, expect, it, vi } from 'vitest'
import { PlaybackController } from './controller'
import { createFakeApi } from '../test/fake-api'
import type { MusicKitClient } from '../musickit/client'
import type { PlayerSample } from './meter'
const song = {
  position: 0,
  trackId: 't',
  appleId: 'a',
  spotifyId: null,
  title: 'Song',
  artist: 'Artist',
  durationMs: 200000,
}
function fixture(enabled = true) {
  let observe: (sample: PlayerSample) => void = () => {}
  const send = vi.fn(async () => ({ accepted: true }))
  const api = createFakeApi({
    playbackPreferences: async () => ({ enabled, revision: 1 }),
    sendPlaybackEvidence: send,
  })
  const music = {
    play: vi.fn(async () => {}),
    stop: vi.fn(async () => {}),
    pause: vi.fn(async () => {}),
    observe: (listener: (sample: PlayerSample) => void) => {
      observe = listener
      return () => {}
    },
    resume: vi.fn(async () => {}),
    next: vi.fn(async () => {}),
  } as unknown as MusicKitClient
  const controller = new PlaybackController(api, music, 'test')
  return {
    api,
    music,
    controller,
    send,
    sample: (positionMs: number, time: number) => {
      vi.spyOn(performance, 'now').mockReturnValue(time)
      observe({ index: 0, positionMs, status: 'playing' })
    },
  }
}
const players: PlaybackController[] = []
afterEach(() => {
  players.forEach((p) => p.dispose())
  players.length = 0
  vi.restoreAllMocks()
  localStorage.clear()
})
it('attributes observed listening to a fixed version, and a new brief does not count old audio while loading', async () => {
  const f = fixture()
  players.push(f.controller)
  await f.controller.initialize()
  await f.controller.start('s', 2, 'Mix', [song])
  for (let t = 0; t <= 60000; t += 1000) f.sample(t, t)
  await f.controller.stop()
  await Promise.resolve()
  expect(f.send).toHaveBeenCalledWith({
    revision: 1,
    events: [
      expect.objectContaining({
        sessionId: 's',
        version: 2,
        trackId: 't',
        observedMs: 60000,
        kind: 'listen',
      }),
    ],
  })
})
it('does not collect without consent, and disposal fences a pending start', async () => {
  const f = fixture(false)
  players.push(f.controller)
  await f.controller.initialize()
  let resolve!: () => void
  vi.mocked(f.music.play).mockImplementation(
    () =>
      new Promise<void>((r) => {
        resolve = r
      }),
  )
  const start = f.controller.start('s', 1, 'Mix', [song])
  await Promise.resolve()
  await Promise.resolve()
  f.controller.dispose()
  resolve()
  await start
  expect(f.send).not.toHaveBeenCalled()
  expect(f.music.stop).toHaveBeenCalled()
})
it('clears pending evidence immediately on opt-out and surfaces an unconfirmed save', async () => {
  const f = fixture()
  players.push(f.controller)
  await f.controller.initialize()
  await f.controller.start('s', 1, 'Mix', [song])
  f.api.savePlaybackPreference = vi.fn(async () => {
    throw new Error('offline')
  })
  await expect(f.controller.preference(false)).rejects.toThrow()
  for (let t = 0; t <= 60000; t += 1000) f.sample(t, t)
  await f.controller.stop()
  expect(f.send).not.toHaveBeenCalled()
  expect(f.controller.getState().preferences).toBeNull()
})
it('retries an offline batch with the same occurrence identity', async () => {
  vi.useFakeTimers()
  const f = fixture()
  players.push(f.controller)
  f.send.mockRejectedValueOnce(new Error('offline'))
  await f.controller.initialize()
  await f.controller.start('s', 2, 'Mix', [song])
  for (let t = 0; t <= 60000; t += 1000) f.sample(t, t)
  await f.controller.stop()
  await Promise.resolve()
  const first = f.send.mock.calls[0]
  await vi.advanceTimersByTimeAsync(30000)
  expect(f.send).toHaveBeenCalledTimes(2)
  expect(f.send.mock.calls[1]).toEqual(first)
  f.controller.dispose()
  vi.useRealTimers()
})
it('a failed start retries the intended queue rather than resuming a leftover provider queue', async () => {
  const f = fixture()
  players.push(f.controller)
  await f.controller.initialize()
  vi.mocked(f.music.play).mockRejectedValueOnce(new Error('unavailable'))
  await f.controller.start('new-mix', 3, 'New mix', [song])
  await f.controller.command('resume')
  expect(f.music.play).toHaveBeenCalledTimes(2)
  expect(f.music.resume).not.toHaveBeenCalled()
  expect(f.controller.getState().sessionId).toBe('new-mix')
})
it('cancel during Apple authorization does not start playback when consent returns later', async () => {
  const f = fixture()
  players.push(f.controller)
  await f.controller.initialize()
  await f.controller.start('s', 1, 'Mix', [song])
  let allow!: () => void
  f.music.connect = vi.fn(
    () =>
      new Promise<void>((resolve) => {
        allow = resolve
      }),
  )
  const reconnect = f.controller.reconnect()
  await f.controller.stop()
  allow()
  await reconnect
  expect(f.music.play).toHaveBeenCalledTimes(1)
  expect(f.controller.getState().busy).toBe(false)
})
