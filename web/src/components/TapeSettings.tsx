import { useRef, useState } from 'react'
import type { DjSession } from '../domain'
import { tapeColors } from '../data/tape-colors'
import { ControlModal } from './ControlModal'

export function TapeSettings({ session, onColor, onClose }: { session: DjSession; onColor: (color: string) => Promise<void>; onClose: () => void }) {
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const saving = useRef(false)
  const uncertain = useRef(false)
  async function select(color: string) {
    if (saving.current || (!uncertain.current && color === session.caseColor)) return
    saving.current = true
    setBusy(true)
    setError('')
    try { await onColor(color); uncertain.current = false }
    catch { uncertain.current = true; setError('Couldn’t save the colour. Try again.') }
    finally { saving.current = false; setBusy(false) }
  }
  return <ControlModal title="Tape settings" onClose={() => { if (!saving.current) onClose() }}>
    <div className="tape-settings">
      <button className="wc-text tape-settings-done" disabled={busy} onClick={onClose}>Done</button>
      <p className="settings-mix">{session.title}</p>
      <div className="settings-label"><span>Tape colour</span><span>{tapeColors.find(([, color]) => color === session.caseColor)?.[0] ?? 'Original'}</span></div>
      <div className="tape-swatches" role="group" aria-label="Tape colour" aria-busy={busy}>
        {tapeColors.map(([name, color]) => <button key={color} type="button" aria-label={name} title={name} aria-pressed={session.caseColor === color} disabled={busy} onClick={() => void select(color)}><span style={{ background: color }} /></button>)}
      </div>
      {error && <p className="dialog-error" role="alert">{error}</p>}
    </div>
  </ControlModal>
}
