import { useMemo, useState } from 'react'
import type { DjSession, QueueTrack } from '../domain'
import { CloseIcon, MoreIcon } from './Icons'
import { LabelButton, PlayButton } from './TapeActions'

type QueuePanelProps = {
  session: DjSession
  tracks: QueueTrack[]
  playing: boolean
  open: boolean
  onTogglePlay: () => void
  onSave: () => void
  onClose: () => void
}

function formatDuration(milliseconds: number) {
  const minutes = Math.floor(milliseconds / 60_000)
  const seconds = Math.floor((milliseconds % 60_000) / 1000)
  return `${minutes}:${seconds.toString().padStart(2, '0')}`
}

export function QueuePanel({
  session,
  tracks,
  playing,
  open,
  onTogglePlay,
  onSave,
  onClose,
}: QueuePanelProps) {
  const [expandedTrackId, setExpandedTrackId] = useState<string | null>(null)
  const totalDuration = useMemo(
    () => tracks.reduce((sum, track) => sum + (track.durationMs ?? 0), 0),
    [tracks],
  )

  return (
    <aside className={`queue-panel ${open ? 'is-open' : ''}`} aria-label="Your tape">
      <header className="queue-header">
        <div>
          <p>Your tape</p>
          <span>Side A</span>
        </div>
        <button className="queue-close" type="button" onClick={onClose} aria-label="Close your tape queue">
          <CloseIcon />
        </button>
      </header>

      <div className="queue-summary">
        <strong>{tracks.length === 0 ? 'Blank tape' : `${tracks.length} tracks`}</strong>
        <span>{tracks.length === 0 ? 'waiting for a prompt' : `about ${Math.round(totalDuration / 60_000)} min`}</span>
      </div>

      {tracks.length === 0 ? (
        <div className="empty-queue">
          <span>Side A is clear</span>
          <h2>This tape is still blank.</h2>
          <p>Tell the DJ what belongs on it. The queue will appear here as the conversation takes shape.</p>
        </div>
      ) : (
        <ol className="track-list" aria-label={`${session.title} track list`}>
          {tracks.map((track) => {
            const expanded = expandedTrackId === track.trackId
            return (
              <li className={expanded ? 'track-row is-expanded' : 'track-row'} key={track.trackId}>
                <button
                  className="track-main"
                  type="button"
                  onClick={() => setExpandedTrackId(expanded ? null : track.trackId)}
                  aria-expanded={expanded}
                >
                  <span className="track-number">{String(track.position + 1).padStart(2, '0')}</span>
                  <span className="track-copy">
                    <strong>{track.title}</strong>
                    <small>{track.artist}</small>
                  </span>
                  <span className="track-duration">{track.durationMs ? formatDuration(track.durationMs) : '—'}</span>
                </button>
                <button className="track-more" type="button" aria-label={`More options for ${track.title}`}>
                  <MoreIcon />
                </button>
                {expanded ? <p className="track-reason">{track.reason}</p> : null}
              </li>
            )
          })}
        </ol>
      )}

      <div className="queue-actions">
        <PlayButton playing={playing} disabled={tracks.length === 0} onClick={onTogglePlay} />
        <LabelButton onClick={onSave} disabled={tracks.length === 0} ariaLabel="Save playlist">
          Save playlist
        </LabelButton>
      </div>
    </aside>
  )
}
