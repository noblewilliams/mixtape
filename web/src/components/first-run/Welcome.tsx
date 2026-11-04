import { useEffect, useRef, useState } from 'react'
import { useAiConsentGate } from '../AiConsent'
import { Cassette } from '../Cassette'
import { SendIcon } from '../Icons'
import { useVoicePrompt, VoiceGlyph, voiceLabel, voiceStatus, type Transcribe } from '../useVoicePrompt'
import { FirstRunPage, Pill } from './FirstRunPage'

export const WELCOME_HEADLINE = 'What do you want to hear?'
export const WELCOME_EXAMPLES = ['something for a rainy commute', '90s R&B, no ballads', 'warm up for a long run'] as const

type ComposerProps = {
  draft: string
  onDraft: (value: string) => void
  onSend: (prompt: string) => void
  /** Voice capture; the flow makes sure of the session (and consent) first. Absent: no microphone. */
  transcribe?: Transcribe
  busy?: boolean
}

const MAX_LENGTH = 2000

/**
 * The welcome field: the Home composer's field on paper, rotating the three
 * spec examples while it is empty and unfocused, Enter or the send key to go,
 * or the microphone to speak it (the transcript lands in the field to edit).
 */
export function FirstRunComposer({ draft, onDraft, onSend, transcribe, busy = false }: ComposerProps) {
  const [example, setExample] = useState(0)
  const [voiceError, setVoiceError] = useState<string | null>(null)
  const input = useRef<HTMLTextAreaElement>(null)
  // The latest draft, for a transcript that lands after more typing.
  const latest = useRef(draft)
  latest.current = draft
  const consentReady = useAiConsentGate()
  const { voice, toggle } = useVoicePrompt({
    transcribe: transcribe ?? (async () => { throw new Error('Transcription unavailable') }),
    consentReady,
    onError: setVoiceError,
    onText: (text) => {
      onDraft([latest.current.trimEnd(), text].filter(Boolean).join(' ').slice(0, MAX_LENGTH))
      requestAnimationFrame(() => input.current?.focus())
    },
  })
  useEffect(() => {
    if (draft || busy || voice !== 'idle') return
    const id = setInterval(() => {
      if (document.activeElement !== input.current && !window.matchMedia?.('(prefers-reduced-motion: reduce)').matches) {
        setExample((value) => (value + 1) % WELCOME_EXAMPLES.length)
      }
    }, 5000)
    return () => clearInterval(id)
  }, [draft, busy, voice])
  const ready = Boolean(draft.trim()) && !busy && voice === 'idle'
  function send() {
    if (ready) onSend(draft.trim())
  }
  return (
    <>
    <form className="home-composer fr-composer" onSubmit={(event) => { event.preventDefault(); send() }}>
      <i className="fr-stripe" aria-hidden="true" />
      {voice === 'idle' ? <textarea
        ref={input}
        aria-label="Describe your mix"
        rows={1}
        maxLength={MAX_LENGTH}
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
      /> : (
        <div className="home-voice-status" role="status">
          {voice === 'recording' ? <i className="home-record-dot" /> : null}
          <span>{voiceStatus(voice)}</span>
        </div>
      )}
      {transcribe ? (
        <button className="home-voice-button fr-voice" type="button" disabled={busy} aria-label={voiceLabel(voice)} aria-pressed={voice === 'recording'} onClick={toggle}>
          <VoiceGlyph voice={voice} />
        </button>
      ) : null}
      <button className="home-send-button fr-send" type="submit" aria-label="Make a mix" disabled={!ready}>
        <i><SendIcon /></i>
      </button>
    </form>
    {voiceError ? <p className="fr-status fr-status--err" role="alert">{voiceError}</p> : null}
    </>
  )
}

type Props = {
  draft: string
  onDraft: (value: string) => void
  onSend: (prompt: string) => void
  transcribe?: Transcribe
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

export function Welcome({ draft, onDraft, onSend, transcribe, onAddMusic, line, onSignIn, onBack, busy, error, focusHeading }: Props) {
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
      <FirstRunComposer draft={draft} onDraft={onDraft} onSend={onSend} transcribe={transcribe} busy={busy} />
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
