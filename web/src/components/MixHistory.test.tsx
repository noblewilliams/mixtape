import {
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor,
} from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { MixHistory } from './MixHistory'
import { createFakeApi } from '../test/fake-api'
import { ApiError } from '../api/client'
afterEach(cleanup)
const list = {
  currentVersion: 2,
  versions: [
    { version: 1, trackCount: 1, restoredFrom: null, createdAt: '2026-09-09' },
  ],
  nextBefore: null,
}
const detail = {
  version: 1,
  currentVersion: 2,
  restoredFrom: null,
  entries: [
    {
      position: 0,
      trackId: 't',
      title: 'Song',
      artist: 'Artist',
      reason: null,
      available: true,
    },
  ],
}
it('previews and confirms restore, then refreshes the current mix', async () => {
  const restore = vi.fn(async () => ({ version: 3 })),
    refresh = vi.fn(async () => {})
  render(
    <MixHistory
      sessionId="s"
      api={createFakeApi({
        listMixVersions: async () => list,
        readMixVersion: async () => detail,
        restoreMixVersion: restore,
      })}
      onClose={() => {}}
      onSessionExpired={() => {}}
      onRestored={refresh}
    />,
  )
  fireEvent.click(await screen.findByRole('button', { name: 'View' }))
  expect(await screen.findByText('Song')).toBeInTheDocument()
  expect(restore).not.toHaveBeenCalled()
  fireEvent.click(screen.getByRole('button', { name: 'Use this version' }))
  fireEvent.click(screen.getByRole('button', { name: 'Use version 1' }))
  expect(await screen.findByText(/Version 3 is ready/)).toBeInTheDocument()
  expect(restore.mock.calls[0]).toEqual([
    's',
    expect.objectContaining({
      version: 1,
      expectedVersion: 2,
      requestId: expect.any(String),
    }),
  ])
  expect(refresh).toHaveBeenCalledTimes(1)
})
it('reuses the restore identity after an unknown response', async () => {
  const restore = vi
    .fn()
    .mockRejectedValueOnce(new Error('offline'))
    .mockResolvedValue({ version: 3 })
  render(
    <MixHistory
      sessionId="s"
      api={createFakeApi({
        listMixVersions: async () => list,
        readMixVersion: async () => detail,
        restoreMixVersion: restore,
      })}
      onClose={() => {}}
      onSessionExpired={() => {}}
      onRestored={async () => {}}
    />,
  )
  fireEvent.click(await screen.findByRole('button', { name: 'View' }))
  fireEvent.click(
    await screen.findByRole('button', { name: 'Use this version' }),
  )
  fireEvent.click(screen.getByRole('button', { name: 'Use version 1' }))
  fireEvent.click(await screen.findByRole('button', { name: 'Retry restore' }))
  await screen.findByText(/Version 3 is ready/)
  expect(restore.mock.calls[0]).toEqual(restore.mock.calls[1])
})
it('rejects stale restore without success and reloads the latest list', async () => {
  const refresh = vi.fn(async () => {})
  render(
    <MixHistory
      sessionId="s"
      api={createFakeApi({
        listMixVersions: async () => list,
        readMixVersion: async () => detail,
        restoreMixVersion: async () => {
          throw new ApiError(409, { error: 'conflict' })
        },
      })}
      onClose={() => {}}
      onSessionExpired={() => {}}
      onRestored={refresh}
    />,
  )
  fireEvent.click(await screen.findByRole('button', { name: 'View' }))
  fireEvent.click(
    await screen.findByRole('button', { name: 'Use this version' }),
  )
  fireEvent.click(screen.getByRole('button', { name: 'Use version 1' }))
  expect(await screen.findByRole('alert')).toHaveTextContent('Your mix changed')
  expect(refresh).not.toHaveBeenCalled()
  fireEvent.click(screen.getByRole('button', { name: 'Review latest' }))
  await waitFor(() =>
    expect(screen.queryByRole('alert')).not.toBeInTheDocument(),
  )
})
