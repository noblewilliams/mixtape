import { Buffer } from 'node:buffer'
import { sql } from 'drizzle-orm'
import type { Db } from '../db/types'
import { PLAYLIST_SYNC_MAX_ENTRIES } from './contracts'

export class PlaylistBrowseCursorError extends Error {
  constructor() {
    super('playlist-browse:invalid-cursor')
  }
}

export type PlaylistSummary = {
  id: string
  name: string
  curatorName: string | null
  kind: string
  artworkUrlTemplate: string | null
  artworkWidth: number | null
  artworkHeight: number | null
  artworkBgColor: string | null
  entryCount: number
  knownDurationMs: number | null
  lastModifiedAt: Date | null
  syncedAt: Date | null
  inLibrary: boolean
  capability: 'copy_only'
}

export type PlaylistEntryView = {
  id: string
  position: number
  trackId: string | null
  appleCatalogId: string | null
  title: string
  artist: string
  album: string | null
  durationMs: number | null
  artworkUrlTemplate: string | null
  artworkWidth: number | null
  artworkHeight: number | null
  artworkBgColor: string | null
  resolved: boolean
}

type PlaylistCursor = { v: 1; t: string; id: string }
type EntryCursor = { v: 1; p: number; id: string }
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const CURSOR_MAX_LENGTH = 512
const POSTGRES_BIGINT_MAX = 9_223_372_036_854_775_807n

function encodeCursor(value: PlaylistCursor | EntryCursor) {
  return Buffer.from(JSON.stringify(value)).toString('base64url')
}

function decodeObject(cursor: string): Record<string, unknown> {
  if (cursor.length === 0 || cursor.length > CURSOR_MAX_LENGTH || !/^[A-Za-z0-9_-]+$/.test(cursor)) {
    throw new PlaylistBrowseCursorError()
  }
  try {
    const decoded = JSON.parse(Buffer.from(cursor, 'base64url').toString('utf8'))
    if (!decoded || typeof decoded !== 'object' || Array.isArray(decoded)) {
      throw new PlaylistBrowseCursorError()
    }
    return decoded as Record<string, unknown>
  } catch (error) {
    if (error instanceof PlaylistBrowseCursorError) throw error
    throw new PlaylistBrowseCursorError()
  }
}

function decodePlaylistCursor(cursor: string): PlaylistCursor {
  const value = decodeObject(cursor)
  if (
    value.v !== 1
    || typeof value.t !== 'string'
    || !/^\d{1,20}$/.test(value.t)
    || BigInt(value.t) > POSTGRES_BIGINT_MAX
    || typeof value.id !== 'string'
    || !UUID_RE.test(value.id)
    || Object.keys(value).some((key) => !['v', 't', 'id'].includes(key))
  ) throw new PlaylistBrowseCursorError()
  return value as PlaylistCursor
}

function decodeEntryCursor(cursor: string): EntryCursor {
  const value = decodeObject(cursor)
  if (
    value.v !== 1
    || typeof value.p !== 'number'
    || !Number.isSafeInteger(value.p)
    || value.p < 0
    || value.p >= PLAYLIST_SYNC_MAX_ENTRIES
    || typeof value.id !== 'string'
    || !UUID_RE.test(value.id)
    || Object.keys(value).some((key) => !['v', 'p', 'id'].includes(key))
  ) throw new PlaylistBrowseCursorError()
  return value as EntryCursor
}

function normalizeRows(value: unknown): Record<string, unknown>[] {
  if (Array.isArray(value)) return value as Record<string, unknown>[]
  if (value && typeof value === 'object' && 'rows' in value) {
    const rows = (value as { rows?: unknown }).rows
    return Array.isArray(rows) ? rows as Record<string, unknown>[] : []
  }
  return []
}

function nullableDate(value: unknown): Date | null {
  if (value == null) return null
  if (value instanceof Date) return value
  const parsed = new Date(String(value))
  if (Number.isNaN(parsed.getTime())) throw new Error('playlist-browse:invalid-date')
  return parsed
}

function nullableNumber(value: unknown): number | null {
  if (value == null) return null
  const parsed = Number(value)
  if (!Number.isSafeInteger(parsed) || parsed < 0) {
    throw new Error('playlist-browse:invalid-number')
  }
  return parsed
}

function summaryFromRow(row: Record<string, unknown>): PlaylistSummary {
  return {
    id: String(row.id),
    name: String(row.name),
    curatorName: row.curator_name == null ? null : String(row.curator_name),
    kind: String(row.kind),
    artworkUrlTemplate: row.artwork_url_template == null ? null : String(row.artwork_url_template),
    artworkWidth: nullableNumber(row.artwork_width),
    artworkHeight: nullableNumber(row.artwork_height),
    artworkBgColor: row.artwork_bg_color == null ? null : String(row.artwork_bg_color),
    entryCount: Number(row.entry_count),
    knownDurationMs: nullableNumber(row.known_duration_ms),
    lastModifiedAt: nullableDate(row.last_modified_at),
    syncedAt: nullableDate(row.synced_at),
    inLibrary: row.in_library === true,
    capability: 'copy_only',
  }
}

function entryFromRow(row: Record<string, unknown>): PlaylistEntryView {
  const trackId = row.track_id == null ? null : String(row.track_id)
  return {
    id: String(row.id),
    position: Number(row.position),
    trackId,
    appleCatalogId: row.apple_catalog_id == null ? null : String(row.apple_catalog_id),
    title: String(row.title_snapshot),
    artist: String(row.artist_snapshot),
    album: row.album_snapshot == null ? null : String(row.album_snapshot),
    durationMs: nullableNumber(row.duration_ms_snapshot),
    artworkUrlTemplate: row.artwork_url_template_snapshot == null
      ? null
      : String(row.artwork_url_template_snapshot),
    artworkWidth: nullableNumber(row.artwork_width_snapshot),
    artworkHeight: nullableNumber(row.artwork_height_snapshot),
    artworkBgColor: row.artwork_bg_color_snapshot == null
      ? null
      : String(row.artwork_bg_color_snapshot),
    resolved: trackId != null,
  }
}

const summarySelect = sql`
  up.id,
  up.name,
  up.curator_name,
  up.kind,
  up.artwork_url_template,
  up.artwork_width,
  up.artwork_height,
  up.artwork_bg_color,
  count(pe.id)::int AS entry_count,
  CASE WHEN count(pe.duration_ms_snapshot) = 0
    THEN NULL
    ELSE sum(pe.duration_ms_snapshot)
  END AS known_duration_ms,
  up.apple_last_modified_at AS last_modified_at,
  ump.playlists_synced_at AS synced_at,
  up.in_library,
  coalesce(up.apple_last_modified_at, up.updated_at) AS sort_at,
  (extract(epoch FROM coalesce(up.apple_last_modified_at, up.updated_at))
    * 1000000)::bigint AS sort_micros
`

export function createPlaylistBrowseStore(db: Db) {
  return {
    async list(
      userId: string,
      options: { status: 'active' | 'all'; q?: string; limit: number; cursor?: string },
    ) {
      const cursor = options.cursor ? decodePlaylistCursor(options.cursor) : null
      const active = options.status === 'active' ? sql`AND up.in_library = true` : sql``
      const search = options.q
        ? sql`AND position(lower(${options.q}) in lower(up.name)) > 0`
        : sql``
      const after = cursor
        ? sql`AND (
            (extract(epoch FROM coalesce(up.apple_last_modified_at, up.updated_at))
              * 1000000)::bigint,
            up.id
          ) < (${cursor.t}::bigint, ${cursor.id}::uuid)`
        : sql``
      const rows = normalizeRows(await db.execute(sql`
        SELECT ${summarySelect}
        FROM user_playlists up
        JOIN user_music_profiles ump ON ump.user_id = up.user_id
        LEFT JOIN playlist_entries pe ON pe.playlist_id = up.id
        WHERE up.user_id = ${userId}
        ${active}
        ${search}
        ${after}
        GROUP BY up.id, ump.playlists_synced_at
        ORDER BY sort_at DESC, up.id DESC
        LIMIT ${options.limit + 1}
      `))
      const hasMore = rows.length > options.limit
      const pageRows = hasMore ? rows.slice(0, options.limit) : rows
      const playlists = pageRows.map(summaryFromRow)
      const last = hasMore ? pageRows.at(-1) : null
      return {
        playlists,
        nextCursor: last
          ? encodeCursor({
              v: 1,
              t: String(last.sort_micros),
              id: String(last.id),
            })
          : null,
      }
    },

    async detail(
      userId: string,
      playlistId: string,
      options: { limit: number; cursor?: string },
    ) {
      const cursor = options.cursor ? decodeEntryCursor(options.cursor) : null
      const metadataRows = normalizeRows(await db.execute(sql`
        SELECT ${summarySelect}
        FROM user_playlists up
        JOIN user_music_profiles ump ON ump.user_id = up.user_id
        LEFT JOIN playlist_entries pe ON pe.playlist_id = up.id
        WHERE up.user_id = ${userId} AND up.id = ${playlistId}::uuid
        GROUP BY up.id, ump.playlists_synced_at
      `))
      const metadata = metadataRows[0]
      if (!metadata) return null
      const after = cursor
        ? sql`AND (pe.position, pe.id) > (${cursor.p}, ${cursor.id}::uuid)`
        : sql``
      const rows = normalizeRows(await db.execute(sql`
        SELECT
          pe.id,
          pe.position,
          pe.track_id,
          pe.apple_catalog_id,
          pe.title_snapshot,
          pe.artist_snapshot,
          pe.album_snapshot,
          pe.duration_ms_snapshot,
          pe.artwork_url_template_snapshot,
          pe.artwork_width_snapshot,
          pe.artwork_height_snapshot,
          pe.artwork_bg_color_snapshot
        FROM playlist_entries pe
        JOIN user_playlists up ON up.id = pe.playlist_id
        WHERE up.user_id = ${userId} AND up.id = ${playlistId}::uuid
        ${after}
        ORDER BY pe.position ASC, pe.id ASC
        LIMIT ${options.limit + 1}
      `))
      const hasMore = rows.length > options.limit
      const pageRows = hasMore ? rows.slice(0, options.limit) : rows
      const entries = pageRows.map(entryFromRow)
      const last = hasMore ? pageRows.at(-1) : null
      return {
        playlist: summaryFromRow(metadata),
        entries,
        nextEntryCursor: last
          ? encodeCursor({ v: 1, p: Number(last.position), id: String(last.id) })
          : null,
      }
    },
  }
}
