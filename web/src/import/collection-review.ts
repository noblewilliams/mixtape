import type {
  LibraryReview,
  PlaylistReview,
  SpotifyCollectionReview,
} from '../api/client'
import type { ListeningExportSnapshot } from './snapshot'
export type FileSelection = {
  ordinal: number
  name: string
  role: 'playlist' | 'liked' | 'skip'
  target: string | null
  createKey: string
  fileHash: string
}
export type CollectionSelection = {
  context: SpotifyCollectionReview
  files: FileSelection[]
  libraryMode: 'add' | 'replace'
  confirmed: boolean
  confirmRemovals: boolean
}
export function initialSelection(
  snapshot: ListeningExportSnapshot,
  context: SpotifyCollectionReview,
): CollectionSelection {
  return {
    context,
    confirmed: false,
    confirmRemovals: false,
    libraryMode: 'add',
    files: snapshot.playlists.map((p, i) => {
      const matches = context.playlists.filter((t) => t.fileHash === p.key)
      return {
        ordinal: p.ordinal,
        name: p.name,
        role: 'playlist',
        target: matches.length === 1 ? matches[0].key : null,
        createKey: `exportify:${p.key}:${i}`,
        fileHash: p.key,
      }
    }),
  }
}
export function applySelection(
  original: ListeningExportSnapshot,
  selection: CollectionSelection,
): {
  snapshot: ListeningExportSnapshot
  libraryReview: LibraryReview
  playlistReview: PlaylistReview
} {
  if (
    !selection.confirmed ||
    selection.files.filter((f) => f.role === 'liked').length > 1
  )
    throw new Error('Review the collection roles before importing.')
  const library = new Map(original.library.map((r) => [r.platformId, r]))
  const playlists: ListeningExportSnapshot['playlists'] = [],
    playlistReview: PlaylistReview = []
  const used = new Set<string>()
  for (const file of selection.files) {
    if (file.role === 'skip') continue
    const p = original.playlists.find((p) => p.ordinal === file.ordinal)
    if (!p) throw new Error('Review the files again.')
    if (file.role === 'liked') {
      for (const e of p.entries)
        if (e.platformId)
          library.set(e.platformId, {
            platformId: e.platformId,
            playCount: null,
            skipCount: null,
            lastPlayedAt: null,
            dateAdded:
              e.addedAt ?? library.get(e.platformId)?.dateAdded ?? null,
            likeRating: null,
          })
    } else {
      const target =
        file.target === null
          ? null
          : selection.context.playlists.find((t) => t.key === file.target)
      if (file.target !== null && !target)
        throw new Error('Choose a current playlist.')
      const key = target?.key ?? file.createKey
      if (used.has(key) || !file.name.trim() || file.name.length > 500)
        throw new Error('Choose distinct playlists and valid names.')
      used.add(key)
      playlists.push({
        ...p,
        ordinal: playlists.length,
        key,
        name: file.name.trim(),
      })
      playlistReview.push({
        key,
        baseFingerprint: target?.fingerprint ?? null,
        fileHash: file.fileHash,
      })
    }
  }
  const hasLikes =
    original.package === 'spotify_account' ||
    selection.files.some((f) => f.role === 'liked')
  if (
    (!hasLikes && playlists.length === 0) ||
    (original.package === 'spotify_exportify' &&
      library.size === 0 &&
      playlists.every((p) => p.entries.length === 0))
  )
    throw new Error('Choose at least one collection.')
  if (
    selection.libraryMode === 'replace' &&
    hasLikes &&
    !selection.confirmRemovals
  )
    throw new Error('Confirm replacing imported Liked Songs.')
  const libraryReview: LibraryReview =
    selection.libraryMode === 'replace' && hasLikes
      ? { mode: 'replace', fingerprint: selection.context.library.fingerprint }
      : { mode: 'add' }
  const ids = new Set([
    ...library.keys(),
    ...playlists.flatMap((p) =>
      p.entries.flatMap((e) => (e.platformId ? [e.platformId] : [])),
    ),
  ])
  return {
    snapshot: {
      ...original,
      tracks: original.tracks.filter((t) => ids.has(t.platformId)),
      library: [...library.values()],
      unresolved:
        original.package === 'spotify_exportify'
          ? {
              rows: original.playlists
                .filter((p) =>
                  selection.files.some(
                    (f) => f.ordinal === p.ordinal && f.role !== 'skip',
                  ),
                )
                .reduce(
                  (n, p) => n + p.entries.filter((e) => !e.platformId).length,
                  0,
                ),
              plays: 0,
            }
          : original.unresolved,
      playlists,
    },
    libraryReview,
    playlistReview,
  }
}
