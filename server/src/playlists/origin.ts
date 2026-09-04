import { and, eq, sql } from 'drizzle-orm'
import type { Db } from '../db/types'
import { djSessions, playlistOrigins, userMusicProfiles, userPlaylists } from '../db/schema'

// Shared by browse and scoring. Caller aliases the user-owned snapshot as up.
// A legacy known-Mixtape flag always wins, even over an inconsistent receipt.
export const playlistOriginSql = sql`CASE WHEN up.is_mixtape_owned THEN 'mixtape'
  ELSE COALESCE((SELECT po.origin FROM playlist_origins po
    WHERE po.user_id = up.user_id AND po.source = up.source
      AND po.library_id = up.apple_library_id), 'unknown') END`

export async function recordPlaylistCreation(db: Db, userId: string, sessionId: string, libraryId: string) {
  const [session] = await db.select({ id: djSessions.id }).from(djSessions)
    .where(and(eq(djSessions.id, sessionId), eq(djSessions.userId, userId))).limit(1)
  if (!session) return false
  await db.insert(playlistOrigins).values({ userId, source: 'apple', libraryId, origin: 'mixtape' })
    .onConflictDoUpdate({ target: [playlistOrigins.userId, playlistOrigins.source, playlistOrigins.libraryId],
      set: { origin: 'mixtape' } })
  return true
}

export async function confirmPlaylistTaste(db: Db, userId: string, playlistId: string, confirmed: boolean) {
  return db.transaction(async tx => {
    // Same lock order as sync/source deletion: confirmation cannot resurrect
    // a source's evidence while that source is being removed.
    await tx.select().from(userMusicProfiles).where(eq(userMusicProfiles.userId, userId)).for('update')
    const [playlist] = await tx.select().from(userPlaylists)
      .where(and(eq(userPlaylists.userId, userId), eq(userPlaylists.id, playlistId))).for('update')
    if (!playlist) return 'not_found' as const
    const key = and(eq(playlistOrigins.userId, userId), eq(playlistOrigins.source, playlist.source),
      eq(playlistOrigins.libraryId, playlist.appleLibraryId))
    if (!confirmed) {
      await tx.delete(playlistOrigins).where(and(key, eq(playlistOrigins.origin, 'user_confirmed')))
      return 'ok' as const
    }
    if (!playlist.inLibrary || playlist.isMixtapeOwned
      || ['editorial', 'replay', 'personal_mix'].includes(playlist.kind)) return 'ineligible' as const
    // Concurrent creation receipt wins regardless of which write arrives first.
    const written = await tx.insert(playlistOrigins).values({ userId, source: playlist.source,
      libraryId: playlist.appleLibraryId, origin: 'user_confirmed' }).onConflictDoUpdate({
      target: [playlistOrigins.userId, playlistOrigins.source, playlistOrigins.libraryId],
      set: { origin: 'user_confirmed' }, setWhere: eq(playlistOrigins.origin, 'user_confirmed'),
    }).returning()
    return written.length ? 'ok' as const : 'ineligible' as const
  })
}
