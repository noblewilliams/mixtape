import { useEffect, useRef, useState } from 'react'
import { ApiError, type ApiPlaylistSummary, type MixtapeApi } from '../api/client'
import { ControlModal } from './ControlModal'

export function PlaylistTasteControls({
  playlist,
  api,
  onChanged,
  onSessionExpired,
}: {
  playlist: ApiPlaylistSummary
  api: MixtapeApi
  onChanged: (playlist: ApiPlaylistSummary) => void
  onSessionExpired: () => void
}) {
  const [confirm, setConfirm] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [uncertain, setUncertain] = useState(false)
  const life = useRef(new AbortController())
  const writing = useRef(false)
  useEffect(() => {
    life.current = new AbortController()
    return () => life.current.abort()
  }, [playlist.id, api])
  const confirmed = playlist.origin === 'user_confirmed'
  const eligible =
    playlist.inLibrary &&
    playlist.origin !== undefined &&
    playlist.origin !== 'mixtape' &&
    !['editorial', 'replay', 'personal_mix'].includes(playlist.kind)
  async function refresh() {
    const signal = life.current.signal
    setBusy(true)
    try {
      const result = await api.getPlaylist(playlist.id, { entryLimit: 1 }, signal)
      if (!signal.aborted) {
        onChanged(result.playlist)
        setUncertain(false)
        setError('')
      }
    } catch (error) {
      if (!signal.aborted && error instanceof ApiError && error.status === 401) onSessionExpired()
    } finally {
      if (!signal.aborted) setBusy(false)
    }
  }
  async function change(value: boolean) {
    if (writing.current || uncertain) return
    writing.current = true
    setBusy(true)
    setError('')
    const signal = life.current.signal
    try {
      let failed = false
      try {
        await api.confirmPlaylistTaste(playlist.id, value, signal)
      } catch (e) {
        if (signal.aborted) return
        if (e instanceof ApiError && e.status === 401) {
          onSessionExpired()
          return
        }
        failed = true
      }
      const result = await api.getPlaylist(playlist.id, { entryLimit: 1 }, signal)
      if (signal.aborted) return
      onChanged(result.playlist)
      setConfirm(false)
      if ((result.playlist.origin === 'user_confirmed') !== value)
        setError(
          failed
            ? 'Couldn’t save that choice. Playlist details have been refreshed.'
            : 'The playlist changed. Review its current details.',
        )
    } catch (e) {
      if (signal.aborted) return
      setUncertain(true)
      setError('Couldn’t confirm the result. Refresh the playlist before trying again.')
      setConfirm(false)
      if (e instanceof ApiError && e.status === 401) onSessionExpired()
    } finally {
      writing.current = false
      if (!signal.aborted) setBusy(false)
    }
  }
  return (
    <section className="wc-taste">
      <h3>Your taste</h3>
      <p>
        {confirmed
          ? 'You confirmed that you personally curated this playlist. It can inform future mixes.'
          : eligible
            ? 'Did you choose these songs yourself? Confirming helps the DJ learn your taste.'
            : 'Personal curation is unavailable for this playlist. It stays neutral as a taste signal.'}
      </p>
      {confirmed ? (
        <button className="wc-text" disabled={busy || uncertain} onClick={() => void change(false)}>
          Remove confirmation
        </button>
      ) : eligible ? (
        <button className="wc-text" disabled={busy || uncertain} onClick={() => setConfirm(true)}>
          I curated this
        </button>
      ) : null}
      {uncertain && (
        <button className="wc-text" disabled={busy} onClick={() => void refresh()}>
          Refresh playlist
        </button>
      )}
      {busy && <small role="status">Saving confirmation…</small>}
      {error && <small role="alert">{error}</small>}
      {confirm && (
        <ControlModal title="Use this as a taste signal?" onClose={() => setConfirm(false)}>
          <p>
            Confirm only if you personally chose these songs. This helps shape future mixes without changing
            your playlist.
          </p>
          <div className="wc-actions">
            <button className="wc-text" onClick={() => setConfirm(false)}>
              Cancel
            </button>
            <button className="wc-text" disabled={busy || uncertain} onClick={() => void change(true)}>
              Confirm my curation
            </button>
          </div>
        </ControlModal>
      )}
    </section>
  )
}
