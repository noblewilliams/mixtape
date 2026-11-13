import { afterEach, describe, expect, it, vi } from 'vitest'
import { createSseDecoder, readTurnStream, type SseEvent, type TurnProgress } from './sse'

const encoder = new TextEncoder()

/** Decodes `chunks` in order and returns every event, the end flush included. */
function decode(chunks: Uint8Array[]): SseEvent[] {
  const decoder = createSseDecoder()
  const events = chunks.flatMap((chunk) => decoder.push(chunk))
  return [...events, ...decoder.end()]
}

const bytes = (text: string) => encoder.encode(text)

function streamOf(chunks: Array<string | Uint8Array>, { error, onCancel }: { error?: unknown; onCancel?: () => void } = {}) {
  let index = 0
  return new ReadableStream<Uint8Array>({
    pull(controller) {
      if (index < chunks.length) {
        const chunk = chunks[index++]
        controller.enqueue(typeof chunk === 'string' ? bytes(chunk) : chunk)
      } else if (error !== undefined) controller.error(error)
      else controller.close()
    },
    cancel() {
      onCancel?.()
    },
  })
}

describe('SSE decoder', () => {
  it('dispatches an event on its blank line, named by its event field', () => {
    expect(decode([bytes('event: step\ndata: {"step":"digging"}\n\n')])).toEqual([
      { event: 'step', data: '{"step":"digging"}' },
    ])
  })

  it('names an event with no event field "message"', () => {
    expect(decode([bytes('data: hi\n\n')])).toEqual([{ event: 'message', data: 'hi' }])
  })

  it('joins several data lines with a newline', () => {
    expect(decode([bytes('event: result\ndata: {"a":\ndata: 1}\n\n')])).toEqual([
      { event: 'result', data: '{"a":\n1}' },
    ])
  })

  it('skips comment lines, keepalives among them', () => {
    expect(decode([bytes(': keepalive\n\n:\nevent: step\n: in the middle\ndata: x\n\n: keepalive\n\n')])).toEqual([
      { event: 'step', data: 'x' },
    ])
  })

  it('strips one leading space from a value, and reads a field with no colon as empty', () => {
    expect(decode([bytes('data:  two spaces\n\ndata\n\nevent:tight\ndata:tight\n\n')])).toEqual([
      { event: 'message', data: ' two spaces' },
      { event: 'message', data: '' },
      { event: 'tight', data: 'tight' },
    ])
  })

  it('ignores id, retry and unknown fields', () => {
    expect(decode([bytes('id: 7\nretry: 1000\nwho: me\nevent: step\ndata: y\n\n')])).toEqual([{ event: 'step', data: 'y' }])
  })

  it('does not dispatch an event with no data lines, and forgets its name at the blank line', () => {
    expect(decode([bytes('event: lonely\n\ndata: z\n\n')])).toEqual([{ event: 'message', data: 'z' }])
  })

  it('never dispatches an event cut off by the end of the stream', () => {
    expect(decode([bytes('event: step\ndata: a\n\nevent: result\ndata: {"b":1}\n')])).toEqual([{ event: 'step', data: 'a' }])
    expect(decode([bytes('event: result\ndata: {"b":1}')])).toEqual([])
  })

  it.each([
    ['LF', '\n'],
    ['CRLF', '\r\n'],
    ['CR', '\r'],
  ])('reads %s line endings', (_name, eol) => {
    const text = ['event: step', 'data: one', 'data: two', '', ': keepalive', '', 'event: result', 'data: {}', '', ''].join(eol)
    expect(decode([bytes(text)])).toEqual([
      { event: 'step', data: 'one\ntwo' },
      { event: 'result', data: '{}' },
    ])
  })

  it('reads a CRLF split across chunks as one line end', () => {
    // Read as two line ends, the LF would be a blank line and dispatch "one" alone.
    expect(decode([bytes('event: step\r\ndata: one\r'), bytes('\ndata: two\r\n\r\n')])).toEqual([
      { event: 'step', data: 'one\ntwo' },
    ])
  })

  it('reads a lone CR at the end of a chunk as a line end', () => {
    expect(decode([bytes('data: one\r'), bytes('data: two\r'), bytes('\r')])).toEqual([{ event: 'message', data: 'one\ntwo' }])
  })

  it('keeps a pending CR across a chunk that decodes to nothing', () => {
    // Dropped at the empty chunk, the CR would make the LF a blank line and dispatch "a" alone.
    expect(decode([bytes('data: a\r'), new Uint8Array(0), bytes('\ndata: b\n\n')])).toEqual([{ event: 'message', data: 'a\nb' }])
    const tape = bytes('🎧')
    expect(decode([bytes('data: a\r'), tape.slice(0, 1), tape.slice(1), bytes('\r\n')])).toEqual([])
  })

  describe('chunk boundaries', () => {
    const text = [
      ': keepalive\r\n\r\n',
      'event: session\ndata: {"session":{"id":"s-1"}}\n\n',
      'event: step\r\ndata: {"step":"digging","artists":["Tems","Asake"]}\r\n\r\n',
      'event: step\rdata: {"step":"labelling","title":"Café 🎧 “late”"}\r\r',
      'event: result\ndata: {"djMessage":\ndata: {"content":"Señor — ✓"}}\n\n',
    ].join('')
    const all = bytes(text)
    const expected: SseEvent[] = [
      { event: 'session', data: '{"session":{"id":"s-1"}}' },
      { event: 'step', data: '{"step":"digging","artists":["Tems","Asake"]}' },
      { event: 'step', data: '{"step":"labelling","title":"Café 🎧 “late”"}' },
      { event: 'result', data: '{"djMessage":\n{"content":"Señor — ✓"}}' },
    ]

    it('reads the same events whole', () => {
      expect(decode([all])).toEqual(expected)
    })

    it('reads the same events split at every byte, inside multi-byte characters too', () => {
      for (let at = 0; at <= all.length; at += 1) {
        expect(decode([all.slice(0, at), all.slice(at)]), `split at byte ${at}`).toEqual(expected)
      }
    })

    it('reads the same events one byte at a time', () => {
      expect(decode(Array.from(all, (byte) => Uint8Array.of(byte)))).toEqual(expected)
    })

    it('reads the same events split at every pair of bytes', () => {
      for (let first = 0; first < all.length; first += 7) {
        for (let second = first; second <= all.length; second += 5) {
          expect(decode([all.slice(0, first), all.slice(first, second), all.slice(second)])).toEqual(expected)
        }
      }
    })
  })
})

describe('reading a turn stream', () => {
  const stepFrame = (data: unknown) => `event: step\ndata: ${JSON.stringify(data)}\n\n`

  it('hands on each step and the create session, then answers with the result body', async () => {
    const seen: TurnProgress[] = []
    const result = { djMessage: { id: 'm', content: 'Here it is' }, queue: [] }
    const end = await readTurnStream(
      streamOf([
        `event: session\ndata: ${JSON.stringify({ session: { id: 'session-9', title: 'x' } })}\n\n`,
        ': keepalive\n\n',
        stepFrame({ step: 'digging', scope: 'catalogue', artists: ['Tems', 'Asake'] }),
        stepFrame({ step: 'pressing', count: 15 }),
        `event: result\ndata: ${JSON.stringify(result)}\n\n`,
      ]),
      (progress) => seen.push(progress),
    )
    expect(seen).toEqual([
      { type: 'session', sessionId: 'session-9' },
      { type: 'step', step: 'digging', scope: 'catalogue', artists: ['Tems', 'Asake'] },
      { type: 'step', step: 'pressing', count: 15 },
    ])
    expect(end).toEqual({ kind: 'result', body: result })
  })

  it('answers an error event with its status and body', async () => {
    const body = { error: 'curation_failed', message: 'The DJ lost the thread. Try again.' }
    const end = await readTurnStream(streamOf([stepFrame({ step: 'picking' }), `event: error\ndata: ${JSON.stringify({ status: 502, body })}\n\n`]), () => {})
    expect(end).toEqual({ kind: 'error', status: 502, body })
  })

  it('answers an error event with no integer status as malformed', async () => {
    expect(await readTurnStream(streamOf(['event: error\ndata: {"body":{}}\n\n']), () => {})).toEqual({ kind: 'malformed' })
    expect(await readTurnStream(streamOf(['event: error\ndata: not json\n\n']), () => {})).toEqual({ kind: 'malformed' })
  })

  it('passes unknown steps on as raw strings, drops mistyped name fields, and skips steps that do not parse', async () => {
    const seen: TurnProgress[] = []
    await readTurnStream(
      streamOf([
        stepFrame({ step: 'tuning', scope: 'moon' }),
        stepFrame({ step: 'digging', scope: 7, artists: ['', '  ', 'Tems', 3], genres: 'jazz', playlist: '', title: 4, count: 2.5 }),
        stepFrame({ step: 'picking', artists: [] }),
        stepFrame({ step: '' }),
        stepFrame({ count: 3 }),
        'event: step\ndata: {not json\n\n',
        'event: session\ndata: {"session":{}}\n\n',
        'event: result\ndata: {}\n\n',
      ]),
      (progress) => seen.push(progress),
    )
    expect(seen).toEqual([
      { type: 'step', step: 'tuning', scope: 'moon' },
      { type: 'step', step: 'digging', artists: ['Tems'] },
      { type: 'step', step: 'picking' },
    ])
  })

  it('ignores unknown events', async () => {
    const seen: TurnProgress[] = []
    const end = await readTurnStream(streamOf(['event: weather\ndata: {"rain":true}\n\n', 'data: {"plain":1}\n\n', 'event: result\ndata: {"ok":1}\n\n']), (progress) => seen.push(progress))
    expect(seen).toEqual([])
    expect(end).toEqual({ kind: 'result', body: { ok: 1 } })
  })

  it('keeps reading when a progress listener throws', async () => {
    const listener = vi.fn(() => {
      throw new Error('caption broke')
    })
    const end = await readTurnStream(streamOf([stepFrame({ step: 'picking' }), stepFrame({ step: 'pressing' }), 'event: result\ndata: {"ok":1}\n\n']), listener)
    expect(listener).toHaveBeenCalledTimes(2)
    expect(end).toEqual({ kind: 'result', body: { ok: 1 } })
  })

  it('throws a network failure (TypeError) when the stream ends before its result or error', async () => {
    await expect(readTurnStream(streamOf([stepFrame({ step: 'picking' })]), () => {})).rejects.toBeInstanceOf(TypeError)
    // An unterminated result is not a result.
    await expect(readTurnStream(streamOf(['event: result\ndata: {"ok":1}\n']), () => {})).rejects.toBeInstanceOf(TypeError)
  })

  it('throws a network failure (TypeError) when reading fails', async () => {
    const failure = await readTurnStream(streamOf([stepFrame({ step: 'picking' })], { error: new DOMException('reset', 'NetworkError') }), () => {}).catch((e: unknown) => e)
    expect(failure).toBeInstanceOf(TypeError)
  })

  it('stops reading and releases the stream after the last event', async () => {
    const onCancel = vi.fn()
    const body = streamOf(['event: result\ndata: {"ok":1}\n\n', stepFrame({ step: 'late' })], { onCancel })
    const seen: TurnProgress[] = []
    await readTurnStream(body, (progress) => seen.push(progress))
    expect(seen).toEqual([])
    expect(onCancel).toHaveBeenCalledOnce()
    expect(body.locked).toBe(false)
  })

  it('throws the JSON parse error of a result that is not JSON, as the JSON path would, and releases the stream', async () => {
    const onCancel = vi.fn()
    const body = streamOf(['event: result\ndata: {oops\n\n', stepFrame({ step: 'late' })], { onCancel })
    await expect(readTurnStream(body, () => {})).rejects.toBeInstanceOf(SyntaxError)
    expect(onCancel).toHaveBeenCalledOnce()
    expect(body.locked).toBe(false)
  })

  it('stops reading and releases the stream after an error event', async () => {
    const onCancel = vi.fn()
    const body = streamOf([`event: error\ndata: ${JSON.stringify({ status: 409, body: { error: 'conflict' } })}\n\n`, stepFrame({ step: 'late' })], { onCancel })
    expect(await readTurnStream(body, () => {})).toEqual({ kind: 'error', status: 409, body: { error: 'conflict' } })
    expect(onCancel).toHaveBeenCalledOnce()
    expect(body.locked).toBe(false)
  })

  describe('the idle timeout', () => {
    afterEach(() => {
      vi.useRealTimers()
    })

    /** A stream the test feeds by hand. */
    function fed() {
      let controller!: ReadableStreamDefaultController<Uint8Array>
      const onCancel = vi.fn()
      const body = new ReadableStream<Uint8Array>({ start: (c) => { controller = c }, cancel: onCancel })
      return { body, onCancel, send: (text: string) => controller.enqueue(bytes(text)) }
    }

    it('is 45 s by default, and a stream that goes quiet that long is a network failure (TypeError)', async () => {
      vi.useFakeTimers()
      const { body, onCancel } = fed()
      let failure: unknown
      const reading = readTurnStream(body, () => {}).catch((e: unknown) => { failure = e })
      await vi.advanceTimersByTimeAsync(44_999)
      expect(failure).toBeUndefined()
      await vi.advanceTimersByTimeAsync(1)
      await reading
      expect(failure).toBeInstanceOf(TypeError)
      expect(onCancel).toHaveBeenCalledOnce()
      expect(body.locked).toBe(false)
    })

    it('restarts on any bytes, keepalives and half events included', async () => {
      vi.useFakeTimers()
      const { body, send } = fed()
      const seen: TurnProgress[] = []
      let end: unknown
      const reading = readTurnStream(body, (progress) => seen.push(progress), { idleTimeoutMs: 1_000 }).then((value) => { end = value }, (e: unknown) => { end = e })
      await vi.advanceTimersByTimeAsync(900)
      send(': keepalive\n\n')
      await vi.advanceTimersByTimeAsync(900)
      send('event: step\ndata: {"step":')
      await vi.advanceTimersByTimeAsync(900)
      send('"picking"}\n\n')
      await vi.advanceTimersByTimeAsync(900)
      send('event: result\ndata: {"ok":1}\n\n')
      await reading
      expect(seen).toEqual([{ type: 'step', step: 'picking' }])
      expect(end).toEqual({ kind: 'result', body: { ok: 1 } })
    })

    it('ends a stream that stops between events', async () => {
      vi.useFakeTimers()
      const { body, send } = fed()
      let failure: unknown
      const reading = readTurnStream(body, () => {}, { idleTimeoutMs: 1_000 }).catch((e: unknown) => { failure = e })
      send(stepFrame({ step: 'picking' }))
      await vi.advanceTimersByTimeAsync(999)
      expect(failure).toBeUndefined()
      await vi.advanceTimersByTimeAsync(1)
      await reading
      expect(failure).toBeInstanceOf(TypeError)
    })
  })
})
