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
  beginPlaylistSync: (input: {
    source: 'ios_native' | 'web_musickit'
    storefront: string
    expectedPlaylists: number
    expectedEntries: number
  }, signal?: AbortSignal) => Promise<StagedSyncStart>
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
    this.code = typeof record?.error === 'string' ? record.error : undefined
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
  }
}
