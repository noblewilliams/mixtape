import type { Session, User } from 'better-auth'
import { sql, type SQL } from 'drizzle-orm'
import type { Db } from '../db/types'
import type { Surface } from '../seeds/contracts'

// The anonymous-to-account merge (spec 2026-10-20-first-run-flow → The merge).
// Better Auth's anonymous plugin calls linkAnonymousAccount after a social
// sign-in that arrives with an anonymous session, then deletes the anonymous
// user. Whatever this leaves on the anonymous id goes with that cascade.

export type MergeMode = 'all' | 'mixes_only'
export type LinkMode = MergeMode | 'none'
// What GET /me tells the client once after a link:
// 'all'          everything moved to a new account;
// 'mixes_only'   mixes moved, the account's existing library kept;
// 'library_kept' no mixes to move, and the anonymous library was dropped
//                in favour of the account's.
export type MergedNotice = MergeMode | 'library_kept'

export type LinkAnonymousRowsInput = {
  anonymousUserId: string
  newUserId: string
  // The session the sign-in just created; it carries the mode to GET /me.
  newSessionId?: string
  surface?: Surface
}

// Each move skips any row whose unique key the new user already holds: that
// row stays on the anonymous id and the cascade removes it, so the account's
// own row wins and nothing ever collides. `unique` lists the columns that,
// with user_id, form a unique key ([] when user_id alone is the key); omitted
// when the table has no per-user unique key. `partial` is the predicate of a
// partial unique index (the open-run indexes).
type Move = { table: string; unique?: string[]; partial?: string }

// Moved in both modes. dj_sessions carries its children (messages, events,
// queue rows, playlist seeds, versions) by session id. dj_memories is unique
// on (user_id, note), despite the spec; playback_evidence on
// (user_id, playback_id, sequence).
const MIX_MOVES: Move[] = [
  { table: 'dj_sessions' },
  { table: 'dj_memories', unique: ['note'] },
  { table: 'funnel_events' },
  { table: 'playback_evidence', unique: ['playback_id', 'sequence'] },
]

// Moved only for an account with no mixes and no library ('all'). Such an
// account can still hold settings, seeds, memories or an open import, hence
// the guards. user_tracks and user_track_library_sources are absent: they
// move together in one statement (moveLibraryTracks). The rest have no FK
// through user_id between them; run staging rows and playlist entries follow
// by run or playlist id, and drafts by their own row.
const LIBRARY_MOVES: Move[] = [
  // Guarded per source, so an account keeps its whole recent snapshot for a
  // source it already has (the rows are one ranked snapshot per source).
  { table: 'user_recent_track_observations', unique: ['source'] },
  { table: 'listening_days', unique: ['source', 'track_id', 'day'] },
  { table: 'user_music_profiles', unique: [] },
  { table: 'user_artist_seeds', unique: ['name'] },
  { table: 'user_music_sources', unique: ['source'] },
  { table: 'library_sync_runs', unique: [], partial: "status = 'open'" },
  { table: 'listening_import_runs', unique: ['source'], partial: "status = 'open'" },
  { table: 'playlist_sync_runs', unique: [], partial: "status = 'open'" },
  { table: 'playlist_origins', unique: ['source', 'library_id'] },
  { table: 'user_playlists', unique: ['apple_library_id'] },
  // Its resumable index is on (user_id, source_playlist_id): the playlist ids
  // are the anonymous user's own rows, so they never match the account's.
  { table: 'playlist_edit_drafts' },
  { table: 'playback_settings', unique: [] },
  { table: 'suggestion_settings', unique: [] },
]

// Table, column and predicate text is constant in this file, never input.
function moveStatement({ table, unique, partial }: Move, anonymousUserId: string, newUserId: string): SQL {
  const update = sql`UPDATE ${sql.raw(`"${table}"`)} t SET user_id = ${newUserId} WHERE t.user_id = ${anonymousUserId}`
  if (!unique) return update
  const match = unique.map((c) => ` AND n."${c}" = t."${c}"`).join('') + (partial ? ` AND n.${partial}` : '')
  const held = sql`EXISTS (SELECT 1 FROM ${sql.raw(`"${table}"`)} n WHERE n.user_id = ${newUserId}${sql.raw(match)})`
  return partial
    ? sql`${update} AND NOT (${sql.raw(`t.${partial}`)} AND ${held})`
    : sql`${update} AND NOT ${held}`
}

// user_tracks and its library-source children in one statement: Postgres
// checks NO ACTION foreign keys at the end of the whole statement, data-
// modifying CTEs included, so parent and child move together. Only reached
// in 'all', where the account has no user_tracks, so neither key collides.
function moveLibraryTracks(anonymousUserId: string, newUserId: string): SQL {
  return sql`
    WITH moved_sources AS (
      UPDATE user_track_library_sources SET user_id = ${newUserId} WHERE user_id = ${anonymousUserId}
    )
    UPDATE user_tracks SET user_id = ${newUserId} WHERE user_id = ${anonymousUserId}`
}

const ALL_USER_TABLES = [
  ...MIX_MOVES.map((m) => m.table),
  'user_tracks',
  'user_track_library_sources',
  ...LIBRARY_MOVES.map((m) => m.table),
]

function ownsAny(tables: string[], userId: string): SQL {
  return sql.join(
    tables.map((t) => sql`EXISTS (SELECT 1 FROM ${sql.raw(`"${t}"`)} WHERE user_id = ${userId})`),
    sql` OR `,
  )
}

type Row = Record<string, unknown>
function rowsOf(result: unknown): Row[] {
  if (Array.isArray(result)) return result as Row[]
  return ((result as { rows?: Row[] }).rows ?? [])
}

export async function linkAnonymousRows(db: Db, input: LinkAnonymousRowsInput): Promise<{ mode: LinkMode }> {
  const { anonymousUserId: anon, newUserId: next } = input
  if (anon === next) return { mode: 'none' }

  return db.transaction(async (tx) => {
    // Lock the anonymous user so a concurrent retry waits for this merge.
    const anonRow = rowsOf(await tx.execute(
      sql`SELECT 1 FROM "user" WHERE id = ${anon} FOR UPDATE`,
    ))[0]
    if (!anonRow) return { mode: 'none' as const }

    const probe = rowsOf(await tx.execute(sql`
      SELECT
        (${ownsAny(['dj_sessions', 'user_music_sources', 'user_tracks'], next)}) AS next_has_data,
        (${ownsAny(ALL_USER_TABLES, anon)}) AS anon_has_rows,
        (${ownsAny(MIX_MOVES.map((m) => m.table), anon)}) AS anon_has_mixes
    `))[0]!
    const mode: MergeMode = probe.next_has_data ? 'mixes_only' : 'all'

    // Nothing to move (a retried callback after the rows already moved, or an
    // anonymous user with nothing the mode would carry): write nothing.
    const movable = mode === 'all' ? probe.anon_has_rows : probe.anon_has_mixes
    if (!movable) return { mode: 'none' as const }

    let movedMixes = 0
    for (const move of MIX_MOVES) {
      if (move.table === 'dj_sessions') {
        movedMixes = rowsOf(await tx.execute(sql`${moveStatement(move, anon, next)} RETURNING 1`)).length
      } else {
        await tx.execute(moveStatement(move, anon, next))
      }
    }
    if (mode === 'all') {
      await tx.execute(moveLibraryTracks(anon, next))
      for (const move of LIBRARY_MOVES) await tx.execute(moveStatement(move, anon, next))
    }

    const type = mode === 'all' ? 'account_linked_new' : 'account_linked_existing'
    await tx.execute(sql`
      INSERT INTO funnel_events (user_id, type, surface) VALUES (${next}, ${type}, ${input.surface ?? 'web'})`)

    let notice: MergedNotice | null = 'all'
    if (mode === 'mixes_only') {
      if (movedMixes > 0) {
        notice = 'mixes_only'
      } else {
        const dropped = rowsOf(await tx.execute(
          sql`SELECT (${ownsAny(['user_tracks', 'user_music_sources'], anon)}) AS library_dropped`,
        ))[0]
        notice = dropped?.library_dropped ? 'library_kept' : null
      }
    }
    if (input.newSessionId && notice) {
      await tx.execute(sql`UPDATE "session" SET merged_mode = ${notice} WHERE id = ${input.newSessionId}`)
    }
    return { mode }
  })
}

// Reads the link outcome stamped on a session and clears it, so the client
// hears about a merge exactly once.
export async function takeMergedMode(db: Db, sessionId: string): Promise<MergedNotice | null> {
  const row = rowsOf(await db.execute(sql`
    UPDATE "session" s SET merged_mode = NULL
    FROM (SELECT id, merged_mode FROM "session" WHERE id = ${sessionId} AND merged_mode IS NOT NULL FOR UPDATE) o
    WHERE s.id = o.id
    RETURNING o.merged_mode`))[0]
  const mode = row?.merged_mode
  return mode === 'all' || mode === 'mixes_only' || mode === 'library_kept' ? mode : null
}

export type LinkAnonymousAccountInput = {
  anonymousUser: { user: User & Record<string, unknown>; session: Session & Record<string, unknown> }
  newUser: { user: User & Record<string, unknown>; session: Session & Record<string, unknown> }
  surface?: Surface
}

// The plugin hook. A failure propagates: the sign-in fails and the plugin
// never deletes the anonymous user, so a retry can still merge. Swallowing it
// would let the cascade delete the listener's mixes.
export async function linkAnonymousAccount(db: Db, input: LinkAnonymousAccountInput): Promise<{ mode: LinkMode }> {
  try {
    return await linkAnonymousRows(db, {
      anonymousUserId: input.anonymousUser.user.id,
      newUserId: input.newUser.user.id,
      newSessionId: input.newUser.session.id,
      surface: input.surface,
    })
  } catch (error) {
    // Fixed marker, the error name and the Postgres code only, matching
    // app.onError: the message may carry row data.
    console.error(
      'anonymous account link failed',
      error instanceof Error ? error.name : 'unknown',
      ...pgCode(error),
    )
    throw error
  }
}

// Drizzle wraps driver errors (DrizzleQueryError.cause), so look one level down.
function pgCode(error: unknown): string[] {
  const own = (error as { code?: unknown } | null)?.code
  const cause = (error as { cause?: { code?: unknown } } | null)?.cause?.code
  const code = typeof own === 'string' ? own : typeof cause === 'string' ? cause : undefined
  return code ? [code] : []
}
