import { createContext, useContext, useEffect, useId, useRef, useState } from 'react'
import { ControlModal } from './ControlModal'
import './ai-consent.css'

// Copy is fixed by docs/superpowers/plans/2026-11-02-ai-consent-and-privacy.md.
export const AI_CONSENT_TITLE = 'Before your first mix'
export const AI_CONSENT_BODY =
  'Mixtape’s DJ runs on Anthropic’s Claude. To make your mixes we send it what you type or say, and the music and listening history you add. Voice clips are transcribed by Groq. Your data is not sold or used for ads.'
export const AI_CONSENT_FAILED = 'Couldn’t save that. Try again.'
export const PRIVACY_POLICY_URL = 'https://miixtape.netlify.app/privacy/'

type Props = {
  /** Records the answer (and, in the first run, continues). A rejection keeps the dialog with the error. */
  onAgree: () => Promise<void>
  /** Not now, Escape and the backdrop: nothing is recorded or sent. */
  onNotNow: () => void
}

/**
 * The AI-processing consent, one dialog for both places it shows: before the
 * first run's first mix, and once over the app for a listener whose /me says
 * no. Compact and quiet, like the other confirmations.
 */
export function AiConsentDialog({ onAgree, onNotNow }: Props) {
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const inFlight = useRef(false)
  const mounted = useRef(true)
  const bodyId = useId()
  useEffect(() => {
    mounted.current = true
    return () => {
      mounted.current = false
    }
  }, [])

  async function agree() {
    if (inFlight.current) return
    inFlight.current = true
    setBusy(true)
    setError('')
    try {
      await onAgree()
    } catch {
      if (mounted.current) setError(AI_CONSENT_FAILED)
    } finally {
      inFlight.current = false
      if (mounted.current) setBusy(false)
    }
  }

  return (
    <ControlModal title={AI_CONSENT_TITLE} className="ai-consent" describedBy={bodyId} onClose={() => { if (!inFlight.current) onNotNow() }}>
      <p id={bodyId}>{AI_CONSENT_BODY}</p>
      {/* tabIndex keeps the link inside ControlModal's focus loop, which lists buttons and inputs. */}
      <p>
        <a className="ai-consent-policy" href={PRIVACY_POLICY_URL} target="_blank" rel="noopener noreferrer" tabIndex={0}>
          Privacy policy
        </a>
      </p>
      {error ? <p className="ai-consent-error" role="alert">{error}</p> : null}
      <div className="wc-actions">
        <button type="button" className="wc-text" disabled={busy} onClick={onNotNow} data-autofocus>Not now</button>
        <button type="button" className="wc-text ai-consent-agree" disabled={busy} aria-busy={busy || undefined} onClick={() => void agree()}>
          Agree and continue
        </button>
      </div>
    </ControlModal>
  )
}

/**
 * Asked before anything that would reach the DJ (a prompt, a voice capture).
 * Returns true to go ahead; false means consent is missing and the dialog
 * has been re-opened, so the caller sends nothing and keeps what was typed.
 * Outside the app shell (the first run handles its own) it always allows.
 */
export const AiConsentGate = createContext<() => boolean>(() => true)

export function useAiConsentGate(): () => boolean {
  return useContext(AiConsentGate)
}
