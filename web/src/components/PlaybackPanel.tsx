import { useState, useSyncExternalStore } from 'react'
import { PlaybackController } from '../playback/controller'
import { ControlModal } from './ControlModal'
import './playback.css'
const time = (ms: number) =>
  `${Math.floor(ms / 60000)}:${String(Math.floor(ms / 1000) % 60).padStart(2, '0')}`
export function PlaybackPanel({
  controller, settingsOnly = false,
}: {
  controller: PlaybackController
  settingsOnly?: boolean
}) {
  const state = useSyncExternalStore(controller.subscribe, controller.getState)
  const [seek, setSeek] = useState<number | null>(null)
  const [open, setOpen] = useState(false),
    [preferences, setPreferences] = useState(false),
    [confirm, setConfirm] = useState(false)
  const [message, setMessage] = useState(''),
    [busy, setBusy] = useState(false),
    [clearId, setClearId] = useState<string | null>(null)
  const track = state.tracks[state.sample.index ?? 0]
  async function save(enabled: boolean) {
    setBusy(true)
    setMessage('')
    try {
      await controller.preference(enabled)
      setMessage(
        enabled ? 'Listening learning is on.' : 'Listening learning is off.',
      )
    } catch {
      setMessage('Could not save. Collection is paused until you try again.')
    } finally {
      setBusy(false)
    }
  }
  async function clear() {
    setBusy(true)
    const id = clearId ?? crypto.randomUUID()
    setClearId(id)
    try {
      await controller.clear(id)
      setConfirm(false)
      setClearId(null)
      setMessage('Learned listening cleared.')
    } catch {
      setMessage('Could not confirm clearing. Retry to check the same request.')
    } finally {
      setBusy(false)
    }
  }
  return (
    <>
      {(state.sessionId || settingsOnly) && <div className={settingsOnly ? "settings-listening-details" : "playback-mini"}>
        {state.sessionId && !settingsOnly && (
          <>
            <div>
              <strong>{track?.title ?? state.title}</strong>
              <small>
                {state.error
                  ? 'Playback unavailable'
                  : state.busy
                    ? 'Getting ready…'
                    : state.sample.status === 'playing'
                      ? 'Playing'
                      : state.sample.status === 'waiting'
                        ? 'Waiting for Apple Music'
                        : 'Paused'}{' '}
                · {track?.artist}
              </small>
            </div>
            <button type="button" onClick={() => setOpen(true)}>
              Open player
            </button>
          </>
        )}
        {settingsOnly && (
          <button className="wc-text" aria-label="Listening preferences" type="button" onClick={() => setPreferences(true)}>
            Manage
          </button>
        )}
      </div>}
      {open && (
        <ControlModal
          title={track?.title ?? 'Your player'}
          onClose={() => setOpen(false)}
        >
          <p>{track?.artist} · Apple Music</p>
          <p>
            {state.title} · version {state.version}
          </p>
          {state.error && (
            <>
              <p role="alert">{state.error}</p>
              <button
                className="wc-text"
                disabled={state.busy}
                onClick={() => void controller.reconnect()}
              >
                Connect Apple Music
              </button>
            </>
          )}
          <label className="playback-seek">
            Playback position
            <input
              type="range"
              min={0}
              max={track?.durationMs ?? 0}
              value={
                seek ??
                Math.min(state.sample.positionMs, track?.durationMs ?? 0)
              }
              aria-valuetext={`${time(state.sample.positionMs)} of ${time(track?.durationMs ?? 0)}`}
              disabled={state.busy || !track?.durationMs}
              onChange={(e) => setSeek(Number(e.target.value))}
              onPointerUp={(e) => {
                void controller.command(
                  'resume',
                  Number(e.currentTarget.value) / 1000,
                )
                setSeek(null)
              }}
              onKeyUp={(e) => {
                if (seek !== null) {
                  void controller.command('resume', seek / 1000)
                  setSeek(null)
                }
              }}
              onBlur={() => {
                if (seek !== null) {
                  void controller.command('resume', seek / 1000)
                  setSeek(null)
                }
              }}
            />
          </label>
          <p>
            {time(state.sample.positionMs)} / {time(track?.durationMs ?? 0)}
          </p>
          <div className="playback-actions">
            <button
              disabled={state.busy}
              onClick={() => void controller.command('previous')}
            >
              Previous
            </button>
            <button
              className="playback-primary"
              disabled={state.busy}
              onClick={() =>
                void controller.command(
                  state.sample.status === 'playing' ? 'pause' : 'resume',
                )
              }
            >
              {state.sample.status === 'playing' ? 'Pause' : 'Resume'}
            </button>
            <button
              disabled={state.busy}
              onClick={() => void controller.command('next')}
            >
              Next
            </button>
            <button
              disabled={state.busy}
              onClick={() => void controller.command('repeat')}
            >
              Repeat song
            </button>
          </div>
          <div className="playback-actions">
            <button onClick={() => setOpen(false)}>Back to mix</button>
            <button
              onClick={() => {
                void controller.stop()
                setOpen(false)
              }}
            >
              {state.busy ? 'Cancel' : 'Stop playback'}
            </button>
            <button
              onClick={() => {
                setOpen(false)
                setPreferences(true)
              }}
            >
              Listening preferences
            </button>
          </div>
        </ControlModal>
      )}
      {preferences && (
        <ControlModal
          title="Let listening shape your mixes."
          onClose={() => {
            if (!busy) setPreferences(false)
          }}
        >
          <p>
            Patterns in skips, repeats and listening help the DJ adapt. One
            skipped song does not mean you dislike it.
          </p>
          <label>
            <input
              type="checkbox"
              checked={state.preferences?.enabled ?? false}
              disabled={busy}
              onChange={(e) => void save(e.target.checked)}
            />{' '}
            Learn from my listening in Mixtape
          </label>
          <p>Imported history and preferences you told the DJ stay separate.</p>
          {message && <p role="status">{message}</p>}
          {confirm ? (
            <>
              <p>
                Remove the listening activity Mixtape collected for learning?
                Imported history, mixes and written preferences stay.
              </p>
              <div className="playback-actions">
                <button disabled={busy} onClick={() => void clear()}>
                  Clear learned listening
                </button>
                <button disabled={busy} onClick={() => setConfirm(false)}>
                  Cancel
                </button>
              </div>
            </>
          ) : (
            <button className="wc-text" onClick={() => setConfirm(true)}>
              Clear learned listening
            </button>
          )}
          <button
            className="wc-text"
            disabled={busy}
            onClick={() => setPreferences(false)}
          >
            Done
          </button>
        </ControlModal>
      )}
    </>
  )
}
