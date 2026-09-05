import { eq, sql } from 'drizzle-orm'
import type { Db } from '../db/types'
import { tracks, userMusicProfiles } from '../db/schema'
import { sanitizeForPrompt } from '../dj/sanitize'
import type { AppleCatalogSearchClient, CatalogSong } from '../musickit/catalog'
import type { PlaylistEditDraftView } from './store'

export type CatalogDiscoveryInput = {
  query: string
  artist?: string
  album?: string
  limit: number
}

export type CatalogDiscoverySong = {
  trackId: string
  appleId: string
  title: string
  artist: string
  album: string | null
  durationMs: number | null
  genre: string | null
  releaseYear: number | null
  explicit: boolean | null
}

export class PlaylistCatalogError extends Error {
  constructor(readonly category: 'no_storefront' | 'upstream') {
    super(`playlist_catalog:${category}`)
    this.name = 'PlaylistCatalogError'
  }
}

function normalized(value: string): string {
  return value.normalize('NFKC').trim().toLocaleLowerCase('en')
}

function exact(value: string | null, expected: string | undefined): boolean {
  return expected === undefined || (value != null && normalized(value) === normalized(expected))
}

function boundedText(value: string | null, max: number): string | null {
  if (value == null) return null
  const clean = value.replace(/\p{C}+/gu, ' ').trim().slice(0, max).trim()
  return clean || null
}

function insertValue(song: CatalogSong, storefront: string): typeof tracks.$inferInsert {
  return {
    appleId: song.appleId,
    appleCatalogStorefront: storefront,
    isrc: boundedText(song.isrc, 32),
    title: boundedText(song.title, 1000) ?? 'Unknown song',
    artist: boundedText(song.artist, 1000) ?? 'Unknown artist',
    album: boundedText(song.album, 1000),
    genre: boundedText(song.genre ?? null, 250),
    durationMs: song.durationMs ?? null,
    releaseYear: song.releaseYear ?? null,
    explicit: song.explicit ?? null,
    artworkUrlTemplate: song.artwork?.url ?? null,
    artworkWidth: song.artwork?.width ?? null,
    artworkHeight: song.artwork?.height ?? null,
    artworkBgColor: song.artwork?.bgColor ?? null,
    artworkFetchedAt: song.artwork ? new Date() : null,
    artistSource: 'apple_catalog',
    enrichPriority: 1,
  }
}

export async function discoverCatalogSongs(
  db: Db,
  catalog: AppleCatalogSearchClient,
  userId: string,
  draft: PlaylistEditDraftView,
  input: CatalogDiscoveryInput,
): Promise<CatalogDiscoverySong[]> {
  const [profile] = await db.select({ storefront: userMusicProfiles.appleStorefront })
    .from(userMusicProfiles).where(eq(userMusicProfiles.userId, userId)).limit(1)
  if (!profile?.storefront) throw new PlaylistCatalogError('no_storefront')

  let found: CatalogSong[]
  try {
    found = await catalog.searchSongs(profile.storefront, input.query.trim(), input.limit)
  } catch {
    throw new PlaylistCatalogError('upstream')
  }
  const existingAppleIds = new Set(draft.entries.flatMap((entry) =>
    entry.appleCatalogId ? [entry.appleCatalogId] : []))
  const eligible = [...new Map(found.filter((song) =>
    !existingAppleIds.has(song.appleId)
    && exact(song.artist, input.artist)
    && exact(song.album, input.album))
    .map((song) => [song.appleId, song])).values()].slice(0, input.limit)
  if (!eligible.length) return []

  const values = eligible.map((song) => insertValue(song, profile.storefront!))
  const rows = await db.insert(tracks).values(values).onConflictDoUpdate({
    target: tracks.appleId,
    targetWhere: sql`${tracks.appleId} IS NOT NULL`,
    set: {
      appleCatalogStorefront: sql`excluded.apple_catalog_storefront`,
      isrc: sql`coalesce(excluded.isrc, ${tracks.isrc})`,
      title: sql`excluded.title`,
      artist: sql`excluded.artist`,
      album: sql`coalesce(excluded.album, ${tracks.album})`,
      genre: sql`coalesce(excluded.genre, ${tracks.genre})`,
      durationMs: sql`coalesce(excluded.duration_ms, ${tracks.durationMs})`,
      releaseYear: sql`coalesce(excluded.release_year, ${tracks.releaseYear})`,
      explicit: sql`coalesce(excluded.explicit, ${tracks.explicit})`,
      artworkUrlTemplate: sql`coalesce(excluded.artwork_url_template, ${tracks.artworkUrlTemplate})`,
      artworkWidth: sql`coalesce(excluded.artwork_width, ${tracks.artworkWidth})`,
      artworkHeight: sql`coalesce(excluded.artwork_height, ${tracks.artworkHeight})`,
      artworkBgColor: sql`coalesce(excluded.artwork_bg_color, ${tracks.artworkBgColor})`,
      artworkFetchedAt: sql`coalesce(excluded.artwork_fetched_at, ${tracks.artworkFetchedAt})`,
      artistSource: 'apple_catalog',
      enrichPriority: sql`greatest(${tracks.enrichPriority}, 1)`,
    },
  }).returning()
  const byAppleId = new Map(rows.map((row) => [row.appleId, row]))

  return eligible.flatMap((song) => {
    const row = byAppleId.get(song.appleId)
    return row ? [{
      trackId: row.id,
      appleId: song.appleId,
      title: sanitizeForPrompt(song.title, 120),
      artist: sanitizeForPrompt(song.artist, 120),
      album: song.album ? sanitizeForPrompt(song.album, 120) : null,
      durationMs: song.durationMs ?? null,
      genre: song.genre ? sanitizeForPrompt(song.genre, 80) : null,
      releaseYear: song.releaseYear ?? null,
      explicit: song.explicit ?? null,
    }] : []
  })
}
