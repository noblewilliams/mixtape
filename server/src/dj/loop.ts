import { z } from 'zod'
import { and, desc, eq, gt } from 'drizzle-orm'
import type { Db } from '../db/types'
import type { Embedder } from '../enrich/embedder'
import { djMessages, djSessions, queueTracks, tracks } from '../db/schema'
import type { LlmClient, LlmMessage } from './llm'
import { LlmError } from './llm'
import { intentSchema, opIntentSchema, queueOpsSchema, DJ_TOOLS, type Intent, type OpIntent } from './contracts'
import { buildPool } from './pool'
import { curate, CurationTruncated, CurationUnparseable } from './curate'
import {
  applyOps,
  getActiveQueue,
  replaceQueue,
  QueueOpError,
  QueueVersionConflict,
  type QueueTrackView,
  type ReplacementsProvider,
} from './queue-store'

export type DjDeps = { llm: LlmClient; embed: Embedder }

// The only session fields the loop actually needs — callers (the session
// routes, Task 8) already have the full dj_sessions row and can pass it
// straight through; this stays a narrow structural type rather than the
// whole row so tests don't need to fabricate one.
export type DjSessionRef = { id: string; userId: string }

export type DjTurnResult = {
  djMessage: typeof djMessages.$inferSelect
  queue: QueueTrackView[]
  queueVersion: number
}

// Bounds the number of tool-use round trips in a single turn. A round is one
// LLM call that comes back with tool_use — text-only never counts against
// this, since it's the loop's normal exit. Guards against a model that keeps
// calling tools forever (or two tools that keep undoing each other).
const MAX_TURNS = 4

export const FALLBACK_TEXT = "took too many tries — here's where I landed."
const CURATION_APOLOGY = 'lost my train of thought on that one — try again?'
const CONFLICT_APOLOGY = 'the queue shifted while I was working on it — try that again?'

// Thrown out of runDjTurn on any turn-ending failure. `message` is always a
// short, fixed, content-free string — never the LLM's own error text, a
// curation parse failure, or anything else that could echo request content
// (system prompt, pool tracks, tool input). Callers (the session routes)
// surface `message` directly to the client and use `kind` to decide status
// code / retry behavior.
export class DjError extends Error {
  constructor(
    readonly kind: 'llm' | 'curation' | 'conflict' | 'validation' | 'internal',
    message: string,
  ) {
    super(message)
    this.name = 'DjError'
  }
}

function normalizeError(e: unknown): DjError {
  if (e instanceof DjError) return e
  if (e instanceof LlmError) {
    return new DjError('llm', `dj: llm request failed${e.status !== undefined ? ` (status ${e.status})` : ''}`)
  }
  if (e instanceof CurationTruncated || e instanceof CurationUnparseable) return new DjError('curation', CURATION_APOLOGY)
  if (e instanceof QueueVersionConflict) return new DjError('conflict', CONFLICT_APOLOGY)
  return new DjError('internal', 'dj: internal error')
}

// Static across every turn — the volatile bit (queue summary, recent
// removals) is appended as a suffix built fresh per turn (buildSessionContext
// below), same cache-shape reasoning as curate's SYSTEM_PROMPT.
const PERSONA_PROMPT = [
  "You are the DJ — warm, brief, music-literate. You talk WITH the listener about their queue, not at them.",
  'Queues come ONLY from your tools (generate_queue, edit_queue) — never claim a track is queued, or describe ' +
    "one, unless a tool call actually put it there. Don't invent tracks or artists.",
  'When the listener names a duration ("an hour", "half an hour") instead of a count, convert it to a track ' +
    'count yourself at ~3.5 minutes per track before calling a tool.',
  "If the session context below says the listener manually removed tracks, acknowledge it briefly and adapt — " +
    "don't just re-add what they took out unless they ask for it back.",
  'Keep spoken replies SHORT — a sentence or two, like a text from a friend who runs the board.',
].join('\n')

// Formats the failure of a zod safeParse into tool_result text: issue paths
// and messages only, never the offending input value itself (a malformed
// tool call could carry anything — echoing it back would be an injection
// vector into the model's own context on the very next turn).
function formatZodIssues(prefix: string, error: z.ZodError): string {
  const issues = error.issues.map((i) => `${i.path.join('.') || '(root)'}: ${i.message}`).join('; ')
  return `${prefix}: ${issues}`
}

async function loadHistory(db: Db, sessionId: string): Promise<LlmMessage[]> {
  // Last 12 by seq, newest first from the query, reversed back to
  // chronological order for the request. Plain-text reconstruction is fine
  // for PERSISTED rows — the verbatim-replay requirement (turn.raw) only
  // applies to the assistant turns generated WITHIN this live turn, which
  // never touch this function.
  const rows = await db
    .select({ role: djMessages.role, content: djMessages.content })
    .from(djMessages)
    .where(eq(djMessages.sessionId, sessionId))
    .orderBy(desc(djMessages.seq))
    .limit(12)
  return rows.reverse().map((r) => ({ role: r.role === 'dj' ? ('assistant' as const) : ('user' as const), content: r.content }))
}

async function getSessionQueueVersion(db: Db, sessionId: string): Promise<number> {
  const [row] = await db.select({ queueVersion: djSessions.queueVersion }).from(djSessions).where(eq(djSessions.id, sessionId))
  if (!row) throw new DjError('internal', 'dj: session not found')
  return row.queueVersion
}

// Builds the per-turn context suffix: a one-line queue summary, plus an
// acknowledgment line for any track the LISTENER (not the dj) removed since
// the dj's own last message — so the model can react to it instead of acting
// like nothing happened. "Since" is the last dj message's createdAt; with no
// prior dj message at all (a brand new session, or one whose queue was only
// ever touched via the manual queue-ops route), everything counts as "since"
// — there's no earlier dj turn to bound it against.
async function buildSessionContext(db: Db, sessionId: string): Promise<string> {
  const queue = await getActiveQueue(db, sessionId)
  const queueLine =
    queue.length === 0
      ? 'Current queue: empty.'
      : queue.length === 1
        ? `Current queue: 1 track — "${queue[0].title}".`
        : `Current queue: ${queue.length} tracks, from "${queue[0].title}" to "${queue[queue.length - 1].title}".`

  const [lastDj] = await db
    .select({ createdAt: djMessages.createdAt })
    .from(djMessages)
    .where(and(eq(djMessages.sessionId, sessionId), eq(djMessages.role, 'dj')))
    .orderBy(desc(djMessages.seq))
    .limit(1)
  const since = lastDj?.createdAt ?? new Date(0)

  const removals = await db
    .select({ title: tracks.title, artist: tracks.artist })
    .from(queueTracks)
    .innerJoin(tracks, eq(tracks.id, queueTracks.trackId))
    .where(
      and(
        eq(queueTracks.sessionId, sessionId),
        eq(queueTracks.state, 'removed'),
        eq(queueTracks.removedBy, 'user'),
        gt(queueTracks.updatedAt, since),
      ),
    )

  const removalLine =
    removals.length > 0
      ? `The listener manually removed since your last message: ${removals.map((r) => `"${r.title}" — ${r.artist}`).join(', ')}.`
      : null

  return [queueLine, removalLine].filter((l): l is string => l !== null).join('\n')
}

// Wraps a full Intent (as captured off a successful generate_queue call)
// back down to an OpIntent shape — dropping targetCount, which an op's own
// `count` (extend) or the implicit 1 (swap) replaces.
function toOpIntent(intent: Intent): OpIntent {
  const { targetCount: _targetCount, ...rest } = intent
  return opIntentSchema.parse(rest)
}

const editQueueInputSchema = z.object({ ops: queueOpsSchema })

type GenerateOutcome = {
  resultText: string
  queueChanged: boolean
  newVersion?: number
  intent?: Intent
}

async function executeGenerateQueue(
  db: Db,
  deps: DjDeps,
  session: DjSessionRef,
  rawInput: unknown,
  sessionContext: string,
): Promise<GenerateOutcome> {
  const parsed = intentSchema.safeParse(rawInput)
  if (!parsed.success) {
    return { resultText: formatZodIssues('invalid generate_queue input', parsed.error), queueChanged: false }
  }
  const intent = parsed.data
  const pool = await buildPool(db, deps.embed, session.userId, intent)
  if (pool.length === 0) {
    // Not an error — the model still gets to tell the listener, in its own
    // voice, that nothing matched.
    return { resultText: 'no tracks in the library match those constraints', queueChanged: false, intent }
  }
  const picks = await curate(deps.llm, pool, intent, sessionContext)
  const version = await replaceQueue(
    db,
    session.id,
    picks.map((p) => ({ trackId: p.trackId, reason: p.reason })),
    'dj',
  )
  return {
    resultText: `queue generated: ${picks.length} tracks (now version ${version})`,
    queueChanged: true,
    newVersion: version,
    intent,
  }
}

type EditOutcome = {
  resultText: string
  queueChanged: boolean
  newVersion?: number
}

async function executeEditQueue(
  db: Db,
  deps: DjDeps,
  session: DjSessionRef,
  rawInput: unknown,
  userText: string,
  lastGenerateIntent: Intent | undefined,
  sessionContext: string,
): Promise<EditOutcome> {
  const parsed = editQueueInputSchema.safeParse(rawInput)
  if (!parsed.success) {
    return { resultText: formatZodIssues('invalid edit_queue input', parsed.error), queueChanged: false }
  }
  const ops = parsed.data.ops

  // Resolves a swap/extend's replacement picks. `opIntent` is whatever the
  // model put on that specific op (may be absent). With no op intent, this
  // falls back to the last generate_queue intent seen EARLIER IN THIS SAME
  // TURN (held only in-loop, on purpose — no schema change to persist a
  // "last intent" on the session; see Task 7 plan notes). With neither an op
  // intent nor a generate this turn, there's nothing to go on but the
  // listener's own current message — parsed as a weak intent (just its text
  // as `themes`, every other field defaulted) rather than failing the op.
  const provider: ReplacementsProvider = async (count, opIntent) => {
    const base: OpIntent = opIntent ?? (lastGenerateIntent ? toOpIntent(lastGenerateIntent) : opIntentSchema.parse({ themes: userText }))
    // NOT intentSchema.parse(...): intentSchema's targetCount is bounded 3-60
    // (a sane floor for a whole generated queue), but a swap/extend can
    // legitimately ask for as few as 1 replacement track — `base` is already
    // fully validated (via opIntentSchema, either directly or through
    // toOpIntent/the userText fallback above) and `count` is already
    // validated by queueOpsSchema's own op-specific bounds, so this is a
    // plain object build, not a re-validation.
    const fullIntent: Intent = { ...base, targetCount: count }
    const pool = await buildPool(db, deps.embed, session.userId, fullIntent)
    if (pool.length === 0) return [] // shortfall — queue-store leaves the original track(s) in place
    const picks = await curate(deps.llm, pool, fullIntent, sessionContext)
    return picks.map((p) => ({ trackId: p.trackId, reason: p.reason }))
  }

  try {
    const result = await applyOps(db, session.id, ops, 'dj', provider)
    return {
      resultText: `queue edited — requested ${result.requested}, added ${result.added}, removed ${result.removed} (now version ${result.version})`,
      queueChanged: true,
      newVersion: result.version,
    }
  } catch (e) {
    // QueueOpError (an out-of-range position/from/to against the CURRENT
    // queue) is a model mistake the model itself can correct on the next
    // round, same as a zod failure — recovered here rather than aborting the
    // whole turn. QueueVersionConflict is a genuine external race and is
    // deliberately NOT caught here: it propagates up to runDjTurn's
    // whole-turn retry.
    if (e instanceof QueueOpError) {
      return { resultText: 'invalid edit_queue ops: a position/from/to was out of range for the current queue', queueChanged: false }
    }
    throw e
  }
}

type AttemptStats = {
  llmCalls: number
  toolCalls: number
  inputTokens: number
  outputTokens: number
  cacheReadInputTokens: number
}

type AttemptResult = {
  text: string
  queueChanged: boolean
  queueVersion: number
  stats: AttemptStats
}

// Runs the full tool-use loop for one turn: builds history + context fresh,
// then drives up to MAX_TURNS rounds of (LLM call -> maybe tool calls ->
// tool_results) until the model replies with plain text or the bound is hit.
// Reading everything fresh on every call is what makes the conflict retry in
// runDjTurn ("retry the turn once from a fresh snapshot") correct: a second
// call to this function naturally picks up whatever the racing writer left
// behind, with no stale state carried over from the failed attempt.
async function attemptTurn(db: Db, deps: DjDeps, session: DjSessionRef, userText: string): Promise<AttemptResult> {
  const [history, sessionContext, startVersion] = await Promise.all([
    loadHistory(db, session.id),
    buildSessionContext(db, session.id),
    getSessionQueueVersion(db, session.id),
  ])

  const system = `${PERSONA_PROMPT}\n\n${sessionContext}`
  const baseMessages: LlmMessage[] = [...history, { role: 'user', content: userText }]
  const liveMessages: LlmMessage[] = []

  let lastGenerateIntent: Intent | undefined
  let queueChanged = false
  let currentVersion = startVersion
  let finalText: string | null = null
  const stats: AttemptStats = { llmCalls: 0, toolCalls: 0, inputTokens: 0, outputTokens: 0, cacheReadInputTokens: 0 }

  for (let round = 0; round < MAX_TURNS && finalText === null; round++) {
    const turn = await deps.llm({ system, messages: [...baseMessages, ...liveMessages], tools: DJ_TOOLS })
    stats.llmCalls += 1
    if (turn.usage) {
      stats.inputTokens += turn.usage.inputTokens
      stats.outputTokens += turn.usage.outputTokens
      stats.cacheReadInputTokens += turn.usage.cacheReadInputTokens ?? 0
    }
    liveMessages.push({ role: 'assistant', content: turn.raw })

    if (turn.toolCalls.length === 0) {
      finalText = turn.text
      break
    }

    const toolResultBlocks: Array<{ type: 'tool_result'; tool_use_id: string; content: string }> = []
    for (const call of turn.toolCalls) {
      stats.toolCalls += 1
      let resultText: string
      if (call.name === 'generate_queue') {
        const outcome = await executeGenerateQueue(db, deps, session, call.input, sessionContext)
        resultText = outcome.resultText
        if (outcome.intent) lastGenerateIntent = outcome.intent
        if (outcome.queueChanged) {
          queueChanged = true
          currentVersion = outcome.newVersion!
        }
      } else if (call.name === 'edit_queue') {
        const outcome = await executeEditQueue(db, deps, session, call.input, userText, lastGenerateIntent, sessionContext)
        resultText = outcome.resultText
        if (outcome.queueChanged) {
          queueChanged = true
          currentVersion = outcome.newVersion!
        }
      } else {
        resultText = `unknown tool: ${call.name}`
      }
      toolResultBlocks.push({ type: 'tool_result', tool_use_id: call.id, content: resultText })
    }
    liveMessages.push({ role: 'user', content: toolResultBlocks })
  }

  return { text: finalText ?? FALLBACK_TEXT, queueChanged, queueVersion: currentVersion, stats }
}

async function attemptWithConflictRetry(db: Db, deps: DjDeps, session: DjSessionRef, userText: string): Promise<AttemptResult> {
  try {
    return await attemptTurn(db, deps, session, userText)
  } catch (e) {
    if (e instanceof QueueVersionConflict) {
      // Exactly one retry, from a fresh snapshot (attemptTurn re-reads
      // everything itself) — a second conflict means the queue is contested
      // enough that the caller should surface it rather than loop forever.
      return attemptTurn(db, deps, session, userText)
    }
    throw e
  }
}

function logTurn(sessionId: string, stats: AttemptStats | null, errorKind: DjError['kind'] | null): void {
  // Counts only — no message content, no track/tool payloads.
  console.log('dj turn', JSON.stringify({ sessionId, ...(stats ?? {}), error: errorKind }))
}

export async function runDjTurn(db: Db, deps: DjDeps, session: DjSessionRef, userText: string): Promise<DjTurnResult> {
  // Persisted first and unconditionally — the listener's own words stay in
  // the transcript no matter what happens next in this turn.
  await db.insert(djMessages).values({ sessionId: session.id, role: 'user', content: userText })

  let attempt: AttemptResult
  try {
    attempt = await attemptWithConflictRetry(db, deps, session, userText)
  } catch (e) {
    const djError = normalizeError(e)
    logTurn(session.id, null, djError.kind)
    throw djError
  }

  const [djMessageRow] = await db
    .insert(djMessages)
    .values({
      sessionId: session.id,
      role: 'dj',
      content: attempt.text,
      queueVersion: attempt.queueChanged ? attempt.queueVersion : null,
    })
    .returning()

  const queue = await getActiveQueue(db, session.id)
  logTurn(session.id, attempt.stats, null)
  return { djMessage: djMessageRow, queue, queueVersion: attempt.queueVersion }
}
