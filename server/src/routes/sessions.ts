import { TAPE_CASE_COLORS } from '../dj/tape-colors'
import { Hono, type Context, type MiddlewareHandler } from 'hono'
import { mixHistoryRoutes } from './mix-history'
import { z } from 'zod'
import { zValidator } from '@hono/zod-validator'
import { and, asc, desc, eq, sql } from 'drizzle-orm'
import type { AppVars } from '../app'
import type { Db } from '../db/types'
import { djSessions, djMessages, queueTracks, sessionEvents, tracks } from '../db/schema'
import { runDjTurn, DjError, type DjDeps, type DjSessionRef } from '../dj/loop'
import { runAlbumTurn, AlbumTurnError, type AlbumDeps, type AlbumTurnResult } from '../albums/loop'
import { AlbumStoreError, choosePick, goBack, readPickState, type AlbumPickState } from '../albums/store'
import { applyOps, getActiveQueue, QueueOpError, QueueVersionConflict } from '../dj/queue-store'
import { intentSchema, queueOpsSchema } from '../dj/contracts'
import { generateSessionTitle } from '../dj/title'
import { sanitizeTitleText } from '../dj/sanitize'
import { bodyLimit } from 'hono/body-limit'
import { ANONYMOUS_MIX_CAP, countUserSessions, createSessionWithPlaylistSeed, initialSeedSchema, PlaylistSeedError, readPlaylistSeed, selectPlaylistSeed, seedSelectionSchema } from '../playlists/seed'

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

// dj_sessions.id is a uuid column — handing Postgres a non-uuid string
// (e.g. a path segment like "not-a-uuid") throws an "invalid input syntax
// for type uuid" query error, which would otherwise surface as a 500. Every
// :id-scoped route pre-checks the shape so a malformed id resolves to the
// same 404 a missing-but-well-formed id gets, never a 500.
function isUuid(value: string): boolean {
  return UUID_RE.test(value)
}

// Thin wrapper over sanitizeTitleText (dj/sanitize.ts) with a non-empty
// fallback — the one thing that step doesn't itself decide, since PATCH
// /sessions/:id and the rename_session tool both want a REJECTION on an
// empty-after-sanitize title instead of a silent fallback. Exported for
// scripts/retitle-sessions.ts, which needs the exact same transform to
// recognize a session whose title is still this fallback (never overwritten
// by a generated title) as a backfill candidate.
export function titleFromPrompt(prompt: string): string {
  return sanitizeTitleText(prompt) || 'new session'
}

async function loadOwnedSession(db: Db, sessionId: string, userId: string) {
  if (!isUuid(sessionId)) return null
  const [row] = await db
    .select()
    .from(djSessions)
    .where(and(eq(djSessions.id, sessionId), eq(djSessions.userId, userId)))
  return row ?? null
}

// 'conflict' is the same queue-version race the manual queue-ops route
// reports as 409 (see QueueVersionConflict handling below) — same
// condition, same status, regardless of which route hit it. 'validation'
// (reserved, no construction site yet — see DjError's kind comment in
// dj/loop.ts) maps to 400 like any client-side input error. Everything else
// (an upstream LLM hiccup, a truncated curation, an unexpected internal
// fault) is a server-side condition the client can retry as-is — those map
// to 502.
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
  // sessionTitle rides this body the same way queue/queueVersion do — absent
  // (dropped by JSON.stringify) unless a rename_session call landed earlier
  // this turn before the failure that produced `e`. Without it, a client
  // whose turn renamed the session and then failed would keep showing the
  // stale AppBar title until its next unrelated fetch self-heals it — see
  // dj/loop.ts's DjError.sessionTitle comment.
  return { error: e.kind, message: e.message, queue: e.queue, queueVersion: e.queueVersion, sessionTitle: e.sessionTitle, ...extra }
}

// AlbumTurnError → status, mirroring djErrorStatus: a missing session is
// 404, a version race or a session of the other kind is 409, and everything
// else (Apple catalogue, model, internal) is a server-side condition the
// client can retry as-is, 502.
function albumErrorStatus(kind: AlbumTurnError['kind']): 404 | 409 | 502 {
  if (kind === 'not_found') return 404
  if (kind === 'conflict' || kind === 'wrong_kind') return 409
  return 502
}

// Same listener-ready message discipline as djErrorBody. The pick state rides
// along only when a version landed before the failure (AlbumTurnError.state).
function albumErrorBody(e: AlbumTurnError, extra: Record<string, unknown> = {}) {
  return {
    error: e.kind,
    message: e.message,
    step: e.step,
    sessionTitle: e.sessionTitle,
    ...(e.state ? pickStateBody(e.state) : {}),
    ...extra,
  }
}

function pickStateBody(state: AlbumPickState) {
  return { pick: state.pick, runnersUp: state.runnersUp, passed: state.passed, version: state.version }
}

// The album turn's response fields, shared by session creation and messages.
// suggestions and sessionTitle are present only when the turn set them.
function albumTurnBody(result: AlbumTurnResult) {
  return {
    pick: result.pick,
    runnersUp: result.runnersUp,
    passed: result.passed,
    version: result.version,
    ...(result.suggestions ? { suggestions: result.suggestions } : {}),
    ...(result.sessionTitle ? { sessionTitle: result.sessionTitle } : {}),
  }
}

const ALBUM_PICKS_OFF = { error: 'album_picks_off' } as const
const WRONG_SESSION_KIND = { error: 'wrong_session_kind' } as const

// energyArc stays accepted for both kinds and is ignored for album sessions.
// playlistSeed is accepted for album sessions too (the spec allows the
// attachment), though only mixes read it today.
const createSessionSchema = z.object({
  prompt: z.string().min(1).max(2000),
  playlistSeed: initialSeedSchema.optional(),
  energyArc: intentSchema.shape.energyArc,
  kind: z.enum(['mix', 'album']).default('mix'),
}).strict()
// Exactly one of albumId (choose a runner-up) or version (go back to an
// earlier shortlist), with optional fencing on the current version.
const pickSchema = z
  .object({
    albumId: z.uuid().optional(),
    version: z.number().int().min(1).max(2147483647).optional(),
    expectedVersion: z.number().int().min(0).max(2147483647).optional(),
  })
  .strict()
  .refine((b) => (b.albumId === undefined) !== (b.version === undefined), {
    message: 'exactly one of albumId or version is required',
  })
const messageSchema = z.object({ text: z.string().min(1).max(2000), energyArc: intentSchema.shape.energyArc })
const queueOpsBodySchema = z.object({
  ops: queueOpsSchema,
  expectedVersion: z.number().int().min(0).optional(),
})
// `title` is bounded 1..120 raw (mirrors rename_session's own tool-input
// bound in dj/contracts.ts) — the actual DISPLAY cap (60, sanitized) is
// applied in the handler via sanitizeTitleText, same discipline as
// titleFromPrompt. Fields may be sent independently or together; the refine below
// rejects a body carrying none (an empty PATCH is a client bug, not a
// silent no-op).
const patchSessionSchema = z
  .object({
    status: z.union([z.literal('active'), z.literal('archived')]).optional(),
    title: z.string().min(1).max(120).optional(),
    caseColor: z.enum(TAPE_CASE_COLORS).optional(),
  })
  .refine((data) => data.status !== undefined || data.title !== undefined || data.caseColor !== undefined, {
    message: 'at least one of status, title or caseColor is required',
  })
const sessionEventSchema = z.object({ type: z.union([z.literal('played'), z.literal('saved_playlist')]) })

const MANUAL_OPS_HINT = 'swap/extend require the DJ — send a message instead'

// The list-row shape: what GET /sessions returns per row, and what POST /
// and PATCH /:id echo back for the ONE session they touched — one shape
// everywhere a session is summarized, rather than three routes each
// inventing their own subset of its columns. (GET /:id returns the full row,
// a superset of this.)
const sessionListColumns = {
  id: djSessions.id,
  title: djSessions.title,
  caseColor: djSessions.caseColor,
  status: djSessions.status,
  queueVersion: djSessions.queueVersion,
  // True once a corpus-mode generate/swap has put shared-catalog picks in
  // this session's queue (dj/loop.ts markNotPersonal) — the client's "not
  // personal yet" banner reads this off every summary, so a listener sees
  // it in the collection list, not only inside the open session.
  notPersonal: djSessions.notPersonal,
  // 'mix' | 'album': which loop, read shape and routes the session takes.
  kind: djSessions.kind,
  updatedAt: djSessions.updatedAt,
}

// Where a turn's request came from, for the catalogue fill's funnel row. The
// native app talks to the API through Dart's HTTP client, whose default
// User-Agent is "Dart/<version> (dart:io)"; anything else is the web.
export function requestSurface(userAgent: string | undefined): 'ios' | 'web' {
  return userAgent?.startsWith('Dart/') ? 'ios' : 'web'
}

// albumDeps is present only with ALBUM_PICKS on (src/index.ts); absent, album
// sessions are refused with album_picks_off and mixes are untouched.
export function sessionRoutes(db: Db, deps: DjDeps, albumDeps?: AlbumDeps) {
  const app = new Hono<{ Variables: AppVars }>()
  app.route('/', mixHistoryRoutes(db))

  // Newest 200 by seq; callers reverse back to chronological order for the
  // response — a long-running session must keep showing its RECENT
  // transcript as it grows, not pin forever to whatever the first 200
  // messages happened to be.
  function recentMessages(sessionId: string) {
    return db
      .select()
      .from(djMessages)
      .where(eq(djMessages.sessionId, sessionId))
      .orderBy(desc(djMessages.seq))
      .limit(200)
  }

  // The album twin of the mix creation path below: same persist-first row,
  // same concurrent title job (allSettled, an explicit rename wins), one
  // closing UPDATE. Only the turn and the response shape differ.
  async function createAlbumSession(
    c: Context<{ Variables: AppVars }>,
    albumDeps: AlbumDeps,
    userId: string,
    prompt: string,
    playlistSeed: z.infer<typeof initialSeedSchema> | undefined,
  ) {
    const fallbackTitle = titleFromPrompt(prompt)
    let session
    try {
      session = await createSessionWithPlaylistSeed(db, userId, fallbackTitle, playlistSeed, 'album')
    } catch (e) {
      if (e instanceof PlaylistSeedError) return c.json({ error: e.kind }, e.kind === 'not_found' ? 404 : 409)
      throw e
    }
    const titlePromise = albumDeps.titleComplete
      ? generateSessionTitle(albumDeps.titleComplete, prompt, fallbackTitle)
      : Promise.resolve(fallbackTitle)
    const [turnResult, titleResult] = await Promise.allSettled([
      runAlbumTurn(db, albumDeps, { id: session.id, userId }, prompt),
      titlePromise,
    ])
    const renamedTitle =
      turnResult.status === 'fulfilled'
        ? turnResult.value.sessionTitle
        : turnResult.reason instanceof AlbumTurnError
          ? turnResult.reason.sessionTitle
          : undefined
    const title = renamedTitle ?? (titleResult.status === 'fulfilled' ? titleResult.value : fallbackTitle)
    const [sessionRow] = await db
      .update(djSessions)
      .set({ updatedAt: new Date(), title })
      .where(eq(djSessions.id, session.id))
      .returning(sessionListColumns)

    if (turnResult.status === 'rejected') {
      const e = turnResult.reason
      if (e instanceof AlbumTurnError) {
        return c.json(albumErrorBody(e, { sessionId: session.id }), albumErrorStatus(e.kind))
      }
      throw e
    }
    const messages = await db
      .select()
      .from(djMessages)
      .where(eq(djMessages.sessionId, session.id))
      .orderBy(asc(djMessages.seq))
    return c.json({ session: sessionRow, messages, ...albumTurnBody(turnResult.value) })
  }

  app.put('/:id/playlist-seed', bodyLimit({ maxSize: 2048 }), zValidator('json', seedSelectionSchema), async c => {
    const id = c.req.param('id')
    if (!isUuid(id)) return c.json({ error: 'not_found' }, 404)
    try {
      return c.json({ playlistSeed: await selectPlaylistSeed(db, id, c.get('user').id, c.req.valid('json')) })
    } catch (e) {
      if (!(e instanceof PlaylistSeedError)) throw e
      return c.json({ error: e.kind }, e.kind === 'not_found' ? 404 : 409)
    }
  })

  app.post('/', zValidator('json', createSessionSchema), async (c) => {
    const { prompt, playlistSeed, energyArc, kind } = c.req.valid('json')
    const { id: userId, isAnonymous } = c.get('user')
    if (kind === 'album') {
      // Both refusals land before any write, count or model call.
      if (!albumDeps) return c.json(ALBUM_PICKS_OFF, 404)
      // Decision 2026-10-20: album mode stays out of the anonymous flow.
      if (isAnonymous) return c.json({ error: 'anonymous_albums' }, 403)
      return createAlbumSession(c, albumDeps, userId, prompt, playlistSeed)
    }
    // Checked before any insert or model call: a capped request costs one
    // count and nothing else. Only new mixes are capped; follow-ups, queue
    // ops and edits on an existing session are not.
    if (isAnonymous && (await countUserSessions(db, userId)) >= ANONYMOUS_MIX_CAP) {
      return c.json({ error: 'anonymous_cap', limit: ANONYMOUS_MIX_CAP }, 403)
    }
    const fallbackTitle = titleFromPrompt(prompt)

    // Persist-first: the session row (and, inside runDjTurn, the user's own
    // message) exist before the first turn runs — a failure below still
    // leaves the listener with a session they can reopen and retry, rather
    // than losing their prompt to an LLM hiccup. Starts with the durable
    // truncated-prompt title; replaced below only once the Haiku-generated
    // name (run concurrently with the turn) resolves.
    let session
    try {
      session = await createSessionWithPlaylistSeed(db, userId, fallbackTitle, playlistSeed)
    } catch (e) {
      if (e instanceof PlaylistSeedError) return c.json({ error: e.kind }, e.kind === 'not_found' ? 404 : 409)
      throw e
    }
    const sessionRef: DjSessionRef = { id: session.id, userId }

    // A naming call, not curation (see dj/title.ts) — run CONCURRENTLY with
    // the DJ turn, bounded to a 5s worst case via generateSessionTitle's
    // timeoutMs (dj/title.ts), so it adds at most that much to session
    // creation rather than the turn's own latency. generateSessionTitle
    // never throws and always resolves to at least fallbackTitle, so this
    // can never fail the turn below; no deps.titleComplete wired (e.g. a
    // caller that only set up the tool-loop LlmClient) degrades the same
    // way, via the same fallback.
    const titlePromise = deps.titleComplete
      ? generateSessionTitle(deps.titleComplete, prompt, fallbackTitle)
      : Promise.resolve(fallbackTitle)

    // allSettled, not all: the title must land on the row even when the DJ
    // turn itself fails — that's exactly when the listener will reopen the
    // session and retry, and the row must not still be showing the
    // truncated fallback. titlePromise itself never rejects (see above), but
    // allSettled keeps that guarantee explicit rather than relying on it.
    const [turnResult, titleResult] = await Promise.allSettled([runDjTurn(db, deps, sessionRef, prompt, { energyArc, surface: requestSurface(c.req.header('User-Agent')) }), titlePromise])

    // A rename_session call within this very first turn (unusual, but the
    // listener COULD open with "call this tape Lagos Nights") wins over the
    // concurrently-generated Haiku title — an explicit rename is a stronger
    // signal than the auto-naming pass, and the auto-generated title must
    // never clobber it on the write below. Checked on the REJECTED branch
    // too (DjError.sessionTitle, dj/loop.ts) — the rename's DB write already
    // landed before whatever later failed this turn (a conflict that
    // persisted through the retry, a curation error, ...), so a failed turn
    // must never overwrite that persisted rename with the Haiku title here.
    const renamedTitle =
      turnResult.status === 'fulfilled'
        ? turnResult.value.sessionTitle
        : turnResult.reason instanceof DjError
          ? turnResult.reason.sessionTitle
          : undefined
    const title = renamedTitle ?? (titleResult.status === 'fulfilled' ? titleResult.value : fallbackTitle)

    // A text-only first turn never touches dj_sessions itself (no queue
    // write to ride $onUpdate's automatic bump) — bumped explicitly, same as
    // the message-turn route below, so list ordering (newest first by
    // updatedAt) reflects even a chat-only first turn. The generated (or
    // renamed) title rides this same UPDATE (one write, not two), written
    // UNCONDITIONALLY — both promises have already settled by this point, so
    // whatever queue writes runDjTurn made (or didn't, on failure) are done:
    // this UPDATE (touching only updatedAt/title) can't race
    // dj/queue-store.ts's queueVersion write either way.
    const [sessionRow] = await db
      .update(djSessions)
      .set({ updatedAt: new Date(), title })
      .where(eq(djSessions.id, session.id))
      .returning(sessionListColumns)

    if (turnResult.status === 'rejected') {
      const e = turnResult.reason
      if (e instanceof DjError) {
        return c.json(djErrorBody(e, { sessionId: session.id }), djErrorStatus(e.kind))
      }
      throw e
    }

    const messages = await db
      .select()
      .from(djMessages)
      .where(eq(djMessages.sessionId, session.id))
      .orderBy(asc(djMessages.seq))
    return c.json({
      session: sessionRow,
      messages,
      queue: turnResult.value.queue,
      // Same capability flag GET /:id carries (see its comment): a mix
      // opened straight from creation must be able to offer Undo without a
      // refetch, so both session-detail shapes advertise it.
      supportsInsert: true,
      playlistSeed: await readPlaylistSeed(db, session.id, userId),
      // Present ONLY when rename_session actually fired this turn — lets the
      // client adopt the new title without a refetch (see
      // dj_providers.dart's ChatNotifier). Omitted entirely on a no-rename
      // turn, never sent as null.
      ...(renamedTitle ? { sessionTitle: renamedTitle } : {}),
    })
  })

  app.get('/', async (c) => {
    const userId = c.get('user').id
    // Archived sessions are included here on purpose — the client filters
    // by `status` for its default view; this is the one list endpoint, not
    // two.
    const sessions = await db
      .select({
        ...sessionListColumns,
        // Only active queue entries count: removed songs are history, not
        // part of the tape a listener sees in the collection.
        trackCount: sql<number>`count(${queueTracks.id})::int`,
        durationMs: sql<number>`coalesce(sum(${tracks.durationMs}), 0)::int`,
        // Album sessions: the current pick (the latest version's rank 0) for
        // the Mixes list, null before the first pick. Correlated on the
        // grouped primary key, so this stays one statement.
        pick: sql<{ title: string; artist: string; artwork: unknown } | null>`(
          SELECT json_build_object(
            'title', a.title,
            'artist', a.artist,
            'artwork', CASE WHEN a.artwork_url_template IS NULL THEN NULL ELSE json_build_object(
              'url', a.artwork_url_template, 'width', a.artwork_width,
              'height', a.artwork_height, 'bgColor', a.artwork_bg_color) END)
          FROM album_picks ap
          JOIN albums a ON a.id = ap.album_id
          WHERE ap.session_id = ${djSessions.id} AND ap.rank = 0
          ORDER BY ap.version DESC
          LIMIT 1
        )`,
      })
      .from(djSessions)
      .leftJoin(
        queueTracks,
        and(eq(queueTracks.sessionId, djSessions.id), eq(queueTracks.state, 'active')),
      )
      .leftJoin(tracks, eq(tracks.id, queueTracks.trackId))
      .where(eq(djSessions.userId, userId))
      .groupBy(djSessions.id)
      .orderBy(desc(djSessions.updatedAt))
      .limit(50)
    return c.json({
      sessions: sessions.map(({ pick, ...row }) => (row.kind === 'album' ? { ...row, pick: pick ?? null } : row)),
    })
  })

  app.get('/:id', async (c) => {
    const userId = c.get('user').id
    const session = await loadOwnedSession(db, c.req.param('id'), userId)
    if (!session) return c.json({ error: 'not_found' }, 404)

    if (session.kind === 'album') {
      const [newestFirst, state, playlistSeed] = await Promise.all([
        recentMessages(session.id),
        readPickState(db, session.id, userId),
        readPlaylistSeed(db, session.id, userId),
      ])
      return c.json({ session, messages: newestFirst.reverse(), ...pickStateBody(state), playlistSeed })
    }

    const [newestFirst, queue] = await Promise.all([
      recentMessages(session.id),
      getActiveQueue(db, session.id),
    ])
    const messages = newestFirst.reverse()
    // supportsInsert is a CAPABILITY flag, not session state: it tells the
    // arrangement screen whether this server understands the `insert` queue
    // op, i.e. whether a swipe-remove may offer Undo
    // (docs/mockups/approved/2026-09-17-mobile-arrangement-states.md). It
    // rides the session detail rather than the queue-ops response so the
    // client knows BEFORE it shows the affordance — and because
    // QueueOpsResult's shape is a settled contract the client parses
    // strictly. A client talking to an older deploy simply never sees the
    // key and keeps Undo hidden.
    return c.json({
      session,
      messages,
      queue,
      supportsInsert: true,
      playlistSeed: await readPlaylistSeed(db, session.id, userId),
    })
  })

  // Archiving is client-side-only bookkeeping — no queue/message side
  // effects, no LLM call, just the `status` column. GET /sessions still
  // returns archived rows (the client filters); this route only changes
  // which bucket a session sits in. A `title` rename rides the same PATCH —
  // manual (from Home) rather than the DJ's own rename_session tool
  // (dj/loop.ts), but both land on the identical sanitize-then-write step.
  app.patch('/:id', zValidator('json', patchSessionSchema), async (c) => {
    const userId = c.get('user').id
    const session = await loadOwnedSession(db, c.req.param('id'), userId)
    if (!session) return c.json({ error: 'not_found' }, 404)

    const { status, title, caseColor } = c.req.valid('json')
    const updates: { status?: 'active' | 'archived'; title?: string; caseColor?: string } = {}
    if (caseColor !== undefined) updates.caseColor = caseColor
    if (status !== undefined) updates.status = status
    if (title !== undefined) {
      // min(1) above only rejects a literally-empty string — a
      // whitespace-only title (or one that sanitizes down to nothing, e.g.
      // all control characters) still needs its own rejection here.
      const sanitized = sanitizeTitleText(title)
      if (!sanitized) return c.json({ error: 'invalid_title', message: 'title cannot be empty' }, 400)
      updates.title = sanitized
    }
    // Also bumps updatedAt via djSessions' own $onUpdate (db/schema.ts) even
    // for a title-only or colour-only PATCH — editing mix settings
    // reorders the session to the top of GET /sessions' newest-first list.
    const [updated] = await db
      .update(djSessions)
      .set(updates)
      .where(eq(djSessions.id, session.id))
      .returning(sessionListColumns)
    return c.json({ session: updated })
  })

  // Raw listen/save signals from the client — fire-and-forget on its side
  // (P4 Task 1). No dedupe: multiple plays of the same session are multiple
  // taste signals, intentionally counted more than once downstream.
  app.post('/:id/events', zValidator('json', sessionEventSchema), async (c) => {
    const userId = c.get('user').id
    const session = await loadOwnedSession(db, c.req.param('id'), userId)
    if (!session) return c.json({ error: 'not_found' }, 404)

    const { type } = c.req.valid('json')
    await db.insert(sessionEvents).values({ sessionId: session.id, type })
    return c.json({ ok: true })
  })

  app.post('/:id/messages', zValidator('json', messageSchema), async (c) => {
    const userId = c.get('user').id
    const session = await loadOwnedSession(db, c.req.param('id'), userId)
    if (!session) return c.json({ error: 'not_found' }, 404)

    const { text, energyArc } = c.req.valid('json')
    const sessionRef: DjSessionRef = { id: session.id, userId }
    if (session.kind === 'album') {
      if (!albumDeps) return c.json(ALBUM_PICKS_OFF, 404)
      try {
        const result = await runAlbumTurn(db, albumDeps, sessionRef, text)
        await db.update(djSessions).set({ updatedAt: new Date() }).where(eq(djSessions.id, session.id))
        return c.json({ djMessage: result.djMessage, ...albumTurnBody(result) })
      } catch (e) {
        if (e instanceof AlbumTurnError) return c.json(albumErrorBody(e), albumErrorStatus(e.kind))
        throw e
      }
    }
    try {
      const result = await runDjTurn(db, deps, sessionRef, text, { energyArc, surface: requestSurface(c.req.header('User-Agent')) })
      // A text-only reply never touches dj_sessions itself (no queue write
      // to ride $onUpdate's automatic bump), so list ordering (newest first
      // by updatedAt) would otherwise never reflect a chat-only turn.
      await db.update(djSessions).set({ updatedAt: new Date() }).where(eq(djSessions.id, session.id))
      return c.json({
        djMessage: result.djMessage,
        queue: result.queue,
        queueVersion: result.queueVersion,
        // Same contract as POST /sessions above: present ONLY when
        // rename_session fired this turn.
        ...(result.sessionTitle ? { sessionTitle: result.sessionTitle } : {}),
      })
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
    if (session.kind !== 'mix') return c.json(WRONG_SESSION_KIND, 409)

    const { ops, expectedVersion } = c.req.valid('json')
    // Manual queue-ops never carry an LLM call — swap/extend need one (to
    // pick a replacement), so they're only reachable through a DJ message
    // turn. remove/move/insert all name exactly what they act on, so they
    // stay here (insert is in fact manual-ONLY — see dj/contracts.ts).
    // Checked up front rather than left to applyOps's own
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

  // Choose a runner-up ({ albumId }) or go back to an earlier shortlist
  // ({ version }). No model call: the store writes a new version from rows it
  // already holds, fenced on expectedVersion like queue ops.
  // The flag is checked ahead of the body validator, so a bad body with the
  // flag off still answers album_picks_off.
  const albumPicksOn: MiddlewareHandler = async (c, next) => {
    if (!albumDeps) return c.json(ALBUM_PICKS_OFF, 404)
    await next()
  }
  app.post('/:id/pick', albumPicksOn, zValidator('json', pickSchema), async (c) => {
    const userId = c.get('user').id
    const session = await loadOwnedSession(db, c.req.param('id'), userId)
    if (!session) return c.json({ error: 'not_found' }, 404)
    if (session.kind !== 'album') return c.json(WRONG_SESSION_KIND, 409)

    const { albumId, version, expectedVersion } = c.req.valid('json')
    try {
      const state = albumId !== undefined
        ? await choosePick(db, { sessionId: session.id, userId, albumId, expectedVersion })
        : await goBack(db, { sessionId: session.id, userId, version: version!, expectedVersion })
      return c.json(pickStateBody(state))
    } catch (e) {
      if (!(e instanceof AlbumStoreError)) throw e
      if (e.kind === 'not_found') return c.json({ error: 'not_found' }, 404)
      if (e.kind === 'wrong_kind') return c.json(WRONG_SESSION_KIND, 409)
      const [current] = await db
        .select({ version: djSessions.queueVersion })
        .from(djSessions)
        .where(eq(djSessions.id, session.id))
      return c.json({ error: 'stale', version: current?.version }, 409)
    }
  })

  return app
}
