import { useEffect, useRef, type CSSProperties, type ReactNode } from 'react'
import './first-run.css'

export type FirstRunBackground = 'welcome' | 'artists' | 'step-1' | 'step-2' | 'step-3' | 'sign-in'
export type FirstRunStep = 1 | 2 | 3

export function backgroundUrl(background: FirstRunBackground): string {
  return `${import.meta.env.BASE_URL}first-run/bg-${background}.jpg`
}

/** The accessible page name: the step leads on counted pages. */
export function pageName(headline: string, step?: FirstRunStep): string {
  return step ? `Step ${step} of 3, ${headline}` : headline
}

export function RewindGlyph() {
  return (
    <svg className="fr-glyph" viewBox="0 0 24 24" aria-hidden="true">
      <path d="M20 6l-8 6 8 6zM12 6l-8 6 8 6z" />
    </svg>
  )
}

/** Solid when the action is ready, hollow when it is not (state is never opacity alone). */
export function FastForwardGlyph({ hollow = false }: { hollow?: boolean }) {
  return (
    <svg className={`fr-glyph fr-ff${hollow ? ' fr-ff--hollow' : ''}`} viewBox="0 0 24 24" aria-hidden="true">
      <path d="m4 6 8 6-8 6zM12 6l8 6-8 6z" />
    </svg>
  )
}

/** The tape-shaped outline back button carrying the rewind glyph. */
export function BackButton({ onBack, className = '' }: { onBack: () => void; className?: string }) {
  return (
    <button type="button" className={`fr-back ${className}`.trim()} aria-label="Back" onClick={onBack}>
      <RewindGlyph />
    </button>
  )
}

type Props = {
  background: FirstRunBackground
  headline: string
  /** Path B pages only: the counter and the progress line. */
  step?: FirstRunStep
  onBack?: () => void
  /** Move focus to the heading when the page appears (every page change, not the first load). */
  focusHeading?: boolean
  /** Drawn above the headline (wordmark, cassette). */
  before?: ReactNode
  children?: ReactNode
}

/**
 * The shared chrome of every first-run page: the full-bleed image for the
 * page, the scrim, cream text, the 420 px column, the outlined back button,
 * and on counted pages "STEP n OF 3" with a 2 px line filling a third per
 * step. The counter is decorative; the heading carries the step.
 */
export function FirstRunPage({ background, headline, step, onBack, focusHeading = false, before, children }: Props) {
  const heading = useRef<HTMLHeadingElement>(null)
  useEffect(() => {
    if (focusHeading) heading.current?.focus({ preventScroll: true })
  }, [focusHeading])
  const style = { '--fr-bg': `url("${backgroundUrl(background)}")` } as CSSProperties
  return (
    <main className={`fr-page fr-page--${background}`} style={style} data-background={background}>
      <div className="fr-col">
        <div className="fr-top">
          {onBack ? <BackButton onBack={onBack} /> : null}
          {step ? <span className="fr-stepc" aria-hidden="true">Step {step} of 3</span> : null}
        </div>
        <div className={`fr-prog${step ? '' : ' fr-prog--none'}`} aria-hidden="true">
          {step ? <i data-testid="fr-progress" style={{ width: `${(step / 3) * 100}%` }} /> : null}
        </div>
        <div className="fr-body">
          {before}
          <h1 className="fr-h" ref={heading} tabIndex={-1} aria-label={step ? pageName(headline, step) : undefined}>
            {headline}
          </h1>
          {children}
        </div>
      </div>
    </main>
  )
}

type PillProps = {
  children: ReactNode
  onClick?: () => void
  go?: boolean
  disabled?: boolean
  describedBy?: string
  type?: 'button' | 'submit'
}

/** The paper pill. `go` is the forward action: bold with the fast-forward glyph. */
export function Pill({ children, onClick, go = false, disabled = false, describedBy, type = 'button' }: PillProps) {
  return (
    <button
      type={type}
      className={`fr-pill${go ? ' fr-pill--go' : ''}${disabled ? ' fr-pill--off' : ''}`}
      disabled={disabled}
      aria-describedby={describedBy}
      onClick={onClick}
    >
      {children}
      {go ? <FastForwardGlyph hollow={disabled} /> : null}
    </button>
  )
}
