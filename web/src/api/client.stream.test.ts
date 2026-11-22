import { afterEach, describe, expect, it, vi } from 'vitest'
import { AnonymousCapError, ApiError, createMixtapeApi, TurnAnswerGoneError, type TurnProgress } from './client'

const fetchMock = vi.fn<typeof fetch>()
const BASE = 'https://api.mixtape.test'

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } })

const frame = (event: string, data: unknown) => `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`

/** A 200 event stream of `chunks`, each one a separate read (split mid-event where a test wants). */
function stream(chunks: string[]) {
  const encoder = new TextEncoder()
  let index = 0
  const body = new ReadableStream<Uint8Array>({
    pull(controller) {
      if (index < chunks.length) controller.enqueue(encoder.encode(chunks[index++]))
      else controller.close()
    },
  })
  return new Response(body, { status: 200, headers: { 'content-type': 'text/event-stream; charset=utf-8', 'cache-control': 'no-cache, no-transform' } })
}

/** Splits `text` into chunks of `size` characters, so events straddle reads. */
const chunked = (text: string, size = 7) => Array.from({ length: Math.ceil(text.length / size) }, (_, i) => text.slice(i * size, (i + 1) * size))

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
const keyOf = (call = 0) => new Headers(fetchMock.mock.calls[call][1]?.headers).get('idempotency-key')
const accept = (call = 0) => new Headers(fetchMock.mock.calls[call][1]?.headers).get('accept')
const sentBody = (call = 0) => fetchMock.mock.calls[call][1]?.body

const created = {
  session: { id: 'session-9', title: 'Rain on Third Mainland', status: 'active', queueVersion: 1, notPersonal: true, updatedAt: '2026-11-13T08:00:00.000Z' },
  messages: [
    { id: 'u-1', role: 'user', content: 'Rainy commute', createdAt: '2026-11-13T08:00:00.000Z' },
    { id: 'd-1', role: 'dj', content: 'Fifteen for the bridge.', queueVersion: 1, createdAt: '2026-11-13T08:00:30.000Z' },
  ],
  queue: [],
  suggestions: [],
  addMusic: 'history',
}

const reply = {
  djMessage: { id: 'd-2', role: 'dj', content: 'Slower in the middle now.', queueVersion: 2, createdAt: '2026-11-13T08:01:00.000Z' },
  queue: [],
  queueVersion: 2,
  sessionTitle: 'Slow bridge',
}

describe('streamed mix turns', () => {
  afterEach(() => {
    fetchMock.mockReset()
    vi.unstubAllGlobals()
  })

  it('asks for JSON exactly as before when no one listens for progress', async () => {
    fetchMock.mockImplementation(async (url) => (String(url).endsWith('/messages') ? json(reply) : json(created)))
    vi.stubGlobal('fetch', fetchMock)
    const api = createMixtapeApi(BASE)

    await api.createSession('Rainy commute')
    await api.createSession('Rainy commute', undefined, 'rise')
    await api.createSession('Rainy commute', undefined, undefined, 'mix', {})
    await api.sendMessage('session-9', 'Slower')
    await api.sendMessage('session-9', 'Slower', undefined, { remake: true })

    expect(fetchMock.mock.calls.map((_, call) => accept(call))).toEqual(Array(5).fill('application/json'))
  })

  it('sends exactly today’s request without a listener, and the same one but for Accept with one', async () => {
    fetchMock.mockImplementation(async (url) => (String(url).endsWith('/messages') ? json(reply) : json(created)))
    vi.stubGlobal('fetch', fetchMock)
    const api = createMixtapeApi(BASE, () => 'token')
    const request = (call: number) => {
      const [url, init] = fetchMock.mock.calls[call]
      const { headers, ...rest } = init!
      return { url, ...rest, headers: Object.fromEntries(new Headers(headers).entries()) }
    }
    const today = (path: string, body: unknown, accept = 'application/json') => ({
      url: `${BASE}${path}`,
      method: 'POST',
      body: JSON.stringify(body),
      credentials: 'include',
      headers: {
        accept, authorization: 'Bearer token', 'content-type': 'application/json',
        // A streamed turn carries its Idempotency-Key (durable turns); the JSON path stays as it was.
        ...(accept === 'text/event-stream' ? { 'idempotency-key': expect.stringMatching(UUID) } : {}),
      },
    })

    await api.createSession('Rainy commute', { playlistId: 'p-1' }, 'rise')
    await api.sendMessage('session-9', 'Slower', 'fall', { remake: true })
    fetchMock.mockImplementation(async () => stream([frame('result', reply)]))
    await api.createSession('Rainy commute', { playlistId: 'p-1' }, 'rise', undefined, { onProgress: () => {} })
    await api.sendMessage('session-9', 'Slower', 'fall', { remake: true, onProgress: () => {} })

    expect(request(0)).toEqual(today('/sessions', { prompt: 'Rainy commute', playlistSeed: { playlistId: 'p-1' }, energyArc: 'rise' }))
    expect(request(1)).toEqual(today('/sessions/session-9/messages', { text: 'Slower', energyArc: 'fall', remake: true }))
    expect(request(2)).toEqual(today('/sessions', { prompt: 'Rainy commute', playlistSeed: { playlistId: 'p-1' }, energyArc: 'rise' }, 'text/event-stream'))
    expect(request(3)).toEqual(today('/sessions/session-9/messages', { text: 'Slower', energyArc: 'fall', remake: true }, 'text/event-stream'))
  })

  it('gives up on a stream that goes quiet past the idle timeout, as a network failure', async () => {
    const body = new ReadableStream<Uint8Array>({ start: (controller) => controller.enqueue(new TextEncoder().encode(frame('step', { step: 'picking' }))) })
    fetchMock.mockResolvedValueOnce(new Response(body, { status: 200, headers: { 'content-type': 'text/event-stream' } }))
    vi.stubGlobal('fetch', fetchMock)
    const seen: TurnProgress[] = []

    const error = await createMixtapeApi(BASE, () => null, { streamIdleTimeoutMs: 30 })
      .sendMessage('session-9', 'Slower', undefined, { onProgress: (progress) => seen.push(progress) })
      .catch((e: unknown) => e)

    expect(error).toBeInstanceOf(TypeError)
    expect(seen).toEqual([{ type: 'opened' }, { type: 'step', step: 'picking' }])
  })

  it('streams a new mix: opened, the session, each step, then the same body the JSON path gives', async () => {
    const events = [
      ': keepalive\n\n',
      frame('session', { session: { id: 'session-9', title: 'Rainy commute' } }),
      frame('step', { step: 'digging', scope: 'catalogue', artists: ['Tems', 'Asake'] }),
      frame('step', { step: 'labelling', title: 'Rain on Third Mainland — “live”' }),
      frame('step', { step: 'pressing', count: 15 }),
      frame('result', created),
    ].join('')
    fetchMock.mockResolvedValueOnce(json(created)).mockResolvedValueOnce(stream(chunked(events)))
    vi.stubGlobal('fetch', fetchMock)
    const api = createMixtapeApi(BASE, () => 'token')
    const seen: TurnProgress[] = []

    const plain = await api.createSession('Rainy commute', undefined, 'rise')
    const streamed = await api.createSession('Rainy commute', undefined, 'rise', undefined, { onProgress: (progress) => seen.push(progress) })

    expect(streamed).toEqual(plain)
    expect(streamed.addMusic).toBe('history')
    expect(accept(1)).toBe('text/event-stream')
    expect(sentBody(1)).toBe(sentBody(0))
    expect(new Headers(fetchMock.mock.calls[1][1]?.headers).get('authorization')).toBe('Bearer token')
    expect(seen).toEqual([
      { type: 'opened' },
      { type: 'session', sessionId: 'session-9' },
      { type: 'step', step: 'digging', scope: 'catalogue', artists: ['Tems', 'Asake'] },
      { type: 'step', step: 'labelling', title: 'Rain on Third Mainland — “live”' },
      { type: 'step', step: 'pressing', count: 15 },
    ])
  })

  it('streams a message turn and a remake, and keeps only history pills it knows, as the JSON path does', async () => {
    const unknownPill = { ...reply, addMusic: 'apple_export' }
    fetchMock
      .mockResolvedValueOnce(json(unknownPill))
      .mockResolvedValueOnce(stream([frame('step', { step: 'editing' }), frame('result', unknownPill)]))
      .mockResolvedValueOnce(stream([frame('result', reply)]))
    vi.stubGlobal('fetch', fetchMock)
    const api = createMixtapeApi(BASE)
    const seen: TurnProgress[] = []
    const onProgress = (progress: TurnProgress) => seen.push(progress)

    const plain = await api.sendMessage('session-9', 'Slower', 'fall')
    const streamed = await api.sendMessage('session-9', 'Slower', 'fall', { onProgress })
    await api.sendMessage('session-9', 'Remake this with my music', undefined, { remake: true, onProgress })

    expect(streamed).toEqual(plain)
    expect(streamed).not.toHaveProperty('addMusic')
    expect([accept(1), accept(2)]).toEqual(['text/event-stream', 'text/event-stream'])
    expect(sentBody(1)).toBe(JSON.stringify({ text: 'Slower', energyArc: 'fall' }))
    expect(sentBody(2)).toBe(JSON.stringify({ text: 'Remake this with my music', remake: true }))
    expect(seen).toEqual([{ type: 'opened' }, { type: 'step', step: 'editing' }, { type: 'opened' }])
  })

  it('throws the error event as the ApiError the JSON path throws for the same status and body', async () => {
    const body = { error: 'curation_failed', message: 'The DJ lost the thread. Try again.', sessionTitle: 'Slow bridge' }
    fetchMock
      .mockResolvedValueOnce(json(body, 502))
      .mockResolvedValueOnce(stream([frame('step', { step: 'picking' }), frame('error', { status: 502, body })]))
    vi.stubGlobal('fetch', fetchMock)
    const api = createMixtapeApi(BASE)

    const plain = await api.sendMessage('session-9', 'Slower').catch((e: unknown) => e)
    const streamed = await api.sendMessage('session-9', 'Slower', undefined, { onProgress: () => {} }).catch((e: unknown) => e)

    expect(streamed).toBeInstanceOf(ApiError)
    expect(streamed).toMatchObject({ status: 502, code: 'curation_failed', message: body.message, payload: body })
    expect(streamed).toEqual(plain)
  })

  it('maps an in-band anonymous cap and a 401 through the same errors', async () => {
    fetchMock
      .mockResolvedValueOnce(stream([frame('error', { status: 403, body: { error: 'anonymous_cap', limit: 3 } })]))
      .mockResolvedValueOnce(stream([frame('error', { status: 401, body: { error: 'unauthorized' } })]))
    vi.stubGlobal('fetch', fetchMock)
    const api = createMixtapeApi(BASE)

    const cap = await api.createSession('again', undefined, undefined, undefined, { onProgress: () => {} }).catch((e: unknown) => e)
    const expired = await api.sendMessage('session-9', 'Slower', undefined, { onProgress: () => {} }).catch((e: unknown) => e)

    expect(cap).toBeInstanceOf(AnonymousCapError)
    expect(cap).toMatchObject({ limit: 3 })
    expect(expired).toMatchObject({ status: 401 })
  })

  it('throws a server error for an error event it cannot read', async () => {
    fetchMock.mockResolvedValueOnce(stream(['event: error\ndata: {"body":{}}\n\n']))
    vi.stubGlobal('fetch', fetchMock)

    const error = await createMixtapeApi(BASE).sendMessage('session-9', 'Slower', undefined, { onProgress: () => {} }).catch((e: unknown) => e)

    expect(error).toBeInstanceOf(ApiError)
    expect(error).toMatchObject({ status: 502, code: 'malformed_response' })
  })

  it('reads a JSON answer (an older server) exactly as before, and reports nothing', async () => {
    fetchMock.mockResolvedValueOnce(json(reply)).mockResolvedValueOnce(json(created))
    vi.stubGlobal('fetch', fetchMock)
    const api = createMixtapeApi(BASE)
    const onProgress = vi.fn()

    expect(await api.sendMessage('session-9', 'Slower', undefined, { onProgress })).toEqual(reply)
    expect(await api.createSession('Rainy commute', undefined, undefined, undefined, { onProgress })).toEqual(created)
    expect(onProgress).not.toHaveBeenCalled()
  })

  it('keeps a refusal before the turn as today’s status and error, and reports nothing', async () => {
    fetchMock
      .mockResolvedValueOnce(json({ error: 'ai_consent_required' }, 403))
      .mockResolvedValueOnce(json({ error: 'anonymous_cap', limit: 3 }, 403))
      .mockResolvedValueOnce(json({ error: 'not_found' }, 404))
    vi.stubGlobal('fetch', fetchMock)
    const api = createMixtapeApi(BASE)
    const onProgress = vi.fn()

    const consent = await api.sendMessage('session-9', 'Slower', undefined, { onProgress }).catch((e: unknown) => e)
    const cap = await api.createSession('again', undefined, undefined, undefined, { onProgress }).catch((e: unknown) => e)
    const missing = await api.sendMessage('gone', 'Slower', undefined, { onProgress }).catch((e: unknown) => e)

    expect(consent).toMatchObject({ status: 403, code: 'ai_consent_required' })
    expect(cap).toBeInstanceOf(AnonymousCapError)
    expect(missing).toMatchObject({ status: 404, code: 'not_found' })
    expect(onProgress).not.toHaveBeenCalled()
  })

  it('throws a network failure, as a failed fetch does, when the stream ends before its result', async () => {
    const offline = new TypeError('Failed to fetch')
    fetchMock
      .mockRejectedValueOnce(offline)
      .mockResolvedValueOnce(stream([frame('step', { step: 'picking' }), 'event: result\ndata: {"djMessage":'] ))
    vi.stubGlobal('fetch', fetchMock)
    const api = createMixtapeApi(BASE)
    const seen: TurnProgress[] = []

    const before = await api.sendMessage('session-9', 'Slower', undefined, { onProgress: (progress) => seen.push(progress) }).catch((e: unknown) => e)
    expect(before).toBe(offline)
    expect(seen).toEqual([])

    const dropped = await api.sendMessage('session-9', 'Slower', undefined, { onProgress: (progress) => seen.push(progress) }).catch((e: unknown) => e)
    expect(dropped).toBeInstanceOf(TypeError)
    expect(dropped).not.toBeInstanceOf(ApiError)
    expect(seen).toEqual([{ type: 'opened' }, { type: 'step', step: 'picking' }])
  })

  it('keeps an album create on the plain path, even with a listener', async () => {
    fetchMock.mockResolvedValueOnce(json({ session: { id: 'a-1', kind: 'album' }, messages: [], pick: null, runnersUp: [], passed: [], version: 1 }))
    vi.stubGlobal('fetch', fetchMock)
    const onProgress = vi.fn()

    await createMixtapeApi(BASE).createSession('An album for the train', undefined, 'rise', 'album', { onProgress })

    expect(accept()).toBe('application/json')
    expect(sentBody()).toBe(JSON.stringify({ prompt: 'An album for the train', kind: 'album' }))
    expect(onProgress).not.toHaveBeenCalled()
  })

  it('finishes the turn when the progress listener throws', async () => {
    fetchMock.mockResolvedValueOnce(stream([frame('step', { step: 'picking' }), frame('result', reply)]))
    vi.stubGlobal('fetch', fetchMock)
    const onProgress = vi.fn(() => {
      throw new Error('the caption broke')
    })

    expect(await createMixtapeApi(BASE).sendMessage('session-9', 'Slower', undefined, { onProgress })).toEqual(reply)
    expect(onProgress).toHaveBeenCalledTimes(2)
  })
})

describe('stopping a turn', () => {
  afterEach(() => {
    fetchMock.mockReset()
    vi.unstubAllGlobals()
  })

  it('posts the stop for the session and reads its answer', async () => {
    fetchMock.mockResolvedValueOnce(json({ stopped: true })).mockResolvedValueOnce(json({ stopped: false }))
    vi.stubGlobal('fetch', fetchMock)
    const api = createMixtapeApi(BASE, () => 'token-1')

    expect(await api.stopTurn('session 9')).toEqual({ stopped: true })
    expect(await api.stopTurn('session-9')).toEqual({ stopped: false })
    expect(String(fetchMock.mock.calls[0][0])).toBe(`${BASE}/sessions/session%209/turn/stop`)
    expect(fetchMock.mock.calls[0][1]?.method).toBe('POST')
    expect(new Headers(fetchMock.mock.calls[0][1]?.headers).get('authorization')).toBe('Bearer token-1')
  })

  it('reads a 404 (the session went with an earlier stop) as stopped, and throws other failures', async () => {
    fetchMock.mockResolvedValueOnce(json({ error: 'not_found' }, 404)).mockResolvedValueOnce(json({ error: 'internal' }, 500))
    vi.stubGlobal('fetch', fetchMock)
    const api = createMixtapeApi(BASE)

    expect(await api.stopTurn('gone')).toEqual({ stopped: true })
    await expect(api.stopTurn('session-9')).rejects.toMatchObject({ status: 500 })
  })

  it('hands the signal to the turn request, so an abort abandons a stream mid-read', async () => {
    const controller = new AbortController()
    fetchMock.mockImplementation(async (_url, init) => {
      const signal = init?.signal
      const body = new ReadableStream<Uint8Array>({
        start(stream) {
          stream.enqueue(new TextEncoder().encode(frame('session', { session: { id: 'session-9' } })))
          signal?.addEventListener('abort', () => stream.error(new DOMException('aborted', 'AbortError')))
        },
      })
      return new Response(body, { status: 200, headers: { 'content-type': 'text/event-stream' } })
    })
    vi.stubGlobal('fetch', fetchMock)
    const seen: TurnProgress[] = []

    const turn = createMixtapeApi(BASE).createSession('Rainy commute', undefined, undefined, undefined, { onProgress: (progress) => {
      seen.push(progress)
      if (progress.type === 'session') controller.abort()
    }, signal: controller.signal })

    await expect(turn).rejects.toBeInstanceOf(Error)
    expect(fetchMock.mock.calls[0][1]?.signal).toBe(controller.signal)
    expect(seen).toEqual([{ type: 'opened' }, { type: 'session', sessionId: 'session-9' }])
  })

  it('hands the signal to a message turn too', async () => {
    const controller = new AbortController()
    fetchMock.mockResolvedValueOnce(json(reply))
    vi.stubGlobal('fetch', fetchMock)

    await createMixtapeApi(BASE).sendMessage('session-9', 'Slower', undefined, { onProgress: () => {}, signal: controller.signal })

    expect(fetchMock.mock.calls[0][1]?.signal).toBe(controller.signal)
    expect(sentBody()).toBe(JSON.stringify({ text: 'Slower' }))
  })
})

describe('durable mix turns', () => {
  afterEach(() => {
    fetchMock.mockReset()
    vi.unstubAllGlobals()
  })

  const TURN = '0b6f3c1e-5d2a-4f8e-9c3b-7a1d2e4f6a8b'
  const turnFrame = frame('turn', { turnId: TURN, push: true })
  const url = (call: number) => String(fetchMock.mock.calls[call][0])
  const method = (call: number) => fetchMock.mock.calls[call][1]?.method ?? 'GET'

  it('reports the turn event after the session, and skips events it does not know', async () => {
    fetchMock.mockResolvedValueOnce(stream([
      frame('session', { session: { id: 'session-9' } }),
      turnFrame,
      frame('later_thing', { anything: true }),
      frame('turn', { push: true }),
      frame('step', { step: 'picking' }),
      frame('result', created),
    ]))
    vi.stubGlobal('fetch', fetchMock)
    const seen: TurnProgress[] = []

    await createMixtapeApi(BASE).createSession('Rainy commute', undefined, undefined, undefined, { onProgress: (progress) => seen.push(progress) })

    expect(seen).toEqual([
      { type: 'opened' },
      { type: 'session', sessionId: 'session-9' },
      { type: 'turn', turnId: TURN, push: true },
      { type: 'step', step: 'picking' },
    ])
  })

  it('sends a fresh Idempotency-Key with every streamed mix turn, and none on the JSON or album paths', async () => {
    fetchMock.mockImplementation(async (input) => (String(input).endsWith('/messages') ? stream([frame('result', reply)]) : stream([frame('result', created)])))
    vi.stubGlobal('fetch', fetchMock)
    const api = createMixtapeApi(BASE)
    const onProgress = () => {}

    await api.createSession('Rainy commute', undefined, undefined, undefined, { onProgress })
    await api.sendMessage('session-9', 'Slower', undefined, { onProgress })
    await api.sendMessage('session-9', 'Remake this with my music', undefined, { remake: true, onProgress })
    fetchMock.mockImplementation(async () => json(created))
    await api.createSession('Rainy commute')
    await api.createSession('An album', undefined, undefined, 'album', { onProgress })

    const keys = [0, 1, 2].map(keyOf)
    keys.forEach((key) => expect(key).toMatch(UUID))
    expect(new Set(keys).size).toBe(3)
    expect([keyOf(3), keyOf(4)]).toEqual([null, null])
  })

  it('never retries a failure before the stream opened against a server that has not sent a turn event', async () => {
    const offline = new TypeError('Failed to fetch')
    fetchMock.mockRejectedValueOnce(offline).mockResolvedValueOnce(stream([frame('result', reply)]))
    vi.stubGlobal('fetch', fetchMock)

    const error = await createMixtapeApi(BASE).sendMessage('session-9', 'Slower', undefined, { onProgress: () => {} }).catch((e: unknown) => e)

    expect(error).toBe(offline)
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })

  it('retries a failure before the stream opened once, with the same key, once the server has sent a turn event', async () => {
    fetchMock
      .mockResolvedValueOnce(stream([turnFrame, frame('result', reply)]))
      .mockRejectedValueOnce(new TypeError('Failed to fetch'))
      .mockResolvedValueOnce(stream([turnFrame, frame('result', reply)]))
      .mockRejectedValueOnce(new TypeError('Failed to fetch'))
      .mockRejectedValueOnce(new TypeError('Failed to fetch again'))
    vi.stubGlobal('fetch', fetchMock)
    const api = createMixtapeApi(BASE)

    await api.sendMessage('session-9', 'Slower', undefined, { onProgress: () => {} })
    expect(await api.sendMessage('session-9', 'Faster', undefined, { onProgress: () => {} })).toEqual(reply)
    const twice = await api.sendMessage('session-9', 'Again', undefined, { onProgress: () => {} }).catch((e: unknown) => e)

    expect(fetchMock).toHaveBeenCalledTimes(5)
    expect(keyOf(1)).toBe(keyOf(2))
    expect(sentBody(2)).toBe(sentBody(1))
    expect(keyOf(1)).not.toBe(keyOf(0))
    expect(keyOf(3)).toBe(keyOf(4))
    expect(keyOf(3)).not.toBe(keyOf(1))
    expect(twice).toMatchObject({ message: 'Failed to fetch again' })
  })

  it('never retries an aborted request', async () => {
    const controller = new AbortController()
    fetchMock
      .mockResolvedValueOnce(stream([turnFrame, frame('result', reply)]))
      .mockImplementationOnce(async () => { controller.abort(); throw new DOMException('aborted', 'AbortError') })
    vi.stubGlobal('fetch', fetchMock)
    const api = createMixtapeApi(BASE)

    await api.sendMessage('session-9', 'Slower', undefined, { onProgress: () => {} })
    await expect(api.sendMessage('session-9', 'Faster', undefined, { onProgress: () => {}, signal: controller.signal })).rejects.toMatchObject({ name: 'AbortError' })
    expect(fetchMock).toHaveBeenCalledTimes(2)
  })

  it('answers a retry whose turn has no answer left (204) as a TurnAnswerGoneError', async () => {
    fetchMock
      .mockResolvedValueOnce(stream([turnFrame, frame('result', reply)]))
      .mockRejectedValueOnce(new TypeError('Failed to fetch'))
      .mockResolvedValueOnce(new Response(null, { status: 204 }))
    vi.stubGlobal('fetch', fetchMock)
    const api = createMixtapeApi(BASE)

    await api.sendMessage('session-9', 'Slower', undefined, { onProgress: () => {} })
    const gone = await api.sendMessage('session-9', 'Faster', undefined, { onProgress: () => {} }).catch((e: unknown) => e)

    expect(gone).toBeInstanceOf(TurnAnswerGoneError)
    expect(gone).toBeInstanceOf(TypeError)
  })

  it('attaches when a message stream drops after its turn event, resuming the step, and answers with the turn’s result', async () => {
    fetchMock
      .mockResolvedValueOnce(stream([turnFrame, frame('step', { step: 'digging', scope: 'library' })]))
      .mockResolvedValueOnce(stream([turnFrame, frame('step', { step: 'picking' }), frame('result', reply)]))
    vi.stubGlobal('fetch', fetchMock)
    const seen: TurnProgress[] = []

    const answer = await createMixtapeApi(BASE, () => 'token').sendMessage('session 9', 'Slower', undefined, { onProgress: (progress) => seen.push(progress) })

    expect(answer).toEqual(reply)
    expect(url(1)).toBe(`${BASE}/sessions/session%209/turn/stream`)
    expect(method(1)).toBe('GET')
    expect(accept(1)).toBe('text/event-stream')
    expect(new Headers(fetchMock.mock.calls[1][1]?.headers).get('authorization')).toBe('Bearer token')
    expect(seen).toEqual([
      { type: 'opened' },
      { type: 'turn', turnId: TURN, push: true },
      { type: 'step', step: 'digging', scope: 'library' },
      { type: 'opened' },
      { type: 'turn', turnId: TURN, push: true },
      { type: 'step', step: 'picking' },
    ])
  })

  it('attaches a dropped create through the session its stream named, and throws an error event as the JSON path would', async () => {
    const body = { error: 'curation_failed', message: 'The DJ lost the thread. Try again.' }
    fetchMock
      .mockResolvedValueOnce(stream([frame('session', { session: { id: 'session-9' } }), turnFrame]))
      .mockResolvedValueOnce(stream([frame('error', { status: 502, body })]))
    vi.stubGlobal('fetch', fetchMock)

    const error = await createMixtapeApi(BASE).createSession('Rainy commute', undefined, undefined, undefined, { onProgress: () => {} }).catch((e: unknown) => e)

    expect(url(1)).toBe(`${BASE}/sessions/session-9/turn/stream`)
    expect(error).toBeInstanceOf(ApiError)
    expect(error).toMatchObject({ status: 502, code: 'curation_failed' })
  })

  it('keeps the drop when the attach finds nothing running or fails, and never attaches without a turn event', async () => {
    fetchMock
      .mockResolvedValueOnce(stream([turnFrame, frame('step', { step: 'picking' })]))
      .mockResolvedValueOnce(new Response(null, { status: 204 }))
      .mockResolvedValueOnce(stream([turnFrame]))
      .mockRejectedValueOnce(new TypeError('Failed to fetch'))
      .mockResolvedValueOnce(stream([frame('step', { step: 'picking' })]))
    vi.stubGlobal('fetch', fetchMock)
    const api = createMixtapeApi(BASE)

    const finished = await api.sendMessage('session-9', 'Slower', undefined, { onProgress: () => {} }).catch((e: unknown) => e)
    const failed = await api.sendMessage('session-9', 'Slower', undefined, { onProgress: () => {} }).catch((e: unknown) => e)
    const old = await createMixtapeApi(BASE).sendMessage('session-9', 'Slower', undefined, { onProgress: () => {} }).catch((e: unknown) => e)

    for (const error of [finished, failed, old]) {
      expect(error).toBeInstanceOf(TypeError)
      expect(error).not.toBeInstanceOf(ApiError)
      expect(error).toMatchObject({ message: 'The turn stream ended before its result.' })
    }
    expect(fetchMock).toHaveBeenCalledTimes(5)
    expect(url(4)).toBe(`${BASE}/sessions/session-9/messages`)
  })

  it('never attaches a stream it abandoned itself', async () => {
    const controller = new AbortController()
    fetchMock.mockImplementation(async (_url, init) => {
      const signal = init?.signal
      const body = new ReadableStream<Uint8Array>({
        start(stream) {
          stream.enqueue(new TextEncoder().encode(turnFrame))
          signal?.addEventListener('abort', () => stream.error(new DOMException('aborted', 'AbortError')))
        },
      })
      return new Response(body, { status: 200, headers: { 'content-type': 'text/event-stream' } })
    })
    vi.stubGlobal('fetch', fetchMock)

    const turn = createMixtapeApi(BASE).sendMessage('session-9', 'Slower', undefined, { onProgress: (progress) => { if (progress.type === 'turn') controller.abort() }, signal: controller.signal })

    await expect(turn).rejects.toBeInstanceOf(Error)
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })

  it('attachTurn: nothing running is a 204; a stream reports its steps and ends with the result or error', async () => {
    const body = { error: 'curation_failed', message: 'The DJ lost the thread.' }
    fetchMock
      .mockResolvedValueOnce(new Response(null, { status: 204 }))
      .mockResolvedValueOnce(stream([turnFrame, frame('step', { step: 'pressing', count: 12 }), frame('result', { ...reply, addMusic: 'apple_export' })]))
      .mockResolvedValueOnce(stream([frame('error', { status: 502, body })]))
      .mockResolvedValueOnce(json({ error: 'not_found' }, 404))
    vi.stubGlobal('fetch', fetchMock)
    const api = createMixtapeApi(BASE)
    const seen: TurnProgress[] = []

    expect(await api.attachTurn('session-9')).toEqual({ kind: 'not_running' })
    expect(await api.attachTurn('session-9', (progress) => seen.push(progress))).toEqual({ kind: 'result', body: reply })
    expect(await api.attachTurn('session-9')).toEqual({ kind: 'error', status: 502, body })
    await expect(api.attachTurn('session-9')).rejects.toMatchObject({ status: 404 })
    expect(url(0)).toBe(`${BASE}/sessions/session-9/turn/stream`)
    expect(fetchMock.mock.calls[0][1]?.body).toBeUndefined()
    expect(seen).toEqual([{ type: 'opened' }, { type: 'turn', turnId: TURN, push: true }, { type: 'step', step: 'pressing', count: 12 }])
  })

  it('markTurnSeen posts the acknowledgement for the turn', async () => {
    fetchMock.mockResolvedValueOnce(new Response(null, { status: 204 }))
    vi.stubGlobal('fetch', fetchMock)

    await createMixtapeApi(BASE, () => 'token').markTurnSeen('session-9', TURN)

    expect(url(0)).toBe(`${BASE}/sessions/session-9/turn/${TURN}/seen`)
    expect(method(0)).toBe('POST')
  })
})
