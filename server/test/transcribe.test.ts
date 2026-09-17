import { afterEach, describe, expect, it, vi, type Mock } from 'vitest'
import { createApp, type AuthLike } from '../src/app'
import type { FetchLike } from '../src/musickit/catalog'
import { buildTranscribe } from '../src/index'

function stubAuth(session: { user: { id: string } } | null): AuthLike {
  return {
    handler: () => new Response('ok'),
    api: { getSession: async () => session },
  }
}

function audioBody(bytes: number, name = 'clip.m4a'): FormData {
  const body = new FormData()
  body.append('audio', new File([new Uint8Array(bytes)], name, { type: 'audio/mp4' }))
  return body
}

function appWith(
  fetchLike?: Mock<FetchLike>,
  session: { user: { id: string } } | null = { user: { id: 'user-1' } },
  // `null` means "secret not set" — plain undefined would fall through to the default.
  apiKey: string | null = 'groq-test-key',
) {
  return createApp({
    auth: stubAuth(session),
    transcribe: { apiKey: apiKey ?? undefined, ...(fetchLike ? { fetchLike } : {}) },
  })
}

afterEach(() => {
  vi.unstubAllGlobals()
  vi.restoreAllMocks()
})

describe('POST /transcribe', () => {
  it('requires the existing Mixtape session', async () => {
    const fetchLike = vi.fn<FetchLike>()
    const app = appWith(fetchLike, null)

    const response = await app.request('http://x/transcribe', { method: 'POST', body: audioBody(2048) })

    expect(response.status).toBe(401)
    expect(await response.json()).toEqual({ error: 'unauthorized' })
    expect(fetchLike).not.toHaveBeenCalled()
  })

  it('returns the transcript and language on a successful Groq call', async () => {
    const fetchLike = vi.fn<FetchLike>(async () =>
      new Response(JSON.stringify({ text: 'play me something warm', language: 'en' }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    const app = appWith(fetchLike)

    const response = await app.request('http://x/transcribe', { method: 'POST', body: audioBody(4096) })

    expect(response.status).toBe(200)
    expect(await response.json()).toEqual({ text: 'play me something warm', language: 'en' })
    expect(response.headers.get('cache-control')).toBe('private, no-store')

    expect(fetchLike).toHaveBeenCalledTimes(1)
    const [url, init] = fetchLike.mock.calls[0]!
    expect(init).toBeDefined()
    expect(url).toBe('https://api.groq.com/openai/v1/audio/transcriptions')
    expect(init!.method).toBe('POST')
    expect(new Headers(init!.headers).get('authorization')).toBe('Bearer groq-test-key')
    const forwarded = init!.body as FormData
    expect(forwarded.get('model')).toBe('whisper-large-v3-turbo')
    expect(forwarded.get('response_format')).toBe('json')
    expect(forwarded.get('file')).toBeInstanceOf(File)
    expect(init!.signal).toBeInstanceOf(AbortSignal)
  })

  it('defaults the language when Groq omits it', async () => {
    const fetchLike = vi.fn<FetchLike>(async () => new Response(JSON.stringify({ text: 'hello' }), { status: 200 }))
    const app = appWith(fetchLike)

    const response = await app.request('http://x/transcribe', { method: 'POST', body: audioBody(2048) })

    expect(response.status).toBe(200)
    expect(await response.json()).toEqual({ text: 'hello', language: 'en' })
  })

  it('rejects a request with no audio part without calling Groq', async () => {
    const fetchLike = vi.fn<FetchLike>()
    const app = appWith(fetchLike)

    const response = await app.request('http://x/transcribe', { method: 'POST', body: new FormData() })

    expect(response.status).toBe(400)
    expect(await response.json()).toEqual({ error: 'invalid_request' })
    expect(response.headers.get('cache-control')).toBe('private, no-store')
    expect(fetchLike).not.toHaveBeenCalled()
  })

  it('rejects a clip under 1 KB as empty audio', async () => {
    const fetchLike = vi.fn<FetchLike>()
    const app = appWith(fetchLike)

    const response = await app.request('http://x/transcribe', { method: 'POST', body: audioBody(512) })

    expect(response.status).toBe(400)
    expect(await response.json()).toEqual({ error: 'audio_too_short' })
    expect(fetchLike).not.toHaveBeenCalled()
  })

  it('rejects a clip over 25 MB before spending an upstream call', async () => {
    const fetchLike = vi.fn<FetchLike>()
    const app = appWith(fetchLike)

    const response = await app.request('http://x/transcribe', {
      method: 'POST',
      body: audioBody(25 * 1024 * 1024 + 1),
    })

    expect(response.status).toBe(400)
    expect(await response.json()).toEqual({ error: 'audio_too_large' })
    expect(fetchLike).not.toHaveBeenCalled()
  })

  it('answers 504 when the Groq call times out', async () => {
    const fetchLike = vi.fn<FetchLike>(async () => {
      throw new DOMException('The operation was aborted due to timeout', 'TimeoutError')
    })
    const app = appWith(fetchLike)

    const response = await app.request('http://x/transcribe', { method: 'POST', body: audioBody(2048) })

    expect(response.status).toBe(504)
    expect(await response.json()).toEqual({ error: 'transcription_timeout' })
  })

  it('answers 502 when Groq fails, without echoing the upstream body', async () => {
    const fetchLike = vi.fn<FetchLike>(async () => new Response('groq exploded: sensitive detail', { status: 500 }))
    const app = appWith(fetchLike)

    const response = await app.request('http://x/transcribe', { method: 'POST', body: audioBody(2048) })

    expect(response.status).toBe(502)
    expect(await response.json()).toEqual({ error: 'upstream' })
    expect(response.headers.get('cache-control')).toBe('private, no-store')
  })

  it('answers 502 when the Groq call fails for any other reason', async () => {
    const fetchLike = vi.fn<FetchLike>(async () => {
      throw new TypeError('network down')
    })
    const app = appWith(fetchLike)

    const response = await app.request('http://x/transcribe', { method: 'POST', body: audioBody(2048) })

    expect(response.status).toBe(502)
    expect(await response.json()).toEqual({ error: 'upstream' })
  })

  it('uses the platform fetch when no client is injected', async () => {
    const globalFetch = vi.fn<FetchLike>(async () => new Response(JSON.stringify({ text: 'global', language: 'fr' }), { status: 200 }))
    vi.stubGlobal('fetch', globalFetch)
    const app = appWith()

    const response = await app.request('http://x/transcribe', { method: 'POST', body: audioBody(2048) })

    expect(response.status).toBe(200)
    expect(await response.json()).toEqual({ text: 'global', language: 'fr' })
    expect(globalFetch).toHaveBeenCalledTimes(1)
  })

  it('never logs audio content or transcript text', async () => {
    const log = vi.spyOn(console, 'log').mockImplementation(() => {})
    const error = vi.spyOn(console, 'error').mockImplementation(() => {})
    const fetchLike = vi.fn<FetchLike>(async () => new Response('groq exploded: sensitive detail', { status: 500 }))

    await appWith(fetchLike).request('http://x/transcribe', { method: 'POST', body: audioBody(2048) })

    const logged = [...log.mock.calls, ...error.mock.calls].flat().map(String).join(' ')
    expect(logged).not.toContain('sensitive detail')
    expect(logged).not.toContain('clip.m4a')
  })

  it('answers 502 when a 200 response is not JSON', async () => {
    const fetchLike = vi.fn<FetchLike>(async () =>
      new Response('<html>upstream proxy error</html>', {
        status: 200,
        headers: { 'Content-Type': 'text/html' },
      }),
    )
    const app = appWith(fetchLike)

    const response = await app.request('http://x/transcribe', { method: 'POST', body: audioBody(2048) })

    expect(response.status).toBe(502)
    expect(await response.json()).toEqual({ error: 'upstream' })
  })

  it('answers 502 when a 200 response carries no transcript string', async () => {
    const fetchLike = vi.fn<FetchLike>(async () =>
      new Response(JSON.stringify({ error: { message: 'model overloaded' } }), { status: 200 }),
    )
    const app = appWith(fetchLike)

    const response = await app.request('http://x/transcribe', { method: 'POST', body: audioBody(2048) })

    expect(response.status).toBe(502)
    expect(await response.json()).toEqual({ error: 'upstream' })
  })

  it('answers 400 for a malformed multipart body rather than 500', async () => {
    const fetchLike = vi.fn<FetchLike>()
    const app = appWith(fetchLike)

    const response = await app.request('http://x/transcribe', {
      method: 'POST',
      headers: { 'Content-Type': 'multipart/form-data; boundary=----mixtape' },
      body: '------mixtape\r\nContent-Disposition: form-data; name="audio"; filename="clip.m4a"\r\n',
    })

    expect(response.status).toBe(400)
    expect(await response.json()).toEqual({ error: 'invalid_request' })
    expect(fetchLike).not.toHaveBeenCalled()
  })

  it('rejects a non-File audio field', async () => {
    const fetchLike = vi.fn<FetchLike>()
    const body = new FormData()
    body.append('audio', 'https://example.com/clip.m4a')
    const app = appWith(fetchLike)

    const response = await app.request('http://x/transcribe', { method: 'POST', body })

    expect(response.status).toBe(400)
    expect(await response.json()).toEqual({ error: 'invalid_request' })
    expect(fetchLike).not.toHaveBeenCalled()
  })

  it('answers 503 when GROQ_API_KEY is not configured', async () => {
    const fetchLike = vi.fn<FetchLike>()
    const app = appWith(fetchLike, { user: { id: 'user-1' } }, null)

    const response = await app.request('http://x/transcribe', { method: 'POST', body: audioBody(2048) })

    expect(response.status).toBe(503)
    expect(await response.json()).toEqual({ error: 'transcription_not_configured' })
    expect(response.headers.get('cache-control')).toBe('private, no-store')
    expect(fetchLike).not.toHaveBeenCalled()
  })

  it('stays unmounted when the Worker is wired without transcription', async () => {
    const app = createApp({ auth: stubAuth({ user: { id: 'user-1' } }) })

    const response = await app.request('http://x/transcribe', { method: 'POST', body: audioBody(2048) })

    expect(response.status).toBe(404)
  })
})

describe('transcription startup check', () => {
  it('flags a missing GROQ_API_KEY without taking down the rest of the API', async () => {
    const error = vi.spyOn(console, 'error').mockImplementation(() => {})

    expect(buildTranscribe({})).toEqual({ apiKey: undefined })
    expect(buildTranscribe({ GROQ_API_KEY: '' })).toEqual({ apiKey: undefined })
    expect(error.mock.calls.flat().map(String).join(' ')).toContain('GROQ_API_KEY is missing')

    // Other routes stay live on the same wiring.
    const app = createApp({ auth: stubAuth({ user: { id: 'user-1' } }), transcribe: buildTranscribe({}) })
    expect((await app.request('http://x/me')).status).toBe(200)
  })

  it('returns the transcription wiring when the key is configured', () => {
    expect(buildTranscribe({ GROQ_API_KEY: 'groq-live-key' })).toEqual({ apiKey: 'groq-live-key' })
  })
})
