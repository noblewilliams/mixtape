import type {
  LibrarySongSnapshot,
  PlaylistEntrySnapshot,
  PlaylistSnapshot,
} from '../musickit/library'

export type InitialPlaylistSeed = { playlistId: string; excludeSourceTracks?: boolean }

export type PlaylistSeedSelection = {
  playlistId: string | null
  excludeSourceTracks: boolean
  expectedRevision: number
}

export type ApiPlaylistSeed = {
  playlistId: string | null
  revision: number
  excludeSourceTracks: boolean
  status: 'none' | 'ready' | 'unavailable' | 'insufficient_profile'
  name: string | null
  source: 'apple' | 'spotify_export' | null
  fingerprint: string | null
  updatedAt: string | null
  entries: number
  resolvedEntries: number
  recordings: number
  profile: {
    sampledRecordings: number
    tempo: number | null
    energy: number | null
    releaseYear: number | null
    artists: string[]
    genres: string[]
  } | null
}

export type ApiSessionStatus = 'active' | 'archived'

export type ApiSession = {
  caseColor?: string | null
  id: string
  title: string
  status: ApiSessionStatus
  queueVersion: number
  /** True once corpus-mode picks landed in the queue: the "Not personal yet" banner. */
  notPersonal: boolean
  updatedAt: string
  /** Absent on older servers; absence means a mix. */
  kind?: 'mix' | 'album'
}

export type ApiSessionSummary = ApiSession & {
  /** Both 0 for album sessions. */
  trackCount: number
  durationMs: number
  /** Album sessions only: the current pick, null before the first. */
  pick?: { title: string; artist: string; artwork: ApiAlbumArtwork | null } | null
}

export type ApiAlbumType = 'album' | 'ep' | 'single' | 'live' | 'compilation' | 'soundtrack' | 'mixtape'
export type ApiAlbumArtwork = { url: string; width: number | null; height: number | null; bgColor: string | null }

type ApiAlbumFields = {
  id: string
  upc: string | null
  appleId: string | null
  title: string
  artist: string
  releaseYear: number | null
  type: ApiAlbumType
  trackCount: number | null
  durationMs: number | null
  artwork: ApiAlbumArtwork | null
}

export type ApiAlbum = ApiAlbumFields & {
  newToThem: boolean
  reason: string
  savedForLater: boolean
  version: number
}

export type AlbumPickResponse = {
  pick: ApiAlbum | null
  runnersUp: ApiAlbum[]
  passed: ApiAlbum[]
  version: number
}

export type ApiListenLaterEntry = ApiAlbumFields & {
  sessionId: string | null
  savedAt: string
  listenedAt: string | null
  reason: string | null
}

export type ChoosePickInput = { albumId: string; version?: never } | { version: number; albumId?: never }

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
  /** Absent on older servers; absence means the listener's own song. */
  newToYou?: boolean
}

export type SessionDetailResponse = {
  session: ApiSession
  /** Absent on older servers; absence is not a confirmed empty selection. */
  playlistSeed?: ApiPlaylistSeed
  messages: ApiMessage[]
  /** Mix sessions only. */
  queue?: ApiQueueTrack[]
} & Partial<AlbumPickResponse>

export type CreateSessionResponse = SessionDetailResponse & {
  sessionTitle?: string
  suggestions?: string[]
}

/** A mix turn carries queue and queueVersion; an album turn the pick state instead. */
export type SendMessageResponse = {
  djMessage: ApiMessage
  queue?: ApiQueueTrack[]
  queueVersion?: number
  sessionTitle?: string
  suggestions?: string[]
} & Partial<AlbumPickResponse>

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
  source: 'apple' | 'spotify_export'
  curatorName: string | null
  kind: string
  origin?: 'unknown' | 'mixtape' | 'user_confirmed'
  artworkUrlTemplate: string | null
  artworkWidth: number | null
  artworkHeight: number | null
  artworkBgColor: string | null
  entryCount: number
  knownDurationMs: number | null
  durationComplete: boolean
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
  spotifyId: string | null
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
export type MusicCollectionSummary = {
  apple: { songs: number | null; playlists: number; librarySyncedAt: string | null }
  spotify: { playlists: number }
}

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
export type ListeningImportPackage = 'spotify_extended' | 'spotify_account' | 'spotify_exportify' | 'apple_media'

export type LibraryReview = {mode:'add'} | {mode:'replace';fingerprint:string}
export type PlaylistReview = {key:string;baseFingerprint:string|null;fileHash:string}[]
export type SpotifyCollectionReview = {hasQuickImport?:boolean;library:{ids:string[];fingerprint:string};playlists:{key:string;name:string;fileHash:string|null;fingerprint:string}[]}
export type BeginListeningImportInput = {
  libraryReview?: LibraryReview
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
  /** Uppercase, well-formed ISRC; omitted when unknown, never null. */
  isrc?: string
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
  /** Packages with a completed import behind this source, sorted. */
  packages: ListeningImportPackage[]
}
export type OnboardingResponse = {
  /** Keys the per-device "service chosen" flag. */
  userId: string
  sources: ApiMusicSource[]
  hasLibrary: boolean
  chosenService: 'spotify' | 'apple' | null
  markedRequestedAt: string | null
  interviewCompletedAt: string | null
  importCompletedAt: string | null
  /** What the interview produced; null until it has been completed. */
  interview: { artists: number; notes: number } | null
}

export type FunnelEventType =
  | 'chose_spotify'
  | 'marked_requested'
  | 'file_inspected'
  | 'import_completed'
  | 'first_personal_mix'
  | 'first_output'
  // First run (spec 2026-10-20 → Clients, Funnel events), one-time per
  // anonymous user. account_linked_new and account_linked_existing are written
  // by the server and never posted.
  | 'first_run_opened'
  | 'chose_make_mix'
  | 'chose_add_music'
  | 'chose_service'
  | 'chose_method'
  | 'sync_done'
  | 'first_mix_made'
  | 'first_mix_refused'
  | 'keep_sheet_shown'
  | 'keep_sheet_signed_in'
  | 'keep_sheet_dismissed'
  | 'cap_reached'
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
    review?: PlaylistReview
    storefront: null
    expectedPlaylists: number
    expectedEntries: number
  }

export type MixVersionList = { currentVersion: number; versions: Array<{ version: number; trackCount: number; restoredFrom: number | null; createdAt: string }>; nextBefore: number | null }
export type EnergyArc = 'steady' | 'rise' | 'fall' | 'arc'
export type MixVersionDetail = { energyArc?: EnergyArc | null; energyJourney?: {status:'limited'|'follows'|'mixed';known:number;total:number;bands:[number,number,number]|null} | null; version: number; currentVersion: number; restoredFrom: number | null; entries: Array<{ position: number; trackId: string; title: string; artist: string; reason: string | null; available: boolean }> }
export type MixRestoreInput = { version: number; expectedVersion: number; requestId: string }

export type RoutineSuggestion = { id: string; title: string; prompt: string; reason: string }
export type SuggestionsResponse = { enabled: boolean; suggestion: RoutineSuggestion | null; dismissed: boolean }
export type PlaybackPreferences = {enabled:boolean;revision:number;userId?:string}
export type PlaybackObservation = {playbackId:string;sequence:number;sessionId:string;version:number;position:number;trackId:string;source:'apple_web'|'apple_native';kind:'listen'|'skip'|'repeat';observedMs:number;occurredAt:string}
export type MergedMode = 'all' | 'mixes_only' | 'library_kept'
export type MeResponse = {
  user: { id: string; isAnonymous: boolean }
  merged: MergedMode | null
  /** Whether album sessions and Listen later are offered; false on older servers. */
  albumPicks: boolean
}
export type MixtapeApi = {
  /** `merged` is reported once after an anonymous session joins an account; the server clears it on read. */
  getMe: (signal?: AbortSignal) => Promise<MeResponse>
  transcribe: (audio: File, signal?: AbortSignal) => Promise<{text:string;language:string}>
  getSuggestions: (timeZone: string) => Promise<SuggestionsResponse>
  selectSuggestion: (id: string, timeZone: string) => Promise<{prompt: string}>
  dismissSuggestion: (id: string, timeZone: string) => Promise<{ok: boolean}>
  saveSuggestionPreference: (enabled: boolean) => Promise<{enabled: boolean}>
  playbackPreferences: () => Promise<PlaybackPreferences>
  savePlaybackPreference: (enabled:boolean) => Promise<PlaybackPreferences>
  clearPlaybackEvidence: (requestId:string,revision:number) => Promise<PlaybackPreferences>
  sendPlaybackEvidence: (body:{revision:number;events:PlaybackObservation[]}) => Promise<unknown>

  listMixVersions: (id: string, before?: number) => Promise<MixVersionList>
  readMixVersion: (id: string, version: number) => Promise<MixVersionDetail>
  restoreMixVersion: (id: string, input: MixRestoreInput) => Promise<{version:number}>

  listSessions: () => Promise<{ sessions: ApiSessionSummary[] }>
  getSession: (sessionId: string) => Promise<SessionDetailResponse>
  createSession: (
    prompt: string,
    playlistSeed?: InitialPlaylistSeed,
    energyArc?: EnergyArc,
    kind?: 'mix' | 'album',
  ) => Promise<CreateSessionResponse>
  sendMessage: (sessionId: string, text: string, energyArc?: EnergyArc) => Promise<SendMessageResponse>
  applyQueueOps: (sessionId: string, ops: QueueOp[], expectedVersion?: number) => Promise<QueueOpsResponse>
  choosePick: (sessionId: string, input: ChoosePickInput, expectedVersion?: number) => Promise<AlbumPickResponse>
  listListenLater: (signal?: AbortSignal) => Promise<{ entries: ApiListenLaterEntry[] }>
  saveForLater: (albumId: string, sessionId?: string, signal?: AbortSignal) => Promise<{ entry: ApiListenLaterEntry }>
  unsaveForLater: (albumId: string, signal?: AbortSignal) => Promise<{ ok: true }>
  markListened: (albumId: string, signal?: AbortSignal) => Promise<{ entry: ApiListenLaterEntry }>
  getMusicKitToken: () => Promise<MusicKitTokenResponse>
  recordSessionEvent: (sessionId: string, type: 'played' | 'saved_playlist') => Promise<{ ok: true }>
  recordPlaylistCreation: (sessionId: string, appleLibraryId: string) => Promise<{ ok: true }>
  updateSession: (
    sessionId: string,
    updates: { title?: string; status?: ApiSessionStatus; caseColor?: string },
    signal?: AbortSignal,
  ) => Promise<{ session: ApiSession }>
  selectPlaylistSeed: (
    sessionId: string,
    selection: PlaylistSeedSelection,
    signal?: AbortSignal,
  ) => Promise<{ playlistSeed: ApiPlaylistSeed }>
  listMemories: (signal?: AbortSignal) => Promise<{ memories: ApiMemory[] }>
  deleteMemory: (memoryId: string, signal?: AbortSignal) => Promise<{ ok: true }>
  confirmPlaylistTaste: (playlistId: string, confirmed: boolean, signal?: AbortSignal) => Promise<{ ok: true }>
  getMusicCollectionSummary: (signal?: AbortSignal) => Promise<MusicCollectionSummary>
  listPlaylists: (options?: {
    status?: 'active' | 'all'
    source?: 'apple' | 'spotify_export'
    q?: string
    limit?: number
    cursor?: string
  }, signal?: AbortSignal) => Promise<{ playlists: ApiPlaylistSummary[]; nextCursor: string | null; total: number }>
  getPlaylist: (
    playlistId: string,
    options?: { entryLimit?: number; entryCursor?: string },
    signal?: AbortSignal,
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
  getSpotifyCollectionReview: (signal?:AbortSignal) => Promise<SpotifyCollectionReview>
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

/** POST /sessions refused a new mix: an anonymous listener reached the cap. */
export class AnonymousCapError extends ApiError {
  readonly limit: number

  constructor(payload: unknown) {
    super(403, payload)
    this.name = 'AnonymousCapError'
    const limit = isRecord(payload) ? payload.limit : undefined
    this.limit = typeof limit === 'number' ? limit : 3
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
    if (init.body !== undefined && !(init.body instanceof FormData)) headers.set('content-type', 'application/json')
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
    transcribe: (audio, signal) => {
      const body = new FormData(); body.append('audio', audio)
      return request('/transcribe', {method:'POST', body, signal})
    },
    getSuggestions: timeZone => request(`/suggestions?timeZone=${encodeURIComponent(timeZone)}`),
    selectSuggestion: (id,timeZone) => request('/suggestions/select',{method:'POST',body:JSON.stringify({id,timeZone})}),
    dismissSuggestion: (id,timeZone) => request('/suggestions/dismiss',{method:'POST',body:JSON.stringify({id,timeZone})}),
    saveSuggestionPreference: enabled => request('/suggestions/preferences',{method:'POST',body:JSON.stringify({enabled})}),
    playbackPreferences: () => request('/playback/preferences'),
    savePlaybackPreference: enabled => request('/playback/preferences',{method:'PUT',body:JSON.stringify({enabled})}),
    clearPlaybackEvidence: (requestId,revision) => request('/playback/clear',{method:'POST',body:JSON.stringify({requestId,revision})}),
    sendPlaybackEvidence: body => request('/playback/events',{method:'POST',body:JSON.stringify(body)}),
    listMixVersions: (id, before) => request(`/sessions/${encodeURIComponent(id)}/versions${before ? `?before=${before}` : ''}`),
    readMixVersion: (id, version) => request(`/sessions/${encodeURIComponent(id)}/versions/${version}`),
    restoreMixVersion: (id, input) => request(`/sessions/${encodeURIComponent(id)}/versions/restore`, { method: 'POST', body: JSON.stringify(input) }),
    listSessions: () => request('/sessions'),
    getSession: (sessionId) => request(`/sessions/${encodeURIComponent(sessionId)}`),
    getMe: async (signal) => {
      const body = await request<{
        user: { id: string; isAnonymous?: boolean | null }
        merged?: MergedMode | null
        albumPicks?: boolean
      }>('/me', { signal })
      return {
        user: { id: body.user.id, isAnonymous: body.user.isAnonymous === true },
        merged: body.merged ?? null,
        albumPicks: body.albumPicks === true,
      }
    },
    createSession: (prompt, playlistSeed, energyArc, kind) =>
      request<CreateSessionResponse>('/sessions', {
        method: 'POST',
        // The server ignores energyArc on an album, but it is never sent: albums have no shape.
        body: JSON.stringify({
          prompt,
          ...(playlistSeed ? { playlistSeed } : {}),
          ...(kind === 'album' ? { kind } : energyArc ? { energyArc } : {}),
        }),
      }).catch((error: unknown) => {
        if (error instanceof ApiError && error.status === 403 && error.code === 'anonymous_cap') throw new AnonymousCapError(error.payload)
        throw error
      }),
    sendMessage: (sessionId, text, energyArc) =>
      request(`/sessions/${encodeURIComponent(sessionId)}/messages`, {
        method: 'POST',
        body: JSON.stringify({ text, ...(energyArc ? { energyArc } : {}) }),
      }),
    applyQueueOps: (sessionId, ops, expectedVersion) =>
      request(`/sessions/${encodeURIComponent(sessionId)}/queue-ops`, {
        method: 'POST',
        body: JSON.stringify({ ops, ...(expectedVersion === undefined ? {} : { expectedVersion }) }),
      }),
    choosePick: (sessionId, input, expectedVersion) =>
      request(`/sessions/${encodeURIComponent(sessionId)}/pick`, {
        method: 'POST',
        body: JSON.stringify({ ...input, ...(expectedVersion === undefined ? {} : { expectedVersion }) }),
      }),
    listListenLater: (signal) => request('/me/listen-later', { signal }),
    saveForLater: (albumId, sessionId, signal) =>
      request(`/me/listen-later/${encodeURIComponent(albumId)}`, {
        method: 'PUT',
        body: JSON.stringify(sessionId ? { sessionId } : {}),
        signal,
      }),
    unsaveForLater: (albumId, signal) =>
      request(`/me/listen-later/${encodeURIComponent(albumId)}`, { method: 'DELETE', signal }),
    markListened: (albumId, signal) =>
      request(`/me/listen-later/${encodeURIComponent(albumId)}/listened`, { method: 'POST', signal }),
    getMusicKitToken: () => request('/musickit/token'),
    recordPlaylistCreation: (sessionId, appleLibraryId) => request('/playlists/creation-receipts', {
      method: 'POST', body: JSON.stringify({ sessionId, appleLibraryId }),
    }),
    recordSessionEvent: (sessionId, type) =>
      request(`/sessions/${encodeURIComponent(sessionId)}/events`, {
        method: 'POST',
        body: JSON.stringify({ type }),
      }),
    updateSession: (sessionId, updates, signal) =>
      request(`/sessions/${encodeURIComponent(sessionId)}`, {
        method: 'PATCH',
        body: JSON.stringify(updates), signal,
      }),
    selectPlaylistSeed: (sessionId, selection, signal) =>
      request(`/sessions/${encodeURIComponent(sessionId)}/playlist-seed`, {
        method: 'PUT', body: JSON.stringify(selection), signal,
      }),
    listMemories: (signal) => request('/me/memories', { signal }),
    deleteMemory: (memoryId, signal) =>
      request(`/me/memories/${encodeURIComponent(memoryId)}`, { method: 'DELETE', signal }),
    confirmPlaylistTaste: (playlistId, confirmed, signal) =>
      request(`/playlists/${encodeURIComponent(playlistId)}/taste-confirmation`, {
        method: 'PUT', body: JSON.stringify({ confirmed }), signal,
      }),
    getMusicCollectionSummary: (signal) => request('/playlists/summary', { signal }),
    listPlaylists: (options = {}, signal) => {
      const params = new URLSearchParams()
      params.set('status', options.status ?? 'active')
      params.set('limit', String(options.limit ?? 30))
      if (options.q) params.set('q', options.q)
      if (options.source) params.set('source', options.source)
      if (options.cursor) params.set('cursor', options.cursor)
      return request(`/playlists?${params.toString()}`, { signal })
    },
    getPlaylist: (playlistId, options = {}, signal) => {
      const params = new URLSearchParams()
      params.set('entryLimit', String(options.entryLimit ?? 200))
      if (options.entryCursor) params.set('entryCursor', options.entryCursor)
      return request(`/playlists/${encodeURIComponent(playlistId)}?${params.toString()}`, { signal })
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
    getSpotifyCollectionReview: signal => request('/ingest/listening/spotify/review',{signal}),
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
        // cap_reached and keep_sheet_signed_in are followed by the sign-in
        // redirect; keepalive lets the post outlive the page.
        keepalive: true,
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
