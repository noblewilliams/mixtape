import { Hono } from 'hono'
import type { AppVars, TranscribeWiring } from '../app'

const GROQ_TRANSCRIPTIONS_URL = 'https://api.groq.com/openai/v1/audio/transcriptions'
// whisper-large-v3-turbo is the cheap/fast tier; the DJ only needs a prompt
// transcribed, not diarisation or word timings.
const GROQ_MODEL = 'whisper-large-v3-turbo'
// Groq rejects anything over 25 MB; under 1 KB is a mic that never opened, so
// both bounds are checked here rather than spending an upstream call on them.
const MIN_AUDIO_BYTES = 1_024
const MAX_AUDIO_BYTES = 25 * 1024 * 1024
const UPSTREAM_TIMEOUT_MS = 15_000

/**
 * POST /transcribe — multipart `audio` clip in, `{ text, language }` out.
 *
 * Audio bytes and transcript text are forwarded and returned, never logged and
 * never persisted: failure logging carries a fixed marker plus the upstream
 * status only, and the upstream error body is not read at all.
 */
export function transcribeRoutes({ apiKey, fetchLike }: TranscribeWiring) {
  const app = new Hono<{ Variables: AppVars }>()

  // Transcripts are user speech: no response from this route, success or
  // failure, may sit in a shared cache.
  app.use('*', async (c, next) => {
    await next()
    c.header('Cache-Control', 'private, no-store')
  })

  app.post('/', async (c) => {
    // Missing secret degrades this route only — Workers has no NODE_ENV to gate
    // a dev fallback on, so the key is checked explicitly rather than assumed.
    if (!apiKey) return c.json({ error: 'transcription_not_configured' }, 503)

    let audio: unknown
    try {
      audio = (await c.req.parseBody())['audio']
    } catch {
      // A truncated or malformed multipart body is a client mistake, not a
      // server fault: no marker logged, since the throw can wrap the audio.
      return c.json({ error: 'invalid_request' }, 400)
    }
    if (!(audio instanceof File)) return c.json({ error: 'invalid_request' }, 400)
    if (audio.size < MIN_AUDIO_BYTES) return c.json({ error: 'audio_too_short' }, 400)
    if (audio.size > MAX_AUDIO_BYTES) return c.json({ error: 'audio_too_large' }, 400)

    const upstreamBody = new FormData()
    upstreamBody.append('file', audio, audio.name || 'audio.m4a')
    upstreamBody.append('model', GROQ_MODEL)
    upstreamBody.append('response_format', 'json')

    // Resolved per request so a stubbed platform fetch is honoured, and so the
    // injected client (tests, future retry wrapper) wins when it is present.
    const doFetch = fetchLike ?? fetch

    let upstream: Response
    try {
      upstream = await doFetch(GROQ_TRANSCRIPTIONS_URL, {
        method: 'POST',
        headers: { Authorization: `Bearer ${apiKey}` },
        body: upstreamBody,
        signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
      })
    } catch (error) {
      const timedOut = error instanceof DOMException && error.name === 'TimeoutError'
      // Fixed marker only: the thrown error can wrap the request (and so the
      // audio) or the upstream response body.
      console.error(timedOut ? 'transcribe upstream timed out' : 'transcribe upstream call failed')
      return timedOut
        ? c.json({ error: 'transcription_timeout' }, 504)
        : c.json({ error: 'upstream' }, 502)
    }

    if (!upstream.ok) {
      console.error('transcribe upstream rejected', upstream.status)
      return c.json({ error: 'upstream' }, 502)
    }

    // A 200 carrying HTML, an error envelope, or a truncated stream is an
    // upstream failure, not a transcript.
    let parsed: unknown
    try {
      parsed = await upstream.json()
    } catch {
      console.error('transcribe upstream returned unparseable body', upstream.status)
      return c.json({ error: 'upstream' }, 502)
    }
    const result = parsed as { text?: unknown; language?: unknown }
    if (typeof result?.text !== 'string') {
      console.error('transcribe upstream returned no transcript', upstream.status)
      return c.json({ error: 'upstream' }, 502)
    }

    return c.json({
      text: result.text,
      language: typeof result.language === 'string' && result.language ? result.language : 'en',
    })
  })

  return app
}
