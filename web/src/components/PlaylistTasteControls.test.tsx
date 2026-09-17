import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { PlaylistTasteControls } from './PlaylistTasteControls'
import { createFakeApi } from '../test/fake-api'
import type { ApiPlaylistSummary } from '../api/client'
afterEach(cleanup)
const playlist: ApiPlaylistSummary = {
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
}
it('requires explicit personal-curation confirmation and adopts the server result', async () => {
  const changed = vi.fn()
  const api = createFakeApi({
    confirmPlaylistTaste: async () => ({ ok: true }),
    getPlaylist: async () => ({
      playlist: { ...playlist, origin: 'user_confirmed' },
      entries: [],
      nextEntryCursor: null,
    }),
  })
  render(
    <PlaylistTasteControls playlist={playlist} api={api} onChanged={changed} onSessionExpired={vi.fn()} />,
  )
  fireEvent.click(screen.getByRole('button', { name: 'I curated this' }))
  expect(api.calls.some((c) => c.method === 'confirmPlaylistTaste')).toBe(false)
  fireEvent.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Confirm my curation' }))
  await waitFor(() =>
    expect(changed).toHaveBeenCalledWith(expect.objectContaining({ origin: 'user_confirmed' })),
  )
})
it('keeps generated or unknown-capability playlists neutral', () => {
  render(
    <PlaylistTasteControls
      playlist={{ ...playlist, origin: 'mixtape' }}
      api={createFakeApi()}
      onChanged={vi.fn()}
      onSessionExpired={vi.fn()}
    />,
  )
  expect(screen.queryByRole('button', { name: 'I curated this' })).not.toBeInTheDocument()
})
it('requires a successful refresh after an uncertain write before another mutation', async () => {
  let readable = false
  const write = vi.fn(async () => ({ ok: true as const }))
  render(
    <PlaylistTasteControls
      playlist={playlist}
      api={createFakeApi({
        confirmPlaylistTaste: write,
        getPlaylist: async () => {
          if (!readable) throw new Error('offline')
          return { playlist, entries: [], nextEntryCursor: null }
        },
      })}
      onChanged={vi.fn()}
      onSessionExpired={vi.fn()}
    />,
  )
  fireEvent.click(screen.getByRole('button', { name: 'I curated this' }))
  fireEvent.click(screen.getByRole('button', { name: 'Confirm my curation' }))
  await screen.findByRole('button', { name: 'Refresh playlist' })
  expect(screen.getByRole('button', { name: 'I curated this' })).toBeDisabled()
  readable = true
  fireEvent.click(screen.getByRole('button', { name: 'Refresh playlist' }))
  await waitFor(() => expect(screen.getByRole('button', { name: 'I curated this' })).toBeEnabled())
  expect(write).toHaveBeenCalledTimes(1)
})
