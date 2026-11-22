import { randomUUID } from 'node:crypto'
import { TAPE_CASE_COLORS } from '../dj/tape-colors'
import { Hono, type Context, type MiddlewareHandler } from 'hono'
import { mixHistoryRoutes } from './mix-history'
import { z } from 'zod'
import { zValidator } from '@hono/zod-validator'
import { and, asc, desc, eq, inArray, sql } from 'drizzle-orm'
import type { AppVars } from '../app'
import type { Db } from '../db/types'
import { djSessions, djMessages, queueTracks, sessionEvents, tracks } from '../db/schema'
import { insertUserMessage, type DjDeps, type DjSessionRef, type DjTurnOptions } from '../dj/loop'
import { requestStop, type TurnStopTiming } from '../dj/turn-stop'
import { streamTurn, wantsTurnStream } from './turn-stream'
import { createMixTurn, mixMessageTurn, sessionListColumns, sessionListRow, titleFromPrompt } from './turn-bodies'
import { runAlbumTurn, AlbumTurnError, type AlbumDeps, type AlbumTurnResult } from '../albums/loop'
import { AlbumStoreError, choosePick, goBack, readPickState, type AlbumPickState } from '../albums/store'
import { applyOps, getActiveQueue, QueueOpError, QueueVersionConflict } from '../dj/queue-store'
import { intentSchema, queueOpsSchema } from '../dj/contracts'
import { generateSessionTitle } from '../dj/title'
import { isUsableName } from '../auth/profile-name'
import { createOrReuseShare, hasActiveShare, revokeShares } from '../shares/store'
import { sanitizeTitleText } from '../dj/sanitize'
import {
  INVALID_IDEMPOTENCY_KEY,
  isUniqueViolation,
  liveTurnColumn,
  queueTurnRow,
  readIdempotencyKey,
  readLiveTurn,
  replayForKey,
  startDurableTurn,
  turnRoutes,
  type DurableTurnsWiring,
} from './turns'
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

// titleFromPrompt lives beside the turn builders (turn-bodies.ts), since the
// durable turn job derives a create's fallback title from the stored prompt
// too; re-exported here for scripts/retitle-sessions.ts.
export { titleFromPrompt }

async function loadOwnedSession(db: Db, sessionId: string, userId: string) {
  if (!isUuid(sessionId)) return null
  const [row] = await db
    .select()
    .from(djSessions)
    .where(and(eq(djSessions.id, sessionId), eq(djSessions.userId, userId)))
  return row ?? null
}

// AlbumTurnError → status, mirroring djErrorStatus (turn-bodies.ts): a
// missing session is 404, a version race or a session of the other kind is
// 409, and everything else (Apple catalogue, model, internal) is a
// server-side condition the client can retry as-is, 502.
function albumErrorStatus(kind: AlbumTurnError['kind']): 404 | 409 | 502 {
  if (kind === 'not_found') return 404
  if (kind === 'conflict' || kind === 'wrong_kind') return 409
  return 502
}

// Same listener-ready message discipline as djErrorBody (turn-bodies.ts).
// The pick state rides along only when a version landed before the failure
// (AlbumTurnError.state).
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
// remake: the "Remake with my music" tap (spec 2026-11-09
// add-your-music-loop, decision 4). Mix sessions only. The clients send fixed
// text with it, but only this flag means anything: the text is never read.
const messageSchema = z.object({
  text: z.string().min(1).max(2000),
  energyArc: intentSchema.shape.energyArc,
  remake: z.boolean().optional(),
})
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
// One select-mode action: at most the 50 mixes GET /sessions lists, with room.
const deleteSessionsSchema = z.object({ ids: z.array(z.uuid()).min(1).max(100) })
// How long a delete waits for a running turn to undo itself before deleting.
const DELETE_STOP_WAIT_MS = 5_000
const sessionEventSchema = z.object({ type: z.union([z.literal('played'), z.literal('saved_playlist')]) })

const MANUAL_OPS_HINT = 'swap/extend require the DJ — send a message instead'

// Where a turn's request came from, for the catalogue fill's funnel row. The
// native app talks to the API through Dart's HTTP client, whose default
// User-Agent is "Dart/<version> (dart:io)"; anything else is the web.
export function requestSurface(userAgent: string | undefined): 'ios' | 'web' {
  return userAgent?.startsWith('Dart/') ? 'ios' : 'web'
}

// albumDeps is present only with ALBUM_PICKS on (src/index.ts); absent, album
// sessions are refused with album_picks_off and mixes are untouched.
// share carries SHARE_BASE_URL; absent, the share routes are not mounted.

// stopTiming is for tests: how a stop request waits for the turn to let go.
// durable is present only with DURABLE_TURNS on (src/index.ts): mix turns
// then run in the session's TurnRunner object (routes/turns.ts). Absent,
// every path below is the in-request one.
export function sessionRoutes(db: Db, deps: DjDeps, albumDeps?: AlbumDeps, share?: { baseUrl: string }, stopTiming?: TurnStopTiming, durable?: DurableTurnsWiring) {
  const app = new Hono<{ Variables: AppVars }>()

  // Reads the Idempotency-Key and attaches a replay to its turn (spec
  // 2026-11-21 durable-mix-turns, "Start", 1). `response` answers the
  // request (a 400, or the replay); otherwise `turnId` is the new turn's id.
  async function keyedTurn(
    c: Context<{ Variables: AppVars }>,
    durable: DurableTurnsWiring,
    scope: { userId: string; sessionId?: string },
  ): Promise<{ response: Response } | { response?: undefined; turnId: string; keyed: boolean }> {
    const read = readIdempotencyKey(c)
    if (!read.ok) return { response: c.json(INVALID_IDEMPOTENCY_KEY, 400) }
    if (read.key) {
      const replay = await replayForKey(c, db, durable, read.key, scope)
      if (replay) return { response: replay }
    }
    return { turnId: read.key ?? randomUUID(), keyed: read.key !== undefined }
  }

  // Permanent delete of the listener's chosen mixes (select mode on the
  // Mixes list). Registered before mix history, whose '/:id/*' guard would
  // otherwise 404 this path as a malformed id. Everything hanging off a
  // session cascades (messages, queue, versions, shares and their saves).
  // Ids the listener doesn't own are skipped silently, never reported.
  // Anonymous listeners can't delete: the free-mix cap counts the rows they
  // have, so deleting would reset it. A mix with a turn still running is
  // stopped first (bounded wait), so the turn never writes into a session
  // that has gone; a turn that outlives the wait sees it gone on finish.
  app.post('/delete', zValidator('json', deleteSessionsSchema), async (c) => {
    const { id: userId, isAnonymous } = c.get('user')
    if (isAnonymous) return c.json({ error: 'sign_in_required' }, 403)
    const owned = await db
      .select({ id: djSessions.id, activeTurnId: djSessions.activeTurnId })
      .from(djSessions)
      .where(and(eq(djSessions.userId, userId), inArray(djSessions.id, c.req.valid('json').ids)))
    await Promise.all(owned
      .filter((s) => s.activeTurnId != null)
      .map((s) => requestStop(db, s.id, { timeoutMs: DELETE_STOP_WAIT_MS, ...stopTiming })))
    if (owned.length === 0) return c.json({ deleted: [] })
    const deleted = await db
      .delete(djSessions)
      .where(and(eq(djSessions.userId, userId), inArray(djSessions.id, owned.map((s) => s.id))))
      .returning({ id: djSessions.id })
    return c.json({ deleted: deleted.map((r) => r.id) })
  })

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

  // The album twin of the mix creation path (turn-bodies.ts createMixTurn):
  // same persist-first row, same concurrent title job (allSettled, an
  // explicit rename wins), one closing UPDATE. Only the turn and the
  // response shape differ.
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

  // Stops the mix turn running on this session and answers once it has been
  // undone (spec 2026-11-15 stop-a-turn). { stopped: false }: nothing was
  // running, the turn finished first; the client re-reads the session. No
  // model call, so no AI consent gate (app.ts gates /sessions itself only).
  app.post('/:id/turn/stop', async (c) => {
    const session = await loadOwnedSession(db, c.req.param('id'), c.get('user').id)
    if (!session) return c.json({ error: 'not_found' }, 404)
    return c.json({ stopped: await requestStop(db, session.id, stopTiming) })
  })

  if (durable) app.route('/', turnRoutes(db, durable, (id, userId) => loadOwnedSession(db, id, userId)))

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
    // A replay is answered before the cap: the mix it names already counts.
    let keyed: { turnId: string; keyed: boolean } | undefined
    if (durable) {
      const read = await keyedTurn(c, durable, { userId })
      if (read.response) return read.response
      keyed = { turnId: read.turnId, keyed: read.keyed }
    }
    // Checked before any insert or model call: a capped request costs one
    // count and nothing else. Only new mixes are capped; follow-ups, queue
    // ops and edits on an existing session are not.
    if (isAnonymous && (await countUserSessions(db, userId)) >= ANONYMOUS_MIX_CAP) {
      return c.json({ error: 'anonymous_cap', limit: ANONYMOUS_MIX_CAP }, 403)
    }
    const fallbackTitle = titleFromPrompt(prompt)

    // Durable: the session, the listener's message, the queued turn and the
    // session's pointer to it, in one transaction, then the object runs it.
    if (durable && keyed) {
      const turnId = keyed.turnId
      let created
      try {
        created = await db.transaction(async (raw) => {
          const tx = raw as unknown as Db
          const row = await createSessionWithPlaylistSeed(tx, userId, fallbackTitle, playlistSeed)
          const userMessageSeq = await insertUserMessage(tx, row.id, prompt)
          const previousTurnId = await queueTurnRow(tx, { id: turnId, sessionId: row.id, userId, kind: 'create' })
          return { row, userMessageSeq, previousTurnId }
        })
      } catch (e) {
        if (e instanceof PlaylistSeedError) return c.json({ error: e.kind }, e.kind === 'not_found' ? 404 : 409)
        // Two requests raced one key: this one's rows rolled back; answer
        // with the winner's turn.
        if (keyed.keyed && isUniqueViolation(e)) {
          const replay = await replayForKey(c, db, durable, turnId, { userId })
          if (replay) return replay
        }
        throw e
      }
      return startDurableTurn(c, db, durable, {
        id: turnId,
        sessionId: created.row.id,
        userId,
        kind: 'create',
        userMessageSeq: created.userMessageSeq,
        options: { energyArc, surface: requestSurface(c.req.header('User-Agent')) },
        previousTurnId: created.previousTurnId,
        session: sessionListRow(created.row),
      })
    }

    // Persist-first: the session row and the user's own message exist
    // before the first turn runs — a failure below still leaves the
    // listener with a session they can reopen and retry, rather than losing
    // their prompt to an LLM hiccup. Starts with the durable
    // truncated-prompt title; replaced below only once the generated
    // name (run concurrently with the turn) resolves.
    let session
    try {
      session = await createSessionWithPlaylistSeed(db, userId, fallbackTitle, playlistSeed)
    } catch (e) {
      if (e instanceof PlaylistSeedError) return c.json({ error: e.kind }, e.kind === 'not_found' ? 404 : 409)
      throw e
    }
    const userMessageSeq = await insertUserMessage(db, session.id, prompt)
    const options: DjTurnOptions = { energyArc, surface: requestSurface(c.req.header('User-Agent')), userMessageSeq }

    // Every refusal above answered JSON; the stream starts only now, with
    // the row in hand, so its first event can name the session.
    if (wantsTurnStream(c)) {
      const row = session
      return streamTurn(c, (onStep) => createMixTurn(db, deps, row, userId, prompt, fallbackTitle, { ...options, onStep }), {
        session: sessionListRow(row),
      })
    }
    const reply = await createMixTurn(db, deps, session, userId, prompt, fallbackTitle, options)
    return c.json(reply.body, reply.status)
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
        // A live (unrevoked) share link: select mode's delete confirm warns
        // that links stop working, without opening each mix to find out.
        shared: sql<boolean>`EXISTS (
          SELECT 1 FROM mix_shares ms
          WHERE ms.session_id = ${djSessions.id} AND ms.revoked_at IS NULL
        )`,
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
        // Durable turns: the current turn while it runs (routes/turns.ts).
        ...(durable ? { turn: liveTurnColumn() } : {}),
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
      sessions: sessions.map(({ pick, ...listed }) => {
        // `turn` is present only while a turn runs, never null.
        const { turn, ...row } = listed as typeof listed & { turn?: unknown }
        const withTurn = turn ? { ...row, turn } : row
        return row.kind === 'album' ? { ...withTurn, pick: pick ?? null } : withTurn
      }),
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
      // Albums have no Share in v1, so never shared.
      return c.json({ session, messages: newestFirst.reverse(), ...pickStateBody(state), playlistSeed, shared: false })
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
    // shared: an active share exists, for the Stop sharing menu item.
    const [playlistSeed, shared, turn] = await Promise.all([
      readPlaylistSeed(db, session.id, userId),
      hasActiveShare(db, session.id),
      durable ? readLiveTurn(db, session.currentTurnId) : null,
    ])
    return c.json({
      // The current turn while it runs (durable turns), never null.
      session: turn ? { ...session, turn } : session,
      messages,
      queue,
      supportsInsert: true,
      playlistSeed,
      shared,
    })
  })

  // Shared mixes (spec 2026-11-13). Mixes only: an album session is 404 as a
  // non-owner's is. No model call, so no AI consent gate (app.ts).
  if (share) {
    app.post('/:id/share', async (c) => {
      const user = c.get('user')
      const session = await loadOwnedSession(db, c.req.param('id'), user.id)
      if (!session || session.kind !== 'mix') return c.json({ error: 'not_found' }, 404)
      // The recipient sees the sharer's first name, so a share needs one
      // (decision 3). Anonymous listeners carry "Listener", which is not usable.
      if (!isUsableName(user.name)) return c.json({ error: 'name_required' }, 409)
      const result = await createOrReuseShare(db, { sessionId: session.id, userId: user.id })
      if (result.kind === 'not_found') return c.json({ error: 'not_found' }, 404)
      if (result.kind === 'empty_mix') return c.json({ error: 'empty_mix' }, 422)
      return c.json({ token: result.token, url: `${share.baseUrl}/m/${result.token}` })
    })

    app.delete('/:id/share', async (c) => {
      const session = await loadOwnedSession(db, c.req.param('id'), c.get('user').id)
      if (!session || session.kind !== 'mix') return c.json({ error: 'not_found' }, 404)
      await revokeShares(db, session.id)
      return c.body(null, 204)
    })
  }

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

    const { text, energyArc, remake } = c.req.valid('json')
    const sessionRef: DjSessionRef = { id: session.id, userId }
    if (session.kind === 'album') {
      // An album has no mix to remake: refused before any write or model call.
      if (remake === true) return c.json(WRONG_SESSION_KIND, 409)
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
    // Durable: the listener's message, the queued turn and the session's
    // pointer in one transaction, then the session's object runs it.
    if (durable) {
      const read = await keyedTurn(c, durable, { userId, sessionId: session.id })
      if (read.response) return read.response
      const turnId = read.turnId
      const kind = remake === true ? 'remake' : 'message'
      let queued
      try {
        queued = await db.transaction(async (raw) => {
          const tx = raw as unknown as Db
          const userMessageSeq = await insertUserMessage(tx, session.id, text)
          const previousTurnId = await queueTurnRow(tx, { id: turnId, sessionId: session.id, userId, kind })
          return { userMessageSeq, previousTurnId }
        })
      } catch (e) {
        if (read.keyed && isUniqueViolation(e)) {
          const replay = await replayForKey(c, db, durable, turnId, { userId, sessionId: session.id })
          if (replay) return replay
        }
        throw e
      }
      return startDurableTurn(c, db, durable, {
        id: turnId,
        sessionId: session.id,
        userId,
        kind,
        userMessageSeq: queued.userMessageSeq,
        options: {
          energyArc,
          surface: requestSurface(c.req.header('User-Agent')),
          ...(remake === true ? { remake: true } : {}),
        },
        previousTurnId: queued.previousTurnId,
      })
    }
    // Persist-first, after every refusal: the listener's words are kept
    // whatever the turn does.
    const userMessageSeq = await insertUserMessage(db, session.id, text)
    const options: DjTurnOptions = {
      energyArc,
      surface: requestSurface(c.req.header('User-Agent')),
      ...(remake === true ? { remake: true } : {}),
      userMessageSeq,
    }
    // A mix turn only: an album session answered JSON above.
    if (wantsTurnStream(c)) return streamTurn(c, (onStep) => mixMessageTurn(db, deps, sessionRef, text, { ...options, onStep }))
    const reply = await mixMessageTurn(db, deps, sessionRef, text, options)
    return c.json(reply.body, reply.status)
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
