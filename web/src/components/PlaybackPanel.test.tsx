import { afterEach, expect, it, vi } from 'vitest'
import {
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor,
} from '@testing-library/react'
import { PlaybackPanel } from './PlaybackPanel'
import { PlaybackController } from '../playback/controller'
import { createFakeApi } from '../test/fake-api'
import type { MusicKitClient } from '../musickit/client'
afterEach(cleanup)
it('seeks once on release and keeps clear learning behind explicit confirmation', async () => {
  const api = createFakeApi()
  const seek = vi.fn(async () => {})
  const music = {
    play: async () => {},
    pause: async () => {},
    seek,
    stop: async () => {},
  } as unknown as MusicKitClient
  const controller = new PlaybackController(api, music, 'test-panel')
  await controller.initialize()
  await controller.start('s', 1, 'Mix', [
    {
      position: 0,
      trackId: 't',
      appleId: '1',
      spotifyId: null,
      title: 'Song',
      artist: 'Artist',
      durationMs: 200000,
    },
  ])
  const { unmount } = render(<PlaybackPanel controller={controller} />)
  fireEvent.click(screen.getByRole('button', { name: 'Open player' }))
  const slider = screen.getByRole('slider')
  fireEvent.change(slider, { target: { value: '60000' } })
  expect(seek).not.toHaveBeenCalled()
  fireEvent.pointerUp(slider)
  await waitFor(() => expect(seek).toHaveBeenCalledWith(60))
  fireEvent.click(screen.getByRole('button', { name: 'Listening preferences' }))
  fireEvent.click(
    screen.getByRole('button', { name: 'Clear learned listening' }),
  )
  expect(
    api.calls.filter((c) => c.method === 'clearPlaybackEvidence'),
  ).toHaveLength(0)
  fireEvent.click(
    screen.getByRole('button', { name: 'Clear learned listening' }),
  )
  await screen.findByText('Learned listening cleared.')
  expect(
    api.calls.filter((c) => c.method === 'clearPlaybackEvidence'),
  ).toHaveLength(1)
  unmount()
  controller.dispose()
})
