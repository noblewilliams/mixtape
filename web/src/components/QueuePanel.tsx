import {
  useEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
  type KeyboardEvent,
  type PointerEvent,
  type WheelEvent,
} from 'react'
import { ApiError, type QueueOp } from '../api/client'
import type { DjSession, QueueTrack } from '../domain'
import { CloseIcon, ErrorCircleIcon, SuccessCircleIcon, UndoIcon } from './Icons'
import { ConnectMusicButton, LabelButton, PlayButton } from './TapeActions'

export type MusicConnectionState = 'disconnected' | 'connecting' | 'connected' | 'error'

type QueuePanelProps = {
  session: DjSession
  tracks: QueueTrack[]
  playing: boolean
  playbackBusy: boolean
  musicConnection: MusicConnectionState
  open: boolean
  onConnect: () => void
  onTogglePlay: () => void
  onSave: () => void
  onClose: () => void
  onPreviewTracks: (tracks: QueueTrack[]) => void
  onCommitQueueOp: (op: QueueOp) => Promise<void>
}

type SwipeState = {
  trackId: string
  reveal: number
  phase: 'moving' | 'settled' | 'armed'
}

type PendingUndo =
  | { kind: 'remove'; track: QueueTrack; index: number }
  | { kind: 'move'; trackId: string; from: number; to: number; commit: Promise<void> }

type PointerSwipe = {
  trackId: string
  pointerId: number
  startX: number
  startY: number
  width: number
  horizontal: boolean
}

type PointerReorder = {
  trackId: string
  pointerId: number
  from: number
  started: boolean
}

const REMOVE_THRESHOLD = 0.65
const SETTLED_REMOVE_SIZE = 42
const UNDO_WINDOW_MS = 3000
const WHEEL_RELEASE_MS = 120

function formatDuration(milliseconds: number) {
  const minutes = Math.floor(milliseconds / 60_000)
  const seconds = Math.floor((milliseconds % 60_000) / 1000)
  return `${minutes}:${seconds.toString().padStart(2, '0')}`
}

function artworkSource(template?: string) {
  if (!template) return null
  return template
    .replaceAll('{w}', '96')
    .replaceAll('{h}', '96')
    .replaceAll('{f}', 'jpg')
}

function withPositions(tracks: QueueTrack[]) {
  return tracks.map((track, position) => ({ ...track, position }))
}

function movedTracks(tracks: QueueTrack[], from: number, to: number) {
  const next = [...tracks]
  const [moved] = next.splice(from, 1)
  next.splice(to, 0, moved)
  return withPositions(next)
}

export function QueuePanel({
  session,
  tracks,
  playing,
  playbackBusy,
  musicConnection,
  open,
  onConnect,
  onTogglePlay,
  onSave,
  onClose,
  onPreviewTracks,
  onCommitQueueOp,
}: QueuePanelProps) {
  const [displayTracks, setDisplayTracks] = useState(() => withPositions(tracks))
  const [swipe, setSwipeState] = useState<SwipeState | null>(null)
  const [draggedTrackId, setDraggedTrackId] = useState<string | null>(null)
  const [toast, setToast] = useState<{ message: string; undo: boolean } | null>(null)
  const displayTracksRef = useRef(displayTracks)
  const swipeRef = useRef<SwipeState | null>(null)
  const pendingUndoRef = useRef<PendingUndo | null>(null)
  const undoTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const statusTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const wheelTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const pointerSwipeRef = useRef<PointerSwipe | null>(null)
  const pointerReorderRef = useRef<PointerReorder | null>(null)
  const onCommitRef = useRef(onCommitQueueOp)

  const totalDuration = useMemo(
    () => displayTracks.reduce((sum, track) => sum + (track.durationMs ?? 0), 0),
    [displayTracks],
  )

  useEffect(() => {
    const normalized = withPositions(tracks)
    setDisplayTracks(normalized)
    displayTracksRef.current = normalized
  }, [tracks])

  useEffect(() => {
    onCommitRef.current = onCommitQueueOp
  }, [onCommitQueueOp])

  useEffect(
    () => () => {
      if (undoTimerRef.current) clearTimeout(undoTimerRef.current)
      if (statusTimerRef.current) clearTimeout(statusTimerRef.current)
      if (wheelTimerRef.current) clearTimeout(wheelTimerRef.current)
      const pending = pendingUndoRef.current
      if (pending?.kind === 'remove') {
        void onCommitRef.current({ op: 'remove', position: pending.index }).catch(() => undefined)
      }
    },
    [],
  )

  function preview(nextTracks: QueueTrack[]) {
    const normalized = withPositions(nextTracks)
    displayTracksRef.current = normalized
    setDisplayTracks(normalized)
    onPreviewTracks(normalized)
  }

  function setSwipe(next: SwipeState | null) {
    swipeRef.current = next
    setSwipeState(next)
  }

  function clearToastTimers() {
    if (undoTimerRef.current) clearTimeout(undoTimerRef.current)
    if (statusTimerRef.current) clearTimeout(statusTimerRef.current)
    undoTimerRef.current = null
    statusTimerRef.current = null
  }

  function commitErrorCopy(error: unknown) {
    return error instanceof ApiError && error.status === 409
      ? 'This mix changed elsewhere. The latest order is shown.'
      : 'That update could not be saved. Please try again.'
  }

  function showCommitError(error: unknown, pending: PendingUndo) {
    if (pendingUndoRef.current !== pending) return
    clearToastTimers()
    pendingUndoRef.current = null
    setToast({ message: commitErrorCopy(error), undo: false })
    statusTimerRef.current = setTimeout(() => setToast(null), UNDO_WINDOW_MS)
  }

  function beginUndo(pending: PendingUndo, message: string) {
    clearToastTimers()
    pendingUndoRef.current = pending
    setToast({ message, undo: true })
    undoTimerRef.current = setTimeout(() => {
      if (pendingUndoRef.current !== pending) return
      pendingUndoRef.current = null
      setToast(null)
      if (pending.kind === 'remove') {
        void onCommitQueueOp({ op: 'remove', position: pending.index }).catch((error: unknown) => {
          setToast({ message: commitErrorCopy(error), undo: false })
          statusTimerRef.current = setTimeout(() => setToast(null), UNDO_WINDOW_MS)
        })
      }
    }, UNDO_WINDOW_MS)
  }

  function finalizePreviousUndo() {
    const pending = pendingUndoRef.current
    if (!pending) return
    clearToastTimers()
    pendingUndoRef.current = null
    setToast(null)
    if (pending.kind === 'remove') {
      void onCommitQueueOp({ op: 'remove', position: pending.index }).catch((error: unknown) => {
        setToast({ message: commitErrorCopy(error), undo: false })
        statusTimerRef.current = setTimeout(() => setToast(null), UNDO_WINDOW_MS)
      })
    }
  }

  function showUndoConfirmation() {
    setToast({ message: 'Update undone.', undo: false })
    statusTimerRef.current = setTimeout(() => setToast(null), 1200)
  }

  function undoLastMutation() {
    const pending = pendingUndoRef.current
    if (!pending) return
    clearToastTimers()
    pendingUndoRef.current = null

    if (pending.kind === 'remove') {
      const next = [...displayTracksRef.current]
      next.splice(Math.min(pending.index, next.length), 0, pending.track)
      preview(next)
      showUndoConfirmation()
      return
    }

    const currentIndex = displayTracksRef.current.findIndex((track) => track.trackId === pending.trackId)
    if (currentIndex >= 0) preview(movedTracks(displayTracksRef.current, currentIndex, pending.from))
    void pending.commit
      .then(() => onCommitQueueOp({ op: 'move', from: pending.to, to: pending.from }))
      .then(showUndoConfirmation)
      .catch((error: unknown) => {
        setToast({ message: commitErrorCopy(error), undo: false })
        statusTimerRef.current = setTimeout(() => setToast(null), UNDO_WINDOW_MS)
      })
  }

  function moveTrack(from: number, to: number) {
    if (from === to || from < 0 || to < 0 || from >= displayTracksRef.current.length || to >= displayTracksRef.current.length) {
      return
    }
    finalizePreviousUndo()
    const track = displayTracksRef.current[from]
    preview(movedTracks(displayTracksRef.current, from, to))
    setSwipe(null)
    const commit = onCommitQueueOp({ op: 'move', from, to })
    const pending: PendingUndo = { kind: 'move', trackId: track.trackId, from, to, commit }
    beginUndo(pending, `${track.title} moved to track ${to + 1}.`)
    void commit.catch((error: unknown) => showCommitError(error, pending))
  }

  function removeTrack(trackId: string) {
    const index = displayTracksRef.current.findIndex((track) => track.trackId === trackId)
    if (index < 0) return
    finalizePreviousUndo()
    const track = displayTracksRef.current[index]
    preview(displayTracksRef.current.filter((item) => item.trackId !== trackId))
    setSwipe(null)
    beginUndo({ kind: 'remove', track, index }, `${track.title} removed from the mix.`)
  }

  function handleRowKeyDown(event: KeyboardEvent<HTMLElement>, trackId: string) {
    if (event.key === 'Delete' || event.key === 'Backspace') {
      event.preventDefault()
      setSwipe({ trackId, reveal: SETTLED_REMOVE_SIZE, phase: 'settled' })
    } else if (event.key === 'Escape' && swipeRef.current?.trackId === trackId) {
      event.preventDefault()
      setSwipe(null)
    }
  }

  function handleReorderKeyDown(event: KeyboardEvent<HTMLButtonElement>, trackId: string) {
    const from = displayTracksRef.current.findIndex((track) => track.trackId === trackId)
    if (event.key === 'ArrowUp' && from > 0) {
      event.preventDefault()
      moveTrack(from, from - 1)
    } else if (event.key === 'ArrowDown' && from < displayTracksRef.current.length - 1) {
      event.preventDefault()
      moveTrack(from, from + 1)
    }
  }

  function beginPointerSwipe(event: PointerEvent<HTMLElement>, trackId: string) {
    if (event.button !== 0 || pointerReorderRef.current) return
    const row = event.currentTarget.closest<HTMLElement>('.track-row')
    if (!row) return
    pointerSwipeRef.current = {
      trackId,
      pointerId: event.pointerId,
      startX: event.clientX,
      startY: event.clientY,
      width: Math.max(1, row.getBoundingClientRect().width),
      horizontal: false,
    }
    event.currentTarget.setPointerCapture?.(event.pointerId)
  }

  function movePointerSwipe(event: PointerEvent<HTMLLIElement>) {
    const gesture = pointerSwipeRef.current
    if (!gesture || event.pointerId !== gesture.pointerId) return
    const deltaX = gesture.startX - event.clientX
    const deltaY = gesture.startY - event.clientY
    if (!gesture.horizontal) {
      if (Math.abs(deltaX) < 6) return
      if (Math.abs(deltaY) > Math.abs(deltaX)) {
        pointerSwipeRef.current = null
        return
      }
      gesture.horizontal = true
    }
    event.preventDefault()
    const reveal = Math.max(0, Math.min(gesture.width, deltaX))
    setSwipe({
      trackId: gesture.trackId,
      reveal,
      phase: reveal >= gesture.width * REMOVE_THRESHOLD ? 'armed' : 'moving',
    })
  }

  function endPointerSwipe(event: PointerEvent<HTMLLIElement>) {
    const gesture = pointerSwipeRef.current
    if (!gesture || event.pointerId !== gesture.pointerId) return
    pointerSwipeRef.current = null
    const current = swipeRef.current
    if (!current || current.trackId !== gesture.trackId) return
    if (current.reveal >= gesture.width * REMOVE_THRESHOLD) {
      removeTrack(gesture.trackId)
    } else if (current.reveal >= 18) {
      setSwipe({ trackId: gesture.trackId, reveal: SETTLED_REMOVE_SIZE, phase: 'settled' })
    } else {
      setSwipe(null)
    }
  }

  function cancelPointerSwipe() {
    pointerSwipeRef.current = null
    setSwipe(null)
  }

  function handleTrackpad(event: WheelEvent<HTMLLIElement>, trackId: string) {
    if (Math.abs(event.deltaX) <= Math.abs(event.deltaY) || Math.abs(event.deltaX) < 2) return
    event.preventDefault()
    const width = Math.max(1, event.currentTarget.getBoundingClientRect().width)
    const current = swipeRef.current?.trackId === trackId ? swipeRef.current.reveal : 0
    const reveal = Math.max(0, Math.min(width, current + event.deltaX))
    setSwipe({ trackId, reveal, phase: reveal >= width * REMOVE_THRESHOLD ? 'armed' : 'moving' })
    if (wheelTimerRef.current) clearTimeout(wheelTimerRef.current)
    wheelTimerRef.current = setTimeout(() => {
      const settled = swipeRef.current
      if (!settled || settled.trackId !== trackId) return
      if (settled.reveal >= width * REMOVE_THRESHOLD) {
        removeTrack(trackId)
      } else if (settled.reveal >= 18) {
        setSwipe({ trackId, reveal: SETTLED_REMOVE_SIZE, phase: 'settled' })
      } else {
        setSwipe(null)
      }
    }, WHEEL_RELEASE_MS)
  }

  function beginPointerReorder(event: PointerEvent<HTMLButtonElement>, trackId: string) {
    if (event.button !== 0) return
    setSwipe(null)
    pointerReorderRef.current = {
      trackId,
      pointerId: event.pointerId,
      from: displayTracksRef.current.findIndex((track) => track.trackId === trackId),
      started: false,
    }
    setDraggedTrackId(trackId)
    event.currentTarget.setPointerCapture?.(event.pointerId)
  }

  function movePointerReorder(event: PointerEvent<HTMLButtonElement>) {
    const gesture = pointerReorderRef.current
    if (!gesture || event.pointerId !== gesture.pointerId) return
    event.preventDefault()
    const rows = [...event.currentTarget.closest('.track-list')!.querySelectorAll<HTMLElement>('.track-row')]
    const target = rows.findIndex((row) => {
      const rect = row.getBoundingClientRect()
      return event.clientY >= rect.top && event.clientY <= rect.bottom
    })
    const current = displayTracksRef.current.findIndex((track) => track.trackId === gesture.trackId)
    if (target >= 0 && target !== current) {
      if (!gesture.started) {
        finalizePreviousUndo()
        gesture.started = true
      }
      preview(movedTracks(displayTracksRef.current, current, target))
    }
  }

  function endPointerReorder(event: PointerEvent<HTMLButtonElement>) {
    const gesture = pointerReorderRef.current
    if (!gesture || event.pointerId !== gesture.pointerId) return
    pointerReorderRef.current = null
    setDraggedTrackId(null)
    const to = displayTracksRef.current.findIndex((track) => track.trackId === gesture.trackId)
    if (to === gesture.from) return
    const track = displayTracksRef.current[to]
    const commit = onCommitQueueOp({ op: 'move', from: gesture.from, to })
    const pending: PendingUndo = { kind: 'move', trackId: gesture.trackId, from: gesture.from, to, commit }
    beginUndo(pending, `${track.title} moved to track ${to + 1}.`)
    void commit.catch((error: unknown) => showCommitError(error, pending))
  }

  function cancelPointerReorder(event: PointerEvent<HTMLButtonElement>) {
    const gesture = pointerReorderRef.current
    if (!gesture || event.pointerId !== gesture.pointerId) return
    const current = displayTracksRef.current.findIndex((track) => track.trackId === gesture.trackId)
    if (current >= 0 && current !== gesture.from) preview(movedTracks(displayTracksRef.current, current, gesture.from))
    pointerReorderRef.current = null
    setDraggedTrackId(null)
  }

  return (
    <aside className={`queue-panel ${open ? 'is-open' : ''}`} aria-label="Your mix">
      <header className="queue-header">
        <div>
          <p>Your mix</p>
          <span>version {session.queueVersion} · arrange</span>
        </div>
        <button className="queue-close" type="button" onClick={onClose} aria-label="Close your mix">
          <CloseIcon />
        </button>
      </header>

      <div className="queue-summary">
        <strong>{displayTracks.length === 0 ? 'Blank mix' : `${displayTracks.length} tracks`}</strong>
        <span>{displayTracks.length === 0 ? 'waiting for a prompt' : `about ${Math.round(totalDuration / 60_000)} min`}</span>
      </div>

      {displayTracks.length === 0 ? (
        <div className="empty-queue">
          <h2>This mix is still blank.</h2>
          <p>Tell the DJ what belongs on it. The songs will appear here as the conversation takes shape.</p>
        </div>
      ) : (
        <ol className="track-list" aria-label={`${session.title} track list`} aria-describedby="queue-interaction-help">
          {displayTracks.map((track, index) => {
            const currentSwipe = swipe?.trackId === track.trackId ? swipe : null
            const artwork = artworkSource(track.artworkUrl)
            const reasonId = `track-reason-${track.trackId}`
            const rowStyle = {
              '--swipe-reveal': `${currentSwipe?.reveal ?? 0}px`,
              '--artwork-color': track.artworkBgColor ? `#${track.artworkBgColor}` : '#d8d3cd',
            } as CSSProperties
            return (
              <li
                className={`track-row ${draggedTrackId === track.trackId ? 'is-dragging' : ''}`}
                key={track.trackId}
                data-track-id={track.trackId}
                data-swipe-state={currentSwipe?.phase ?? 'closed'}
                style={rowStyle}
                onPointerMove={movePointerSwipe}
                onPointerUp={endPointerSwipe}
                onPointerCancel={cancelPointerSwipe}
                onWheel={(event) => handleTrackpad(event, track.trackId)}
              >
                <div
                  className="track-swipe-surface"
                  data-testid="track-swipe-surface"
                  tabIndex={0}
                  aria-label={`${track.title} by ${track.artist}, track ${index + 1}`}
                  aria-describedby={reasonId}
                  onKeyDown={(event) => handleRowKeyDown(event, track.trackId)}
                  onPointerDown={(event) => beginPointerSwipe(event, track.trackId)}
                >
                  <span className="track-artwork-wrap" aria-hidden="true">
                    {artwork ? <img className="track-artwork" src={artwork} alt="" /> : <span className="track-artwork-fallback" />}
                  </span>
                  <span className="track-copy">
                    <strong>{track.title}</strong>
                    <small>{track.artist} · {track.durationMs ? formatDuration(track.durationMs) : '—'}</small>
                    <em id={reasonId}>{track.reason || 'Chosen to hold the shape of this mix.'}</em>
                  </span>
                  <button
                    className="reorder-handle"
                    type="button"
                    aria-label={`Move ${track.title}, track ${index + 1}`}
                    onKeyDown={(event) => handleReorderKeyDown(event, track.trackId)}
                    onPointerDown={(event) => beginPointerReorder(event, track.trackId)}
                    onPointerMove={movePointerReorder}
                    onPointerUp={endPointerReorder}
                    onPointerCancel={cancelPointerReorder}
                  >
                    <span className="reorder-grip" aria-hidden="true">
                      <i className="reorder-grip-line" />
                      <i className="reorder-grip-line" />
                      <i className="reorder-grip-line" />
                    </span>
                  </button>
                </div>
                <button
                  className="track-remove"
                  type="button"
                  aria-label={`Remove ${track.title}`}
                  aria-hidden={currentSwipe ? undefined : true}
                  tabIndex={currentSwipe ? 0 : -1}
                  onClick={() => removeTrack(track.trackId)}
                >
                  <CloseIcon />
                </button>
              </li>
            )
          })}
        </ol>
      )}

      <p id="queue-interaction-help" className="sr-only">
        Use the three-line handle or its Arrow keys to reorder. Swipe left with one finger or two fingers on a trackpad to remove. Delete reveals Remove and Escape closes it.
      </p>

      {displayTracks.length > 0 ? (
        <div className="music-actions">
          {musicConnection === 'connected' ? (
            <>
              <p className="connection-note connection-note--success" role="status">
                <SuccessCircleIcon />
                <span>Apple Music connected. Ready to play.</span>
              </p>
              <div className="queue-actions">
                <PlayButton playing={playing} disabled={playbackBusy} onClick={onTogglePlay} />
                <LabelButton onClick={onSave} ariaLabel="Create playlist">
                  Create playlist
                </LabelButton>
              </div>
            </>
          ) : musicConnection === 'error' ? (
            <>
              <p className="connection-note connection-note--error" role="alert">
                <ErrorCircleIcon />
                <span>
                  <strong>Apple Music didn’t connect.</strong> Try again or keep shaping the mix.
                </span>
              </p>
              <ConnectMusicButton state="retry" onClick={onConnect} />
            </>
          ) : (
            <>
              <p className="connect-copy" role={musicConnection === 'connecting' ? 'status' : undefined}>
                {musicConnection === 'connecting'
                  ? 'Waiting for Apple Music. Keep this window open.'
                  : 'Connect Apple Music to play this mix or create it as a playlist. Your Mixtape account is already signed in.'}
              </p>
              <ConnectMusicButton state={musicConnection} onClick={onConnect} />
            </>
          )}
        </div>
      ) : null}

      {toast ? (
        <div className="queue-undo-toast">
          <span className="queue-undo-message" role="status" aria-live="polite">{toast.message}</span>
          {toast.undo ? (
            <button className="queue-undo-action" type="button" onClick={undoLastMutation} aria-label="Undo">
              <UndoIcon />
              <span>Undo</span>
            </button>
          ) : null}
        </div>
      ) : null}
    </aside>
  )
}
