import { useEffect, useRef, useState } from 'react'
import { Cassette } from '../Cassette'
import { SendIcon } from '../Icons'
import { FirstRunPage, Pill } from './FirstRunPage'

export const WELCOME_HEADLINE = 'What do you want to hear?'
export const WELCOME_EXAMPLES = ['something for a rainy commute', '90s R&B, no ballads', 'warm up for a long run'] as const

type ComposerProps = {
  draft: string
  onDraft: (value: string) => void
  onSend: (prompt: string) => void
  busy?: boolean
}

/**
 * The welcome field: the Home composer's field on paper, rotating the three
 * spec examples while it is empty and unfocused, Enter or the send key to go.
 * No microphone: transcription needs a session, and none exists yet.
 */
export function FirstRunComposer({ draft, onDraft, onSend, busy = false }: ComposerProps) {
  const [example, setExample] = useState(0)
  const input = useRef<HTMLTextAreaElement>(null)
  useEffect(() => {
    if (draft || busy) return
    const id = setInterval(() => {
      if (document.activeElement !== input.current && !window.matchMedia?.('(prefers-reduced-motion: reduce)').matches) {
        setExample((value) => (value + 1) % WELCOME_EXAMPLES.length)
      }
    }, 5000)
    return () => clearInterval(id)
  }, [draft, busy])
  const ready = Boolean(draft.trim()) && !busy
  function send() {
    if (ready) onSend(draft.trim())
  }
  return (
    <form className="home-composer fr-composer" onSubmit={(event) => { event.preventDefault(); send() }}>
      <i className="fr-stripe" aria-hidden="true" />
      <textarea
        ref={input}
        aria-label="Describe your mix"
        rows={1}
        maxLength={2000}
        value={draft}
        placeholder={WELCOME_EXAMPLES[example]}
        disabled={busy}
        onChange={(event) => onDraft(event.target.value)}
        onKeyDown={(event) => {
          if (event.key === 'Enter' && !event.shiftKey && !event.nativeEvent.isComposing) {
            event.preventDefault()
            send()
          }
        }}
      />
      <button className="home-send-button fr-send" type="submit" aria-label="Make a mix" disabled={!ready}>
        <i><SendIcon /></i>
      </button>
    </form>
  )
}

type Props = {
  draft: string
  onDraft: (value: string) => void
  onSend: (prompt: string) => void
  /** Welcome only; the prompt page after a sync has no add-music pill. */
  onAddMusic?: () => void
  /** The prompt page's line under the field ("1,284 songs in. Ask for anything."). */
  line?: string
  onSignIn: () => void
  onBack?: () => void
  busy?: boolean
  error?: string
  focusHeading?: boolean
}

export function Welcome({ draft, onDraft, onSend, onAddMusic, line, onSignIn, onBack, busy, error, focusHeading }: Props) {
  return (
    <FirstRunPage
      background="welcome"
      headline={WELCOME_HEADLINE}
      onBack={onBack}
      focusHeading={focusHeading}
      before={
        <>
          <span className="fr-wordmark">mixtape</span>
          <div className="fr-hero" aria-hidden="true">
            <Cassette className="fr-cassette" loading labelled={false} />
          </div>
        </>
      }
    >
      <FirstRunComposer draft={draft} onDraft={onDraft} onSend={onSend} busy={busy} />
      {line ? <p className="fr-line">{line}</p> : null}
      {error ? <p className="fr-status fr-status--err" role="alert">{error}</p> : null}
      {onAddMusic ? (
        <>
          <p className="fr-or">or</p>
          <div className="fr-acts">
            <Pill onClick={onAddMusic}>Add my music first</Pill>
          </div>
        </>
      ) : null}
      <p className="fr-foot">
        <span>Already have an account?</span>{' '}
        <button type="button" className="fr-link" onClick={onSignIn}>Sign in.</button>
      </p>
    </FirstRunPage>
  )
}
