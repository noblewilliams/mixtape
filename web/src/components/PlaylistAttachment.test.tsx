import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { PlaylistAttachment } from './PlaylistAttachment'
import { createFakeApi } from '../test/fake-api'
afterEach(cleanup)
it('selects an exact playlist without generating a mix and dismisses its floating picker', async () => {
  const select = vi.fn().mockResolvedValue(undefined)
  const api = createFakeApi({
    listPlaylists: async () => ({
      playlists: [
        {
          id: 'p',
          name: 'Night notes',
          source: 'apple',
          entryCount: 12,
          curatorName: null,
          kind: 'unknown',
          origin: 'unknown',
          artworkUrlTemplate: null,
          artworkWidth: null,
          artworkHeight: null,
          artworkBgColor: null,
          knownDurationMs: null,
          durationComplete: false,
          lastModifiedAt: null,
          syncedAt: null,
          inLibrary: true,
          capability: 'copy_only',
        },
      ],
      total: 1,
      nextCursor: null,
    }),
  })
  render(<PlaylistAttachment api={api} value={null} onSelect={select} onSessionExpired={vi.fn()} />)
  fireEvent.click(screen.getByRole('button', { name: 'Attach playlist inspiration' }))
  fireEvent.click(await screen.findByRole('button', { name: /Night notes/ }))
  await waitFor(() =>
    expect(select).toHaveBeenCalledWith(expect.objectContaining({ playlistId: 'p', name: 'Night notes' })),
  )
  expect(api.calls.some((c) => c.method === 'createSession')).toBe(false)
  expect(screen.queryByRole('searchbox')).not.toBeInTheDocument()
})
