import type {
  ListeningExportSnapshot,
  SnapshotArtist,
  SnapshotDay,
  SnapshotLibraryRow,
  SnapshotPlaylist,
  SnapshotPlaylistEntry,
  SnapshotTrack,
} from './snapshot'

/** Ordinal comparison by UTF-16 code unit: the only string order the contract uses. */
export const compareOrdinal = (a: string, b: string): number => (a < b ? -1 : a > b ? 1 : 0)

const compareNullLast = (a: string | null, b: string | null): number =>
  a === null ? (b === null ? 0 : 1) : b === null ? -1 : compareOrdinal(a, b)

const trackRow = (track: SnapshotTrack): SnapshotTrack => ({
  platformId: track.platformId,
  title: track.title,
  artist: track.artist,
  album: track.album,
  durationMs: track.durationMs,
})

const dayRow = (day: SnapshotDay): SnapshotDay => ({
  platformId: day.platformId,
  day: day.day,
  plays: day.plays,
  skips: day.skips,
  completes: day.completes,
  msPlayed: day.msPlayed,
  hoursMask: day.hoursMask,
})

const libraryRow = (row: SnapshotLibraryRow): SnapshotLibraryRow => ({
  platformId: row.platformId,
  playCount: row.playCount,
  skipCount: row.skipCount,
  lastPlayedAt: row.lastPlayedAt,
  dateAdded: row.dateAdded,
  likeRating: row.likeRating,
})

const artistRow = (artist: SnapshotArtist): SnapshotArtist => ({
  name: artist.name,
  spotifyId: artist.spotifyId,
})

const entryRow = (entry: SnapshotPlaylistEntry): SnapshotPlaylistEntry => ({
  position: entry.position,
  platformId: entry.platformId,
  title: entry.title,
  artist: entry.artist,
  album: entry.album,
  addedAt: entry.addedAt,
})

const playlistRow = (playlist: SnapshotPlaylist): SnapshotPlaylist => ({
  ordinal: playlist.ordinal,
  key: playlist.key,
  name: playlist.name,
  description: playlist.description,
  lastModifiedAt: playlist.lastModifiedAt,
  entries: [...playlist.entries].sort((a, b) => a.position - b.position).map(entryRow),
})

/**
 * The snapshot with the contract's key order and sort orders: tracks by
 * platformId; days by platformId then day; library by platformId; artists by
 * name (ties by spotifyId, null last); playlists by ordinal; entries by
 * position. Returns a fresh structure; the input is left alone.
 */
export function canonicalize(snapshot: ListeningExportSnapshot): ListeningExportSnapshot {
  return {
    source: snapshot.source,
    package: snapshot.package,
    timeZone: snapshot.timeZone,
    country: snapshot.country,
    tracks: [...snapshot.tracks].sort((a, b) => compareOrdinal(a.platformId, b.platformId)).map(trackRow),
    days: [...snapshot.days]
      .sort((a, b) => compareOrdinal(a.platformId, b.platformId) || compareOrdinal(a.day, b.day))
      .map(dayRow),
    library: [...snapshot.library].sort((a, b) => compareOrdinal(a.platformId, b.platformId)).map(libraryRow),
    artists: [...snapshot.artists]
      .sort((a, b) => compareOrdinal(a.name, b.name) || compareNullLast(a.spotifyId, b.spotifyId))
      .map(artistRow),
    playlists: [...snapshot.playlists].sort((a, b) => a.ordinal - b.ordinal).map(playlistRow),
    unresolved: { rows: snapshot.unresolved.rows, plays: snapshot.unresolved.plays },
    ledgerFrom: snapshot.ledgerFrom,
    ledgerTo: snapshot.ledgerTo,
  }
}

/** Canonical snapshot as the fixture suite serializes it: two-space pretty print, trailing newline. */
export function canonicalJson(snapshot: ListeningExportSnapshot): string {
  return `${JSON.stringify(canonicalize(snapshot), null, 2)}\n`
}
