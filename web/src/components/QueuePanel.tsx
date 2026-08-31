import { useMemo, useState } from 'react'
import type { DjSession, QueueTrack } from '../domain'
import { CloseIcon, ErrorCircleIcon, MoreIcon, SuccessCircleIcon } from './Icons'
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
  playbackBusy,
  musicConnection,
  open,
  onConnect,
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
    <aside className={`queue-panel ${open ? 'is-open' : ''}`} aria-label="Your mix">
      <header className="queue-header">
        <div>
          <p>Your mix</p>
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

      {tracks.length > 0 ? (
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
    </aside>
  )
}
