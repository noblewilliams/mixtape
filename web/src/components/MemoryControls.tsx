import { useEffect, useRef, useState } from 'react'
import { ApiError, type ApiMemory, type MixtapeApi } from '../api/client'
import { ControlModal } from './ControlModal'

export function MemoryControls({
  api,
  onClose,
  onSessionExpired,
}: {
  api: MixtapeApi
  onClose: () => void
  onSessionExpired: () => void
}) {
  const [notes, setNotes] = useState<ApiMemory[] | null>(null)
  const [selected, setSelected] = useState<ApiMemory | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const [revision, setRevision] = useState(0)
  const life = useRef<AbortController | null>(null)
  const expired = useRef(onSessionExpired)
  expired.current = onSessionExpired
  useEffect(() => {
    const controller = new AbortController()
    life.current = controller
    setNotes(null)
    setError('')
    void api
      .listMemories(controller.signal)
      .then((value) => {
        if (!controller.signal.aborted) setNotes(value.memories)
      })
      .catch((e) => {
        if (controller.signal.aborted) return
        setError('Couldn’t load your notes. Try again.')
        if (e instanceof ApiError && e.status === 401) expired.current()
      })
    return () => controller.abort()
  }, [api, revision])
  async function forget() {
    if (!selected || busy) return
    const controller = life.current!
    const note = selected
    setBusy(true)
    setError('')
    setNotice('')
    try {
      try {
        await api.deleteMemory(note.id, controller.signal)
      } catch (e) {
        if (controller.signal.aborted) return
        if (e instanceof ApiError && e.status === 401) {
          expired.current()
          return
        }
        // A lost response may follow a successful delete; the subsequent read decides.
      }
      const current = await api.listMemories(controller.signal)
      if (controller.signal.aborted) return
      setNotes(current.memories)
      setSelected(null)
      if (current.memories.some((item) => item.id === note.id))
        setError('The note is still saved. Try forgetting it again.')
      else setNotice('Note forgotten.')
    } catch (e) {
      if (controller.signal.aborted) return
      setSelected(null)
      setNotes(null)
      setError('Couldn’t confirm the result. Reload your notes before trying again.')
      if (e instanceof ApiError && e.status === 401) expired.current()
    } finally {
      if (!controller.signal.aborted) setBusy(false)
    }
  }
  return (
    <main className="wc-view">
      <header>
        <h1>What the DJ knows</h1>
        <button className="wc-text" onClick={onClose}>
          Back
        </button>
      </header>
      <p>Preferences you asked the DJ to remember.</p>
      {notice && <p role="status">{notice}</p>}
      {error && <p role="alert">{error}</p>}
      {error && !notes ? (
        <button className="wc-text" onClick={() => setRevision((n) => n + 1)}>
          Reload notes
        </button>
      ) : !notes ? (
        <p role="status">Loading notes…</p>
      ) : notes.length === 0 ? (
        <p>Nothing remembered yet. Tell the DJ “remember…” when a preference should stay with you.</p>
      ) : (
        notes.map((note) => (
          <div className="wc-memory" key={note.id}>
            <p>{note.note}</p>
            <button className="wc-text" disabled={busy} onClick={() => setSelected(note)}>
              Forget
            </button>
          </div>
        ))
      )}
      {selected && (
        <ControlModal title="Forget this preference?" alert onClose={() => setSelected(null)}>
          <p>{selected.note}</p>
          <p>The DJ will stop using this note. You can’t undo this.</p>
          <div className="wc-actions">
            <button className="wc-text" onClick={() => setSelected(null)}>
              Keep note
            </button>
            <button className="wc-text wc-danger" disabled={busy} onClick={() => void forget()}>
              {busy ? 'Forgetting…' : 'Forget note'}
            </button>
          </div>
        </ControlModal>
      )}
    </main>
  )
}
