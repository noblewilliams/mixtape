import type { AlbumType } from '../domain'

const TYPE_LABELS: Record<AlbumType, string> = {
  album: 'Album',
  ep: 'EP',
  single: 'Single',
  live: 'Live',
  compilation: 'Compilation',
  soundtrack: 'Soundtrack',
  mixtape: 'Mixtape',
}

export function albumTypeLabel(type: AlbumType): string {
  return TYPE_LABELS[type] ?? 'Album'
}

/** "44 min" or "1 hr 12 min"; null when the catalogue gave no length. */
export function albumLengthLabel(durationMs: number | null): string | null {
  if (durationMs === null || durationMs <= 0) return null
  const minutes = Math.max(1, Math.round(durationMs / 60_000))
  if (minutes < 60) return `${minutes} min`
  const hours = Math.floor(minutes / 60)
  const remainder = minutes % 60
  return remainder === 0 ? `${hours} hr` : `${hours} hr ${remainder} min`
}

type MetaFields = { type: AlbumType; releaseYear: number | null; trackCount: number | null; durationMs: number | null }

/** The meta line's parts, "{Type}", "{year}", "{n} songs", "{length}", skipping what the catalogue left out. */
export function albumMetaParts(album: MetaFields): string[] {
  const songs = album.trackCount === null ? null : `${album.trackCount} ${album.trackCount === 1 ? 'song' : 'songs'}`
  return [albumTypeLabel(album.type), album.releaseYear?.toString() ?? null, songs, albumLengthLabel(album.durationMs)]
    .filter((part): part is string => Boolean(part))
}

/** The card's meta line, "{Type} · {year} · {n} songs · {length}". */
export function albumMetaLine(album: MetaFields): string {
  return albumMetaParts(album).join(' · ')
}

/** A row's byline, "artist · Type · year". */
export function albumByline(album: { artist: string; type: AlbumType; releaseYear: number | null }): string {
  return [album.artist, albumTypeLabel(album.type), album.releaseYear?.toString() ?? null]
    .filter((part): part is string => Boolean(part))
    .join(' · ')
}

/** Apple artwork templates carry {w}x{h}.{f}; drawn at twice the CSS size. */
export function albumArtworkSource(template: string | undefined, size: number): string | null {
  if (!template) return null
  return template.replaceAll('{w}', String(size * 2)).replaceAll('{h}', String(size * 2)).replaceAll('{f}', 'jpg')
}

/** Spotify-only listeners get a search, never an id: no Spotify album ids exist in Mixtape. */
export function spotifySearchUrl(album: { artist: string; title: string }): string {
  return `https://open.spotify.com/search/${encodeURIComponent(`${album.artist} ${album.title}`)}`
}
