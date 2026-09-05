import { and, eq, sql } from 'drizzle-orm'
import { z } from 'zod'
import type { Db } from '../db/types'
import { djSessions, playlistEntries, sessionPlaylistSeeds, tracks, userPlaylists } from '../db/schema'
import { sanitizeForPrompt } from '../dj/sanitize'

export const seedSelectionSchema = z.object({
  playlistId: z.uuid().nullable(),
  excludeSourceTracks: z.boolean().default(false),
  expectedRevision: z.number().int().min(0).max(2147483646),
}).strict()
export const initialSeedSchema = z.object({ playlistId: z.uuid(), excludeSourceTracks: z.boolean().default(false) }).strict()

export class PlaylistSeedError extends Error {
  constructor(readonly kind: 'not_found' | 'unavailable' | 'insufficient_profile' | 'stale') {
    super(`playlist_seed_${kind}`)
  }
}
export type PlaylistSeedState = {
  playlistId: string | null
  revision: number
  excludeSourceTracks: boolean
  status: 'none' | 'ready' | 'unavailable' | 'insufficient_profile'
  name: string | null
  source: 'apple' | 'spotify_export' | null
  fingerprint: string | null
  updatedAt: string | null
  entries: number
  resolvedEntries: number
  recordings: number
  profile: {
    sampledRecordings: number
    tempo: number | null
    energy: number | null
    releaseYear: number | null
    artists: string[]
    genres: string[]
  } | null
}
export const MIN_PROFILE_RECORDINGS = 3
export const MAX_PROFILE_RECORDINGS = 200
export const MAX_PROFILE_RECORDINGS_PER_ARTIST = 5

export function playlistSeedContext(state: PlaylistSeedState): string {
  if (state.status === 'none') return 'Playlist inspiration: none selected.'
  if (state.status !== 'ready') return `Playlist inspiration: selected source is ${state.status.replace('_', ' ')}; do not generate new picks from it.`
  return [
    `Playlist inspiration: "${sanitizeForPrompt(state.name ?? '', 120)}" (${state.source}); selection revision ${state.revision}.`,
    `Coverage: ${state.recordings} resolved recordings from ${state.entries} entries (${state.entries - state.resolvedEntries} unresolved).`,
    state.profile ? [
      `${state.profile.sampledRecordings} sampled recordings`,
      `Profile: ${state.profile.tempo === null ? 'tempo unknown' : `${Math.round(state.profile.tempo)} bpm`}`,
      state.profile.energy === null ? 'energy unknown' : `energy ${state.profile.energy.toFixed(2)}`,
      state.profile.releaseYear === null ? 'era unknown' : `center year ${Math.round(state.profile.releaseYear)}`,
      `artists ${state.profile.artists.slice(0, 8).map(value => sanitizeForPrompt(value, 80)).join(', ') || 'unknown'}`,
      `genres ${state.profile.genres.slice(0, 8).map(value => sanitizeForPrompt(value, 80)).join(', ') || 'unknown'}`,
    ].join('; ') + '.' : 'Profile: enrichment unavailable.',
    state.excludeSourceTracks
      ? 'Use its musical shape, but exclude every resolved source recording and ISRC sibling.'
      : "Its original songs may compete normally; the listener's current request wins conflicts.",
  ].join('\n')
}

export async function findPlaylistSeeds(db: Db, userId: string, query: string) {
  const term = query.trim().toLowerCase()
  if (!term) return { matches: [], hasMore: false }
  const escaped = term.replaceAll('\\', '\\\\').replaceAll('%', '\\%').replaceAll('_', '\\_')
  const rows = await db.select({ id: userPlaylists.id, name: userPlaylists.name, source: userPlaylists.source })
    .from(userPlaylists).where(and(eq(userPlaylists.userId, userId), eq(userPlaylists.inLibrary, true),
      sql`lower(${userPlaylists.name}) like ${`%${escaped}%`} escape '\\'`))
    .orderBy(sql`CASE WHEN lower(${userPlaylists.name}) = ${term} THEN 0 ELSE 1 END`, userPlaylists.name)
    .limit(6)
  return { matches: rows.slice(0, 5).map(row => ({ ...row, name: sanitizeForPrompt(row.name, 120) })), hasMore: rows.length > 5 }
}

export async function readPlaylistSeed(db: Db, sessionId: string, userId: string): Promise<PlaylistSeedState> {
  // One statement means coverage, profile, activity and fingerprint describe
  // the same published snapshot. A later sync is caught again by the queue
  // mutation guard before generated picks can commit.
  const raw = await db.execute(sql`
    WITH selected AS (
      SELECT s.id AS session_id,
        ps.playlist_id,
        COALESCE(ps.enabled, false) AS enabled,
        COALESCE(ps.exclude_source_tracks, false) AS exclude_source_tracks,
        COALESCE(ps.revision, 0) AS revision,
        p.id AS active_playlist_id,
        p.name,
        p.source,
        p.source_fingerprint,
        p.updated_at
      FROM dj_sessions s
      LEFT JOIN session_playlist_seeds ps ON ps.session_id = s.id
      LEFT JOIN user_playlists p ON p.id = ps.playlist_id
        AND p.user_id = s.user_id
        AND p.in_library = true
      WHERE s.id = ${sessionId}::uuid AND s.user_id = ${userId}
    ), coverage AS (
      SELECT COUNT(pe.playlist_id)::int AS entries,
        COUNT(t.id)::int AS resolved_entries,
        COUNT(DISTINCT COALESCE(t.isrc, t.id::text))::int AS recordings
      FROM selected s
      LEFT JOIN playlist_entries pe ON pe.playlist_id = s.active_playlist_id
      LEFT JOIN tracks t ON t.id = pe.track_id
    ), deduped AS (
      SELECT DISTINCT ON (COALESCE(t.isrc, t.id::text))
        t.artist, t.genre, t.release_year, f.tempo, f.energy,
        COALESCE(t.isrc, t.id::text) AS recording_key
      FROM selected s
      JOIN playlist_entries pe ON pe.playlist_id = s.active_playlist_id
      JOIN tracks t ON t.id = pe.track_id
      LEFT JOIN track_features f ON f.track_id = t.id
      ORDER BY COALESCE(t.isrc, t.id::text), pe.position
    ), ranked AS (
      SELECT deduped.*, ROW_NUMBER() OVER (
        PARTITION BY lower(btrim(artist)) ORDER BY md5(recording_key), recording_key
      ) AS artist_rank
      FROM deduped
    ), sampled AS (
      SELECT * FROM ranked WHERE artist_rank <= ${MAX_PROFILE_RECORDINGS_PER_ARTIST}
      ORDER BY md5(recording_key), recording_key LIMIT ${MAX_PROFILE_RECORDINGS}
    ), profile AS (
      SELECT COUNT(*)::int AS sampled_recordings,
        AVG(tempo) AS tempo, AVG(energy) AS energy, AVG(release_year) AS release_year,
        ARRAY_AGG(DISTINCT artist ORDER BY artist) FILTER (WHERE artist IS NOT NULL) AS artists,
        ARRAY_AGG(DISTINCT genre ORDER BY genre) FILTER (WHERE genre IS NOT NULL) AS genres
      FROM sampled
    )
    SELECT selected.*, coverage.*, profile.*
    FROM selected CROSS JOIN coverage CROSS JOIN profile
  `)
  const rows = (Array.isArray(raw) ? raw : (raw as { rows?: unknown[] }).rows ?? []) as Array<Record<string, unknown>>
  const row = rows[0]
  if (!row) throw new PlaylistSeedError('not_found')
  const optionalNumber = (value: unknown) => value === null || value === undefined ? null : Number(value)
  const state: PlaylistSeedState = {
    playlistId: (row.playlist_id as string | null) ?? null,
    revision: Number(row.revision),
    excludeSourceTracks: Boolean(row.exclude_source_tracks),
    status: row.enabled ? 'unavailable' : 'none',
    name: null,
    source: null,
    fingerprint: null,
    updatedAt: null,
    entries: Number(row.entries),
    resolvedEntries: Number(row.resolved_entries),
    recordings: Number(row.recordings),
    profile: null,
  }
  if (!row.enabled || !row.active_playlist_id) return state
  const profile = { sampledRecordings: Number(row.sampled_recordings ?? 0),
    tempo: optionalNumber(row.tempo), energy: optionalNumber(row.energy),
    releaseYear: optionalNumber(row.release_year), artists: (row.artists as string[] | null) ?? [],
    genres: (row.genres as string[] | null) ?? [] }
  return { ...state, name: row.name as string, source: row.source as PlaylistSeedState['source'],
    fingerprint: row.source_fingerprint as string,
    updatedAt: new Date(row.updated_at as string | Date).toISOString(), profile,
    status: state.recordings >= MIN_PROFILE_RECORDINGS ? 'ready' : 'insufficient_profile' }
}

// Call within a short transaction. Session locking serializes selection/clear
// even when there is no seed row yet (revision zero).
export async function selectPlaylistSeed(db: Db, sessionId: string, userId: string,
  input: z.infer<typeof seedSelectionSchema>): Promise<PlaylistSeedState> {
  return db.transaction(async tx => {
    const [session] = await tx.select({ id: djSessions.id }).from(djSessions)
      .where(and(eq(djSessions.id, sessionId), eq(djSessions.userId, userId))).for('update')
    if (!session) throw new PlaylistSeedError('not_found')
    const [previous] = await tx.select().from(sessionPlaylistSeeds).where(eq(sessionPlaylistSeeds.sessionId, sessionId))
    if ((previous?.revision ?? 0) !== input.expectedRevision) throw new PlaylistSeedError('stale')
    if (input.playlistId) {
      const [p] = await tx.select({ inLibrary: userPlaylists.inLibrary }).from(userPlaylists)
        .where(and(eq(userPlaylists.id, input.playlistId), eq(userPlaylists.userId, userId))).for('share')
      if (!p) throw new PlaylistSeedError('not_found')
      if (!p.inLibrary) throw new PlaylistSeedError('unavailable')
    }
    const values = { sessionId, playlistId: input.playlistId, enabled: input.playlistId !== null,
      excludeSourceTracks: input.playlistId !== null && input.excludeSourceTracks, revision: input.expectedRevision + 1 }
    await tx.insert(sessionPlaylistSeeds).values(values).onConflictDoUpdate({ target: sessionPlaylistSeeds.sessionId, set: values })
    const result = await readPlaylistSeed(tx, sessionId, userId)
    if (result.status === 'insufficient_profile') throw new PlaylistSeedError('insufficient_profile')
    return result
  })
}

export async function createSessionWithPlaylistSeed(db: Db, userId: string, title: string,
  input?: z.infer<typeof initialSeedSchema>) {
  return db.transaction(async tx => {
    if (input) {
      const [p] = await tx.select({ id: userPlaylists.id, inLibrary: userPlaylists.inLibrary }).from(userPlaylists).where(and(
        eq(userPlaylists.id, input.playlistId), eq(userPlaylists.userId, userId),
      )).for('share')
      if (!p) throw new PlaylistSeedError('not_found')
      if (!p.inLibrary) throw new PlaylistSeedError('unavailable')
      const [coverage] = await tx.select({ recordings: sql<number>`count(distinct coalesce(${tracks.isrc}, ${tracks.id}::text))::int` })
        .from(playlistEntries).innerJoin(tracks, eq(tracks.id, playlistEntries.trackId))
        .where(eq(playlistEntries.playlistId, p.id))
      if (coverage.recordings < MIN_PROFILE_RECORDINGS) throw new PlaylistSeedError('insufficient_profile')
    }
    const [session] = await tx.insert(djSessions).values({ userId, title }).returning()
    if (input) await tx.insert(sessionPlaylistSeeds).values({ sessionId: session.id,
      playlistId: input.playlistId, enabled: true, excludeSourceTracks: input.excludeSourceTracks, revision: 1 })
    return session
  })
}
