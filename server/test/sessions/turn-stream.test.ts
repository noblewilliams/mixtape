import { afterEach, describe, expect, it, vi } from 'vitest'
import { Hono } from 'hono'
import { streamTurn, wantsTurnStream, TURN_STREAM_KEEPALIVE_MS, type TurnReply } from '../../src/routes/turn-stream'
import type { TurnStepEvent } from '../../src/dj/turn-steps'
import { eventsOnly, parseSse, readEvents, readSse } from '../helpers/sse'

// Spec 2026-11-13 dj-turn-steps, "Wire contract" and "Server plumbing": the
// stream itself, apart from any route.

type Run = (onStep: (event: TurnStepEvent) => void) => Promise<TurnReply>

function streamApp(run: Run, options?: Parameters<typeof streamTurn>[2]) {
  const app = new Hono()
  app.post('/turn', (c) => streamTurn(c, run, options))
  return app
}

function fakeCtx() {
  const waited: Promise<unknown>[] = []
  return { waited, ctx: { waitUntil: (p: Promise<unknown>) => void waited.push(p), passThroughOnException: () => {}, props: {} } }
}

function deferred<T = void>() {
  let resolve!: (value: T) => void
  const promise = new Promise<T>((r) => (resolve = r))
  return { promise, resolve }
}

afterEach(() => {
  vi.useRealTimers()
  vi.restoreAllMocks()
})

describe('wantsTurnStream', () => {
  it('is true only when the Accept header names text/event-stream', async () => {
    const app = new Hono()
    app.get('/', (c) => c.json({ stream: wantsTurnStream(c) }))
    const ask = async (accept?: string) =>
      ((await (await app.request('http://x/', accept === undefined ? {} : { headers: { accept } })).json()) as { stream: boolean }).stream
    expect(await ask()).toBe(false)
    expect(await ask('application/json')).toBe(false)
    expect(await ask('*/*')).toBe(false)
    expect(await ask('text/event-stream')).toBe(true)
    expect(await ask('Text/Event-Stream')).toBe(true)
    expect(await ask('text/event-stream, application/json;q=0.5')).toBe(true)
    expect(await ask('text/event-stream ; charset=utf-8')).toBe(true)
    expect(await ask('text/event-stream;q=0.5')).toBe(true)
  })

  it('reads the media ranges: q=0 refuses the stream, and a longer type is not it', async () => {
    const app = new Hono()
    app.get('/', (c) => c.json({ stream: wantsTurnStream(c) }))
    const ask = async (accept: string) =>
      ((await (await app.request('http://x/', { headers: { accept } })).json()) as { stream: boolean }).stream
    expect(await ask('text/event-stream;q=0')).toBe(false)
    expect(await ask('text/event-stream; Q=0.000')).toBe(false)
    expect(await ask('application/json, text/event-stream;q=0')).toBe(false)
    expect(await ask('text/event-streams')).toBe(false)
    expect(await ask('application/json; note="text/event-stream"')).toBe(false)
  })
})

describe('streamTurn', () => {
  it('answers 200 with the stream headers before the turn ends', async () => {
    const gate = deferred()
    const app = streamApp(async () => {
      await gate.promise
      return { status: 200, body: { ok: true } }
    })

    const res = await app.request('http://x/turn', { method: 'POST' })

    expect(res.status).toBe(200)
    expect(res.headers.get('content-type')).toBe('text/event-stream; charset=utf-8')
    expect(res.headers.get('cache-control')).toBe('no-cache, no-transform')
    gate.resolve()
    expect(eventsOnly(await readSse(res)).map((e) => e.event)).toEqual(['result'])
  })

  it('sends session first, each step as it comes, then result, every event ending in a blank line', async () => {
    const app = streamApp(
      async (onStep) => {
        onStep({ step: 'digging', scope: 'library', artists: ['Tems'] })
        await Promise.resolve()
        onStep({ step: 'pressing', count: 3 })
        return { status: 200, body: { djMessage: { content: 'here.' }, queue: [] } }
      },
      { session: { id: 's1', title: 'a tape' } },
    )

    const res = await app.request('http://x/turn', { method: 'POST' })
    const text = await res.text()

    // parseSse throws unless every block, the last included, ends in \n\n.
    const events = eventsOnly(parseSse(text))
    expect(events.map((e) => [e.event, e.data])).toEqual([
      ['session', { session: { id: 's1', title: 'a tape' } }],
      ['step', { step: 'digging', scope: 'library', artists: ['Tems'] }],
      ['step', { step: 'pressing', count: 3 }],
      ['result', { djMessage: { content: 'here.' }, queue: [] }],
    ])
    expect(text.endsWith('\n\n')).toBe(true)
    expect(events[3].raw).toBe(JSON.stringify({ djMessage: { content: 'here.' }, queue: [] }))
  })

  it('sends a refused turn as error with its status and body', async () => {
    const app = streamApp(async () => ({ status: 409, body: { error: 'conflict', message: 'try again?' } }))

    const events = eventsOnly(await readSse(await app.request('http://x/turn', { method: 'POST' })))

    expect(events.map((e) => [e.event, e.data])).toEqual([
      ['error', { status: 409, body: { error: 'conflict', message: 'try again?' } }],
    ])
  })

  it('sends an unforeseen throw as error 500 internal and logs a fixed line, never the error', async () => {
    const logged = vi.spyOn(console, 'error').mockImplementation(() => {})
    const app = streamApp(async (onStep) => {
      onStep({ step: 'picking' })
      throw new Error('listener words: rainy lagos night')
    })

    const events = eventsOnly(await readSse(await app.request('http://x/turn', { method: 'POST' })))

    expect(events.map((e) => [e.event, e.data])).toEqual([
      ['step', { step: 'picking' }],
      ['error', { status: 500, body: { error: 'internal' } }],
    ])
    expect(logged).toHaveBeenCalledTimes(1)
    expect(logged.mock.calls[0]).toEqual(['turn stream failed'])
  })

  it('hands the turn to waitUntil, which settles once the turn and its last event are done', async () => {
    const gate = deferred()
    let finished = false
    const app = streamApp(async () => {
      await gate.promise
      finished = true
      return { status: 200, body: {} }
    })
    const { ctx, waited } = fakeCtx()

    const res = await app.request('http://x/turn', { method: 'POST' }, undefined, ctx)

    expect(waited).toHaveLength(1)
    expect(finished).toBe(false)
    gate.resolve()
    await waited[0]
    expect(finished).toBe(true)
    expect(eventsOnly(await readSse(res)).map((e) => e.event)).toEqual(['result'])
  })

  it('writes a keepalive comment after each quiet interval, and none once the turn is over', async () => {
    const gate = deferred()
    const app = streamApp(
      async (onStep) => {
        await gate.promise
        onStep({ step: 'writing' })
        return { status: 200, body: {} }
      },
      { keepaliveMs: 15 },
    )

    const res = await app.request('http://x/turn', { method: 'POST' })
    const reader = res.body!.getReader()
    const first = await readEvents(reader, 2)
    expect(first).toEqual([{ comment: 'keepalive' }, { comment: 'keepalive' }])
    gate.resolve()
    const decoder = new TextDecoder()
    let rest = ''
    for (;;) {
      const { value, done } = await reader.read()
      if (done) break
      rest += decoder.decode(value, { stream: true })
    }
    const tail = parseSse(rest)
    // Possibly a keepalive or two more before the gate opened, then the
    // step and the result: nothing after the result.
    const named = eventsOnly(tail).map((e) => e.event)
    expect(named).toEqual(['step', 'result'])
    expect('event' in tail[tail.length - 1] && tail[tail.length - 1]).toMatchObject({ event: 'result' })
  })

  it('keeps alive every 15 s by default on a fake clock, and clears its timer when done', async () => {
    vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout', 'setInterval', 'clearInterval'] })
    expect(TURN_STREAM_KEEPALIVE_MS).toBe(15_000)
    const gate = deferred()
    const { ctx, waited } = fakeCtx()
    const app = streamApp(async () => {
      await gate.promise
      return { status: 200, body: { ok: true } }
    })

    const res = await app.request('http://x/turn', { method: 'POST' }, undefined, ctx)
    const reader = res.body!.getReader()
    await vi.advanceTimersByTimeAsync(14_999)
    await vi.advanceTimersByTimeAsync(1)
    expect(await readEvents(reader, 1)).toEqual([{ comment: 'keepalive' }])
    gate.resolve()
    await waited[0]
    expect(vi.getTimerCount()).toBe(0)
    const tail = await readEvents(reader, 1)
    expect(eventsOnly(tail).map((e) => e.event)).toEqual(['result'])
    expect((await reader.read()).done).toBe(true)
  })

  it('clears its keepalive on a fake clock after an error reply and after an unforeseen throw', async () => {
    vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout', 'setInterval', 'clearInterval'] })
    vi.spyOn(console, 'error').mockImplementation(() => {})
    const replies: Array<() => Promise<TurnReply>> = [
      async () => ({ status: 502, body: { error: 'llm' } }),
      async () => {
        throw new Error('db down')
      },
    ]
    for (const reply of replies) {
      const gate = deferred()
      const { ctx, waited } = fakeCtx()
      const app = streamApp(async () => {
        await gate.promise
        return reply()
      })

      const res = await app.request('http://x/turn', { method: 'POST' }, undefined, ctx)
      const reader = res.body!.getReader()
      await vi.advanceTimersByTimeAsync(TURN_STREAM_KEEPALIVE_MS)
      expect(await readEvents(reader, 1)).toEqual([{ comment: 'keepalive' }])
      gate.resolve()
      await waited[0]

      expect(vi.getTimerCount()).toBe(0)
      expect(eventsOnly(await readEvents(reader, 1)).map((e) => e.event)).toEqual(['error'])
      expect((await reader.read()).done).toBe(true)
    }
  })

  it('stops its keepalive on a fake clock once a write fails after the client left, while the turn runs on', async () => {
    vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout', 'setInterval', 'clearInterval'] })
    const gate = deferred()
    let finished = false
    const { ctx, waited } = fakeCtx()
    const app = streamApp(
      async () => {
        await gate.promise
        finished = true
        return { status: 200, body: {} }
      },
      { session: { id: 's1' } },
    )

    const res = await app.request('http://x/turn', { method: 'POST' }, undefined, ctx)
    const reader = res.body!.getReader()
    expect(eventsOnly(await readEvents(reader, 1)).map((e) => e.event)).toEqual(['session'])
    await reader.cancel()
    // The next keepalive is the write that finds the client gone.
    await vi.advanceTimersByTimeAsync(TURN_STREAM_KEEPALIVE_MS)
    expect(vi.getTimerCount()).toBe(0)
    await vi.advanceTimersByTimeAsync(TURN_STREAM_KEEPALIVE_MS * 4)
    expect(vi.getTimerCount()).toBe(0)

    gate.resolve()
    await waited[0]
    expect(finished).toBe(true)
    expect(vi.getTimerCount()).toBe(0)
  })

  it('a step reported after the turn resolved is dropped: result stays the last frame', async () => {
    let kept: ((event: TurnStepEvent) => void) | undefined
    const { ctx, waited } = fakeCtx()
    const app = streamApp(async (onStep) => {
      kept = onStep
      onStep({ step: 'writing' })
      return { status: 200, body: { ok: true } }
    })

    const res = await app.request('http://x/turn', { method: 'POST' }, undefined, ctx)
    await waited[0]
    kept!({ step: 'pressing', count: 9 })
    await new Promise((r) => setTimeout(r, 10))
    kept!({ step: 'noting' })

    const text = await res.text()
    const events = parseSse(text)
    expect(events.map((e) => ('event' in e ? e.event : 'comment'))).toEqual(['step', 'result'])
    expect(text.endsWith(`event: result\ndata: ${JSON.stringify({ ok: true })}\n\n`)).toBe(true)
  })

  it('a client that stops reading never stops the turn: later steps and the result are dropped quietly', async () => {
    const unhandled: unknown[] = []
    const onUnhandled = (reason: unknown) => unhandled.push(reason)
    process.on('unhandledRejection', onUnhandled)
    try {
      const gate = deferred()
      let finished = false
      const app = streamApp(
        async (onStep) => {
          onStep({ step: 'digging', scope: 'catalogue' })
          await gate.promise
          onStep({ step: 'pressing', count: 5 })
          onStep({ step: 'writing' })
          finished = true
          return { status: 200, body: { done: true } }
        },
        { session: { id: 's1' } },
      )
      const { ctx, waited } = fakeCtx()

      const res = await app.request('http://x/turn', { method: 'POST' }, undefined, ctx)
      const reader = res.body!.getReader()
      const first = eventsOnly(await readEvents(reader, 1))
      expect(first.map((e) => e.event)).toEqual(['session'])
      await reader.cancel()
      gate.resolve()

      await expect(waited[0]).resolves.toBeUndefined()
      expect(finished).toBe(true)
      // Let any stray rejection surface before checking.
      await new Promise((r) => setTimeout(r, 20))
      expect(unhandled).toEqual([])
    } finally {
      process.off('unhandledRejection', onUnhandled)
    }
  })

  it('runs the turn without an execution context (no waitUntil to hand it to)', async () => {
    const app = streamApp(async () => ({ status: 200, body: { ok: 1 } }))
    const events = eventsOnly(await readSse(await app.request('http://x/turn', { method: 'POST' })))
    expect(events.map((e) => e.data)).toEqual([{ ok: 1 }])
  })
})
