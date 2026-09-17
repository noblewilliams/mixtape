// Local synthetic harness; not a production entry and never calls providers.
import { createRoot } from 'react-dom/client'
import { App } from '../src/App'
import {
  ApiError,
  type ApiSessionSummary,
  type ApiPlaylistSummary,
  type ApiPlaylistSeed,
  type ApiQueueTrack,
} from '../src/api/client'
import { createFakeApi } from '../src/test/fake-api'
import '../src/styles.css'
const scenario = new URLSearchParams(location.search).get('state')
const sessions: ApiSessionSummary[] = ['A slow way into Sunday', 'Walk home after rain'].map((title, i) => ({
  id: `mix-${i}`,
  title,
  status: 'active',
  queueVersion: 1,
  notPersonal: false,
  updatedAt: '2026-09-08T10:00:00Z',
  trackCount: 3,
  durationMs: 600000,
}))
const queue: ApiQueueTrack[] = ['First light', 'Window seat', 'Way back'].map((title, i) => ({
  position: i,
  trackId: `song-${i}`,
  appleId: `${i + 1}`,
  spotifyId: null,
  title,
  artist: 'Soft Atlas',
  reason: 'A gentle lift.',
  durationMs: 200000,
  artworkUrl: null,
  artworkWidth: null,
  artworkHeight: null,
  artworkBgColor: null,
}))
let notes = [
  { id: 'note-1', note: 'Prefer a gentle start to morning mixes.', createdAt: '2026-09-06' },
  { id: 'note-2', note: 'For dinner, keep vocals in the background.', createdAt: '2026-09-06' },
]
const playlists: ApiPlaylistSummary[] = ['Night Bus Notes', 'Night Bus Notes'].map((name, i) => ({
  id: `playlist-${i}`,
  name,
  source: i ? 'spotify_export' : 'apple',
  entryCount: 3,
  curatorName: null,
  kind: 'user',
  origin: 'unknown',
  artworkUrlTemplate: null,
  artworkWidth: null,
  artworkHeight: null,
  artworkBgColor: null,
  knownDurationMs: 600000,
  durationComplete: true,
  lastModifiedAt: null,
  syncedAt: '2026-09-06T12:00:00Z',
  inLibrary: true,
  capability: 'copy_only',
}))
const seeds = new Map<string, ApiPlaylistSeed>()
const empty: ApiPlaylistSeed = {
  playlistId: null,
  revision: 0,
  excludeSourceTracks: false,
  status: 'none',
  name: null,
  source: null,
  fingerprint: null,
  updatedAt: null,
  entries: 0,
  resolvedEntries: 0,
  recordings: 0,
  profile: null,
}
const detail = (id: string) => ({
  session: sessions.find((s) => s.id === id)!,
  queue,
  messages: [
    {
      id: 'm',
      role: 'dj' as const,
      content: 'A warm start, a little lift in the middle, then room to wind down.',
      createdAt: '2026-09-08T10:00:00Z',
    },
  ],
  playlistSeed: seeds.get(id) ?? empty,
})
const base = createFakeApi()
const api = createFakeApi({
  getOnboarding: async () => ({ ...(await base.getOnboarding()), chosenService: 'apple', hasLibrary: true }),
  listSessions: async () => ({ sessions: [...sessions] }),
  getSession: async (id) => detail(id),
  updateSession: async (id, updates) => {
    if (scenario === 'save-error') throw new Error('fixture')
    const session = sessions.find((s) => s.id === id)!
    Object.assign(session, updates)
    return { session: { ...session } }
  },
  listMemories: async () => {
    if (scenario === 'notes-error') throw new Error('fixture')
    return { memories: notes }
  },
  deleteMemory: async (id) => {
    notes = notes.filter((n) => n.id !== id)
    return { ok: true }
  },
  listPlaylists: async (options) => ({
    playlists: playlists.filter((p) => p.name.toLowerCase().includes(options?.q?.toLowerCase() ?? '')),
    total: 2,
    nextCursor: null,
  }),
  getMusicCollectionSummary: async () => ({
    apple: { songs: 3, playlists: 1, librarySyncedAt: '2026-09-06' },
    spotify: { playlists: 1 },
  }),
  getPlaylist: async (id) => ({
    playlist: { ...playlists.find((p) => p.id === id)! },
    entries: [],
    nextEntryCursor: null,
  }),
  confirmPlaylistTaste: async (id, confirmed) => {
    playlists.find((p) => p.id === id)!.origin = confirmed ? 'user_confirmed' : 'unknown'
    return { ok: true }
  },
  selectPlaylistSeed: async (id, input) => {
    if (scenario === 'seed-conflict') throw new ApiError(409, { error: 'stale' })
    const p = playlists.find((p) => p.id === input.playlistId)
    const value = {
      ...empty,
      revision: input.expectedRevision + 1,
      playlistId: p?.id ?? null,
      name: p?.name ?? null,
      source: p?.source ?? null,
      status: p ? ('ready' as const) : ('none' as const),
      excludeSourceTracks: input.excludeSourceTracks,
      entries: 3,
      resolvedEntries: 3,
      recordings: 3,
    }
    seeds.set(id, value)
    return { playlistSeed: value }
  },
  createSession: async (prompt, seed) => {
    const id = `mix-${sessions.length}`
    sessions.push({ ...sessions[0], id, title: prompt })
    if (seed) {
      const p = playlists.find((p) => p.id === seed.playlistId)!
      seeds.set(id, {
        ...empty,
        playlistId: p.id,
        name: p.name,
        source: p.source,
        excludeSourceTracks: seed.excludeSourceTracks ?? false,
        status: 'ready',
        revision: 1,
      })
    }
    return detail(id)
  },
})
createRoot(document.getElementById('root')!).render(
  <App
    api={api}
    user={{ id: 'controls-qa', name: 'Jules', email: 'jules@example.test' }}
    lastSignInProvider="google"
    accountAuth={{
      listAccounts: async () => [],
      linkProvider: async () => ({}),
      unlinkAccount: async () => ({}),
    }}
    musicKit={{
      connect: async () => {},
      snapshot: async () => ({
        storefront: 'ng',
        songs: [],
        playlists: [],
        playlistEntries: [],
        recentCatalogIds: [],
        excludedLibrarySongs: 0,
      }),
      play: async () => {},
      pause: async () => {},
      createPlaylist: async () => {},
    }}
    onSignOut={() => location.reload()}
  />,
)
