import { useState, type FormEvent } from 'react'
import { Cassette } from './Cassette'
import { CloseIcon, ErrorCircleIcon, SuccessCircleIcon } from './Icons'

type NewTapeDialogProps = {
  busy?: boolean
  onClose: () => void
  onCreate: (title: string) => void
}

export function NewTapeDialog({ busy = false, onClose, onCreate }: NewTapeDialogProps) {
  const [title, setTitle] = useState('')

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const value = title.trim()
    if (!value) return
    onCreate(value)
  }

  return (
    <div className="overlay" role="presentation" onMouseDown={(event) => event.target === event.currentTarget && onClose()}>
      <section className="dialog" role="dialog" aria-modal="true" aria-labelledby="new-tape-title">
        <button className="dialog-close" type="button" onClick={onClose} aria-label="Close new tape dialog" disabled={busy}>
          <CloseIcon />
        </button>
        <h2 id="new-tape-title">Make a new tape</h2>
        <p>Describe the moment. This becomes your first message to the DJ.</p>
        <form onSubmit={submit}>
          <label htmlFor="new-tape-name">What should this tape feel like?</label>
          <input
            id="new-tape-name"
            autoFocus
            value={title}
            onChange={(event) => setTitle(event.target.value)}
            placeholder="Late dinner with old friends"
            maxLength={80}
            disabled={busy}
          />
          <div className="dialog-actions">
            <button className="dialog-cancel" type="button" onClick={onClose} disabled={busy}>
              Cancel
            </button>
            <button className="dialog-confirm" type="submit" disabled={!title.trim() || busy}>
              {busy ? 'Making tape…' : 'Start tape'}
            </button>
          </div>
        </form>
      </section>
    </div>
  )
}

type SaveDialogProps = {
  busy?: boolean
  error?: string
  defaultName: string
  onClose: () => void
  onSave: (name: string) => void
}

export function SaveDialog({ busy = false, error = '', defaultName, onClose, onSave }: SaveDialogProps) {
  const [name, setName] = useState(defaultName)

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!name.trim()) return
    onSave(name.trim())
  }

  return (
    <div className="overlay" role="presentation" onMouseDown={(event) => event.target === event.currentTarget && onClose()}>
      <section className="dialog" role="dialog" aria-modal="true" aria-labelledby="save-playlist-title">
        <button className="dialog-close" type="button" onClick={onClose} aria-label="Close playlist dialog" disabled={busy}>
          <CloseIcon />
        </button>
        <p className="quiet-kicker">Apple Music</p>
        <h2 id="save-playlist-title">Create playlist</h2>
        <p>The mix stays in Mixtape. This creates a separate Apple Music playlist you can keep.</p>
        <form onSubmit={submit}>
          <label htmlFor="playlist-name">Playlist name</label>
          <input
            id="playlist-name"
            value={name}
            onChange={(event) => setName(event.target.value)}
            maxLength={80}
            disabled={busy}
          />
          {error ? <p className="dialog-error" role="alert">{error}</p> : null}
          <div className="dialog-actions">
            <button className="dialog-cancel" type="button" onClick={onClose} disabled={busy}>
              Cancel
            </button>
            <button
              className="dialog-confirm"
              type="submit"
              aria-label="Confirm create playlist"
              disabled={!name.trim() || busy}
            >
              {busy ? 'Creating playlist…' : 'Create playlist'}
            </button>
          </div>
        </form>
      </section>
    </div>
  )
}

export function SyncOverlay({ onClose }: { onClose: () => void }) {
  return (
    <div className="overlay sync-overlay">
      <section className="sync-card" role="dialog" aria-modal="true" aria-labelledby="sync-title">
        <button className="dialog-close" type="button" onClick={onClose} aria-label="Close library preparation">
          <CloseIcon />
        </button>
        <Cassette className="loader-cassette" loading labelled={false} />
        <p className="quiet-kicker">Preparing your music</p>
        <h2 id="sync-title">Listening through your library</h2>
        <p>You can leave this open. Nothing is being added to Apple Music.</p>
        <div className="sync-progress" role="progressbar" aria-label="Library sync" aria-valuemin={0} aria-valuemax={100} aria-valuenow={68}>
          <span />
        </div>
        <small>Matching sound, meaning, and the songs you return to.</small>
      </section>
    </div>
  )
}

export function Toast({ message, tone }: { message: string; tone: 'success' | 'error' }) {
  return (
    <div className={`toast toast--${tone}`} role={tone === 'error' ? 'alert' : 'status'}>
      {tone === 'success' ? <SuccessCircleIcon /> : <ErrorCircleIcon />}
      <span>{message}</span>
    </div>
  )
}
