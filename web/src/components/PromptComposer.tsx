import { useEffect, useRef, useState, type ReactNode, type Dispatch, type SetStateAction } from 'react'
import { useAiConsentGate } from './AiConsent'
import { SendIcon } from './Icons'
import { PromptKept, useVoicePrompt, VoiceGlyph, voiceLabel, voiceStatus, type Transcribe } from './useVoicePrompt'
import './home-composer.css'

export { PromptKept }

const placeholders = ['A slow evening, nothing too loud…', 'Something for the long way home…', 'Start with one song you love…']
export type PromptComposerProps = {
  draft: string
  setDraft: Dispatch<SetStateAction<string>>
  tools?: ReactNode
  inputLabel?: string
  sendLabel?: string
  inputPlaceholder?: string
  submitError?: string
  maxLength?: number
  onSubmit: (prompt: string) => void | Promise<void>
  busy?: boolean
  transcribe: Transcribe
}

export function PromptComposer({ draft, setDraft, tools, inputLabel = 'Describe your mix', sendLabel = 'Make a mix', inputPlaceholder, submitError = 'Couldn’t make your mix. Your prompt is still here—try again.', maxLength = 2000, onSubmit, busy = false, transcribe }: PromptComposerProps) {
  const [sending, setSending] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [placeholder, setPlaceholder] = useState(0)
  const input = useRef<HTMLTextAreaElement>(null)
  // Missing AI consent re-opens the consent dialog; nothing is sent or recorded and the text stays.
  const consentReady = useAiConsentGate()

  const { voice, toggle } = useVoicePrompt({
    transcribe,
    consentReady,
    onError: setError,
    onText: text => {
      setDraft(value => [value.trimEnd(), text].filter(Boolean).join(' ').slice(0, maxLength))
      requestAnimationFrame(() => input.current?.focus())
    },
  })
  const mounted = useRef(true)
  useEffect(() => {
    mounted.current = true
    return () => { mounted.current = false }
  }, [])

  useEffect(() => {
    if (inputPlaceholder || draft || voice !== 'idle' || busy || sending) return
    const id = setInterval(() => {
      if (document.activeElement !== input.current && !window.matchMedia?.('(prefers-reduced-motion: reduce)').matches) {
        setPlaceholder(value => (value + 1) % placeholders.length)
      }
    }, 5000)
    return () => clearInterval(id)
  }, [draft, voice, busy, sending, inputPlaceholder])

  async function submit() {
    if (!draft.trim() || busy || sending || voice !== 'idle') return
    if (!consentReady()) return
    setSending(true)
    setError(null)
    try {
      await onSubmit(draft.trim())
      if (mounted.current) setDraft('')
    } catch (cause) {
      // The prompt stays and the composer draws nothing: the caller already
      // answered elsewhere (the cap's sign-in page).
      if (mounted.current && !(cause instanceof PromptKept)) setError(submitError)
    } finally {
      if (mounted.current) setSending(false)
    }
  }

  return <div className="home-compose">
    {error && <div className="home-voice-error" role="alert"><span>{error}</span><button type="button" onClick={() => setError(null)}>Dismiss</button></div>}
    <form className={`home-composer${tools ? ' home-composer--tools' : ''}`} onSubmit={event => { event.preventDefault(); void submit() }}>
      {voice === 'idle' ? <textarea ref={input} aria-label={inputLabel} maxLength={maxLength} rows={1} value={draft} placeholder={inputPlaceholder ?? placeholders[placeholder]} disabled={busy || sending} onChange={event => setDraft(event.target.value)} onKeyDown={event => {
        if (event.key === 'Enter' && !event.shiftKey && !event.nativeEvent.isComposing) { event.preventDefault(); void submit() }
      }} /> : <div className="home-voice-status" role="status">{voice === 'recording' && <i className="home-record-dot" />}<span>{voiceStatus(voice)}</span></div>}
      {tools && <div className="composer-tools">{tools}</div>}
      <button className="home-voice-button" type="button" disabled={busy || sending} aria-label={voiceLabel(voice)} aria-pressed={voice === 'recording'} onClick={toggle}><VoiceGlyph voice={voice} /></button>
      <button className="home-send-button" type="submit" aria-label={sendLabel} disabled={!draft.trim() || busy || sending || voice !== 'idle'}><SendIcon /></button>
    </form>
  </div>
}
