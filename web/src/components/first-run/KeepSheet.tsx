import { useEffect, useRef } from 'react'
import { Pill } from './FirstRunPage'
import './first-run.css'

export const KEEP_SHEET_HEADLINE = 'Your mix is ready.'
export const KEEP_SHEET_LINE = 'It’s saved on this device. Create an account to have it on your other devices too.'

const SEEN_KEY = 'mixtape.keep-sheet-seen'

/** Whether the sheet already showed in this browser session. */
export function keepSheetSeen(): boolean {
  try {
    return window.sessionStorage.getItem(SEEN_KEY) !== null
  } catch {
    return false
  }
}

/** Shown once per browser session: showing it (and so Not now) is final until the tab closes. */
export function markKeepSheetSeen() {
  try {
    window.sessionStorage.setItem(SEEN_KEY, new Date().toISOString())
  } catch {
    // Storage blocked: the in-memory guard in the shell still holds for this page.
  }
}

type Props = {
  /** Create an account: opens the sign-in page. */
  onKeep: () => void
  /** The pill (Go to my mix), Escape, the handle and the backdrop: back to the mix under the sheet. */
  onNotNow: () => void
}

/**
 * The sheet over a new anonymous listener's first mix (board A6, copy amended
 * 2026-11-06): it says the mix is ready, leads with Go to my mix, and keeps
 * Create an account as the quieter choice, so nobody mistakes sign-in for the
 * way to their mix. A bottom sheet on narrow widths, a centred compact modal
 * on wide ones. Provider buttons never appear here; they live only on the
 * sign-in page.
 */
export function KeepSheet({ onKeep, onNotNow }: Props) {
  const heading = useRef<HTMLHeadingElement>(null)
  const latest = useRef(onNotNow)
  latest.current = onNotNow

  useEffect(() => {
    heading.current?.focus({ preventScroll: true })
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== 'Escape') return
      event.preventDefault()
      latest.current()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [])

  return (
    <div className="ks-root">
      <div className="ks-backdrop" data-testid="keep-sheet-backdrop" aria-hidden="true" onClick={onNotNow} />
      <section className="ks-sheet" role="dialog" aria-modal="true" aria-labelledby="keep-sheet-title">
        <div className="ks-grab" data-testid="keep-sheet-handle" aria-hidden="true" onClick={onNotNow}>
          <i />
        </div>
        <h2 className="ks-h" id="keep-sheet-title" ref={heading} tabIndex={-1}>
          {KEEP_SHEET_HEADLINE}
        </h2>
        <p className="ks-line">{KEEP_SHEET_LINE}</p>
        <div className="ks-acts">
          <Pill go onClick={onNotNow}>Go to my mix</Pill>
        </div>
        <p className="ks-foot">
          <button type="button" className="ks-link" onClick={onKeep}>Create an account</button>
        </p>
      </section>
    </div>
  )
}
