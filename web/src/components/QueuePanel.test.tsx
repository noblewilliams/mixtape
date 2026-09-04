import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { QueueOp } from '../api/client'
import type { DjSession, QueueTrack } from '../domain'
import { QueuePanel } from './QueuePanel'

const session: DjSession = {
  id: 'session-1',
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

function renderQueue(overrides: {
  onPreviewTracks?: (tracks: QueueTrack[]) => void
  onCommitQueueOp?: (op: QueueOp) => Promise<void>
} = {}) {
  const onPreviewTracks = overrides.onPreviewTracks ?? vi.fn()
  const onCommitQueueOp = overrides.onCommitQueueOp ?? vi.fn(async () => undefined)
  const view = render(
    <QueuePanel
      session={session}
      tracks={tracks}
      playing={false}
      playbackBusy={false}
      musicConnection="disconnected"
      open
      onConnect={vi.fn()}
      onTogglePlay={vi.fn()}
      onSave={vi.fn()}
      onClose={vi.fn()}
      onPreviewTracks={onPreviewTracks}
      onCommitQueueOp={onCommitQueueOp}
    />,
  )
  return { ...view, onPreviewTracks, onCommitQueueOp }
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
