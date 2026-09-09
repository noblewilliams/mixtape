import { and, eq } from 'drizzle-orm'
import type { Db } from '../db/types'
import {
  userMusicSources,
  userPlaylists,
  userTrackLibrarySources,
  tracks,
} from '../db/schema'

export async function reviewHash(value: unknown): Promise<string> {
  const bytes = await crypto.subtle.digest(
    'SHA-256',
    new TextEncoder().encode(JSON.stringify(value)),
  )
  return [...new Uint8Array(bytes)]
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('')
}
export const playlistReviewFingerprint = (
  p: typeof userPlaylists.$inferSelect,
) =>
  reviewHash([
    p.id,
    p.name,
    p.description,
    p.sourceFingerprint,
    p.inLibrary,
    p.updatedAt.toISOString(),
  ])

export async function spotifyLibraryReview(db: Db, userId: string) {
  const rows = await db
    .select({ id: tracks.spotifyId })
    .from(userTrackLibrarySources)
    .innerJoin(tracks, eq(tracks.id, userTrackLibrarySources.trackId))
    .where(
      and(
        eq(userTrackLibrarySources.userId, userId),
        eq(userTrackLibrarySources.source, 'spotify_export'),
      ),
    )
  const ids = rows.flatMap((r) => (r.id ? [r.id] : [])).sort()
  return { ids, fingerprint: await reviewHash(ids) }
}
export async function spotifyCollectionReview(db: Db, userId: string) {
  const library = await spotifyLibraryReview(db, userId)
  const rows = await db
    .select()
    .from(userPlaylists)
    .where(
      and(
        eq(userPlaylists.userId, userId),
        eq(userPlaylists.source, 'spotify_export'),
        eq(userPlaylists.inLibrary, true),
      ),
    )
  const playlists = await Promise.all(
    rows.map(async (p) => ({
      key: p.appleLibraryId,
      name: p.name,
      fileHash: p.importFileHash,
      fingerprint: await playlistReviewFingerprint(p),
    })),
  )
  const [source] = await db
    .select()
    .from(userMusicSources)
    .where(
      and(
        eq(userMusicSources.userId, userId),
        eq(userMusicSources.source, 'spotify_export'),
      ),
    )
  return {
    library,
    playlists,
    hasQuickImport: Boolean(source?.quickImportedAt),
  }
}
