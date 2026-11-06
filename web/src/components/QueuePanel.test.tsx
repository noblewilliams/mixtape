import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { QueueOp } from '../api/client'
import type { DjSession, QueueTrack } from '../domain'
import { QueuePanel, type MusicConnectionState } from './QueuePanel'

const session: DjSession = {
  id: 'session-1',
  kind: 'mix',
  title: 'Blue hour',
  status: 'active',
  queueVersion: 3,
  notPersonal: false,
  updatedAt: '2026-09-01T10:00:00.000Z',
  ageLabel: 'just now',
  trackCount: 3,
  durationLabel: '10 min',
  caseColor: '#3f4851',
}

const tracks: QueueTrack[] = [
  {
    position: 0,
    trackId: 'track-1',
    appleId: 'apple-1',
    spotifyId: null,
    title: 'Sweetest Taboo',
    artist: 'Sade',
    reason: 'A low-lit opening that still has forward motion.',
    durationMs: 238_000,
    artworkUrl: 'https://is1-ssl.mzstatic.com/image/thumb/cover/{w}x{h}.{f}',
    artworkBgColor: '46535e',
  },
  {
    position: 1,
    trackId: 'track-2',
    appleId: 'apple-2',
    spotifyId: null,
    title: 'Essence',
    artist: 'Wizkid feat. Tems',
    reason: 'A familiar lift without breaking the warmth.',
    durationMs: 249_000,
  },
  {
    position: 2,
    trackId: 'track-3',
    appleId: 'apple-3',
    spotifyId: null,
    title: 'Anybody',
    artist: 'Burna Boy',
    reason: 'The first real step onto the road.',
    durationMs: 208_000,
  },
]

// Where mixes play and the Spotify explainer are remembered in this browser.
beforeEach(() => localStorage.clear())

function renderQueue(overrides: {
  session?: DjSession
  tracks?: QueueTrack[]
  musicConnection?: MusicConnectionState
  onPreviewTracks?: (tracks: QueueTrack[]) => void
  onCommitQueueOp?: (op: QueueOp) => Promise<void>
  onOutput?: () => void
  spotifyOnly?: boolean
  onConnect?: () => void
  askService?: boolean
  onChooseService?: (choice: 'spotify' | 'apple') => void
} = {}) {
  const onPreviewTracks = overrides.onPreviewTracks ?? vi.fn()
  const onCommitQueueOp = overrides.onCommitQueueOp ?? vi.fn(async () => undefined)
  const onOutput = overrides.onOutput ?? vi.fn()
  const view = render(
    <QueuePanel
      session={overrides.session ?? session}
      tracks={overrides.tracks ?? tracks}
      playing={false}
      playbackBusy={false}
      musicConnection={overrides.musicConnection ?? 'disconnected'}
      open
      onConnect={overrides.onConnect ?? vi.fn()}
      onTogglePlay={vi.fn()}
      onSave={vi.fn()}
      onClose={vi.fn()}
      onPreviewTracks={onPreviewTracks}
      onCommitQueueOp={onCommitQueueOp}
      onOutput={onOutput}
      spotifyOnly={overrides.spotifyOnly}
      askService={overrides.askService}
      onChooseService={overrides.onChooseService}
    />,
  )
  return { ...view, onPreviewTracks, onCommitQueueOp, onOutput }
}

function row(trackId: string) {
  const element = document.querySelector<HTMLElement>(`[data-track-id="${trackId}"]`)
  if (!element) throw new Error(`missing row ${trackId}`)
  Object.defineProperty(element, 'getBoundingClientRect', {
    configurable: true,
    value: () => ({ width: 400, height: 72, top: 0, right: 400, bottom: 72, left: 0, x: 0, y: 0, toJSON: () => ({}) }),
  })
  return element
}

describe('approved artwork mix rail', () => {
  afterEach(() => {
    cleanup()
    vi.useRealTimers()
  })

  it('uses artwork, a three-line reorder handle, and an always-reserved reason line', () => {
    const { container } = renderQueue()

    expect(container.querySelector('.track-artwork')).toHaveAttribute(
      'src',
      'https://is1-ssl.mzstatic.com/image/thumb/cover/96x96.jpg',
    )
    const handle = screen.getByRole('button', { name: 'Move Sweetest Taboo, track 1' })
    expect(handle.querySelectorAll('.reorder-grip-line')).toHaveLength(3)
    expect(screen.getByText('A low-lit opening that still has forward motion.')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Remove Sweetest Taboo' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /More options for/ })).not.toBeInTheDocument()
  })

  it('reorders from the keyboard and submits the inverse move when Undo is chosen', async () => {
    const onPreviewTracks = vi.fn()
    const onCommitQueueOp = vi.fn(async (_op: QueueOp) => undefined)
    renderQueue({ onPreviewTracks, onCommitQueueOp })

    fireEvent.keyDown(screen.getByRole('button', { name: 'Move Sweetest Taboo, track 1' }), { key: 'ArrowDown' })

    expect(onPreviewTracks).toHaveBeenLastCalledWith([
      expect.objectContaining({ trackId: 'track-2', position: 0 }),
      expect.objectContaining({ trackId: 'track-1', position: 1 }),
      expect.objectContaining({ trackId: 'track-3', position: 2 }),
    ])
    expect(onCommitQueueOp).toHaveBeenCalledWith({ op: 'move', from: 0, to: 1 })

    fireEvent.click(screen.getByRole('button', { name: 'Undo' }))

    await waitFor(() => expect(onCommitQueueOp).toHaveBeenLastCalledWith({ op: 'move', from: 1, to: 0 }))
  })

  it('reveals and stretches the remove action while a pointer is still moving', () => {
    renderQueue()
    const trackRow = row('track-1')

    fireEvent.pointerDown(within(trackRow).getByTestId('track-swipe-surface'), {
      button: 0,
      clientX: 380,
      clientY: 30,
      pointerId: 1,
    })
    fireEvent.pointerMove(trackRow, { clientX: 260, clientY: 31, pointerId: 1 })

    expect(trackRow).toHaveAttribute('data-swipe-state', 'moving')
    expect(trackRow.style.getPropertyValue('--swipe-reveal')).toBe('120px')
    expect(within(trackRow).getByRole('button', { name: 'Remove Sweetest Taboo' })).toBeVisible()
  })

  it('removes past 65 percent, then restores without persistence when Undo is chosen', () => {
    vi.useFakeTimers()
    const onPreviewTracks = vi.fn()
    const onCommitQueueOp = vi.fn(async () => undefined)
    renderQueue({ onPreviewTracks, onCommitQueueOp })
    const trackRow = row('track-1')

    fireEvent.pointerDown(within(trackRow).getByTestId('track-swipe-surface'), {
      button: 0,
      clientX: 390,
      clientY: 30,
      pointerId: 1,
    })
    fireEvent.pointerMove(trackRow, { clientX: 110, clientY: 31, pointerId: 1 })
    fireEvent.pointerUp(trackRow, { clientX: 110, clientY: 31, pointerId: 1 })

    expect(screen.queryByText('Sweetest Taboo')).not.toBeInTheDocument()
    expect(onCommitQueueOp).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: 'Undo' }))
    expect(screen.getByText('Sweetest Taboo')).toBeInTheDocument()

    act(() => vi.advanceTimersByTime(3000))
    expect(onCommitQueueOp).not.toHaveBeenCalled()
  })

  it('persists a removal after the quiet three-second Undo window expires', () => {
    vi.useFakeTimers()
    const onCommitQueueOp = vi.fn(async () => undefined)
    renderQueue({ onCommitQueueOp })
    const trackRow = row('track-1')

    fireEvent.pointerDown(within(trackRow).getByTestId('track-swipe-surface'), {
      button: 0,
      clientX: 390,
      clientY: 30,
      pointerId: 1,
    })
    fireEvent.pointerMove(trackRow, { clientX: 110, clientY: 31, pointerId: 1 })
    fireEvent.pointerUp(trackRow, { clientX: 110, clientY: 31, pointerId: 1 })

    act(() => vi.advanceTimersByTime(2999))
    expect(onCommitQueueOp).not.toHaveBeenCalled()
    act(() => vi.advanceTimersByTime(1))
    expect(onCommitQueueOp).toHaveBeenCalledWith({ op: 'remove', position: 0 })
    expect(screen.queryByText(/3 seconds|2 seconds|1 second/)).not.toBeInTheDocument()
  })

  it('finalizes a pending removal before a newer queue mutation', () => {
    vi.useFakeTimers()
    const onCommitQueueOp = vi.fn(async (_op: QueueOp) => undefined)
    renderQueue({ onCommitQueueOp })
    const trackRow = row('track-1')

    fireEvent.pointerDown(within(trackRow).getByTestId('track-swipe-surface'), {
      button: 0,
      clientX: 390,
      clientY: 30,
      pointerId: 1,
    })
    fireEvent.pointerMove(trackRow, { clientX: 110, clientY: 31, pointerId: 1 })
    fireEvent.pointerUp(trackRow, { clientX: 110, clientY: 31, pointerId: 1 })

    fireEvent.keyDown(screen.getByRole('button', { name: 'Move Essence, track 1' }), { key: 'ArrowDown' })

    expect(onCommitQueueOp.mock.calls.map(([op]) => op)).toEqual([
      { op: 'remove', position: 0 },
      { op: 'move', from: 0, to: 1 },
    ])
  })

  it('accepts a two-finger horizontal trackpad gesture without hijacking vertical scrolling', () => {
    vi.useFakeTimers()
    const onCommitQueueOp = vi.fn(async () => undefined)
    renderQueue({ onCommitQueueOp })
    const trackRow = row('track-1')

    fireEvent.wheel(trackRow, { deltaX: 280, deltaY: 4 })
    expect(trackRow).toHaveAttribute('data-swipe-state', 'armed')
    act(() => vi.advanceTimersByTime(140))

    expect(screen.queryByText('Sweetest Taboo')).not.toBeInTheDocument()

    const verticalRow = row('track-2')
    fireEvent.wheel(verticalRow, { deltaX: 8, deltaY: 90 })
    act(() => vi.advanceTimersByTime(140))
    expect(screen.getByText('Essence')).toBeInTheDocument()
  })
})

const spotifyTracks: QueueTrack[] = [
  { position: 0, trackId: 's-1', appleId: null, spotifyId: '4uLU6hMCjMI75M1A2tKUQC', title: 'Window Seat', artist: 'Niko Vale', durationMs: 200_000 },
  { position: 1, trackId: 's-2', appleId: null, spotifyId: '7ouMYWpwJ422jRcDASZB7P', title: 'Streetlight Weather', artist: 'Juniper North', durationMs: 210_000 },
  { position: 2, trackId: 's-3', appleId: null, spotifyId: null, title: 'Paper Tickets', artist: 'Ari Sola', durationMs: 190_000 },
]

const mixedTracks: QueueTrack[] = [
  { ...spotifyTracks[0], appleId: 'apple-s-1' },
  { ...spotifyTracks[1] },
]

const SPOTIFY_LINES =
  'https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC\nhttps://open.spotify.com/track/7ouMYWpwJ422jRcDASZB7P'
const TRANSFER_LINES = 'Niko Vale - Window Seat\nJuniper North - Streetlight Weather\nAri Sola - Paper Tickets'

function stubClipboard(writeText: ((text: string) => Promise<void>) | null) {
  Object.defineProperty(window.navigator, 'clipboard', {
    configurable: true,
    value: writeText ? { writeText } : undefined,
  })
}

describe('Spotify mix outputs', () => {
  afterEach(() => {
    cleanup()
    vi.useRealTimers()
    vi.restoreAllMocks()
    stubClipboard(null)
  })

  it('links every Spotify track to open.spotify.com in a new tab, named for the track', () => {
    renderQueue({ tracks: spotifyTracks })

    const link = screen.getByRole('link', { name: 'Open in Spotify: Window Seat' })
    expect(link).toHaveAttribute('href', 'https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC')
    expect(link).toHaveAttribute('target', '_blank')
    expect(link).toHaveAttribute('rel', 'noopener')
    expect(link).toHaveClass('open')
    expect(link).toHaveTextContent('Open in Spotify')
    expect(link.getAttribute('aria-label')?.startsWith(link.textContent?.trim() ?? '')).toBe(true)
    expect(screen.getByRole('link', { name: 'Open in Spotify: Streetlight Weather' })).toBeInTheDocument()
    expect(screen.queryByRole('link', { name: 'Open in Spotify: Paper Tickets' })).not.toBeInTheDocument()
  })

  it('shows no Spotify link on an Apple-only mix, but still offers Play on Spotify after Apple', () => {
    renderQueue()

    expect(screen.queryByRole('link', { name: /^Open in Spotify: / })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Copy for Spotify' })).not.toBeInTheDocument()
    const connect = screen.getByRole('button', { name: 'Connect Apple Music' })
    const spotify = screen.getByRole('button', { name: 'Play on Spotify' })
    expect(spotify).not.toHaveClass('primary')
    expect(connect.compareDocumentPosition(spotify) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
  })

  it('with no known service, asks where they listen: Apple Music and Spotify side by side', () => {
    const onConnect = vi.fn()
    const onChooseService = vi.fn()
    renderQueue({ askService: true, onConnect, onChooseService })

    const ask = screen.getByRole('group', { name: 'Where do you listen?' })
    expect(within(ask).getByRole('button', { name: 'Play on Spotify' })).toHaveClass('primary')
    expect(within(ask).getByRole('button', { name: 'Connect Apple Music' })).toBeInTheDocument()
    expect(screen.queryByText(/Connect Apple Music to play this mix/)).not.toBeInTheDocument()

    fireEvent.click(within(ask).getByRole('button', { name: 'Connect Apple Music' }))
    expect(onChooseService).toHaveBeenCalledWith('apple')
    expect(onConnect).toHaveBeenCalledOnce()
  })

  it('answering Spotify remembers it and starts the handoff', () => {
    const onChooseService = vi.fn()
    renderQueue({ askService: true, onChooseService })

    fireEvent.click(within(screen.getByRole('group', { name: 'Where do you listen?' })).getByRole('button', { name: 'Play on Spotify' }))
    expect(onChooseService).toHaveBeenCalledWith('spotify')
    expect(screen.getByRole('dialog', { name: 'Make it a Spotify playlist' })).toBeInTheDocument()
  })

  it('replaces the Apple controls with the Spotify actions when no track has an Apple id', () => {
    renderQueue({ tracks: spotifyTracks, musicConnection: 'connected' })

    expect(screen.queryByRole('button', { name: 'Play now' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Create playlist' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Connect Apple Music' })).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Copy for Spotify' })).toHaveClass('rail-action--desktop')
    expect(screen.getByRole('button', { name: 'Play on Spotify' })).toBeInTheDocument()
    expect(
      screen.getByText('Copy for Spotify gives you links to paste into a Spotify playlist on your computer. Play on Spotify builds the playlist for you on any device.'),
    ).toBeInTheDocument()
  })

  it('shows the Apple controls first, then the Spotify actions, on a mixed Apple and Spotify mix', () => {
    renderQueue({ tracks: mixedTracks, musicConnection: 'connected' })

    const play = screen.getByRole('button', { name: 'Play now' })
    expect(screen.getByRole('button', { name: 'Create playlist' })).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Open in Spotify: Window Seat' })).toBeInTheDocument()
    const copy = screen.getByRole('button', { name: 'Copy for Spotify' })
    expect(screen.getByRole('button', { name: 'Play on Spotify' })).toBeInTheDocument()
    expect(
      screen.getByText('Copy for Spotify gives you links to paste into a Spotify playlist on your computer. Play on Spotify builds the playlist for you on any device.'),
    ).toBeInTheDocument()
    expect(play.compareDocumentPosition(copy) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
  })

  it('still reorders from the keyboard on a row that carries a Spotify link', () => {
    const { onPreviewTracks, onCommitQueueOp } = renderQueue({ tracks: spotifyTracks })

    fireEvent.keyDown(screen.getByRole('button', { name: 'Move Window Seat, track 1' }), { key: 'ArrowDown' })

    expect(onPreviewTracks).toHaveBeenLastCalledWith([
      expect.objectContaining({ trackId: 's-2', position: 0 }),
      expect.objectContaining({ trackId: 's-1', position: 1 }),
      expect.objectContaining({ trackId: 's-3', position: 2 }),
    ])
    expect(onCommitQueueOp).toHaveBeenCalledWith({ op: 'move', from: 0, to: 1 })
    expect(screen.getByRole('link', { name: 'Open in Spotify: Window Seat' })).toBeInTheDocument()
  })

  it('copies one Spotify link per line and says how many, with the paste hint', async () => {
    const writeText = vi.fn(async (_text: string) => undefined)
    stubClipboard(writeText)
    const { onOutput } = renderQueue({ tracks: spotifyTracks })

    fireEvent.click(screen.getByRole('button', { name: 'Copy for Spotify' }))

    await waitFor(() => expect(screen.getByRole('status')).toHaveTextContent('Copied 2 links'))
    expect(writeText).toHaveBeenCalledWith(SPOTIFY_LINES)
    expect(screen.getByRole('status')).toHaveTextContent('Paste the links into a new playlist in Spotify on your computer.')
    expect(onOutput).toHaveBeenCalledTimes(1)
  })

  it('Play on Spotify explains once, then copies Artist - Title lines and opens TuneMyMusic', async () => {
    const writeText = vi.fn(async (_text: string) => undefined)
    stubClipboard(writeText)
    const open = vi.spyOn(window, 'open').mockImplementation(() => null)
    const { onOutput } = renderQueue({ tracks: spotifyTracks })

    fireEvent.click(screen.getByRole('button', { name: 'Play on Spotify' }))
    const dialog = screen.getByRole('dialog', { name: 'Make it a Spotify playlist' })
    expect(within(dialog).getByText('We’ll copy your 3 songs and open TuneMyMusic. Paste them in, connect Spotify, and it makes the playlist for you.')).toBeInTheDocument()
    expect(writeText).not.toHaveBeenCalled()
    expect(open).not.toHaveBeenCalled()

    fireEvent.click(within(dialog).getByRole('button', { name: 'Copy songs and open TuneMyMusic' }))
    await waitFor(() => expect(screen.getByRole('status')).toHaveTextContent('Copied 3 songs · paste them into TuneMyMusic'))
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    expect(writeText).toHaveBeenCalledWith(TRANSFER_LINES)
    expect(open).toHaveBeenCalledWith('https://www.tunemymusic.com/transfer/freetext-to-spotify', '_blank', 'noopener')
    expect(onOutput).toHaveBeenCalledTimes(1)

    // Seen: the next tap goes straight there.
    fireEvent.click(screen.getByRole('button', { name: 'Play on Spotify' }))
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    await waitFor(() => expect(open).toHaveBeenCalledTimes(2))
  })

  it('Cancel on the explainer copies and opens nothing', () => {
    const writeText = vi.fn(async (_text: string) => undefined)
    stubClipboard(writeText)
    const open = vi.spyOn(window, 'open').mockImplementation(() => null)
    const { onOutput } = renderQueue({ tracks: spotifyTracks })

    fireEvent.click(screen.getByRole('button', { name: 'Play on Spotify' }))
    fireEvent.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Cancel' }))

    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    expect(writeText).not.toHaveBeenCalled()
    expect(open).not.toHaveBeenCalled()
    expect(onOutput).not.toHaveBeenCalled()
    expect(localStorage.getItem('mixtape.spotify-intro-seen')).toBeNull()
  })

  it('says so when this browser has no clipboard', async () => {
    localStorage.setItem('mixtape.spotify-intro-seen', 'seen')
    stubClipboard(null)
    const open = vi.spyOn(window, 'open').mockImplementation(() => null)
    renderQueue({ tracks: spotifyTracks })

    fireEvent.click(screen.getByRole('button', { name: 'Copy for Spotify' }))
    await waitFor(() => expect(screen.getByRole('status')).toHaveTextContent('Couldn’t copy on this browser.'))

    fireEvent.click(screen.getByRole('button', { name: 'Play on Spotify' }))
    await waitFor(() => expect(open).toHaveBeenCalledTimes(1))
    expect(screen.getByRole('status')).toHaveTextContent('Couldn’t copy on this browser.')
  })

  it('reports an Open in Spotify click as an output without starting a swipe', () => {
    const { onOutput } = renderQueue({ tracks: spotifyTracks })
    const trackRow = row('s-1')
    const link = screen.getByRole('link', { name: 'Open in Spotify: Window Seat' })
    link.addEventListener('click', (event) => event.preventDefault())

    fireEvent.pointerDown(link, { button: 0, clientX: 380, clientY: 30, pointerId: 1 })
    fireEvent.pointerMove(trackRow, { clientX: 260, clientY: 31, pointerId: 1 })
    expect(trackRow).toHaveAttribute('data-swipe-state', 'closed')

    fireEvent.click(link)
    expect(onOutput).toHaveBeenCalledTimes(1)
  })

  it('carries the Not personal yet banner above the tracks for a corpus-mode mix', () => {
    renderQueue({ session: { ...session, notPersonal: true }, tracks: spotifyTracks })

    const banner = screen.getByRole('status')
    expect(banner).toHaveClass('banner')
    expect(within(banner).getByText('Not personal yet')).toBeInTheDocument()
    expect(banner).toHaveTextContent(
      'Built from Mixtape’s catalog and your interview, not your listening. Import your Spotify data for the real thing.',
    )
    expect(banner.compareDocumentPosition(screen.getByRole('list'))).toBe(Node.DOCUMENT_POSITION_FOLLOWING)
  })

  it('shows no banner for a personal mix', () => {
    renderQueue({ tracks: spotifyTracks })

    expect(screen.queryByText('Not personal yet')).not.toBeInTheDocument()
  })
})

describe('new to you mark', () => {
  afterEach(cleanup)

  const marked: QueueTrack[] = [
    { ...tracks[0] },
    { ...tracks[1], newToYou: true },
    { ...tracks[2], newToYou: false },
  ]

  it('ends the artist line with the words New to you, only on new tracks', () => {
    renderQueue({ tracks: marked })

    const newLine = row('track-2').querySelector('.track-copy small')!
    expect(newLine).toHaveClass('has-mark')
    expect(newLine.querySelector('.track-who')).toHaveTextContent('Wizkid feat. Tems · 4:09')
    expect(newLine.querySelector('.track-mark')).toHaveTextContent(/^\s*· New to you$/)
    expect(newLine.querySelector('.track-mark b')).toHaveTextContent('New to you')
    expect(newLine.lastElementChild).toBe(newLine.querySelector('.track-mark'))

    for (const id of ['track-1', 'track-3']) {
      const line = row(id).querySelector('.track-copy small')!
      expect(line).not.toHaveClass('has-mark')
      expect(line.querySelector('.track-mark')).toBeNull()
      expect(line).not.toHaveTextContent('New to you')
    }
    expect(screen.getAllByText('New to you')).toHaveLength(1)
  })

  it('ends the row label with new to you and keeps the reason as its description', () => {
    renderQueue({ tracks: marked })

    const surfaces = screen.getAllByTestId('track-swipe-surface')
    expect(surfaces[1]).toHaveAttribute('aria-label', 'Essence by Wizkid feat. Tems, track 2, new to you')
    expect(surfaces[1]).toHaveAccessibleDescription('A familiar lift without breaking the warmth.')
    expect(surfaces[0]).toHaveAttribute('aria-label', 'Sweetest Taboo by Sade, track 1')
    expect(surfaces[2]).toHaveAttribute('aria-label', 'Anybody by Burna Boy, track 3')
  })

  it('keeps the mark beside the Open in Spotify link', () => {
    renderQueue({ tracks: [{ ...spotifyTracks[0], newToYou: true }] })

    expect(screen.getByRole('link', { name: 'Open in Spotify: Window Seat' })).toBeInTheDocument()
    expect(row('s-1').querySelector('.track-mark')).toHaveTextContent('New to you')
  })
})

describe('a Spotify-only listener', () => {
  afterEach(cleanup)

  // A catalogue mix: every track has an Apple id and none a Spotify id.
  const catalogueTracks: QueueTrack[] = [
    { position: 0, trackId: 'c-1', appleId: 'apple-c-1', spotifyId: null, title: 'Comfort', artist: 'Julia Jacklin', durationMs: 187_000 },
    { position: 1, trackId: 'c-2', appleId: 'apple-c-2', spotifyId: null, title: 'Walk On By', artist: 'Burt Bacharach', durationMs: 181_000 },
  ]

  it('leads with Play on Spotify instead of the Apple Music connect controls', () => {
    renderQueue({ tracks: catalogueTracks, spotifyOnly: true })

    expect(screen.queryByRole('button', { name: 'Connect Apple Music' })).not.toBeInTheDocument()
    expect(screen.queryByText(/Connect Apple Music to play this mix/)).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Play on Spotify' })).toHaveClass('primary')
    // No Spotify ids means nothing for Copy for Spotify to copy.
    expect(screen.queryByRole('button', { name: 'Copy for Spotify' })).not.toBeInTheDocument()
    expect(screen.getByText('Copies your songs and opens TuneMyMusic, which builds the playlist in Spotify for you.')).toBeInTheDocument()
  })

  it('links each track without a Spotify id to a Spotify search for it', () => {
    renderQueue({ tracks: catalogueTracks, spotifyOnly: true })

    expect(screen.getByRole('link', { name: 'Open in Spotify: Comfort' })).toHaveAttribute(
      'href',
      'https://open.spotify.com/search/Julia%20Jacklin%20Comfort',
    )
  })

  it('keeps a quiet way to connect Apple Music, and shows its progress once started', () => {
    const onConnect = vi.fn()
    const { unmount } = renderQueue({ tracks: catalogueTracks, spotifyOnly: true, onConnect })

    fireEvent.click(screen.getByRole('button', { name: 'Use Apple Music instead' }))
    expect(onConnect).toHaveBeenCalledOnce()
    unmount()

    const onChooseService = vi.fn()
    const second = renderQueue({ tracks: catalogueTracks, spotifyOnly: true, onChooseService })
    fireEvent.click(screen.getByRole('button', { name: 'Use Apple Music instead' }))
    expect(onChooseService).toHaveBeenCalledWith('apple')
    second.unmount()

    renderQueue({ tracks: catalogueTracks, spotifyOnly: true, musicConnection: 'connecting' })
    expect(screen.getByRole('button', { name: 'Connecting Apple Music…' })).toBeInTheDocument()
  })
})
