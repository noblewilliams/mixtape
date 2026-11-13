import type { Context, ExecutionContext } from 'hono'
import type { ContentfulStatusCode } from 'hono/utils/http-status'
import type { TurnStepEvent } from '../dj/turn-steps'

// The streamed turn (spec 2026-11-13 dj-turn-steps, "Wire contract"). A
// client that sends Accept: text/event-stream on a mix turn gets the turn's
// steps down the request it already holds open, then the same body the JSON
// path sends, as SSE events:
//
//   event: session  { session }            create only, first
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

const INTERNAL: TurnReply = { status: 500, body: { error: 'internal' } }

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

// `session` is the create route's list-row, sent first. `keepaliveMs` exists
// for tests.
export type StreamTurnOptions = { session?: unknown; keepaliveMs?: number }

/**
 * Answers 200 with an event stream at once and runs the turn behind it.
 *
 * The turn is a promise of its own, never chained to the writer: a client
 * that leaves only makes the next write fail, and after the first failed
 * write nothing more is written, while the turn runs on to the end and
 * persists as it would have. The promise goes to waitUntil, which keeps the
 * request's Neon pool open until it settles (index.ts withRequestPool) and
 * gives a turn whose client dropped up to 30 more seconds. Hand-rolled over a
 * TransformStream rather than Hono's streamSSE, so this abort behaviour is
 * ours. Nothing here is logged but a fixed line: steps and bodies carry
 * the listener's names and words.
 */
export function streamTurn(
  c: Context,
  run: (onStep: (event: TurnStepEvent) => void) => Promise<TurnReply>,
  options: StreamTurnOptions = {},
): Response {
  const keepaliveMs = options.keepaliveMs ?? TURN_STREAM_KEEPALIVE_MS
  const { readable, writable } = new TransformStream<Uint8Array, Uint8Array>()
  const writer = writable.getWriter()
  const encoder = new TextEncoder()
  // open: false once a write failed (the client left). done: the last event
  // is written, so a step that still arrives is dropped.
  let open = true
  let done = false
  let keepalive: ReturnType<typeof setTimeout> | undefined

  const stop = () => {
    open = false
    clearTimeout(keepalive)
  }
  // Re-armed by every write, so a keepalive goes out only after a quiet
  // interval.
  const arm = () => {
    clearTimeout(keepalive)
    if (open && !done) keepalive = setTimeout(() => send(': keepalive\n\n'), keepaliveMs)
  }
  function send(chunk: string) {
    if (!open) return
    try {
      writer.write(encoder.encode(chunk)).catch(stop)
    } catch {
      stop()
      return
    }
    arm()
  }
  const frame = (name: string, data: unknown) => `event: ${name}\ndata: ${JSON.stringify(data)}\n\n`
  const onStep = (event: TurnStepEvent) => {
    if (done) return
    try {
      send(frame('step', event))
    } catch {
      // A caption never fails the turn.
    }
  }

  if (options.session !== undefined) send(frame('session', { session: options.session }))
  else arm()

  const turn = (async () => {
    let last: string
    try {
      const reply = await run(onStep)
      // Framed inside the try: a body that cannot be serialized is an
      // unforeseen failure, as c.json throwing would be on the JSON path.
      last = reply.status === 200 ? frame('result', reply.body) : frame('error', { status: reply.status, body: reply.body })
    } catch {
      console.error('turn stream failed')
      last = frame('error', INTERNAL)
    }
    done = true
    send(last)
    clearTimeout(keepalive)
    if (open) writer.close().catch(stop)
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

  return new Response(readable, {
    status: 200,
    headers: {
      'content-type': 'text/event-stream; charset=utf-8',
      'cache-control': 'no-cache, no-transform',
    },
  })
}
