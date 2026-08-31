import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { App } from './App'
import type { MusicKitClient } from './musickit/client'
import { createFakeApi } from './test/fake-api'

const user = { id: 'user-1', name: 'Noble', email: 'noble@example.com' }

function createFakeMusicKit(overrides: Partial<MusicKitClient> = {}): MusicKitClient {
  return {
    connect: vi.fn(async () => undefined),
    play: vi.fn(async () => undefined),
    pause: vi.fn(async () => undefined),
    createPlaylist: vi.fn(async () => undefined),
    ...overrides,
  }
}

function renderApp(options: { api?: ReturnType<typeof createFakeApi>; musicKit?: MusicKitClient } = {}) {
  const api = options.api ?? createFakeApi()
  const musicKit = options.musicKit ?? createFakeMusicKit()
  render(<App api={api} musicKit={musicKit} user={user} onSignOut={vi.fn()} />)
  return { api, musicKit }
}

describe('Mixtape web shell', () => {
  afterEach(cleanup)

  it('opens on the server-backed conversation with an unlabeled DJ voice and current tape', async () => {
    renderApp()

    expect(await screen.findByRole('heading', { name: 'Blue hour, windows down' })).toBeInTheDocument()
    expect(await screen.findByText(/I kept the opening close/)).toBeInTheDocument()
    expect(screen.getByRole('complementary', { name: 'Your mix' })).toBeInTheDocument()
    expect(screen.queryByText(/^DJ$/)).not.toBeInTheDocument()
    expect(screen.queryByText(/^You$/)).not.toBeInTheDocument()
  })

  it('renders the Closet as one tightly packed shelf of text-only spines', async () => {
    renderApp()
    fireEvent.click(await screen.findByRole('button', { name: 'Home' }))
    fireEvent.click(screen.getByRole('button', { name: 'Closet view' }))

    const closet = screen.getByRole('region', { name: 'Tape closet' })
    expect(within(closet).getAllByRole('list')).toHaveLength(1)
    expect(within(closet).getAllByRole('button')).toHaveLength(19)
    expect(closet.querySelectorAll('.tape-spine svg')).toHaveLength(0)
  })

  it('creates a tape through the server and opens its conversation', async () => {
    renderApp()
    fireEvent.click(await screen.findByRole('button', { name: 'Make a new tape' }))
    fireEvent.change(screen.getByLabelText('What should this tape feel like?'), {
      target: { value: 'Dinner after the rain' },
    })
    fireEvent.click(screen.getByRole('button', { name: 'Start tape' }))

    expect(await screen.findByRole('heading', { name: 'Dinner after the rain' })).toBeInTheDocument()
    expect(screen.getByText('I made a first pass for this moment.')).toBeInTheDocument()
  })

  it('posts a listener message and follows it with the DJ response', async () => {
    renderApp()
    fireEvent.change(await screen.findByLabelText('Message your DJ'), {
      target: { value: 'Make the middle brighter.' },
    })
    fireEvent.click(screen.getByRole('button', { name: 'Send message' }))

    expect(screen.getByText('Make the middle brighter.')).toBeInTheDocument()
    expect(await screen.findByText(/reshaped the middle around that feeling/)).toBeInTheDocument()
  })

  it('keeps the mix visible and asks for Apple Music only at the action boundary', async () => {
    renderApp()

    expect(await screen.findByText('Sweetest Taboo')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Connect Apple Music' })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Play now' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Create playlist' })).not.toBeInTheDocument()
  })

  it('holds the action footprint while Apple authorizes, then reveals playback controls', async () => {
    let resolveConnection: () => void = () => undefined
    const connect = vi.fn(
      () => new Promise<void>((resolve) => {
        resolveConnection = resolve
      }),
    )
    renderApp({ musicKit: createFakeMusicKit({ connect }) })

    fireEvent.click(await screen.findByRole('button', { name: 'Connect Apple Music' }))
    expect(screen.getByRole('button', { name: 'Connecting Apple Music…' })).toBeDisabled()
    expect(screen.getByText('Waiting for Apple Music. Keep this window open.')).toBeInTheDocument()

    await act(async () => resolveConnection())

    expect(await screen.findByText('Apple Music connected. Ready to play.')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Play now' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Create playlist' })).toBeInTheDocument()
  })

  it('shows the approved recovery action when Apple authorization does not finish', async () => {
    const connect = vi.fn(async () => {
      throw new Error('cancelled')
    })
    renderApp({ musicKit: createFakeMusicKit({ connect }) })

    fireEvent.click(await screen.findByRole('button', { name: 'Connect Apple Music' }))

    expect(await screen.findByText('Apple Music didn’t connect.')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Try Apple Music again' })).toBeInTheDocument()
  })

  it('records playback only after MusicKit starts the real Apple queue', async () => {
    let resolvePlayback: () => void = () => undefined
    const play = vi.fn(
      () => new Promise<void>((resolve) => {
        resolvePlayback = resolve
      }),
    )
    const recordSessionEvent = vi.fn(async () => ({ ok: true as const }))
    const api = createFakeApi({ recordSessionEvent })
    renderApp({ api, musicKit: createFakeMusicKit({ play }) })

    fireEvent.click(await screen.findByRole('button', { name: 'Connect Apple Music' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Play now' }))

    expect(play).toHaveBeenCalledWith(Array.from({ length: 15 }, (_, index) => `apple-${index + 1}`))
    expect(recordSessionEvent).not.toHaveBeenCalled()
    await act(async () => resolvePlayback())

    await waitFor(() => {
      expect(recordSessionEvent).toHaveBeenCalledWith('blue-hour', 'played')
    })
    expect(screen.getByRole('button', { name: 'Pause' })).toBeInTheDocument()
  })

  it('creates and records an Apple playlist only after the Apple request succeeds', async () => {
    let resolvePlaylist: () => void = () => undefined
    const createPlaylist = vi.fn(
      () => new Promise<void>((resolve) => {
        resolvePlaylist = resolve
      }),
    )
    const recordSessionEvent = vi.fn(async () => ({ ok: true as const }))
    const api = createFakeApi({ recordSessionEvent })
    renderApp({ api, musicKit: createFakeMusicKit({ createPlaylist }) })

    fireEvent.click(await screen.findByRole('button', { name: 'Connect Apple Music' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Create playlist' }))
    expect(screen.getByRole('dialog', { name: 'Create playlist' })).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Confirm create playlist' }))

    expect(createPlaylist).toHaveBeenCalledWith(
      'Blue hour, windows down',
      Array.from({ length: 15 }, (_, index) => `apple-${index + 1}`),
    )
    expect(recordSessionEvent).not.toHaveBeenCalled()
    await act(async () => resolvePlaylist())

    await waitFor(() => {
      expect(recordSessionEvent).toHaveBeenCalledWith('blue-hour', 'saved_playlist')
    })
    expect(screen.getByText('“Blue hour, windows down” is now in Apple Music.')).toBeInTheDocument()
  })
})
