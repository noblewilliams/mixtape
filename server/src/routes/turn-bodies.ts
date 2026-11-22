import { and, asc, desc, eq, inArray } from 'drizzle-orm'
import type { Db } from '../db/types'
import { djMessages, djSessions, djTurns, tracks } from '../db/schema'
import {
  runDjTurn,
  CONFLICT_APOLOGY,
  CURATION_APOLOGY,
  DjError,
  INTERNAL_APOLOGY,
  LLM_APOLOGY,
  type DjDeps,
  type DjSessionRef,
  type DjTurnOptions,
  type PersistedTurnWrites,
} from '../dj/loop'
import { getActiveQueue } from '../dj/queue-store'
import { TurnStopped } from '../dj/turn-stop'
import { generateMixTitle, generateSessionTitle, type MixTitleSong } from '../dj/title'
import { readPlaylistSeed } from '../playlists/seed'
import { sanitizeTitleText } from '../dj/sanitize'
import type { TurnReply } from './turn-stream'

// A mix turn and the body it answers with, shared by every way a turn is
// run: the routes' JSON path, their in-request stream (turn-stream.ts), and
// the durable turn job (dj/turn-job.ts, spec 2026-11-21 durable-mix-turns,
// "Run (object side)"). One builder per kind of turn, so `result` and
// `error` cannot drift from the JSON contract whichever path sent them.

// 'conflict' is the same queue-version race the manual queue-ops route
// reports as 409 (see QueueVersionConflict handling in sessions.ts) — same
// condition, same status, regardless of which route hit it. 'validation'
// (reserved, no construction site yet — see DjError's kind comment in
// dj/loop.ts) maps to 400 like any client-side input error. Everything else
// (an upstream LLM hiccup, a truncated curation, an unexpected internal
// fault) is a server-side condition the client can retry as-is — those map
// to 502.
export function djErrorStatus(kind: DjError['kind']): 400 | 409 | 502 {
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
export function djErrorBody(e: DjError, extra: Record<string, unknown> = {}) {
  // sessionTitle rides this body the same way queue/queueVersion do — absent
  // (dropped by JSON.stringify) unless a rename_session call landed earlier
  // this turn before the failure that produced `e`. Without it, a client
  // whose turn renamed the session and then failed would keep showing the
  // stale AppBar title until its next unrelated fetch self-heals it — see
  // dj/loop.ts's DjError.sessionTitle comment.
  return { error: e.kind, message: e.message, queue: e.queue, queueVersion: e.queueVersion, sessionTitle: e.sessionTitle, ...extra }
}

// Thin wrapper over sanitizeTitleText (dj/sanitize.ts) with a non-empty
// fallback — the one thing that step doesn't itself decide, since PATCH
// /sessions/:id and the rename_session tool both want a REJECTION on an
// empty-after-sanitize title instead of a silent fallback. Exported for
// scripts/retitle-sessions.ts (through routes/sessions.ts), which needs the exact same transform to
// recognize a session whose title is still this fallback (never overwritten
// by a generated title) as a backfill candidate.
export function titleFromPrompt(prompt: string): string {
  return sanitizeTitleText(prompt) || 'new session'
}

// The list-row shape: what GET /sessions returns per row, and what POST /
// and PATCH /:id echo back for the ONE session they touched — one shape
// everywhere a session is summarized, rather than three routes each
// inventing their own subset of its columns. (GET /:id returns the full row,
// a superset of this.)
export const sessionListColumns = {
  id: djSessions.id,
  title: djSessions.title,
  caseColor: djSessions.caseColor,
  status: djSessions.status,
  queueVersion: djSessions.queueVersion,
  // True while this session's mix came from the shared catalog: each
  // whole-mix generate sets it from its own pool, and a corpus swap or
  // extend sets it (dj/loop.ts setNotPersonal, markNotPersonal) — the
  // client's "not personal yet" banner reads this off every summary, so a
  // listener sees it in the collection list, not only inside the open session.
  notPersonal: djSessions.notPersonal,
  // 'mix' | 'album': which loop, read shape and routes the session takes.
  kind: djSessions.kind,
  updatedAt: djSessions.updatedAt,
}

type SessionListKey = keyof typeof sessionListColumns

// The list-row shape of a row already in hand (the streamed create's first
// event, sent before the closing UPDATE re-reads it with sessionListColumns),
// in the same key order.
export function sessionListRow(row: typeof djSessions.$inferSelect): Pick<typeof djSessions.$inferSelect, SessionListKey> {
  const keys = Object.keys(sessionListColumns) as SessionListKey[]
  return Object.fromEntries(keys.map((key) => [key, row[key]])) as Pick<typeof djSessions.$inferSelect, SessionListKey>
}

// The abandoned request of a stopped turn, for anyone still reading it.
export const TURN_STOPPED_BODY = { error: 'turn_stopped' }

// How the turn ended, beside the reply: what the durable job records on
// its dj_turns row (status and error_kind). The routes read only the reply.
// A 409 is either a stop or a conflict, so the reply alone cannot say.
export type MixTurnEnd = { kind: 'done' } | { kind: 'stopped' } | { kind: 'failed'; errorKind: DjError['kind'] }
export type MixTurnReply = TurnReply & { end: MixTurnEnd }

// The mix's songs in queue order with their albums (the queue view carries
// no album), for the song-based title.
async function mixTitleSongs(db: Db, queue: Array<{ trackId: string; title: string; artist: string }>): Promise<MixTitleSong[]> {
  const rows = await db
    .select({ id: tracks.id, album: tracks.album })
    .from(tracks)
    .where(inArray(tracks.id, queue.map((q) => q.trackId)))
  const albums = new Map(rows.map((r) => [r.id, r.album]))
  return queue.map((q) => ({ title: q.title, artist: q.artist, album: albums.get(q.trackId) ?? null }))
}

// The mix creation turn once its persist-first row exists: the DJ turn and
// the title job side by side, the closing UPDATE, the messages read, and
// the body. Every path answers with what this returns. A DjError is an
// answer; anything else is thrown, a 500 either way.
export async function createMixTurn(
  db: Db,
  deps: DjDeps,
  session: { id: string },
  userId: string,
  prompt: string,
  fallbackTitle: string,
  options: DjTurnOptions,
): Promise<MixTurnReply> {
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
  const [turnResult, titleResult] = await Promise.allSettled([runDjTurn(db, deps, sessionRef, prompt, { ...options, firstTurn: true }), titlePromise])

  // Stopped by the listener: the turn took its new session with it, so
  // there is no row to title.
  if (turnResult.status === 'rejected' && turnResult.reason instanceof TurnStopped) {
    return { status: 409, body: TURN_STOPPED_BODY, end: { kind: 'stopped' } }
  }

  // A rename_session call within this very first turn (unusual, but the
  // listener COULD open with "call this tape Lagos Nights") wins over the
  // concurrently-generated title — an explicit rename is a stronger
  // signal than the auto-naming pass, and the auto-generated title must
  // never clobber it on the write below. Checked on the REJECTED branch
  // too (DjError.sessionTitle, dj/loop.ts) — the rename's DB write already
  // landed before whatever later failed this turn (a conflict that
  // persisted through the retry, a curation error, ...), so a failed turn
  // must never overwrite that persisted rename with the generated title here.
  const renamedTitle =
    turnResult.status === 'fulfilled'
      ? turnResult.value.sessionTitle
      : turnResult.reason instanceof DjError
        ? turnResult.reason.sessionTitle
        : undefined
  const briefTitle = titleResult.status === 'fulfilled' ? titleResult.value : fallbackTitle

  // Decision 2026-11-16 (mix titles from the songs): a first turn that
  // came back with songs is named from them, so this call waits for the
  // picks (about 1.3 to 2.6 s since 2026-11-22, 5 s cap). The brief-only title
  // above is its fallback; a rename or a chat-only turn skips it.
  const title =
    renamedTitle ??
    (turnResult.status === 'fulfilled' && turnResult.value.queue.length > 0 && deps.titleComplete
      ? await generateMixTitle(deps.titleComplete, prompt, await mixTitleSongs(db, turnResult.value.queue), briefTitle)
      : briefTitle)

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
      return { status: djErrorStatus(e.kind), body: djErrorBody(e, { sessionId: session.id }), end: { kind: 'failed', errorKind: e.kind } }
    }
    throw e
  }

  const messages = await db
    .select()
    .from(djMessages)
    .where(eq(djMessages.sessionId, session.id))
    .orderBy(asc(djMessages.seq))
  return {
    status: 200,
    body: {
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
      // The "Add my listening history" pill (spec 2026-11-09
      // add-your-music-loop, decision 5): present ONLY on the turn that
      // offered it, never sent as null.
      ...(turnResult.value.addMusic ? { addMusic: turnResult.value.addMusic } : {}),
    },
    end: { kind: 'done' },
  }
}

// A mix message turn and its body, shared the same way as createMixTurn.
export async function mixMessageTurn(db: Db, deps: DjDeps, sessionRef: DjSessionRef, text: string, options: DjTurnOptions): Promise<MixTurnReply> {
  try {
    const result = await runDjTurn(db, deps, sessionRef, text, options)
    // A text-only reply never touches dj_sessions itself (no queue write
    // to ride $onUpdate's automatic bump), so list ordering (newest first
    // by updatedAt) would otherwise never reflect a chat-only turn.
    await db.update(djSessions).set({ updatedAt: new Date() }).where(eq(djSessions.id, sessionRef.id))
    return {
      status: 200,
      body: {
        djMessage: result.djMessage,
        queue: result.queue,
        queueVersion: result.queueVersion,
        // Same contract as createMixTurn above: present ONLY when
        // rename_session fired this turn. addMusic likewise: only on the
        // turn that offered the pill.
        ...(result.sessionTitle ? { sessionTitle: result.sessionTitle } : {}),
        ...(result.addMusic ? { addMusic: result.addMusic } : {}),
      },
      end: { kind: 'done' },
    }
  } catch (e) {
    if (e instanceof DjError) {
      return { status: djErrorStatus(e.kind), body: djErrorBody(e), end: { kind: 'failed', errorKind: e.kind } }
    }
    if (e instanceof TurnStopped) return { status: 409, body: TURN_STOPPED_BODY, end: { kind: 'stopped' } }
    throw e
  }
}

// The fixed apology each DjError kind answers with (dj/loop.ts
// normalizeError), for a body rebuilt from the database.
const APOLOGY: Record<DjError['kind'], string> = {
  llm: LLM_APOLOGY,
  curation: CURATION_APOLOGY,
  conflict: CONFLICT_APOLOGY,
  validation: INTERNAL_APOLOGY,
  internal: INTERNAL_APOLOGY,
}

function djErrorKind(code: string | null): DjError['kind'] {
  return code !== null && code in APOLOGY ? (code as DjError['kind']) : 'internal'
}

/**
 * The answer of a durable turn that has finished, rebuilt from the database
 * (spec 2026-11-21 durable-mix-turns, "Start", 1): for a request replayed
 * with its Idempotency-Key after the session's object let go of the last
 * event. A done turn answers the body its route sent, from the rows it left
 * (the session, the transcript, the queue, its recorded writes for the
 * rename and the pill); a stopped one 409 turn_stopped; a failed or lost one
 * its kind's error body, 'internal' and 'lost' as the 502 internal apology,
 * a create's carrying its session id. Null while the turn is unfinished, or
 * when its row (or session) is gone.
 */
export async function finishedTurnReply(db: Db, turnId: string): Promise<TurnReply | null> {
  const [turn] = await db
    .select({ sessionId: djTurns.sessionId, userId: djTurns.userId, kind: djTurns.kind, status: djTurns.status, errorKind: djTurns.errorKind, writes: djTurns.writes })
    .from(djTurns)
    .where(eq(djTurns.id, turnId))
  if (!turn || turn.status === 'queued' || turn.status === 'running') return null
  if (turn.status === 'stopped') return { status: 409, body: TURN_STOPPED_BODY }

  const [session] = await db.select(sessionListColumns).from(djSessions).where(eq(djSessions.id, turn.sessionId))
  if (!session) return null
  const writes = turn.writes as PersistedTurnWrites | null
  const sessionTitle = writes?.renamed ? session.title : undefined
  const isCreate = turn.kind === 'create'

  if (turn.status === 'failed') {
    const e = new DjError(djErrorKind(turn.errorKind), APOLOGY[djErrorKind(turn.errorKind)])
    // As runDjTurn's catch sets them: the queue only when this turn moved it
    // and the move stands, the title only when this turn renamed.
    if (writes && session.queueVersion !== writes.startingVersion) {
      e.queue = await getActiveQueue(db, turn.sessionId)
      e.queueVersion = session.queueVersion
    }
    if (sessionTitle) e.sessionTitle = sessionTitle
    return { status: djErrorStatus(e.kind), body: djErrorBody(e, isCreate ? { sessionId: turn.sessionId } : {}) }
  }

  const queue = await getActiveQueue(db, turn.sessionId)
  const extras = {
    ...(sessionTitle ? { sessionTitle } : {}),
    ...(writes?.historyOffered ? { addMusic: 'history' as const } : {}),
  }
  if (isCreate) {
    const messages = await db.select().from(djMessages).where(eq(djMessages.sessionId, turn.sessionId)).orderBy(asc(djMessages.seq))
    return {
      status: 200,
      body: { session, messages, queue, supportsInsert: true, playlistSeed: await readPlaylistSeed(db, turn.sessionId, turn.userId), ...extras },
    }
  }
  // The turn's DJ reply: the last of its recorded messages (the listener's
  // comes first), else the session's latest DJ message.
  const replySeq = writes && writes.messageSeqs.length > 1 ? writes.messageSeqs[writes.messageSeqs.length - 1] : null
  const [djMessage] = await db
    .select()
    .from(djMessages)
    .where(and(eq(djMessages.sessionId, turn.sessionId), eq(djMessages.role, 'dj'), ...(replySeq !== null ? [eq(djMessages.seq, replySeq)] : [])))
    .orderBy(desc(djMessages.seq))
    .limit(1)
  return { status: 200, body: { djMessage: djMessage ?? null, queue, queueVersion: session.queueVersion, ...extras } }
}
