import type {
  LibrarySongSnapshot,
  PlaylistEntrySnapshot,
  PlaylistSnapshot,
} from '../musickit/library'

export type ApiSessionStatus = 'active' | 'archived'

export type ApiSession = {
  id: string
  title: string
  status: ApiSessionStatus
  queueVersion: number
  /** True once corpus-mode picks landed in the queue: the "Not personal yet" banner. */
  notPersonal: boolean
  updatedAt: string
}

export type ApiSessionSummary = ApiSession & {
  trackCount: number
  durationMs: number
}

export type ApiMessage = {
  id: string
  role: 'user' | 'dj'
  content: string
  queueVersion?: number | null
  createdAt: string
}

export type ApiQueueTrack = {
  position: number
  trackId: string
  appleId: string | null
  spotifyId: string | null
  title: string
  artist: string
  reason?: string | null
  durationMs?: number | null
  artworkUrl: string | null
  artworkWidth: number | null
  artworkHeight: number | null
  artworkBgColor: string | null
}

export type SessionDetailResponse = {
  session: ApiSession
  messages: ApiMessage[]
  queue: ApiQueueTrack[]
}

export type CreateSessionResponse = SessionDetailResponse & {
  sessionTitle?: string
}

export type SendMessageResponse = {
  djMessage: ApiMessage
  queue: ApiQueueTrack[]
  queueVersion: number
  sessionTitle?: string
}

export type QueueOp =
  | { op: 'remove'; position: number }
  | { op: 'move'; from: number; to: number }

export type QueueOpsResponse = {
  queueVersion: number
  requested: number
  added: number
  removed: number
  queue: ApiQueueTrack[]
}

export type MusicKitTokenResponse = {
  developerToken: string
  expiresAt: number
}

export type ApiPlaylistSummary = {
  id: string
  name: string
  curatorName: string | null
  kind: string
  artworkUrlTemplate: string | null
  artworkWidth: number | null
  artworkHeight: number | null
  artworkBgColor: string | null
  entryCount: number
  knownDurationMs: number | null
  lastModifiedAt: string | null
  syncedAt: string | null
  inLibrary: boolean
  capability: 'copy_only'
}

export type ApiPlaylistEntry = {
  id: string
  position: number
  trackId: string | null
  appleCatalogId: string | null
  title: string
  artist: string
  album: string | null
  durationMs: number | null
  artworkUrlTemplate: string | null
  artworkWidth: number | null
  artworkHeight: number | null
  artworkBgColor: string | null
  resolved: boolean
}

export type ApiMemory = { id: string; note: string; createdAt: string }

export type StagedSyncStart = { syncId: string; expiresAt: number }
export type LibrarySyncSummary = {
  songs: number
  catalogResolved: number
  playCountsObserved: number
  recentTracks: number
}
export type PlaylistSyncSummary = {
  playlists: number
  entries: number
  resolvedEntries: number
  unresolvedEntries: number
}

export type ListeningImportSource = 'spotify_export' | 'apple_export'
export type ListeningImportPackage = 'spotify_extended' | 'spotify_account' | 'apple_media'

export type BeginListeningImportInput = {
  source: ListeningImportSource
  package: ListeningImportPackage
  timeZone: string
  country: string | null
  expectedTracks: number
  expectedDays: number
  expectedLibraryTracks: number
  expectedArtists: number
  unresolvedRows: number
  unresolvedPlays: number
}
export type ListeningImportStart = { importId: string; expiresAt: number }
export type ListeningTrackRow = {
  ordinal: number
  platformId: string
  title: string
  artist: string
  album: string | null
  durationMs: number | null
}
export type ListeningDayRow = {
  ordinal: number
  platformId: string
  day: string
  plays: number
  skips: number | null
  completes: number | null
  msPlayed: number
  hoursMask: number | null
}
export type ListeningLibraryRow = {
  ordinal: number
  platformId: string
  playCount: number | null
  skipCount: number | null
  lastPlayedAt: number | null
  dateAdded: number | null
  likeRating: -1 | 0 | 1 | null
}
export type ListeningArtistRow = {
  ordinal: number
  name: string
  spotifyId: string | null
}
export type ListeningImportSummary = {
  tracks: number
  days: number
  libraryTracks: number
  artists: number
  unresolvedRows: number
  unresolvedPlays: number
  ledgerFrom: string | null
  ledgerTo: string | null
  likedRemoved: number
  likedRemovalSkipped: boolean
}
export type DeleteListeningSourceResult = {
  deletedDays: number
  deletedTracks: number
  unlibraried: number
}

export type ApiMusicSource = {
  source: 'apple_live' | 'apple_export' | 'spotify_export'
  connectedAt: string
  lastImportedAt: string | null
  ledgerFrom: string | null
  ledgerTo: string | null
}
export type OnboardingResponse = {
  sources: ApiMusicSource[]
  hasLibrary: boolean
  chosenService: 'spotify' | 'apple' | null
  markedRequestedAt: string | null
  interviewCompletedAt: string | null
  importCompletedAt: string | null
}

export type FunnelEventType =
  | 'chose_spotify'
  | 'marked_requested'
  | 'file_inspected'
  | 'import_completed'
  | 'first_personal_mix'
  | 'first_output'
export type FunnelEventInput = { type: FunnelEventType; surface: 'web' }

export type InterviewInput = {
  surface: 'web'
  neverSkip: string[]
  playsMost: string
  listensWhen: string
  neverWants: string
  era: string
}
export type InterviewResponse = {
  seeds: number
  notes: { saved: number; duplicate: number; capped: number }
}

export type ApiArtistSeed = {
  name: string
  spotifyId: string | null
  source: 'interview' | 'pasted' | 'spotify_export'
  createdAt: string
}
export type ApiSeedTrack = {
  trackId: string
  spotifyId: string | null
  title: string
  artist: string
  album: string | null
}
export type PostSeedTracksResponse = {
  resolved: { spotifyId: string; trackId: string; title: string; artist: string }[]
  unresolved: string[]
}
export type DeleteSeedTrackResponse = { removed: true; deleted: boolean }

export type BeginPlaylistSyncInput =
  | {
    source: 'ios_native' | 'web_musickit'
    storefront: string
    expectedPlaylists: number
    expectedEntries: number
  }
  | {
    source: 'spotify_export'
    storefront: null
    expectedPlaylists: number
    expectedEntries: number
  }

export type MixtapeApi = {
  listSessions: () => Promise<{ sessions: ApiSessionSummary[] }>
  getSession: (sessionId: string) => Promise<SessionDetailResponse>
  createSession: (prompt: string) => Promise<CreateSessionResponse>
  sendMessage: (sessionId: string, text: string) => Promise<SendMessageResponse>
  applyQueueOps: (sessionId: string, ops: QueueOp[], expectedVersion?: number) => Promise<QueueOpsResponse>
  getMusicKitToken: () => Promise<MusicKitTokenResponse>
  recordSessionEvent: (sessionId: string, type: 'played' | 'saved_playlist') => Promise<{ ok: true }>
  updateSession: (
    sessionId: string,
    updates: { title?: string; status?: ApiSessionStatus },
  ) => Promise<{ session: ApiSession }>
  listMemories: () => Promise<{ memories: ApiMemory[] }>
  deleteMemory: (memoryId: string) => Promise<{ ok: true }>
  listPlaylists: (options?: {
    status?: 'active' | 'all'
    q?: string
    limit?: number
    cursor?: string
  }) => Promise<{ playlists: ApiPlaylistSummary[]; nextCursor: string | null }>
  getPlaylist: (
    playlistId: string,
    options?: { entryLimit?: number; entryCursor?: string },
  ) => Promise<{
    playlist: ApiPlaylistSummary
    entries: ApiPlaylistEntry[]
    nextEntryCursor: string | null
  }>
  beginLibrarySync: (input: {
    source: 'ios_native' | 'web_musickit'
    storefront: string
    expectedSongs: number
    expectedRecentTracks: number
  }, signal?: AbortSignal) => Promise<StagedSyncStart>
  putLibrarySongs: (
    syncId: string,
    songs: LibrarySongSnapshot[],
    signal?: AbortSignal,
  ) => Promise<{ accepted: number }>
  putLibraryRecentTracks: (
    syncId: string,
    catalogIds: string[],
    signal?: AbortSignal,
  ) => Promise<{ accepted: number }>
  completeLibrarySync: (syncId: string, signal?: AbortSignal) => Promise<LibrarySyncSummary>
  beginPlaylistSync: (input: BeginPlaylistSyncInput, signal?: AbortSignal) => Promise<StagedSyncStart>
  putPlaylists: (
    syncId: string,
    playlists: PlaylistSnapshot[],
    signal?: AbortSignal,
  ) => Promise<{ accepted: number }>
  putPlaylistEntries: (
    syncId: string,
    playlistAppleId: string,
    entries: Omit<PlaylistEntrySnapshot, 'playlistAppleId'>[],
    signal?: AbortSignal,
  ) => Promise<{ accepted: number }>
  completePlaylistSync: (syncId: string, signal?: AbortSignal) => Promise<PlaylistSyncSummary>
  beginListeningImport: (input: BeginListeningImportInput, signal?: AbortSignal) => Promise<ListeningImportStart>
  putListeningTracks: (importId: string, tracks: ListeningTrackRow[], signal?: AbortSignal) => Promise<{ accepted: number }>
  putListeningDays: (importId: string, days: ListeningDayRow[], signal?: AbortSignal) => Promise<{ accepted: number }>
  putListeningLibrary: (importId: string, tracks: ListeningLibraryRow[], signal?: AbortSignal) => Promise<{ accepted: number }>
  putListeningArtists: (importId: string, artists: ListeningArtistRow[], signal?: AbortSignal) => Promise<{ accepted: number }>
  completeListeningImport: (importId: string, signal?: AbortSignal) => Promise<ListeningImportSummary>
  deleteListeningSource: (source: ListeningImportSource, signal?: AbortSignal) => Promise<DeleteListeningSourceResult>
  getOnboarding: (signal?: AbortSignal) => Promise<OnboardingResponse>
  getMusicSources: (signal?: AbortSignal) => Promise<{ sources: ApiMusicSource[] }>
  postFunnelEvent: (event: FunnelEventInput, signal?: AbortSignal) => Promise<{ ok: true }>
  postInterview: (answers: InterviewInput, signal?: AbortSignal) => Promise<InterviewResponse>
  getArtistSeeds: (signal?: AbortSignal) => Promise<{ seeds: ApiArtistSeed[] }>
  putArtistSeeds: (names: string[], signal?: AbortSignal) => Promise<{ seeds: ApiArtistSeed[] }>
  getSeedTracks: (signal?: AbortSignal) => Promise<{ tracks: ApiSeedTrack[] }>
  postSeedTracks: (spotifyIds: string[], signal?: AbortSignal) => Promise<PostSeedTracksResponse>
  deleteSeedTrack: (trackId: string, signal?: AbortSignal) => Promise<DeleteSeedTrackResponse>
}

export class ApiError extends Error {
  readonly status: number
  readonly code?: string
  readonly payload: unknown

  constructor(status: number, payload: unknown) {
    const record = isRecord(payload) ? payload : null
    const message = typeof record?.message === 'string' ? record.message : `Request failed with status ${status}`
    super(message)
    this.name = 'ApiError'
    this.status = status
    // A schema miss from the server's zValidator comes back as
    // `{ success: false, error: ZodError }` rather than a code string; fold
    // it into the code the malformed-JSON guard uses so a page branches once.
    this.code = typeof record?.error === 'string'
      ? record.error
      : record?.success === false ? 'invalid_request' : undefined
    this.payload = payload
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null
}

function normalizeBaseUrl(baseUrl: string): string {
  return baseUrl.replace(/\/+$/, '')
}

async function readPayload(response: Response): Promise<unknown> {
  if (response.status === 204) return null
  const contentType = response.headers.get('content-type') ?? ''
  if (!contentType.includes('application/json')) return response.text()
  return response.json()
}

type AccessTokenProvider = () => string | null

export function createMixtapeApi(baseUrl: string, getAccessToken: AccessTokenProvider = () => null): MixtapeApi {
  const root = normalizeBaseUrl(baseUrl)

  async function request<T>(path: string, init: RequestInit = {}): Promise<T> {
    const headers = new Headers(init.headers)
    headers.set('accept', 'application/json')
    if (init.body !== undefined) headers.set('content-type', 'application/json')
    const accessToken = getAccessToken()
    if (accessToken) headers.set('authorization', `Bearer ${accessToken}`)

    const response = await fetch(`${root}${path}`, {
      ...init,
      credentials: 'include',
      headers,
    })
    const payload = await readPayload(response)
    if (!response.ok) throw new ApiError(response.status, payload)
    return payload as T
  }

  return {
    listSessions: () => request('/sessions'),
    getSession: (sessionId) => request(`/sessions/${encodeURIComponent(sessionId)}`),
    createSession: (prompt) =>
      request('/sessions', {
        method: 'POST',
        body: JSON.stringify({ prompt }),
      }),
    sendMessage: (sessionId, text) =>
      request(`/sessions/${encodeURIComponent(sessionId)}/messages`, {
        method: 'POST',
        body: JSON.stringify({ text }),
      }),
    applyQueueOps: (sessionId, ops, expectedVersion) =>
      request(`/sessions/${encodeURIComponent(sessionId)}/queue-ops`, {
        method: 'POST',
        body: JSON.stringify({ ops, ...(expectedVersion === undefined ? {} : { expectedVersion }) }),
      }),
    getMusicKitToken: () => request('/musickit/token'),
    recordSessionEvent: (sessionId, type) =>
      request(`/sessions/${encodeURIComponent(sessionId)}/events`, {
        method: 'POST',
        body: JSON.stringify({ type }),
      }),
    updateSession: (sessionId, updates) =>
      request(`/sessions/${encodeURIComponent(sessionId)}`, {
        method: 'PATCH',
        body: JSON.stringify(updates),
      }),
    listMemories: () => request('/me/memories'),
    deleteMemory: (memoryId) =>
      request(`/me/memories/${encodeURIComponent(memoryId)}`, { method: 'DELETE' }),
    listPlaylists: (options = {}) => {
      const params = new URLSearchParams()
      params.set('status', options.status ?? 'active')
      params.set('limit', String(options.limit ?? 30))
      if (options.q) params.set('q', options.q)
      if (options.cursor) params.set('cursor', options.cursor)
      return request(`/playlists?${params.toString()}`)
    },
    getPlaylist: (playlistId, options = {}) => {
      const params = new URLSearchParams()
      params.set('entryLimit', String(options.entryLimit ?? 200))
      if (options.entryCursor) params.set('entryCursor', options.entryCursor)
      return request(`/playlists/${encodeURIComponent(playlistId)}?${params.toString()}`)
    },
    beginLibrarySync: (input, signal) =>
      request('/ingest/library/syncs', {
        method: 'POST',
        body: JSON.stringify(input),
        signal,
      }),
    putLibrarySongs: (syncId, songs, signal) =>
      request(`/ingest/library/syncs/${encodeURIComponent(syncId)}/songs`, {
        method: 'PUT',
        body: JSON.stringify({ songs }),
        signal,
      }),
    putLibraryRecentTracks: (syncId, catalogIds, signal) =>
      request(`/ingest/library/syncs/${encodeURIComponent(syncId)}/recent-tracks`, {
        method: 'PUT',
        body: JSON.stringify({ catalogIds }),
        signal,
      }),
    completeLibrarySync: (syncId, signal) =>
      request(`/ingest/library/syncs/${encodeURIComponent(syncId)}/complete`, {
        method: 'POST',
        signal,
      }),
    beginPlaylistSync: (input, signal) =>
      request('/ingest/playlists/syncs', {
        method: 'POST',
        body: JSON.stringify(input),
        signal,
      }),
    putPlaylists: (syncId, playlists, signal) =>
      request(`/ingest/playlists/syncs/${encodeURIComponent(syncId)}/playlists`, {
        method: 'PUT',
        body: JSON.stringify({ playlists }),
        signal,
      }),
    putPlaylistEntries: (syncId, playlistAppleId, entries, signal) =>
      request(`/ingest/playlists/syncs/${encodeURIComponent(syncId)}/entries`, {
        method: 'PUT',
        body: JSON.stringify({ playlistAppleId, entries }),
        signal,
      }),
    completePlaylistSync: (syncId, signal) =>
      request(`/ingest/playlists/syncs/${encodeURIComponent(syncId)}/complete`, {
        method: 'POST',
        signal,
      }),
    beginListeningImport: (input, signal) =>
      request('/ingest/listening/imports', {
        method: 'POST',
        body: JSON.stringify(input),
        signal,
      }),
    putListeningTracks: (importId, tracks, signal) =>
      request(`/ingest/listening/imports/${encodeURIComponent(importId)}/tracks`, {
        method: 'PUT',
        body: JSON.stringify({ tracks }),
        signal,
      }),
    putListeningDays: (importId, days, signal) =>
      request(`/ingest/listening/imports/${encodeURIComponent(importId)}/days`, {
        method: 'PUT',
        body: JSON.stringify({ days }),
        signal,
      }),
    putListeningLibrary: (importId, tracks, signal) =>
      request(`/ingest/listening/imports/${encodeURIComponent(importId)}/library`, {
        method: 'PUT',
        body: JSON.stringify({ tracks }),
        signal,
      }),
    putListeningArtists: (importId, artists, signal) =>
      request(`/ingest/listening/imports/${encodeURIComponent(importId)}/artists`, {
        method: 'PUT',
        body: JSON.stringify({ artists }),
        signal,
      }),
    completeListeningImport: (importId, signal) =>
      request(`/ingest/listening/imports/${encodeURIComponent(importId)}/complete`, {
        method: 'POST',
        signal,
      }),
    deleteListeningSource: (source, signal) =>
      request(`/ingest/listening/sources/${encodeURIComponent(source)}`, {
        method: 'DELETE',
        signal,
      }),
    getOnboarding: (signal) => request('/me/onboarding', { signal }),
    getMusicSources: (signal) => request('/me/music-sources', { signal }),
    postFunnelEvent: (event, signal) =>
      request('/me/funnel-events', {
        method: 'POST',
        body: JSON.stringify(event),
        signal,
      }),
    postInterview: (answers, signal) =>
      request('/me/interview', {
        method: 'POST',
        body: JSON.stringify(answers),
        signal,
      }),
    getArtistSeeds: (signal) => request('/me/artist-seeds', { signal }),
    putArtistSeeds: (names, signal) =>
      request('/me/artist-seeds', {
        method: 'PUT',
        body: JSON.stringify({ names }),
        signal,
      }),
    getSeedTracks: (signal) => request('/me/seed-tracks', { signal }),
    postSeedTracks: (spotifyIds, signal) =>
      request('/me/seed-tracks', {
        method: 'POST',
        body: JSON.stringify({ spotifyIds }),
        signal,
      }),
    deleteSeedTrack: (trackId, signal) =>
      request(`/me/seed-tracks/${encodeURIComponent(trackId)}`, {
        method: 'DELETE',
        signal,
      }),
  }
}
