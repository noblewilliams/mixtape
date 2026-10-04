import { ControlModal } from './ControlModal'
import { EnergyControl, type EnergyArc } from './EnergyJourney'
import { useId, useState, type FormEvent, type ReactNode } from 'react'
import { CloseIcon } from './Icons'

type NewTapeDialogProps = {
  attachment?: ReactNode
  busy?: boolean
  onClose: () => void
  onCreate: (title: string, shape?: EnergyArc) => void
}

export function NewTapeDialog({ attachment, busy = false, onClose, onCreate }: NewTapeDialogProps) {
  const [title, setTitle] = useState('')
  const [shape, setShape] = useState<EnergyArc | null>(null)

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const value = title.trim()
    if (!value) return
    if (shape) onCreate(value, shape)
    else onCreate(value)
  }

  return (
    <div className="overlay" role="presentation" onMouseDown={(event) => event.target === event.currentTarget && onClose()}>
      <section className="dialog" role="dialog" aria-modal="true" aria-labelledby="new-tape-title">
        <button className="dialog-close" type="button" onClick={onClose} aria-label="Close new tape dialog" disabled={busy}>
          <CloseIcon />
        </button>
        <h2 id="new-tape-title">Make a mix</h2>
        <p>Describe the moment. This becomes your first message to the DJ.</p>
        <form className="wc-new-mix" onSubmit={submit}>
          {attachment}
          <EnergyControl value={shape} onSelect={setShape} disabled={busy} />
          <label htmlFor="new-tape-name">What should this tape feel like?</label>
          <textarea
            id="new-tape-name"
            autoFocus
            value={title}
            onChange={(event) => setTitle(event.target.value)}
            placeholder="Late dinner with old friends"
            maxLength={2000}
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
  /** Songs in the mix the listener does not own yet; creating the playlist adds them to their library. */
  newToYouCount?: number
  onClose: () => void
  onSave: (name: string) => void
}

function newToYouNote(count: number) {
  return count === 1
    ? '1 song here is new to you. Creating the playlist adds it to your Apple Music library.'
    : `${count} songs here are new to you. Creating the playlist adds them to your Apple Music library.`
}

export function SaveDialog({ busy = false, error = '', defaultName, newToYouCount = 0, onClose, onSave }: SaveDialogProps) {
  const [name, setName] = useState(defaultName)
  const noteId = useId()

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!name.trim() || busy) return
    onSave(name.trim())
  }

  return (
    <ControlModal
      title="Create playlist"
      className="playlist-dialog"
      describedBy={newToYouCount > 0 ? noteId : undefined}
      onClose={() => { if (!busy) onClose() }}
    >
        <button className="dialog-close" type="button" onClick={onClose} aria-label="Close playlist dialog" disabled={busy}>
          <CloseIcon />
        </button>
        <form onSubmit={submit}>
          <label htmlFor="playlist-name">Playlist name</label>
          <input
            id="playlist-name"
            value={name}
            onChange={(event) => setName(event.target.value)}
            maxLength={80}
            disabled={busy}
          />
          {newToYouCount > 0 ? <p className="playlist-dialog-note" id={noteId}>{newToYouNote(newToYouCount)}</p> : null}
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
    </ControlModal>
  )
}

export function Toast({ message, tone, action }: { message: string; tone: 'success' | 'error' | 'info'; action?: { label: string; onClick: () => void; disabled?: boolean } }) {
  return <div className={`toast toast--${tone}`} role={tone === 'error' ? 'alert' : 'status'}>
    <img src={`/ui/status-${tone}.svg`} alt="" aria-hidden="true" />
    <span>{message}</span>
    {action && <button type="button" disabled={action.disabled} onClick={action.onClick}>{action.label}</button>}
  </div>
}
