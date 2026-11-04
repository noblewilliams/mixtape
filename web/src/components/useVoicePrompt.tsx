import { useEffect, useRef, useState } from 'react'

export type VoiceState = 'idle' | 'requesting' | 'recording' | 'transcribing'
export type Transcribe = (audio: File, signal: AbortSignal) => Promise<{ text: string }>

/** Rejects a submit or a transcription without an error line: the prompt stays in the field. */
export class PromptKept extends Error {
  constructor() {
    super('Prompt kept')
    this.name = 'PromptKept'
  }
}

type Options = {
  transcribe: Transcribe
  /** The transcript, trimmed and non-empty. */
  onText: (text: string) => void
  /** An error line for the field, or null to clear it. */
  onError: (message: string | null) => void
  /** False opens the caller's consent dialog; nothing is recorded. */
  consentReady: () => boolean
}

/**
 * Voice capture for a prompt field: one tap asks for the microphone and
 * records (up to a minute), the next stops and transcribes. A tap while
 * waiting or transcribing cancels. Shared by the Home composer and the
 * first-run welcome field.
 */
export function useVoicePrompt({ transcribe, onText, onError, consentReady }: Options) {
  const [voice, setVoice] = useState<VoiceState>('idle')
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

  async function startRecording() {
    if (voice !== 'idle') return
    if (!consentReady()) return
    onError(null)
    if (!navigator.mediaDevices?.getUserMedia || typeof MediaRecorder === 'undefined') {
      onError('Voice recording isn’t available in this browser. You can still type.')
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
          onError('That recording is too long. Try a shorter prompt.')
        }
      }
      capture.onerror = () => {
        cancelVoice()
        onError('Couldn’t record your voice. Try again or type.')
      }
      capture.onstop = async () => {
        releaseMicrophone()
        recorder.current = null
        if (!mounted.current || version !== generation.current) return
        if (size < 1024) {
          setVoice('idle')
          onError('That recording was too short. Try again or type.')
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
          setVoice('idle')
          onText(result.text.trim())
        } catch (cause) {
          if (mounted.current && version === generation.current && !request.signal.aborted) {
            // PromptKept: the caller already answered (the consent dialog); no error line.
            if (!(cause instanceof PromptKept)) onError('Couldn’t transcribe that recording. Try again or type.')
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
      onError(cause instanceof DOMException && cause.name === 'NotAllowedError'
        ? 'Microphone access is blocked. You can still type.'
        : 'Couldn’t access your microphone. Try again or type.')
    }
  }

  /** The voice button: record, stop, or cancel, by state. */
  function toggle() {
    if (voice === 'recording') recorder.current?.stop()
    else if (voice !== 'idle') cancelVoice()
    else void startRecording()
  }

  return { voice, toggle }
}

export function voiceLabel(voice: VoiceState) {
  return voice === 'recording' ? 'Stop recording' : voice === 'transcribing' ? 'Cancel transcription' : voice === 'requesting' ? 'Cancel microphone request' : 'Record a voice prompt'
}

export function voiceStatus(voice: VoiceState) {
  return voice === 'requesting' ? 'Waiting for microphone…' : voice === 'recording' ? 'Listening…' : 'Transcribing…'
}

export function VoiceGlyph({ voice }: { voice: VoiceState }) {
  return <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">{voice === 'recording' ? <rect x="6" y="6" width="12" height="12" rx="2" /> : voice === 'transcribing' || voice === 'requesting' ? <path d="m6 6 12 12M18 6 6 18" /> : <><rect x="9" y="3" width="6" height="12" rx="3" /><path d="M6 10v2a6 6 0 0 0 12 0v-2M12 18v3M9 21h6" /></>}</svg>
}
