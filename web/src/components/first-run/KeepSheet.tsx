import { useEffect, useRef } from 'react'
import { Pill } from './FirstRunPage'
import './first-run.css'

export const KEEP_SHEET_HEADLINE = 'Keep this mix.'
export const KEEP_SHEET_LINE = 'Sign in and your mixes and music stay with you on any device.'

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
  /** The pill: opens the sign-in page. */
  onKeep: () => void
  /** Not now, Escape, the handle and the backdrop. */
  onNotNow: () => void
}

/**
 * The Keep this mix sheet (board A6): cream paper, the headline, one line,
 * one paper pill and Not now. A bottom sheet on narrow widths, a centred
 * compact modal on wide ones. Provider buttons never appear here; they live
 * only on the sign-in page.
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
          <Pill go onClick={onKeep}>Keep this mix</Pill>
        </div>
        <p className="ks-foot">
          <button type="button" className="ks-link" onClick={onNotNow}>Not now</button>
        </p>
      </section>
    </div>
  )
}
