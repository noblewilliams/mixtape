import { useEffect, useRef, useState, type ReactNode, type Dispatch, type SetStateAction } from 'react'
import { SendIcon } from './Icons'
import './home-composer.css'

const placeholders = ['A slow evening, nothing too loud…', 'Something for the long way home…', 'Start with one song you love…']
type VoiceState = 'idle' | 'requesting' | 'recording' | 'transcribing'
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
  transcribe: (audio: File, signal: AbortSignal) => Promise<{ text: string }>
}

export function PromptComposer({ draft, setDraft, tools, inputLabel = 'Describe your mix', sendLabel = 'Make a mix', inputPlaceholder, submitError = 'Couldn’t make your mix. Your prompt is still here—try again.', maxLength = 2000, onSubmit, busy = false, transcribe }: PromptComposerProps) {
  const [voice, setVoice] = useState<VoiceState>('idle')
  const [sending, setSending] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [placeholder, setPlaceholder] = useState(0)
  const input = useRef<HTMLTextAreaElement>(null)
  const recorder = useRef<MediaRecorder | null>(null)
  const stream = useRef<MediaStream | null>(null)
  const controller = useRef<AbortController | null>(null)
  const generation = useRef(0)
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null)
  const mounted = useRef(true)

  function releaseMicrophone() {
    if (timer.current) clearTimeout(timer.current)
    timer.current = null
    stream.current?.getTracks().forEach(track => track.stop())
    stream.current = null
  }

  function cancelVoice() {
    generation.current += 1
    controller.current?.abort()
    controller.current = null
    if (recorder.current) {
      recorder.current.onstop = null
      recorder.current.ondataavailable = null
      recorder.current.onerror = null
      if (recorder.current.state !== 'inactive') recorder.current.stop()
      recorder.current = null
    }
    releaseMicrophone()
    if (mounted.current) setVoice('idle')
  }

  useEffect(() => {
    mounted.current = true
    return () => { mounted.current = false; cancelVoice() }
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

  async function startRecording() {
    if (busy || sending || voice !== 'idle') return
    setError(null)
    if (!navigator.mediaDevices?.getUserMedia || typeof MediaRecorder === 'undefined') {
      setError('Voice recording isn’t available in this browser. You can still type.')
      return
    }
    const version = ++generation.current
    setVoice('requesting')
    try {
      const media = await navigator.mediaDevices.getUserMedia({ audio: true })
      if (!mounted.current || version !== generation.current) {
        media.getTracks().forEach(track => track.stop())
        return
      }
      stream.current = media
      const mimeType = ['audio/webm;codecs=opus', 'audio/mp4', 'audio/ogg;codecs=opus'].find(type => MediaRecorder.isTypeSupported(type))
      const capture = new MediaRecorder(media, mimeType ? { mimeType } : undefined)
      recorder.current = capture
      const chunks: Blob[] = []
      let size = 0
      capture.ondataavailable = event => {
        if (event.data.size) { chunks.push(event.data); size += event.data.size }
        if (size > 24 * 1024 * 1024) {
          cancelVoice()
          setError('That recording is too long. Try a shorter prompt.')
        }
      }
      capture.onerror = () => {
        cancelVoice()
        setError('Couldn’t record your voice. Try again or type.')
      }
      capture.onstop = async () => {
        releaseMicrophone()
        recorder.current = null
        if (!mounted.current || version !== generation.current) return
        if (size < 1024) {
          setVoice('idle')
          setError('That recording was too short. Try again or type.')
          return
        }
        setVoice('transcribing')
        const request = new AbortController()
        controller.current = request
        try {
          const type = capture.mimeType || mimeType || 'audio/webm'
          const extension = type.includes('mp4') ? 'm4a' : type.includes('ogg') ? 'ogg' : 'webm'
          const result = await transcribe(new File(chunks, `voice-prompt.${extension}`, { type }), request.signal)
          if (!mounted.current || version !== generation.current || request.signal.aborted) return
          if (!result.text.trim()) throw new Error('empty')
          setDraft(value => [value.trimEnd(), result.text.trim()].filter(Boolean).join(' ').slice(0, maxLength))
          setVoice('idle')
          requestAnimationFrame(() => input.current?.focus())
        } catch {
          if (mounted.current && version === generation.current && !request.signal.aborted) {
            setError('Couldn’t transcribe that recording. Try again or type.')
            setVoice('idle')
          }
        } finally {
          if (controller.current === request) controller.current = null
        }
      }
      capture.start(1000)
      setVoice('recording')
      timer.current = setTimeout(() => { if (capture.state === 'recording') capture.stop() }, 60_000)
    } catch (cause) {
      if (!mounted.current || version !== generation.current) return
      releaseMicrophone()
      setVoice('idle')
      setError(cause instanceof DOMException && cause.name === 'NotAllowedError'
        ? 'Microphone access is blocked. You can still type.'
        : 'Couldn’t access your microphone. Try again or type.')
    }
  }

  async function submit() {
    if (!draft.trim() || busy || sending || voice !== 'idle') return
    setSending(true)
    setError(null)
    try {
      await onSubmit(draft.trim())
      if (mounted.current) setDraft('')
    } catch {
      if (mounted.current) setError(submitError)
    } finally {
      if (mounted.current) setSending(false)
    }
  }

  return <div className="home-compose">
    {error && <div className="home-voice-error" role="alert"><span>{error}</span><button type="button" onClick={() => setError(null)}>Dismiss</button></div>}
    <form className={`home-composer${tools ? ' home-composer--tools' : ''}`} onSubmit={event => { event.preventDefault(); void submit() }}>
      {voice === 'idle' ? <textarea ref={input} aria-label={inputLabel} maxLength={maxLength} rows={1} value={draft} placeholder={inputPlaceholder ?? placeholders[placeholder]} disabled={busy || sending} onChange={event => setDraft(event.target.value)} onKeyDown={event => {
        if (event.key === 'Enter' && !event.shiftKey && !event.nativeEvent.isComposing) { event.preventDefault(); void submit() }
      }} /> : <div className="home-voice-status" role="status">{voice === 'recording' && <i className="home-record-dot" />}<span>{voice === 'requesting' ? 'Waiting for microphone…' : voice === 'recording' ? 'Listening…' : 'Transcribing…'}</span></div>}
      {tools && <div className="composer-tools">{tools}</div>}
      <button className="home-voice-button" type="button" disabled={busy || sending} aria-label={voice === 'recording' ? 'Stop recording' : voice === 'transcribing' ? 'Cancel transcription' : voice === 'requesting' ? 'Cancel microphone request' : 'Record a voice prompt'} aria-pressed={voice === 'recording'} onClick={() => {
        if (voice === 'recording') recorder.current?.stop()
        else if (voice !== 'idle') cancelVoice()
        else void startRecording()
      }}><svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">{voice === 'recording' ? <rect x="6" y="6" width="12" height="12" rx="2" /> : voice === 'transcribing' || voice === 'requesting' ? <path d="m6 6 12 12M18 6 6 18" /> : <><rect x="9" y="3" width="6" height="12" rx="3" /><path d="M6 10v2a6 6 0 0 0 12 0v-2M12 18v3M9 21h6" /></>}</svg></button>
      <button className="home-send-button" type="submit" aria-label={sendLabel} disabled={!draft.trim() || busy || sending || voice !== 'idle'}><SendIcon /></button>
    </form>
  </div>
}
