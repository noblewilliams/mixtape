import { WorkspaceRestoreProvider } from '../lib/workspace-restore'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { PlaylistBrowser } from './PlaylistBrowser'
import { createFakeApi } from '../test/fake-api'
import type { ApiPlaylistSummary } from '../api/client'

afterEach(cleanup)

it('keeps loaded playlists when a later page fails, then retries that cursor', async () => {
  const list = vi
    .fn()
    .mockResolvedValueOnce({ playlists: [playlist], nextCursor: 'next', total: 2 })
    .mockRejectedValueOnce(new TypeError('offline'))
    .mockResolvedValueOnce({
      playlists: [{ ...playlist, id: 'two', name: 'Morning bus' }],
      nextCursor: null,
      total: 2,
    })
  render(
    <PlaylistBrowser
      api={createFakeApi({ listPlaylists: list })}
      onSources={vi.fn()}
      onSessionExpired={vi.fn()}
    />,
  )
  fireEvent.click(await screen.findByRole('button', { name: 'Load more' }))
  fireEvent.click(await screen.findByRole('button', { name: 'Retry loading more' }))
  expect(screen.getByRole('button', { name: 'Open Night bus' })).toBeVisible()
  expect(await screen.findByRole('button', { name: 'Open Morning bus' })).toBeVisible()
  expect(list.mock.calls.slice(1).map(([options]) => options.cursor)).toEqual(['next', 'next'])
})

it('ignores an older response after the source filter changes', async () => {
  let finish!: (value: { playlists: ApiPlaylistSummary[]; nextCursor: null; total: number }) => void
  const list = vi
    .fn()
    .mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          finish = resolve
        }),
    )
    .mockResolvedValue({ playlists: [], nextCursor: null, total: 0 })
  render(
    <PlaylistBrowser
      api={createFakeApi({ listPlaylists: list })}
      onSources={vi.fn()}
      onSessionExpired={vi.fn()}
    />,
  )
  await waitFor(() => expect(list).toHaveBeenCalledOnce())
  fireEvent.change(screen.getByLabelText('Filter source'), { target: { value: 'apple' } })
  await screen.findByText('No matching playlists')
  finish({ playlists: [playlist], nextCursor: null, total: 1 })
  await waitFor(() =>
    expect(screen.queryByRole('button', { name: 'Open Night bus' })).not.toBeInTheDocument(),
  )
  expect(list.mock.calls[0][1].aborted).toBe(true)
})
const playlist: ApiPlaylistSummary = {
  id: 'one',
  name: 'Night bus',
  source: 'spotify_export',
  kind: 'user',
  curatorName: null,
  artworkUrlTemplate: null,
  artworkBgColor: null,
  artworkWidth: null,
  artworkHeight: null,
  entryCount: 3,
  knownDurationMs: null,
  durationComplete: false,
  lastModifiedAt: null,
  syncedAt: null,
  inLibrary: true,
  capability: 'copy_only',
}

it('queries source and search across the collection, not just the loaded tiles', async () => {
  const list = vi.fn(async () => ({ playlists: [playlist], nextCursor: null, total: 1 }))
  const api = createFakeApi({ listPlaylists: list })
  render(<PlaylistBrowser api={api} onSources={vi.fn()} onSessionExpired={vi.fn()} />)
  await screen.findByRole('button', { name: 'Open Night bus' })
  fireEvent.change(screen.getByLabelText('Filter source'), { target: { value: 'spotify_export' } })
  fireEvent.change(screen.getByLabelText('Search playlists'), { target: { value: 'bus' } })
  await waitFor(() =>
    expect(list).toHaveBeenLastCalledWith(
      expect.objectContaining({ source: 'spotify_export', q: 'bus' }),
      expect.any(AbortSignal),
    ),
  )
  expect(await screen.findByText('1 of 1 playlists')).toBeVisible()
})

it('keeps repeated and unavailable entries in order and uses exact Spotify links', async () => {
  const api = createFakeApi({
    listPlaylists: async () => ({ playlists: [playlist], nextCursor: null, total: 1 }),
    getPlaylist: async () => ({
      playlist,
      nextEntryCursor: null,
      entries: [0, 1, 2].map((position) => ({
        id: String(position),
        position,
        trackId: null,
        appleCatalogId: null,
        spotifyId: position === 2 ? null : '4uLU6hMCjMI75M1A2tKUQC',
        title: position === 2 ? 'Home recording' : 'Same song',
        artist: 'Artist',
        album: null,
        durationMs: null,
        artworkUrlTemplate: null,
        artworkWidth: null,
        artworkHeight: null,
        artworkBgColor: null,
        resolved: false,
      })),
    }),
  })
  render(<PlaylistBrowser api={api} onSources={vi.fn()} onSessionExpired={vi.fn()} />)
  fireEvent.click(await screen.findByRole('button', { name: 'Open Night bus' }))
  await screen.findByText('Home recording')
  expect(screen.getAllByText('Same song')).toHaveLength(2)
  expect(screen.getAllByRole('link', { name: 'Open in Spotify' })).toHaveLength(2)
  expect(screen.getAllByRole('link')[0]).toHaveAttribute(
    'href',
    'https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC',
  )
  expect(screen.getByText('Unavailable on the web')).toBeVisible()
})

it('keeps collection controls available without claiming failed music is ready', async () => {
  render(<PlaylistBrowser api={createFakeApi({ listPlaylists: vi.fn().mockRejectedValue(new Error('offline')) })} onSources={vi.fn()} onSessionExpired={vi.fn()} />)
  await screen.findByText('Couldn’t load your playlists')
  expect(screen.queryByText('Your music, ready.')).not.toBeInTheDocument()
  expect(screen.getByRole('textbox', { name: 'Search playlists' })).toBeVisible()
  expect(screen.getByRole('combobox', { name: 'Filter source' })).toBeVisible()
})

it('restores filtered playlists immediately after remount while authentication is pending', async () => {
  sessionStorage.clear()
  const list = vi.fn().mockResolvedValue({ playlists: [playlist], nextCursor: null, total: 1 })
  const api = createFakeApi({ listPlaylists: list })
  const view = (restoring: boolean) => <WorkspaceRestoreProvider userId="library-reader" restoring={restoring}><PlaylistBrowser api={api} onSources={vi.fn()} onSessionExpired={vi.fn()} /></WorkspaceRestoreProvider>
  const first = render(view(false))
  await screen.findByRole('button', { name: 'Open Night bus' })
  fireEvent.change(screen.getByLabelText('Search playlists'), { target: { value: 'Night' } })
  fireEvent.change(screen.getByLabelText('Filter source'), { target: { value: 'spotify_export' } })
  await waitFor(() => expect(list).toHaveBeenLastCalledWith(expect.objectContaining({ q: 'Night', source: 'spotify_export' }), expect.any(AbortSignal)))
  first.unmount()
  list.mockClear()
  const restored = render(view(true))
  expect(screen.getByRole('button', { name: 'Open Night bus' })).toBeVisible()
  expect(screen.getByLabelText('Search playlists')).toHaveValue('Night')
  expect(screen.getByLabelText('Filter source')).toHaveValue('spotify_export')
  expect(list).not.toHaveBeenCalled()
  list.mockImplementation(() => new Promise(() => {}))
  restored.rerender(view(false))
  await waitFor(() => expect(list).toHaveBeenCalled())
  expect(screen.getByRole('button', { name: 'Open Night bus' })).toBeVisible()
  expect(screen.queryByLabelText('Loading playlists')).not.toBeInTheDocument()
})

it('restores an opened playlist and its loaded details', async () => {
  sessionStorage.clear()
  const detail = vi.fn().mockResolvedValue({ playlist: { ...playlist, name: 'Night bus — saved' }, entries: [], nextEntryCursor: null })
  const list = vi.fn().mockResolvedValue({ playlists: [playlist], nextCursor: null, total: 1 })
  const api = createFakeApi({ listPlaylists: list, getPlaylist: detail })
  const view = (restoring: boolean) => <WorkspaceRestoreProvider userId="library-detail-reader" restoring={restoring}><PlaylistBrowser api={api} onSources={vi.fn()} onSessionExpired={vi.fn()} /></WorkspaceRestoreProvider>
  const first = render(view(false))
  fireEvent.click(await screen.findByRole('button', { name: 'Open Night bus' }))
  await screen.findByRole('heading', { name: 'Night bus — saved' })
  first.unmount()
  detail.mockClear()
  render(view(true))
  expect(screen.getByRole('heading', { name: 'Night bus — saved' })).toBeVisible()
  expect(screen.queryByRole('status', { name: 'Loading tracks' })).not.toBeInTheDocument()
  expect(detail).not.toHaveBeenCalled()
  fireEvent.click(screen.getByRole('button', { name: '← All playlists' }))
  expect(screen.getByRole('button', { name: 'Open Night bus' })).toBeVisible()
})

it('holds the playlist layout with a skeleton until its tracks arrive', async () => {
  let finish!: (value: Awaited<ReturnType<ReturnType<typeof createFakeApi>['getPlaylist']>>) => void
  const api = createFakeApi({
    listPlaylists: async () => ({ playlists: [playlist], nextCursor: null, total: 1 }),
    getPlaylist: () => new Promise((resolve) => { finish = resolve }),
  })
  render(<PlaylistBrowser api={api} onInspire={vi.fn()} onSources={vi.fn()} onSessionExpired={vi.fn()} />)
  fireEvent.click(await screen.findByRole('button', { name: 'Open Night bus' }))
  const skeleton = screen.getByRole('status', { name: 'Loading tracks' })
  expect(skeleton.querySelectorAll('.ym-track')).toHaveLength(playlist.entryCount)
  expect(screen.getByRole('heading', { name: 'Night bus' })).toBeVisible()
  expect(screen.getByRole('button', { name: 'Make a mix inspired by this' })).toBeDisabled()
  finish({ playlist: { ...playlist, origin: 'unknown' }, entries: [], nextEntryCursor: null })
  await waitFor(() => expect(screen.queryByRole('status', { name: 'Loading tracks' })).not.toBeInTheDocument())
  expect(screen.getByRole('button', { name: 'Make a mix inspired by this' })).toBeEnabled()
  expect(screen.getByRole('button', { name: 'I curated this' })).toBeVisible()
})
