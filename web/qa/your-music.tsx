// Local-only Vite entry, not a production build input. No provider or server requests.
import { createRoot } from 'react-dom/client'
import { App } from '../src/App'
import { createFakeApi } from '../src/test/fake-api'
import type { ApiPlaylistSummary } from '../src/api/client'
import type { MusicKitClient } from '../src/musickit/client'
import '../src/styles.css'

const scenario = new URLSearchParams(location.search).get('state') ?? 'complete'
const names = [
  'A slow way into Sunday',
  'After the last train',
  'Something with a little warmth',
  'Home recordings',
  'Quiet hours',
  'Window seat',
]
const playlists: ApiPlaylistSummary[] = names.map((name, index) => ({
  id: `playlist-${index}`,
  name,
  source: index % 2 ? 'spotify_export' : 'apple',
  curatorName: null,
  kind: 'user',
  entryCount: 5,
  knownDurationMs: 840000,
  durationComplete: true,
  artworkUrlTemplate: null,
  artworkWidth: null,
  artworkHeight: null,
  artworkBgColor: null,
  inLibrary: true,
  capability: 'copy_only',
  syncedAt: '2026-09-04T12:00:00Z',
  lastModifiedAt: null,
}))
const base = createFakeApi()
let confirmations = 0
const api = createFakeApi({
  getOnboarding: async () => ({ ...(await base.getOnboarding()), chosenService: 'apple', hasLibrary: true }),
  getMusicCollectionSummary: async () => {
    if (scenario === 'sources-failed') throw new Error('fixture')
    return {
      apple: { songs: 1842, playlists: 38, librarySyncedAt: '2026-09-04T12:00:00Z' },
      spotify: { playlists: 26 },
    }
  },
  listPlaylists: async (options) => {
    if (scenario === 'collection-failed') throw new Error('fixture')
    const matches = playlists.filter(
      (p) =>
        (!options?.source || p.source === options.source) &&
        (!options?.q || p.name.toLowerCase().includes(options.q.toLowerCase())),
    )
    return { playlists: matches, nextCursor: null, total: matches.length }
  },
  getPlaylist: async (id) => ({
    playlist: playlists.find((p) => p.id === id)!,
    nextEntryCursor: null,
    entries: [0, 1, 2, 3, 4].map((position) => ({
      id: `entry-${position}`,
      position,
      trackId: null,
      appleCatalogId: position === 3 ? null : '100',
      spotifyId: position === 3 ? null : '4uLU6hMCjMI75M1A2tKUQC',
      title: position === 3 ? 'Home recording 7' : position % 2 ? 'After the last train' : 'Window seat',
      artist: 'Mira Vale',
      album: null,
      durationMs: position === 3 ? null : 221000,
      artworkUrlTemplate: null,
      artworkWidth: null,
      artworkHeight: null,
      artworkBgColor: null,
      resolved: false,
    })),
  }),
  completeLibrarySync: async () => ({
    songs: 1842,
    catalogResolved: 1842,
    recentTracks: 0,
    playCountsObserved: 0,
  }),
  beginPlaylistSync: async () => {
    if (scenario === 'partial') throw new Error('fixture')
    return { syncId: 'qa-playlists', expiresAt: 9999999999 }
  },
  completePlaylistSync: async () => {
    if (scenario === 'checking' && confirmations++ === 0) throw new Error('fixture')
    return { playlists: 38, entries: 1240, resolvedEntries: 1233, unresolvedEntries: 7 }
  },
})
const musicKit: MusicKitClient = {
  connect: async () => undefined,
  snapshot: async ({ onProgress, signal }) => {
    onProgress({ stage: 'library_songs', completed: 600 })
    if (scenario === 'reading')
      await new Promise<void>((_, reject) =>
        signal.addEventListener('abort', () => reject(new DOMException('Cancelled', 'AbortError')), {
          once: true,
        }),
      )
    return {
      storefront: 'ng',
      songs: [],
      playlists: [],
      playlistEntries: [],
      recentCatalogIds: [],
      excludedLibrarySongs: 7,
    }
  },
  play: async () => undefined,
  pause: async () => undefined,
  createPlaylist: async () => undefined,
}
createRoot(document.getElementById('root')!).render(
  <App
    api={api}
    musicKit={musicKit}
    accountAuth={{
      listAccounts: async () => [],
      linkProvider: async () => ({}),
      unlinkAccount: async () => ({}),
    }}
    user={{ id: 'local-qa', name: 'Jules', email: 'jules@example.test' }}
    lastSignInProvider="google"
    onSignOut={() => location.reload()}
  />,
)
