// Listening-export snapshot and inventory types, per
// fixtures/listening-exports/README.md ("Expected file"). Property order in
// these types mirrors the canonical JSON key order; canonical.ts enforces it.

export type ListeningExportSource = 'spotify_export'
export type ListeningExportPackage = 'spotify_extended' | 'spotify_account'

export type SnapshotTrack = {
  platformId: string
  title: string
  artist: string
  album: string | null
  durationMs: number | null
}

export type SnapshotDay = {
  platformId: string
  /** Local calendar day, YYYY-MM-DD, in the snapshot's time zone. */
  day: string
  plays: number
  skips: number
  completes: number
  msPlayed: number
  /** Bit h is set when a counted play ended in local hour h. */
  hoursMask: number
}

export type SnapshotLibraryRow = {
  platformId: string
  playCount: number | null
  skipCount: number | null
  lastPlayedAt: number | null
  dateAdded: number | null
  likeRating: -1 | 0 | 1 | null
}

export type SnapshotArtist = {
  name: string
  spotifyId: string | null
}

export type SnapshotPlaylistEntry = {
  position: number
  platformId: string | null
  title: string
  artist: string
  album: string | null
  addedAt: number | null
}

export type SnapshotPlaylist = {
  ordinal: number
  /** Lowercase hex SHA-256 of `name + " " + ordinal`. */
  key: string
  name: string
  description: string | null
  lastModifiedAt: number | null
  entries: SnapshotPlaylistEntry[]
}

export type SnapshotUnresolved = {
  rows: number
  plays: number
}

export type ListeningExportSnapshot = {
  source: ListeningExportSource
  package: ListeningExportPackage
  timeZone: string
  country: string | null
  tracks: SnapshotTrack[]
  days: SnapshotDay[]
  library: SnapshotLibraryRow[]
  artists: SnapshotArtist[]
  playlists: SnapshotPlaylist[]
  unresolved: SnapshotUnresolved
  ledgerFrom: string | null
  ledgerTo: string | null
}

export type InventoryReadFile = {
  path: string
  /** Row count, or null when the file failed to decode. */
  rows: number | null
}

export type InventoryIgnoredFile = {
  path: string
  /** Uncompressed size from the central directory; the bytes are never read. */
  bytes: number
}

export type ExportInventory = {
  package: ListeningExportPackage | null
  read: InventoryReadFile[]
  ignored: InventoryIgnoredFile[]
}
