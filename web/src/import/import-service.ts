// Snapshot → server, modelled on sync/music-sync-service.ts: the parsed
// listening-export snapshot goes up through the staged listening-import
// protocol in bounded chunks, then (account package only) the playlists go
// through the staged playlist-sync protocol with a null storefront. The
// signal is checked between every step, so a cancel never issues another
// request. Nothing here logs: rows carry track, artist, and playlist names.

import type {
  ApiError,
  BeginListeningImportInput,
  ListeningArtistRow,
  ListeningDayRow,
  ListeningImportSummary,
  ListeningLibraryRow,
  ListeningTrackRow,
  MixtapeApi,
  PlaylistSyncSummary,
} from '../api/client'
import type { PlaylistEntrySnapshot, PlaylistSnapshot } from '../musickit/library'
import type { ExportInventory, ListeningExportSnapshot, SnapshotPlaylist, SnapshotPlaylistEntry } from './snapshot'
import type { ParseProgress, ParseResult } from './spotify-parser'

// Chunk ceilings from server/src/listening/contracts.ts and playlists/contracts.ts.
export const LISTENING_TRACK_CHUNK = 500
export const LISTENING_DAY_CHUNK = 2_000
export const LISTENING_LIBRARY_CHUNK = 500
export const LISTENING_ARTIST_CHUNK = 500
export const PLAYLIST_CHUNK = 50
export const PLAYLIST_ENTRY_CHUNK = 200

/** The parser calls the service needs: the Worker client on the page, the pure parser in tests. */
export type ImportParser = {
  inspect(file: Blob, options?: { signal?: AbortSignal }): Promise<ExportInventory>
  parse(file: Blob, options: {
    timeZone: string
    includePrivateSessions: boolean
    signal?: AbortSignal
    onProgress?: (progress: ParseProgress) => void
  }): Promise<ParseResult>
}

export type ListeningUploadStage =
  | 'uploading_tracks'
  | 'uploading_days'
  | 'uploading_library'
  | 'uploading_artists'
  | 'uploading_playlists'
  | 'complete'

export type ListeningImportProgress =
  | ParseProgress
  | { stage: ListeningUploadStage; completed: number; total: number }

export type ListeningImportResult = {
  inventory: ExportInventory
  summary: ListeningImportSummary
  /** The playlist sync's summary for an account package; null when the package carries no playlists or the sync failed. */
  playlists: PlaylistSyncSummary | null
  /**
   * What stopped the playlist sync, when something did. The listening
   * history had already been committed by then, so the upload resolves as
   * a partial success instead of rejecting. Null when the sync succeeded
   * or never ran.
   */
  playlistError: ApiError | Error | null
}

export type ListeningImportService = {
  /** The inventory for the drop-zone card; records `file_inspected` without waiting on it. */
  inspect(file: Blob, options?: { signal?: AbortSignal }): Promise<ExportInventory>
  upload(file: Blob, options: {
    timeZone: string
    includePrivateSessions: boolean
    signal: AbortSignal
    onProgress: (progress: ListeningImportProgress) => void
  }): Promise<ListeningImportResult>
}

type ListeningImportServiceDeps = {
  api: MixtapeApi
  parser: ImportParser
}

function chunks<T>(values: T[], size: number): T[][] {
  const result: T[][] = []
  for (let index = 0; index < values.length; index += size) {
    result.push(values.slice(index, index + size))
  }
  return result
}

const encoder = new TextEncoder()

async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', encoder.encode(text))
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, '0')).join('')
}

/**
 * The playlist's `sourceFingerprint`: lowercase hex SHA-256 over one line per
 * entry in position order, `position \t platformId (blank when absent) \t
 * title \t artist`, joined by "\n". The same content on a re-import gives the
 * same fingerprint, so the server can skip an unchanged playlist.
 */
export function playlistFingerprint(playlist: SnapshotPlaylist): Promise<string> {
  const lines = playlist.entries.map(
    (entry) => `${entry.position}\t${entry.platformId ?? ''}\t${entry.title}\t${entry.artist}`,
  )
  return sha256Hex(lines.join('\n'))
}

// Explicit field-by-field maps: the server schemas are strict, so a field
// the snapshot grows later must be mapped on purpose, never spread through.

function toTrackRow(track: ListeningExportSnapshot['tracks'][number], ordinal: number): ListeningTrackRow {
  return {
    ordinal,
    platformId: track.platformId,
    title: track.title,
    artist: track.artist,
    album: track.album,
    durationMs: track.durationMs,
  }
}

function toDayRow(day: ListeningExportSnapshot['days'][number], ordinal: number): ListeningDayRow {
  return {
    ordinal,
    platformId: day.platformId,
    day: day.day,
    plays: day.plays,
    skips: day.skips,
    completes: day.completes,
    msPlayed: day.msPlayed,
    hoursMask: day.hoursMask,
  }
}

function toLibraryRow(row: ListeningExportSnapshot['library'][number], ordinal: number): ListeningLibraryRow {
  return {
    ordinal,
    platformId: row.platformId,
    playCount: row.playCount,
    skipCount: row.skipCount,
    lastPlayedAt: row.lastPlayedAt,
    dateAdded: row.dateAdded,
    likeRating: row.likeRating,
  }
}

function toArtistRow(artist: ListeningExportSnapshot['artists'][number], ordinal: number): ListeningArtistRow {
  return { ordinal, name: artist.name, spotifyId: artist.spotifyId }
}

function toPlaylistSnapshot(playlist: SnapshotPlaylist, sourceFingerprint: string): PlaylistSnapshot {
  return {
    ordinal: playlist.ordinal,
    appleLibraryId: playlist.key,
    appleCatalogId: null,
    name: playlist.name,
    description: playlist.description,
    curatorName: null,
    artworkUrlTemplate: null,
    artworkWidth: null,
    artworkHeight: null,
    artworkBgColor: null,
    kind: 'user',
    canEdit: false,
    appleDateAdded: null,
    appleLastModifiedAt: playlist.lastModifiedAt,
    sourceFingerprint,
    entryCount: playlist.entries.length,
  }
}

type PlaylistEntryRow = Omit<PlaylistEntrySnapshot, 'playlistAppleId'>

function toPlaylistEntry(key: string, entry: SnapshotPlaylistEntry): PlaylistEntryRow {
  return {
    position: entry.position,
    appleLibraryEntryId: `${key}:${entry.position}`,
    appleLibraryTrackId: null,
    appleCatalogId: null,
    spotifyId: entry.platformId,
    isrcSnapshot: null,
    titleSnapshot: entry.title,
    artistSnapshot: entry.artist,
    albumSnapshot: entry.album,
    durationMsSnapshot: null,
    artworkUrlTemplateSnapshot: null,
    artworkWidthSnapshot: null,
    artworkHeightSnapshot: null,
    artworkBgColorSnapshot: null,
  }
}

function toBeginInput(snapshot: ListeningExportSnapshot): BeginListeningImportInput {
  return {
    source: snapshot.source,
    package: snapshot.package,
    timeZone: snapshot.timeZone,
    country: snapshot.country,
    expectedTracks: snapshot.tracks.length,
    expectedDays: snapshot.days.length,
    expectedLibraryTracks: snapshot.library.length,
    expectedArtists: snapshot.artists.length,
    unresolvedRows: snapshot.unresolved.rows,
    unresolvedPlays: snapshot.unresolved.plays,
  }
}

const ignore = () => undefined

/** Funnel steps are counts, never a dependency: a failure to record one is dropped, whether it rejects or throws. */
function recordFunnelStep(api: MixtapeApi, type: 'file_inspected' | 'import_completed'): void {
  try {
    void Promise.resolve(api.postFunnelEvent({ type, surface: 'web' })).catch(ignore)
  } catch {
    // Same as a rejection: the step goes unrecorded.
  }
}

/**
 * A cancel, whether raised between steps (`signal.reason` from
 * `throwIfAborted`) or by fetch mid-request (the same reason, or an
 * AbortError from an older runtime). Anything else is a real failure.
 */
function isAbort(error: unknown, signal: AbortSignal): boolean {
  if (signal.aborted && error === signal.reason) return true
  return typeof error === 'object' && error !== null && (error as { name?: unknown }).name === 'AbortError'
}

export function createListeningImportService({ api, parser }: ListeningImportServiceDeps): ListeningImportService {
  async function uploadRows<T>(
    rows: T[],
    size: number,
    stage: Exclude<ListeningUploadStage, 'uploading_playlists' | 'complete'>,
    put: (chunk: T[]) => Promise<unknown>,
    signal: AbortSignal,
    onProgress: (progress: ListeningImportProgress) => void,
  ) {
    let completed = 0
    for (const chunk of chunks(rows, size)) {
      signal.throwIfAborted()
      await put(chunk)
      completed += chunk.length
      onProgress({ stage, completed, total: rows.length })
    }
  }

  async function syncPlaylists(
    playlists: SnapshotPlaylist[],
    signal: AbortSignal,
    onProgress: (progress: ListeningImportProgress) => void,
  ): Promise<PlaylistSyncSummary> {
    const fingerprints = await Promise.all(playlists.map(playlistFingerprint))
    const snapshots = playlists.map((playlist, index) => toPlaylistSnapshot(playlist, fingerprints[index]))
    const totalEntries = playlists.reduce((sum, playlist) => sum + playlist.entries.length, 0)
    const total = playlists.length + totalEntries

    signal.throwIfAborted()
    const run = await api.beginPlaylistSync({
      source: 'spotify_export',
      storefront: null,
      expectedPlaylists: playlists.length,
      expectedEntries: totalEntries,
    }, signal)
    let completed = 0
    for (const chunk of chunks(snapshots, PLAYLIST_CHUNK)) {
      signal.throwIfAborted()
      await api.putPlaylists(run.syncId, chunk, signal)
      completed += chunk.length
      onProgress({ stage: 'uploading_playlists', completed, total })
    }
    for (const playlist of playlists) {
      const entries = playlist.entries.map((entry) => toPlaylistEntry(playlist.key, entry))
      for (const chunk of chunks(entries, PLAYLIST_ENTRY_CHUNK)) {
        signal.throwIfAborted()
        await api.putPlaylistEntries(run.syncId, playlist.key, chunk, signal)
        completed += chunk.length
        onProgress({ stage: 'uploading_playlists', completed, total })
      }
    }
    signal.throwIfAborted()
    return api.completePlaylistSync(run.syncId, signal)
  }

  return {
    async inspect(file, options = {}) {
      const inventory = await parser.inspect(file, { signal: options.signal })
      recordFunnelStep(api, 'file_inspected')
      return inventory
    },

    async upload(file, { timeZone, includePrivateSessions, signal, onProgress }) {
      signal.throwIfAborted()
      const { inventory, snapshot } = await parser.parse(file, {
        timeZone,
        includePrivateSessions,
        signal,
        onProgress,
      })
      signal.throwIfAborted()

      const run = await api.beginListeningImport(toBeginInput(snapshot), signal)
      const { importId } = run
      await uploadRows(
        snapshot.tracks.map(toTrackRow), LISTENING_TRACK_CHUNK, 'uploading_tracks',
        (chunk) => api.putListeningTracks(importId, chunk, signal), signal, onProgress,
      )
      await uploadRows(
        snapshot.days.map(toDayRow), LISTENING_DAY_CHUNK, 'uploading_days',
        (chunk) => api.putListeningDays(importId, chunk, signal), signal, onProgress,
      )
      await uploadRows(
        snapshot.library.map(toLibraryRow), LISTENING_LIBRARY_CHUNK, 'uploading_library',
        (chunk) => api.putListeningLibrary(importId, chunk, signal), signal, onProgress,
      )
      await uploadRows(
        snapshot.artists.map(toArtistRow), LISTENING_ARTIST_CHUNK, 'uploading_artists',
        (chunk) => api.putListeningArtists(importId, chunk, signal), signal, onProgress,
      )
      signal.throwIfAborted()
      const summary = await api.completeListeningImport(importId, signal)
      // The history is committed server-side from here, so the funnel step
      // goes up now: the onboarding read derives importCompletedAt from it
      // and must learn the history landed even if the playlists don't.
      recordFunnelStep(api, 'import_completed')

      // Playlists belong to the account package; the listening run has
      // completed by now, so at most one staged run is open at a time. A
      // failure here is reported on the result as a partial success, never
      // as a rejection; only a cancel still rejects.
      let playlists: PlaylistSyncSummary | null = null
      let playlistError: ApiError | Error | null = null
      if (snapshot.package === 'spotify_account') {
        try {
          playlists = await syncPlaylists(snapshot.playlists, signal, onProgress)
        } catch (error) {
          if (isAbort(error, signal)) throw error
          playlistError = error instanceof Error ? error : new Error(String(error), { cause: error })
        }
      }

      onProgress({ stage: 'complete', completed: 1, total: 1 })
      return { inventory, summary, playlists, playlistError }
    },
  }
}
