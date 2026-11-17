import { useEffect, useRef, useState, type ReactNode, type Dispatch, type SetStateAction } from 'react'
import { useAiConsentGate } from './AiConsent'
import { DJ_PAUSED_DETAIL, DJ_PAUSED_LINE, useDjStatus } from '../lib/dj-status'
import { SendIcon, StopIcon } from './Icons'
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
  /** The DJ is working: the field stays open for the next message, but nothing sends and the mic is hidden. */
  busy?: boolean
  /**
   * A stoppable turn is out (spec 2026-11-15 stop-a-turn): Stop takes the
   * send key's place, draft or not. Absent: no Stop (an album turn).
   */
  onStop?: () => void
  transcribe: Transcribe
}

export function PromptComposer({ draft, setDraft, tools, inputLabel = 'Describe your mix', sendLabel = 'Make a mix', inputPlaceholder, submitError = 'Couldn’t make your mix. Your prompt is still here—try again.', maxLength = 2000, onSubmit, busy = false, onStop, transcribe }: PromptComposerProps) {
  const [sending, setSending] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [placeholder, setPlaceholder] = useState(0)
  const input = useRef<HTMLTextAreaElement>(null)
  // Missing AI consent re-opens the consent dialog; nothing is sent or recorded and the text stays.
  const consentReady = useAiConsentGate()
  // The DJ is paused (credits out, model down): nothing sends, the field and mic are off, a draft stays.
  const { paused } = useDjStatus()

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
    if (inputPlaceholder || draft || voice !== 'idle' || busy || sending || paused) return
    const id = setInterval(() => {
      if (document.activeElement !== input.current && !window.matchMedia?.('(prefers-reduced-motion: reduce)').matches) {
        setPlaceholder(value => (value + 1) % placeholders.length)
      }
    }, 5000)
    return () => clearInterval(id)
  }, [draft, voice, busy, sending, inputPlaceholder, paused])

  async function submit() {
    if (!draft.trim() || busy || sending || voice !== 'idle' || paused) return
    if (!consentReady()) return
    const sent = draft
    setSending(true)
    setError(null)
    try {
      await onSubmit(draft.trim())
      // The field stayed open meanwhile: a draft typed since is the listener's, never cleared.
      if (mounted.current) setDraft(value => (value === sent ? '' : value))
    } catch (cause) {
      // The prompt stays and the composer draws nothing: the caller already
      // answered elsewhere (the cap's sign-in page).
      if (mounted.current && !(cause instanceof PromptKept)) setError(submitError)
    } finally {
      if (mounted.current) setSending(false)
    }
  }

  const working = busy || sending
  return <div className="home-compose">
    {error && <div className="home-voice-error" role="alert"><span>{error}</span><button type="button" onClick={() => setError(null)}>Dismiss</button></div>}
    <form className={`home-composer${tools ? ' home-composer--tools' : ''}`} onSubmit={event => { event.preventDefault(); void submit() }}>
      {voice === 'idle' ? <textarea ref={input} aria-label={inputLabel} maxLength={maxLength} rows={1} value={draft} disabled={paused} placeholder={paused ? DJ_PAUSED_LINE : inputPlaceholder ?? placeholders[placeholder]} onChange={event => setDraft(event.target.value)} onKeyDown={event => {
        if (event.key === 'Enter' && !event.shiftKey && !event.nativeEvent.isComposing) { event.preventDefault(); void submit() }
      }} /> : <div className="home-voice-status" role="status">{voice === 'recording' && <i className="home-record-dot" />}<span>{voiceStatus(voice)}</span></div>}
      {tools && <div className="composer-tools">{tools}</div>}
      {/* A recording already under way keeps its key, so it can still be stopped. */}
      {(!working || voice !== 'idle') && <button className="home-voice-button" type="button" aria-label={voiceLabel(voice)} aria-pressed={voice === 'recording'} disabled={paused && voice === 'idle'} onClick={toggle}><VoiceGlyph voice={voice} /></button>}
      {onStop
        ? <button className="home-send-button" type="button" aria-label="Stop" onClick={onStop}><StopIcon /></button>
        : <button className="home-send-button" type="submit" aria-label={sendLabel} disabled={!draft.trim() || working || voice !== 'idle' || paused}><SendIcon /></button>}
    </form>
    {/* One quiet line, part of the composer; a kept draft hides the placeholder, so the line names the break too. */}
    {paused && <p className="composer-paused">{draft ? `${DJ_PAUSED_LINE}. ` : ''}{DJ_PAUSED_DETAIL}</p>}
  </div>
}
