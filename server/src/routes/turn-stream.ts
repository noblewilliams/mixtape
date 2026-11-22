import type { Context, ExecutionContext } from 'hono'
import type { ContentfulStatusCode } from 'hono/utils/http-status'
import type { TurnStepEvent } from '../dj/turn-steps'

// The streamed turn (spec 2026-11-13 dj-turn-steps, "Wire contract"). A
// client that sends Accept: text/event-stream on a mix turn gets the turn's
// steps down the request it already holds open, then the same body the JSON
// path sends, as SSE events:
//
//   event: session  { session }            create only, first
//   event: turn     { turnId, push }       durable turns only, after session
//   event: step     TurnStepEvent          as each kind of work starts
//   event: result   today's success body   last, on success
//   event: error    { status, body }       last, on failure
//   : keepalive                            after each quiet interval
//
// Every event, the last included, ends with a blank line: the clients count
// an event only once its blank line arrives.

// What a turn answers, whichever way it is sent: the JSON path hands it to
// c.json, the stream to a result (200) or error (anything else) event.
export type TurnReply = { status: ContentfulStatusCode; body: unknown }

export const TURN_STREAM_KEEPALIVE_MS = 15_000

// An unforeseen failure, on either path: the stream's error event and the
// durable job's (dj/turn-job.ts) both send this.
export const INTERNAL_TURN_REPLY: TurnReply = { status: 500, body: { error: 'internal' } }

// True when one of the Accept header's media ranges is text/event-stream
// with a q above 0. Wildcards do not count: only a client that names the
// stream can read it.
export function wantsTurnStream(c: Context): boolean {
  return (c.req.header('accept') ?? '').split(',').some((range) => {
    const [type, ...params] = range.split(';').map((part) => part.trim().toLowerCase())
    if (type !== 'text/event-stream') return false
    const q = params.find((param) => param.startsWith('q='))
    return q === undefined || Number(q.slice(2)) > 0
  })
}

// The durable turn's event (spec 2026-11-21 durable-mix-turns, "The new
// `turn` event"): which turn the stream follows, and whether the server will
// push its end (so the app posts no local notification of its own).
export type TurnStreamTurn = { turnId: string; push: boolean }

const frame = (name: string, data: unknown) => `event: ${name}\ndata: ${JSON.stringify(data)}\n\n`

// The headers every turn stream answers with.
export function turnStreamResponse(readable: ReadableStream<Uint8Array>): Response {
  return new Response(readable, {
    status: 200,
    headers: {
      'content-type': 'text/event-stream; charset=utf-8',
      'cache-control': 'no-cache, no-transform',
    },
  })
}

// `keepaliveMs` exists for tests. `onGone` is called once, when a write
// fails (the client left): the durable turn drops the watcher then.
export type TurnStreamWriterOptions = { keepaliveMs?: number; onGone?: () => void }

/**
 * One turn stream's framing and keepalive, apart from what runs the turn:
 * the in-request stream (streamTurn below) and the durable turn's watchers
 * (dj/turn-runner.ts) write through this, so both send the same bytes.
 *
 * A client that leaves only makes the next write fail; after the first
 * failed write nothing more is written. Every write re-arms the keepalive,
 * so one goes out only after a quiet interval. After `end`, a step that
 * still arrives is dropped. Hand-rolled over a TransformStream rather than
 * Hono's streamSSE, so this abort behaviour is ours.
 */
export class TurnStreamWriter {
  readonly readable: ReadableStream<Uint8Array>
  private readonly writer: WritableStreamDefaultWriter<Uint8Array>
  private readonly encoder = new TextEncoder()
  private readonly keepaliveMs: number
  private readonly onGone?: () => void
  // open: false once a write failed (the client left). done: the last event
  // is written, so a step that still arrives is dropped.
  private isOpen = true
  private done = false
  private keepalive: ReturnType<typeof setTimeout> | undefined

  constructor(options: TurnStreamWriterOptions = {}) {
    const { readable, writable } = new TransformStream<Uint8Array, Uint8Array>()
    this.readable = readable
    this.writer = writable.getWriter()
    this.keepaliveMs = options.keepaliveMs ?? TURN_STREAM_KEEPALIVE_MS
    this.onGone = options.onGone
    this.arm()
  }

  get open(): boolean {
    return this.isOpen
  }

  private readonly stop = () => {
    const wasOpen = this.isOpen
    this.isOpen = false
    clearTimeout(this.keepalive)
    if (wasOpen) this.onGone?.()
  }

  private arm() {
    clearTimeout(this.keepalive)
    if (this.isOpen && !this.done) this.keepalive = setTimeout(() => void this.send(': keepalive\n\n'), this.keepaliveMs)
  }

  // True once the chunk was taken by the stream's reader; false when the
  // write failed or the stream was already closed.
  private send(chunk: string): Promise<boolean> {
    if (!this.isOpen) return Promise.resolve(false)
    let written: Promise<boolean>
    try {
      written = this.writer.write(this.encoder.encode(chunk)).then(
        () => true,
        () => {
          this.stop()
          return false
        },
      )
    } catch {
      this.stop()
      return Promise.resolve(false)
    }
    this.arm()
    return written
  }

  session(session: unknown): void {
    void this.send(frame('session', { session }))
  }

  turn(turn: TurnStreamTurn): void {
    void this.send(frame('turn', turn))
  }

  step(event: TurnStepEvent): void {
    if (this.done) return
    try {
      void this.send(frame('step', event))
    } catch {
      // A caption never fails the turn.
    }
  }

  /**
   * Writes the last event (a 200 reply as `result`, anything else as
   * `error`) and closes the stream. Resolves true once the reader took it.
   * A body that cannot be serialized throws here, before anything is
   * written, so the caller can send INTERNAL_TURN_REPLY instead.
   */
  end(reply: TurnReply): Promise<boolean> {
    const last = reply.status === 200 ? frame('result', reply.body) : frame('error', { status: reply.status, body: reply.body })
    this.done = true
    const written = this.send(last)
    clearTimeout(this.keepalive)
    if (this.isOpen) this.writer.close().catch(this.stop)
    return written
  }

  // Ends the stream with no last event (a duplicate alarm's watcher: there
  // is no answer to send it, and the client re-reads the session).
  close(): void {
    this.done = true
    clearTimeout(this.keepalive)
    if (this.isOpen) this.writer.close().catch(this.stop)
  }
}

// `session` is the create route's list-row, sent first. `keepaliveMs` exists
// for tests.
export type StreamTurnOptions = { session?: unknown; keepaliveMs?: number }

/**
 * Answers 200 with an event stream at once and runs the turn behind it.
 *
 * The turn is a promise of its own, never chained to the writer: a client
 * that leaves only makes the next write fail (TurnStreamWriter), while the
 * turn runs on to the end and persists as it would have. The promise goes
 * to waitUntil, which keeps the request's Neon pool open until it settles
 * (index.ts withRequestPool) and gives a turn whose client dropped up to 30
 * more seconds. Nothing here is logged but a fixed line: steps and bodies
 * carry the listener's names and words.
 */
export function streamTurn(
  c: Context,
  run: (onStep: (event: TurnStepEvent) => void) => Promise<TurnReply>,
  options: StreamTurnOptions = {},
): Response {
  const stream = new TurnStreamWriter({ keepaliveMs: options.keepaliveMs })
  if (options.session !== undefined) stream.session(options.session)

  const turn = (async () => {
    try {
      const reply = await run((event) => stream.step(event))
      // Framed inside the try: a body that cannot be serialized is an
      // unforeseen failure, as c.json throwing would be on the JSON path.
      void stream.end(reply)
    } catch {
      console.error('turn stream failed')
      void stream.end(INTERNAL_TURN_REPLY)
    }
  })()

  // Hono throws when the request has no execution context (app.request in
  // tests): the turn then simply runs as a floating promise that never
  // rejects.
  let ctx: ExecutionContext | undefined
  try {
    ctx = c.executionCtx
  } catch {
    ctx = undefined
  }
  ctx?.waitUntil(turn)

  return turnStreamResponse(stream.readable)
}
