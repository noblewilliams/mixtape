import type {
  LibrarySyncSummary,
  MixtapeApi,
  PlaylistSyncSummary,
} from '../api/client'
import type { MusicKitClient } from '../musickit/client'
import type { MusicSnapshotProgress } from '../musickit/library'

export type MusicSyncProgress = MusicSnapshotProgress | {
  stage: 'uploading_library' | 'uploading_playlists'
  completed: number
  total: number
}

export type MusicSyncResult = LibrarySyncSummary & PlaylistSyncSummary & {
  excludedLibrarySongs: number
  recentCatalogIds: string[]
}

export type MusicSyncService = {
  sync(options: {
    signal: AbortSignal
    onProgress: (progress: MusicSyncProgress) => void
  }): Promise<MusicSyncResult>
}

type MusicSyncServiceDeps = {
  musicKit: MusicKitClient
  api: MixtapeApi
}

function chunks<T>(values: T[], size: number) {
  const result: T[][] = []
  for (let index = 0; index < values.length; index += size) {
    result.push(values.slice(index, index + size))
  }
  return result
}

export function createMusicSyncService({ musicKit, api }: MusicSyncServiceDeps): MusicSyncService {
  return {
    async sync({ signal, onProgress }) {
      signal.throwIfAborted()
      await musicKit.connect()
      signal.throwIfAborted()
      const snapshot = await musicKit.snapshot({ signal, onProgress })
      signal.throwIfAborted()

      const libraryRun = await api.beginLibrarySync({
        source: 'web_musickit',
        storefront: snapshot.storefront,
        expectedSongs: snapshot.songs.length,
        expectedRecentTracks: snapshot.recentCatalogIds.length,
      }, signal)
      let uploadedSongs = 0
      for (const songChunk of chunks(snapshot.songs, 500)) {
        signal.throwIfAborted()
        await api.putLibrarySongs(libraryRun.syncId, songChunk, signal)
        uploadedSongs += songChunk.length
        onProgress({
          stage: 'uploading_library',
          completed: uploadedSongs,
          total: snapshot.songs.length,
        })
      }
      signal.throwIfAborted()
      if (snapshot.recentCatalogIds.length > 0) {
        await api.putLibraryRecentTracks(
          libraryRun.syncId,
          snapshot.recentCatalogIds,
          signal,
        )
      }
      signal.throwIfAborted()
      const library = await api.completeLibrarySync(libraryRun.syncId, signal)

      const playlistRun = await api.beginPlaylistSync({
        source: 'web_musickit',
        storefront: snapshot.storefront,
        expectedPlaylists: snapshot.playlists.length,
        expectedEntries: snapshot.playlistEntries.length,
      }, signal)
      let uploadedPlaylistRows = 0
      for (const playlistChunk of chunks(snapshot.playlists, 50)) {
        signal.throwIfAborted()
        await api.putPlaylists(playlistRun.syncId, playlistChunk, signal)
        uploadedPlaylistRows += playlistChunk.length
        onProgress({
          stage: 'uploading_playlists',
          completed: uploadedPlaylistRows,
          total: snapshot.playlists.length + snapshot.playlistEntries.length,
        })
      }
      for (const playlist of snapshot.playlists) {
        const entries = snapshot.playlistEntries
          .filter((entry) => entry.playlistAppleId === playlist.appleLibraryId)
          .map(({ playlistAppleId: _playlistAppleId, ...entry }) => entry)
        for (const entryChunk of chunks(entries, 200)) {
          signal.throwIfAborted()
          await api.putPlaylistEntries(
            playlistRun.syncId,
            playlist.appleLibraryId,
            entryChunk,
            signal,
          )
          uploadedPlaylistRows += entryChunk.length
          onProgress({
            stage: 'uploading_playlists',
            completed: uploadedPlaylistRows,
            total: snapshot.playlists.length + snapshot.playlistEntries.length,
          })
        }
      }
      signal.throwIfAborted()
      const playlists = await api.completePlaylistSync(playlistRun.syncId, signal)
      onProgress({ stage: 'complete', completed: 1, total: 1 })
      return {
        ...library,
        ...playlists,
        excludedLibrarySongs: snapshot.excludedLibrarySongs,
        recentCatalogIds: [...snapshot.recentCatalogIds],
      }
    },
  }
}
