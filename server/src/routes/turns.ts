import { Hono, type Context } from 'hono'
import type { ContentfulStatusCode } from 'hono/utils/http-status'
import { and, desc, eq, gt, inArray, isNull, ne, sql } from 'drizzle-orm'
import type { AppVars } from '../app'
import type { Db } from '../db/types'
import { djSessions, djTurns } from '../db/schema'
import { CONFLICT_APOLOGY, DjError } from '../dj/loop'
import { abandonTurn, TURN_LOST_MS, type TurnJob } from '../dj/turn-job'
import type { TurnRunnerNamespace, TurnRunnerStub } from '../dj/turn-runner'
import { hasLiveDevice, turnPushEnabled } from '../push/notify'
import { djErrorBody, finishedTurnReply, sessionListColumns } from './turn-bodies'
import { INTERNAL_TURN_REPLY, sessionFrame, TurnStreamWriter, turnStreamResponse, wantsTurnStream, type TurnReply } from './turn-stream'

// Mix turns off the request (spec 2026-11-21 durable-mix-turns, "Start
// (Worker side)" and "Session reads"), behind DURABLE_TURNS. The session
// routes (sessions.ts) keep every refusal and write the persist-first rows;
// this starts the session's TurnRunner object and answers from its watch
// stream, and holds the routes and reads only durable turns have.

export type DurableTurnsWiring = {
  runner: TurnRunnerNamespace
  // What computePush reads (TURN_PUSH).
  push?: { TURN_PUSH?: string }
}

// Whether the server will push this turn's end (the `turn` event's `push`):
// TURN_PUSH on and the user has a live device on the surface the turn came
// from (spec: "this device has a live push registration"). The client then
// stays quiet in the background rather than post its local notification too
// (spec, "Who notifies"). A phone whose listener registered only a laptop
// keeps its local ping, since the push goes to the laptop. A failed read
// says false: the local one then covers it.
export async function computePush(db: Db, userId: string, env: { TURN_PUSH?: string } | undefined, surface?: 'ios' | 'web'): Promise<boolean> {
  if (!turnPushEnabled(env)) return false
  try {
    return await hasLiveDevice(db, userId, surface)
  } catch {
    return false
  }
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export const INVALID_IDEMPOTENCY_KEY = { error: 'invalid_idempotency_key' } as const

// The Idempotency-Key header: absent (old builds; the server mints the
// turn id), a canonical UUID (lower-cased, as Postgres prints it), or
// invalid (a 400).
export function readIdempotencyKey(c: Context): { ok: true; key?: string } | { ok: false } {
  const raw = c.req.header('idempotency-key')
  if (raw === undefined) return { ok: true }
  const key = raw.trim()
  return UUID_RE.test(key) ? { ok: true, key: key.toLowerCase() } : { ok: false }
}

export type TurnRow = { id: string; sessionId: string; userId: string; kind: TurnJob['kind'] }

export async function findTurn(db: Db, turnId: string): Promise<TurnRow | null> {
  const [row] = await db
    .select({ id: djTurns.id, sessionId: djTurns.sessionId, userId: djTurns.userId, kind: djTurns.kind })
    .from(djTurns)
    .where(eq(djTurns.id, turnId))
  return row ?? null
}

// A key that names a turn: attach when it is this listener's (and, for a
// message, this session's), refuse otherwise. Null when no turn has it.
export async function replayForKey(
  c: Context<{ Variables: AppVars }>,
  db: Db,
  durable: DurableTurnsWiring,
  key: string,
  scope: { userId: string; sessionId?: string },
): Promise<Response | null> {
  const turn = await findTurn(db, key)
  if (!turn) return null
  if (turn.userId !== scope.userId || (scope.sessionId !== undefined && turn.sessionId !== scope.sessionId)) {
    return c.json(INVALID_IDEMPOTENCY_KEY, 400)
  }
  return answerTurn(c, db, durable, turn, undefined, { replay: true })
}

// Postgres unique_violation, through drizzle's wrapper or bare: two
// requests racing one Idempotency-Key, the loser's insert of the turn row.
export function isUniqueViolation(e: unknown): boolean {
  for (let err: unknown = e, depth = 0; err && depth < 4; depth += 1) {
    if ((err as { code?: unknown }).code === '23505') return true
    err = (err as { cause?: unknown }).cause
  }
  return false
}

// The persist-first turn row and the session's pointer to it, inside the
// caller's transaction. Returns the pointer it replaced, for a busy start to
// put back. The pointer write leaves updated_at alone: list order moves when
// the turn lands, as today.
export async function queueTurnRow(
  tx: Db,
  row: { id: string; sessionId: string; userId: string; kind: TurnJob['kind'] },
): Promise<string | null> {
  const [prev] = await tx.select({ currentTurnId: djSessions.currentTurnId }).from(djSessions).where(eq(djSessions.id, row.sessionId))
  await tx.insert(djTurns).values(row)
  await tx
    .update(djSessions)
    .set({ currentTurnId: row.id, updatedAt: sql`${djSessions.updatedAt}` })
    .where(eq(djSessions.id, row.sessionId))
  return prev?.currentTurnId ?? null
}

function stubFor(durable: DurableTurnsWiring, sessionId: string): TurnRunnerStub {
  return durable.runner.get(durable.runner.idFromName(sessionId))
}

/**
 * Hands the queued turn to its session's object and answers the request
 * from the object's watch stream. A start the object refuses as busy
 * answers today's 409 conflict body, with the queued row failed and the
 * session's pointer put back on the turn that holds the object.
 */
export async function startDurableTurn(
  c: Context<{ Variables: AppVars }>,
  db: Db,
  durable: DurableTurnsWiring,
  turn: TurnRow & { userMessageSeq: number; options: TurnJob['options']; previousTurnId: string | null; session?: unknown },
): Promise<Response> {
  const job: TurnJob = {
    turnId: turn.id,
    sessionId: turn.sessionId,
    userId: turn.userId,
    kind: turn.kind,
    userMessageSeq: turn.userMessageSeq,
    options: turn.options,
    push: await computePush(db, turn.userId, durable.push, turn.options.surface),
  }
  let answer
  try {
    answer = await stubFor(durable, turn.sessionId).start(job)
  } catch (e) {
    // The object never took it: fail the row now rather than leave it
    // queued for the sweep. The listener's message stands (persist-first).
    await abandonTurn(db, turn.id, 'internal').catch(() => false)
    throw e
  }
  if (answer === 'busy') {
    // Failed as the conflict it answers, so a replay of its key rebuilds
    // the same 409 (finishedTurnReply).
    await abandonTurn(db, turn.id, 'conflict')
    // The pointer goes back to the turn that holds the object: the newest
    // other live turn of the session. previousTurnId alone is not enough,
    // since two sends can read the same previous pointer and the busy one
    // may have committed last.
    const [holder] = await db
      .select({ id: djTurns.id })
      .from(djTurns)
      .where(and(eq(djTurns.sessionId, turn.sessionId), inArray(djTurns.status, ['queued', 'running']), ne(djTurns.id, turn.id)))
      .orderBy(desc(djTurns.createdAt))
      .limit(1)
    await db
      .update(djSessions)
      .set({ currentTurnId: holder?.id ?? turn.previousTurnId, updatedAt: sql`${djSessions.updatedAt}` })
      .where(and(eq(djSessions.id, turn.sessionId), eq(djSessions.currentTurnId, turn.id)))
    const extra = turn.kind === 'create' ? { sessionId: turn.sessionId } : {}
    return c.json(djErrorBody(new DjError('conflict', CONFLICT_APOLOGY), extra), 409)
  }
  return answerTurn(c, db, durable, turn, turn.session)
}

// The create's `session` event: the list row as the database has it now
// (a replay), unless the caller holds the row it just inserted (the first
// request, which sends exactly what streamTurn sent).
async function createSessionEvent(db: Db, sessionId: string): Promise<unknown> {
  const [row] = await db.select(sessionListColumns).from(djSessions).where(eq(djSessions.id, sessionId))
  return row
}

/**
 * The turn's answer, from its object: a stream request gets the watch
 * stream (with `replay=1`, so a turn that already finished still sends its
 * last event), headed by the create's `session` event; a JSON request gets
 * that stream read here to its last event, as the same body and status the
 * in-request path answers. A finished turn whose last event the object no
 * longer keeps is answered from the database (finishedTurnReply) the same
 * two ways; only an unfinished turn the object does not hold answers 204.
 */
// A replay can land between the first request's commit and its start: the
// object then does not know the turn yet (404). It is asked again, briefly.
const UNSTARTED_RETRIES = 5
const UNSTARTED_WAIT_MS = 200

export async function answerTurn(
  c: Context<{ Variables: AppVars }>,
  db: Db,
  durable: DurableTurnsWiring,
  turn: TurnRow,
  session?: unknown,
  options: { replay?: boolean } = {},
): Promise<Response> {
  const stub = stubFor(durable, turn.sessionId)
  let res = await stub.fetch(watchRequest(turn.id, true))
  for (let i = 0; ; i += 1) {
    // The object no longer has the last event (a late replay: 204; or its
    // last event is a later turn's: 404). A finished turn's answer is
    // rebuilt from the database, so a replayed create still learns its
    // session and how the turn ended.
    if (res.status === 204 || res.status === 404) {
      const finished = await finishedTurnReply(db, turn.id)
      if (finished) return answerFinished(c, db, turn, finished)
    }
    if (!(options.replay && res.status === 404 && i < UNSTARTED_RETRIES)) break
    await new Promise((resolve) => setTimeout(resolve, UNSTARTED_WAIT_MS))
    res = await stub.fetch(watchRequest(turn.id, true))
  }
  if (res.status === 204) return c.body(null, 204)
  if (res.status !== 200 || !res.body) return c.json(INTERNAL_TURN_REPLY.body as object, INTERNAL_TURN_REPLY.status)
  if (wantsTurnStream(c)) {
    if (turn.kind !== 'create') return passThrough(res, res.body)
    const row = session ?? (await createSessionEvent(db, turn.sessionId))
    return passThrough(res, withLeadingFrame(sessionFrame(row), res.body))
  }
  // A stream that closed with no last event (a duplicate alarm's) still
  // answers the turn's end when the database has it.
  const reply = lastEvent(await res.text()) ?? (await finishedTurnReply(db, turn.id)) ?? INTERNAL_TURN_REPLY
  return c.json(reply.body as object, reply.status)
}

// A finished turn's rebuilt answer, sent as the live one would be: the
// stream's `session` (create), `turn`, then `result` or `error`; JSON as
// the body and status.
async function answerFinished(c: Context<{ Variables: AppVars }>, db: Db, turn: TurnRow, reply: TurnReply): Promise<Response> {
  if (!wantsTurnStream(c)) return c.json(reply.body as object, reply.status)
  const writer = new TurnStreamWriter()
  if (turn.kind === 'create') writer.session(await createSessionEvent(db, turn.sessionId))
  writer.turn({ turnId: turn.id, push: false })
  void writer.end(reply)
  return turnStreamResponse(writer.readable)
}

function watchRequest(turnId: string, replay: boolean): Request {
  return new Request(`https://turn-runner/watch?turn=${encodeURIComponent(turnId)}${replay ? '&replay=1' : ''}`)
}

// A fresh Response over the object's: a subrequest's headers are immutable
// on Workers, and the app's middleware (CORS) sets its own on the way out.
function passThrough(res: Response, body: ReadableStream<Uint8Array>): Response {
  return new Response(body, { status: res.status, headers: new Headers(res.headers) })
}

// `frame` first, then the object's stream as it comes. A client that leaves
// cancels the object's stream with it, so the object drops the watcher.
function withLeadingFrame(frame: string, body: ReadableStream<Uint8Array>): ReadableStream<Uint8Array> {
  const reader = body.getReader()
  let sent = false
  return new ReadableStream<Uint8Array>({
    async pull(controller) {
      if (!sent) {
        sent = true
        controller.enqueue(new TextEncoder().encode(frame))
        return
      }
      const { value, done } = await reader.read()
      if (done) controller.close()
      else controller.enqueue(value)
    },
    cancel(reason) {
      return reader.cancel(reason)
    },
  })
}

// The stream's last `result` (200, the body) or `error` ({ status, body })
// event, or null when it ended without one (a duplicate alarm closes its
// watchers with nothing to send).
export function lastEvent(text: string): TurnReply | null {
  let reply: TurnReply | null = null
  for (const block of text.split('\n\n')) {
    const lines = block.split('\n')
    const name = lines.find((l) => l.startsWith('event: '))?.slice('event: '.length)
    const data = lines.find((l) => l.startsWith('data: '))?.slice('data: '.length)
    if (data === undefined || (name !== 'result' && name !== 'error')) continue
    try {
      const parsed = JSON.parse(data) as unknown
      if (name === 'result') reply = { status: 200, body: parsed }
      else {
        const error = parsed as { status: ContentfulStatusCode; body: unknown }
        reply = { status: error.status, body: error.body }
      }
    } catch {
      reply = null
    }
  }
  return reply
}

// What a session read shows of its current turn while it runs: queued or
// running and not lost (spec, "Status rules": a heartbeat, or created_at
// while queued, older than 90 s). Absent otherwise, never null.
export type LiveTurn = { id: string; status: 'queued' | 'running'; step: string | null }

export function liveTurnCutoff(now: Date = new Date()): Date {
  return new Date(now.getTime() - TURN_LOST_MS)
}

export async function readLiveTurn(db: Db, turnId: string | null): Promise<LiveTurn | null> {
  if (!turnId) return null
  const [row] = await db
    .select({ id: djTurns.id, status: djTurns.status, step: djTurns.step })
    .from(djTurns)
    .where(and(
      eq(djTurns.id, turnId),
      inArray(djTurns.status, ['queued', 'running']),
      gt(sql`coalesce(${djTurns.heartbeatAt}, ${djTurns.createdAt})`, liveTurnCutoff()),
    ))
  return row ? (row as LiveTurn) : null
}

// GET /sessions's per-row twin of readLiveTurn, one correlated subquery so
// the list stays one statement.
export function liveTurnColumn() {
  const cutoff = liveTurnCutoff().toISOString()
  return sql<LiveTurn | null>`(
    SELECT json_build_object('id', t.id, 'status', t.status, 'step', t.step)
    FROM dj_turns t
    WHERE t.id = ${djSessions.currentTurnId}
      AND t.status IN ('queued', 'running')
      AND coalesce(t.heartbeat_at, t.created_at) > ${cutoff}::timestamptz
  )`
}

type OwnedSession = { id: string; currentTurnId: string | null } | null

/**
 * The durable turn's own routes, mounted on /sessions beside the rest:
 * attach (GET /:id/turn/stream) and the client's acknowledgement (POST
 * /:id/turn/:turnId/seen). Both are the session owner's only.
 */
export function turnRoutes(db: Db, durable: DurableTurnsWiring, loadOwnedSession: (id: string, userId: string) => Promise<OwnedSession>) {
  const app = new Hono<{ Variables: AppVars }>()

  // The current turn's stream: the latest step first, then live. 204 when
  // there is none or it has finished (the client re-reads the session).
  app.get('/:id/turn/stream', async (c) => {
    const session = await loadOwnedSession(c.req.param('id'), c.get('user').id)
    if (!session) return c.json({ error: 'not_found' }, 404)
    if (!session.currentTurnId) return c.body(null, 204)
    const res = await stubFor(durable, session.id).fetch(watchRequest(session.currentTurnId, false))
    if (res.status !== 200 || !res.body) return c.body(null, 204)
    return passThrough(res, res.body)
  })

  // The result was on screen (spec, "Who notifies"): fire and forget from
  // the client, idempotent here. The first time stands.
  app.post('/:id/turn/:turnId/seen', async (c) => {
    const session = await loadOwnedSession(c.req.param('id'), c.get('user').id)
    const turnId = c.req.param('turnId')
    if (!session || !UUID_RE.test(turnId)) return c.json({ error: 'not_found' }, 404)
    const [turn] = await db
      .select({ id: djTurns.id })
      .from(djTurns)
      .where(and(eq(djTurns.id, turnId), eq(djTurns.sessionId, session.id)))
    if (!turn) return c.json({ error: 'not_found' }, 404)
    await db.update(djTurns).set({ seenAt: new Date() }).where(and(eq(djTurns.id, turn.id), isNull(djTurns.seenAt)))
    return c.body(null, 204)
  })

  return app
}
