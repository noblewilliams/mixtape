import { ApiError, type LibrarySyncSummary, type MixtapeApi, type PlaylistSyncSummary } from '../api/client'
import type { MusicKitClient } from '../musickit/client'
import type { MusicSnapshot, MusicSnapshotProgress } from '../musickit/library'

export type MusicSyncProgress =
  | MusicSnapshotProgress
  | {
      stage:
        'authorizing' | 'uploading_library' | 'uploading_playlists' | 'saving_library' | 'saving_playlists'
      completed: number
      total?: number
      library?: LibrarySyncSummary
    }

type SnapshotSummary = { excludedLibrarySongs: number; recentCatalogIds: string[] }
export type MusicSyncOptions = {
  signal: AbortSignal
  onProgress: (progress: MusicSyncProgress) => void
}
export type MusicSyncFailure = 'connection' | 'session' | 'conflict'
export type MusicSyncResult =
  | (LibrarySyncSummary & PlaylistSyncSummary & SnapshotSummary & { kind: 'complete' })
  | (SnapshotSummary & {
      kind: 'partial'
      library: LibrarySyncSummary
      reason: 'failed' | 'cancelled'
      failure: MusicSyncFailure
    })
  | (SnapshotSummary & {
      kind: 'unconfirmed'
      stage: 'library' | 'playlists'
      library: LibrarySyncSummary | null
      failure: MusicSyncFailure
      /** Retry the same completion, never start a replacement run. Memory-only. */
      check(options: MusicSyncOptions): Promise<MusicSyncResult>
    })

export type MusicSyncService = { sync(options: MusicSyncOptions): Promise<MusicSyncResult> }
type MusicSyncServiceDeps = { musicKit: MusicKitClient; api: MixtapeApi }

function chunks<T>(values: T[], size: number) {
  const result: T[][] = []
  for (let index = 0; index < values.length; index += size) result.push(values.slice(index, index + size))
  return result
}

function failureKind(error: unknown): MusicSyncFailure {
  if (error instanceof ApiError && error.status === 401) return 'session'
  if (error instanceof ApiError && [404, 409, 410].includes(error.status)) return 'conflict'
  return 'connection'
}

export function createMusicSyncService({ musicKit, api }: MusicSyncServiceDeps): MusicSyncService {
  // A completion can commit even if the browser loses its response. Retain a
  // continuation that retries that exact idempotent operation. The app-owned
  // run keeps its upload lease while this outcome is unknown.
  async function confirm<T>(
    stage: 'library' | 'playlists',
    summary: SnapshotSummary,
    library: LibrarySyncSummary | null,
    publish: (signal: AbortSignal) => Promise<T>,
    next: (value: T, options: MusicSyncOptions) => Promise<MusicSyncResult>,
    options: MusicSyncOptions,
  ): Promise<MusicSyncResult> {
    options.onProgress({
      stage: stage === 'library' ? 'saving_library' : 'saving_playlists',
      completed: 0,
      ...(library ? { library } : {}),
    })
    let value: T
    try {
      value = await publish(options.signal)
    } catch (error) {
      return {
        kind: 'unconfirmed',
        stage,
        library,
        ...summary,
        failure: failureKind(error),
        check: (retryOptions) => confirm(stage, summary, library, publish, next, retryOptions),
      }
    }
    return next(value, options)
  }

  async function uploadPlaylists(
    snapshot: MusicSnapshot,
    library: LibrarySyncSummary,
    summary: SnapshotSummary,
    options: MusicSyncOptions,
  ): Promise<MusicSyncResult> {
    const { signal, onProgress } = options
    try {
      signal.throwIfAborted()
      onProgress({
        stage: 'uploading_playlists',
        completed: 0,
        total: snapshot.playlistEntries.length,
        library,
      })
      const run = await api.beginPlaylistSync(
        {
          source: 'web_musickit',
          storefront: snapshot.storefront,
          expectedPlaylists: snapshot.playlists.length,
          expectedEntries: snapshot.playlistEntries.length,
        },
        signal,
      )
      for (const batch of chunks(snapshot.playlists, 50)) {
        signal.throwIfAborted()
        await api.putPlaylists(run.syncId, batch, signal)
      }
      const byPlaylist = new Map<
        string,
        Omit<MusicSnapshot['playlistEntries'][number], 'playlistAppleId'>[]
      >()
      for (const { playlistAppleId, ...entry } of snapshot.playlistEntries) {
        const entries = byPlaylist.get(playlistAppleId) ?? []
        entries.push(entry)
        byPlaylist.set(playlistAppleId, entries)
      }
      let completed = 0
      for (const playlist of snapshot.playlists) {
        for (const batch of chunks(byPlaylist.get(playlist.appleLibraryId) ?? [], 200)) {
          signal.throwIfAborted()
          await api.putPlaylistEntries(run.syncId, playlist.appleLibraryId, batch, signal)
          completed += batch.length
          onProgress({
            stage: 'uploading_playlists',
            completed,
            total: snapshot.playlistEntries.length,
            library,
          })
        }
      }
      signal.throwIfAborted()
      return confirm(
        'playlists',
        summary,
        library,
        (nextSignal) => api.completePlaylistSync(run.syncId, nextSignal),
        async (playlists, nextOptions) => {
          nextOptions.onProgress({ stage: 'complete', completed: 1, total: 1 })
          return { kind: 'complete', ...library, ...playlists, ...summary }
        },
        options,
      )
    } catch (error) {
      return {
        kind: 'partial',
        library,
        ...summary,
        reason: signal.aborted ? 'cancelled' : 'failed',
        failure: failureKind(error),
      }
    }
  }

  return {
    async sync(options) {
      const { signal, onProgress } = options
      signal.throwIfAborted()
      onProgress({ stage: 'authorizing', completed: 0 })
      await musicKit.connect()
      signal.throwIfAborted()
      const snapshot = await musicKit.snapshot({
        signal,
        onProgress: (progress) => {
          // Snapshot completion is not server publication.
          if (progress.stage !== 'complete') onProgress(progress)
        },
      })
      signal.throwIfAborted()
      const summary = {
        excludedLibrarySongs: snapshot.excludedLibrarySongs,
        recentCatalogIds: [...snapshot.recentCatalogIds],
      }
      const run = await api.beginLibrarySync(
        {
          source: 'web_musickit',
          storefront: snapshot.storefront,
          expectedSongs: snapshot.songs.length,
          expectedRecentTracks: snapshot.recentCatalogIds.length,
        },
        signal,
      )
      let completed = 0
      onProgress({ stage: 'uploading_library', completed, total: snapshot.songs.length })
      for (const batch of chunks(snapshot.songs, 500)) {
        signal.throwIfAborted()
        await api.putLibrarySongs(run.syncId, batch, signal)
        completed += batch.length
        onProgress({ stage: 'uploading_library', completed, total: snapshot.songs.length })
      }
      signal.throwIfAborted()
      if (snapshot.recentCatalogIds.length > 0)
        await api.putLibraryRecentTracks(run.syncId, snapshot.recentCatalogIds, signal)
      signal.throwIfAborted()
      return confirm(
        'library',
        summary,
        null,
        (nextSignal) => api.completeLibrarySync(run.syncId, nextSignal),
        (library, nextOptions) => uploadPlaylists(snapshot, library, summary, nextOptions),
        options,
      )
    },
  }
}
