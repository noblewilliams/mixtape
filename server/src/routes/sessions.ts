import { Hono } from 'hono'
import { z } from 'zod'
import { zValidator } from '@hono/zod-validator'
import { and, asc, desc, eq } from 'drizzle-orm'
import type { AppVars } from '../app'
import type { Db } from '../db/types'
import { djSessions, djMessages } from '../db/schema'
import { runDjTurn, DjError, type DjDeps, type DjSessionRef } from '../dj/loop'
import { applyOps, getActiveQueue, QueueOpError, QueueVersionConflict } from '../dj/queue-store'
import { queueOpsSchema } from '../dj/contracts'

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

// dj_sessions.id is a uuid column — handing Postgres a non-uuid string
// (e.g. a path segment like "not-a-uuid") throws an "invalid input syntax
// for type uuid" query error, which would otherwise surface as a 500. Every
// :id-scoped route pre-checks the shape so a malformed id resolves to the
// same 404 a missing-but-well-formed id gets, never a 500.
function isUuid(value: string): boolean {
  return UUID_RE.test(value)
}

// Strips control characters (including newlines — a crafted prompt could
// otherwise fake a multi-line title) and caps length, mirroring
// dj/sanitize.ts's treatment of track titles before they reach an LLM
// prompt — applied here to the session's own display title instead.
function titleFromPrompt(prompt: string): string {
  const cleaned = prompt.replace(/\p{C}+/gu, ' ').trim()
  return (cleaned.slice(0, 60) || 'new session').trim()
}

async function loadOwnedSession(db: Db, sessionId: string, userId: string) {
  if (!isUuid(sessionId)) return null
  const [row] = await db
    .select()
    .from(djSessions)
    .where(and(eq(djSessions.id, sessionId), eq(djSessions.userId, userId)))
  return row ?? null
}

// DjError.kind is 'llm' | 'curation' | 'conflict' | 'validation' | 'internal'.
// 'validation' means the request itself was malformed in a way runDjTurn
// detected — a 400, same as any other client-side input error. 'conflict' is
// the same queue-version race the manual queue-ops route reports as 409
// (see QueueVersionConflict handling below) — same condition, same status,
// regardless of which route hit it. Everything else (an upstream LLM hiccup,
// a truncated curation, an unexpected internal fault) is a server-side
// condition the client can retry as-is — those map to 502.
function djErrorStatus(kind: DjError['kind']): 400 | 409 | 502 {
  if (kind === 'validation') return 400
  if (kind === 'conflict') return 409
  return 502
}

// `e.message` is always listener-ready: a short, fixed apology a P3b chat
// bubble can render verbatim as `e.message` with no further formatting —
// never the LLM's raw error text, a curation parse failure, a "dj:"-prefixed
// dev string, or any other diagnostic detail (status codes included). `kind`
// carries the only diagnostic this body needs; see dj/loop.ts's DjError
// class comment and normalizeError for where each kind's copy is set.
function djErrorBody(e: DjError, extra: Record<string, unknown> = {}) {
  return { error: e.kind, message: e.message, queue: e.queue, queueVersion: e.queueVersion, ...extra }
}

const createSessionSchema = z.object({ prompt: z.string().min(1).max(2000) })
const messageSchema = z.object({ text: z.string().min(1).max(2000) })
const queueOpsBodySchema = z.object({
  ops: queueOpsSchema,
  expectedVersion: z.number().int().min(0).optional(),
})

const MANUAL_OPS_HINT = 'swap/extend require the DJ — send a message instead'

export function sessionRoutes(db: Db, deps: DjDeps) {
  const app = new Hono<{ Variables: AppVars }>()

  app.post('/', zValidator('json', createSessionSchema), async (c) => {
    const { prompt } = c.req.valid('json')
    const userId = c.get('user').id
    const title = titleFromPrompt(prompt)

    // Persist-first: the session row (and, inside runDjTurn, the user's own
    // message) exist before the first turn runs — a failure below still
    // leaves the listener with a session they can reopen and retry, rather
    // than losing their prompt to an LLM hiccup.
    const [session] = await db.insert(djSessions).values({ userId, title }).returning()
    const sessionRef: DjSessionRef = { id: session.id, userId }

    try {
      const result = await runDjTurn(db, deps, sessionRef, prompt)
      const messages = await db
        .select()
        .from(djMessages)
        .where(eq(djMessages.sessionId, session.id))
        .orderBy(asc(djMessages.seq))
      return c.json({
        session: { id: session.id, title: session.title, queueVersion: result.queueVersion },
        messages,
        queue: result.queue,
      })
    } catch (e) {
      if (e instanceof DjError) {
        return c.json(djErrorBody(e, { sessionId: session.id }), djErrorStatus(e.kind))
      }
      throw e
    }
  })

  app.get('/', async (c) => {
    const userId = c.get('user').id
    const sessions = await db
      .select({
        id: djSessions.id,
        title: djSessions.title,
        status: djSessions.status,
        queueVersion: djSessions.queueVersion,
        updatedAt: djSessions.updatedAt,
      })
      .from(djSessions)
      .where(eq(djSessions.userId, userId))
      .orderBy(desc(djSessions.updatedAt))
      .limit(50)
    return c.json({ sessions })
  })

  app.get('/:id', async (c) => {
    const userId = c.get('user').id
    const session = await loadOwnedSession(db, c.req.param('id'), userId)
    if (!session) return c.json({ error: 'not_found' }, 404)

    const [newestFirst, queue] = await Promise.all([
      // Newest 200 by seq, then reversed back to chronological order for the
      // response — a long-running session must keep showing its RECENT
      // transcript as it grows, not pin forever to whatever the first 200
      // messages happened to be.
      db
        .select()
        .from(djMessages)
        .where(eq(djMessages.sessionId, session.id))
        .orderBy(desc(djMessages.seq))
        .limit(200),
      getActiveQueue(db, session.id),
    ])
    const messages = newestFirst.reverse()
    return c.json({ session, messages, queue })
  })

  app.post('/:id/messages', zValidator('json', messageSchema), async (c) => {
    const userId = c.get('user').id
    const session = await loadOwnedSession(db, c.req.param('id'), userId)
    if (!session) return c.json({ error: 'not_found' }, 404)

    const { text } = c.req.valid('json')
    const sessionRef: DjSessionRef = { id: session.id, userId }
    try {
      const result = await runDjTurn(db, deps, sessionRef, text)
      // A text-only reply never touches dj_sessions itself (no queue write
      // to ride $onUpdate's automatic bump), so list ordering (newest first
      // by updatedAt) would otherwise never reflect a chat-only turn.
      await db.update(djSessions).set({ updatedAt: new Date() }).where(eq(djSessions.id, session.id))
      return c.json({ djMessage: result.djMessage, queue: result.queue, queueVersion: result.queueVersion })
    } catch (e) {
      if (e instanceof DjError) {
        return c.json(djErrorBody(e), djErrorStatus(e.kind))
      }
      throw e
    }
  })

  app.post('/:id/queue-ops', zValidator('json', queueOpsBodySchema), async (c) => {
    const userId = c.get('user').id
    const session = await loadOwnedSession(db, c.req.param('id'), userId)
    if (!session) return c.json({ error: 'not_found' }, 404)

    const { ops, expectedVersion } = c.req.valid('json')
    // Manual queue-ops never carry an LLM call — swap/extend need one (to
    // pick a replacement), so they're only reachable through a DJ message
    // turn. Checked up front rather than left to applyOps's own
    // no-replacementsProvider QueueOpError so the client gets a message
    // that tells it what to do instead of a content-free "invalid op".
    if (ops.some((op) => op.op === 'swap' || op.op === 'extend')) {
      return c.json({ error: 'dj_required', message: MANUAL_OPS_HINT }, 400)
    }

    try {
      const result = await applyOps(db, session.id, ops, 'user', undefined, expectedVersion)
      // applyOps always bumps queueVersion via its own update (riding
      // $onUpdate), but that's an implementation detail of the store, not a
      // contract this route should lean on — touched explicitly here too,
      // symmetric with the message-turn route above.
      await db.update(djSessions).set({ updatedAt: new Date() }).where(eq(djSessions.id, session.id))
      const queue = await getActiveQueue(db, session.id)
      return c.json({
        queueVersion: result.version,
        requested: result.requested,
        added: result.added,
        removed: result.removed,
        queue,
      })
    } catch (e) {
      if (e instanceof QueueVersionConflict) {
        const [queue, [current]] = await Promise.all([
          getActiveQueue(db, session.id),
          db.select({ queueVersion: djSessions.queueVersion }).from(djSessions).where(eq(djSessions.id, session.id)),
        ])
        return c.json({ error: 'stale', queue, queueVersion: current?.queueVersion }, 409)
      }
      if (e instanceof QueueOpError) {
        return c.json({ error: 'invalid_ops' }, 400)
      }
      throw e
    }
  })

  return app
}
