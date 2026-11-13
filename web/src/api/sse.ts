/**
 * The streamed mix turn (spec `docs/superpowers/specs/2026-11-13-dj-turn-steps-design.md`,
 * "Wire contract"): SSE framing over the response body of `POST /sessions` and
 * `POST /sessions/:id/messages` when the client asked with
 * `Accept: text/event-stream`. Parsed by hand from the fetch body, because
 * EventSource can neither POST nor send a bearer token.
 *
 * The server sends `session` (create only, first), any number of `step`
 * events, then exactly one of `result` (today's success body) or `error`
 * (`{status, body}`), with `: keepalive` comments between. A stream that ends
 * before `result` or `error` is a dropped connection.
 */

/** One server-sent event: its name (`message` when it had no `event:` line) and its data lines joined with `\n`. */
export type SseEvent = { event: string; data: string }

export type SseDecoder = {
  /** Decodes the next chunk; returns the events whose blank line it completed. */
  push: (chunk: Uint8Array) => SseEvent[]
  /** Flushes the decoder at the end of the stream. An event cut off by the end is never dispatched. */
  end: () => SseEvent[]
}

/**
 * Bytes decode as UTF-8 across chunk boundaries (a chunk may end inside a
 * character; a malformed sequence becomes U+FFFD rather than an error). Lines
 * end in LF, CRLF or CR, a CRLF split across chunks included. Lines starting
 * with `:` are comments; `id`, `retry` and unknown fields are ignored. An
 * event is dispatched on its blank line, and only when it has data.
 */
export function createSseDecoder(): SseDecoder {
  const text = new TextDecoder('utf-8')
  // The line read so far, and whether the last character seen was a CR (so
  // an LF that opens the next chunk belongs to it).
  let partial = ''
  let afterCr = false
  let name = ''
  let data: string[] = []

  function line(value: string, out: SseEvent[]) {
    if (value === '') {
      if (data.length > 0) out.push({ event: name || 'message', data: data.join('\n') })
      name = ''
      data = []
      return
    }
    if (value.startsWith(':')) return
    const colon = value.indexOf(':')
    const field = colon < 0 ? value : value.slice(0, colon)
    let content = colon < 0 ? '' : value.slice(colon + 1)
    if (content.startsWith(' ')) content = content.slice(1)
    if (field === 'event') name = content
    else if (field === 'data') data.push(content)
  }

  function feed(chunk: string): SseEvent[] {
    const out: SseEvent[] = []
    let start = 0
    // An empty decode (the chunk ended inside a character) keeps the pending CR.
    if (afterCr && chunk.length > 0) {
      if (chunk[0] === '\n') start = 1
      afterCr = false
    }
    for (let index = start; index < chunk.length; index += 1) {
      const character = chunk[index]
      if (character !== '\r' && character !== '\n') continue
      line(partial + chunk.slice(start, index), out)
      partial = ''
      if (character === '\r') {
        if (index + 1 < chunk.length) {
          if (chunk[index + 1] === '\n') index += 1
        } else afterCr = true
      }
      start = index + 1
    }
    partial += chunk.slice(start)
    return out
  }

  return {
    push: (chunk) => feed(text.decode(chunk, { stream: true })),
    end: () => feed(text.decode()),
  }
}

/** A `step` event: the DJ started a new kind of work. The name fields are optional; render them as plain text. */
export type TurnStepProgress = {
  type: 'step'
  /**
   * `listening`, `playlists`, `digging`, `picking`, `checking`, `editing`,
   * `pressing`, `labelling`, `noting`, `writing`, or one added later: a raw
   * string, since the server may add steps and the line ignores one it does
   * not know.
   */
  step: string
  /** `library` or `catalogue` on `digging`. */
  scope?: string
  /** On `digging` and `picking`: the artists the brief named. */
  artists?: string[]
  /** On the genre sound check (`checking`). */
  genres?: string[]
  /** On `playlists`: the chosen playlist's name. */
  playlist?: string
  /** On `labelling`: the mix's new title. */
  title?: string
  /** On `pressing`: how many songs the queue now holds. */
  count?: number
}

/**
 * What a streamed turn reports while it runs. `opened`: the server answered
 * with a stream (an older server, a refusal before the turn, or an album
 * answers JSON and never sends it). `session`: the create stream named the new
 * session before its turn ran. The final answer is not progress: it is the
 * call's return value or exception, as on the JSON path.
 */
export type TurnProgress = { type: 'opened' } | { type: 'session'; sessionId: string } | TurnStepProgress

export type TurnProgressListener = (progress: TurnProgress) => void

/** How long a turn stream may go without a byte (the server's keepalive is every 15 s) before it counts as dropped. */
export const TURN_STREAM_IDLE_TIMEOUT_MS = 45_000

/** How a streamed turn ended: the result body, the error event, or an error event with no integer status. */
export type TurnStreamEnd = { kind: 'result'; body: unknown } | { kind: 'error'; status: number; body: unknown } | { kind: 'malformed' }

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function text(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim() !== '' ? value : undefined
}

/** The non-blank strings; undefined when none are left. */
function names(value: unknown): string[] | undefined {
  if (!Array.isArray(value)) return undefined
  const kept = value.filter((name): name is string => text(name) !== undefined)
  return kept.length > 0 ? kept : undefined
}

/** A `step` event's data, or null when it has no string `step`. A missing or mistyped name field is dropped, never thrown. */
export function parseTurnStep(data: unknown): TurnStepProgress | null {
  if (!isRecord(data) || typeof data.step !== 'string' || data.step === '') return null
  const step: TurnStepProgress = { type: 'step', step: data.step }
  const scope = text(data.scope)
  const artists = names(data.artists)
  const genres = names(data.genres)
  const playlist = text(data.playlist)
  const title = text(data.title)
  if (scope !== undefined) step.scope = scope
  if (artists) step.artists = artists
  if (genres) step.genres = genres
  if (playlist !== undefined) step.playlist = playlist
  if (title !== undefined) step.title = title
  if (Number.isInteger(data.count)) step.count = data.count as number
  return step
}

function tryParse(data: string): unknown {
  try {
    return JSON.parse(data)
  } catch {
    return undefined
  }
}

/**
 * Reads a streamed turn from `body`: hands each `session` and `step` event to
 * `onProgress` as it arrives (a listener that throws is ignored), and answers
 * with the `result` or `error` event as soon as its blank line arrives. The
 * rest of the body is then cancelled and the reader released. Unknown events,
 * and `session` or `step` events that do not parse, are skipped.
 *
 * Throws a TypeError, as a failed `fetch` does, when the body ends before a
 * `result` or `error` event, a read fails, or no byte arrives for
 * `idleTimeoutMs` (any bytes restart it, keepalives included); a `result`
 * whose data is not JSON throws the parse error, as `response.json()` would.
 */
export async function readTurnStream(
  body: ReadableStream<Uint8Array>,
  onProgress: TurnProgressListener,
  { idleTimeoutMs = TURN_STREAM_IDLE_TIMEOUT_MS }: { idleTimeoutMs?: number } = {},
): Promise<TurnStreamEnd> {
  const report = (progress: TurnProgress) => {
    try {
      onProgress(progress)
    } catch {
      // A caption never breaks the turn.
    }
  }
  const decoder = createSseDecoder()
  const reader = body.getReader()
  let finished = false
  /** The end the events reach, or undefined to keep reading. */
  const handle = (events: SseEvent[]): TurnStreamEnd | undefined => {
    for (const { event, data } of events) {
      if (event === 'session') {
        const session = tryParse(data)
        const id = isRecord(session) && isRecord(session.session) ? session.session.id : undefined
        if (typeof id === 'string' && id !== '') report({ type: 'session', sessionId: id })
      } else if (event === 'step') {
        const step = parseTurnStep(tryParse(data))
        if (step) report(step)
      } else if (event === 'result') {
        return { kind: 'result', body: JSON.parse(data) }
      } else if (event === 'error') {
        const error = tryParse(data)
        if (!isRecord(error) || !Number.isInteger(error.status)) return { kind: 'malformed' }
        return { kind: 'error', status: error.status as number, body: error.body ?? null }
      }
    }
    return undefined
  }
  try {
    for (;;) {
      // Inferred from the reader, not the DOM's ReadableStreamReadResult: the
      // server's tests import this file under node types, which lack that name.
      let chunk: Awaited<ReturnType<typeof reader.read>>
      let idle: ReturnType<typeof setTimeout> | undefined
      try {
        chunk = await Promise.race([
          reader.read(),
          new Promise<never>((_, reject) => {
            idle = setTimeout(() => reject(new TypeError('The turn stream went quiet.')), idleTimeoutMs)
          }),
        ])
      } catch (cause) {
        throw cause instanceof TypeError ? cause : new TypeError('The turn stream was interrupted.', { cause })
      } finally {
        clearTimeout(idle)
      }
      if (chunk.done) {
        finished = true
        const end = handle(decoder.end())
        if (end) return end
        throw new TypeError('The turn stream ended before its result.')
      }
      const end = handle(decoder.push(chunk.value))
      if (end) return end
    }
  } finally {
    // Cancelling settles a read still out (after the idle timeout), so the lock can go.
    if (!finished) void reader.cancel().catch(() => undefined)
    try {
      reader.releaseLock()
    } catch {
      // Released already.
    }
  }
}
