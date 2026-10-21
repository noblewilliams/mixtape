import { ApiError } from '../api/client'
import type {
  AlbumPickResponse,
  ApiAlbum,
  ApiArtistSeed,
  ApiListenLaterEntry,
  ApiMessage,
  ApiMusicSource,
  ApiQueueTrack,
  ApiSeedTrack,
  ApiSession,
  ApiSessionSummary,
  CreateSessionResponse,
  FunnelEventInput,
  ListeningImportPackage,
  ListeningImportSource,
  ListeningImportStart,
  MixtapeApi,
  SessionDetailResponse,
} from '../api/client'
import {
  demoAlbumPick,
  demoAlbumRefinedPick,
  demoAlbumRefineReply,
  demoAlbumReply,
  demoAlbumRunnersUp,
  demoAlbums,
  demoQueue,
  demoSessions,
  makeConversationFor,
  toDemoListenLaterEntry,
} from '../data/demo'

const summaries: ApiSessionSummary[] = demoSessions.map((session) => ({
  id: session.id,
  title: session.title,
  status: session.status,
  queueVersion: session.queueVersion,
  notPersonal: session.notPersonal,
  updatedAt: session.updatedAt,
  kind: 'mix',
  trackCount: session.trackCount,
  durationMs: Math.max(0, Number.parseInt(session.durationLabel, 10)) * 60_000,
}))

function messagesFor(sessionId: string): ApiMessage[] {
  const session = demoSessions.find((item) => item.id === sessionId) ?? demoSessions[0]
  return makeConversationFor(session).map((message) => ({ ...message }))
}

function apiTrack(track: (typeof demoQueue)[number]): ApiQueueTrack {
  return {
    ...track,
    reason: track.reason ?? null,
    durationMs: track.durationMs ?? null,
    artworkUrl: track.artworkUrl ?? null,
    artworkWidth: track.artworkWidth ?? null,
    artworkHeight: track.artworkHeight ?? null,
    artworkBgColor: track.artworkBgColor ?? null,
  }
}

function queueFor(sessionId: string): ApiQueueTrack[] {
  return sessionId === demoSessions[0].id ? demoQueue.map(apiTrack) : []
}

export type FakeApiCall = { method: keyof MixtapeApi; args: unknown[] }

export type FakeApi = MixtapeApi & {
  /** Every call made through the fake, in order, overrides included. */
  calls: FakeApiCall[]
}

type FakeListeningImport = {
  source: ListeningImportSource
  package: ListeningImportPackage
  tracks: number
  days: number
  libraryTracks: number
  artists: number
  unresolvedRows: number
  unresolvedPlays: number
  dayKeys: string[]
}

type FakeAlbumSession = {
  session: ApiSession
  messages: ApiMessage[]
  /** Every shortlist by version, so a go-back can restore any of them. */
  history: Map<number, AlbumPickResponse>
}

type FakeShelfRow = { entry: ApiListenLaterEntry; removed: boolean }

export type FakeApiOptions = {
  /** Listen later entries the fake starts with, e.g. demoListenLaterEntries for the preview harness. */
  listenLater?: ApiListenLaterEntry[]
}

const notFound = () => new ApiError(404, { error: 'not_found' })
const atVersion = (album: ApiAlbum, version: number): ApiAlbum => ({ ...album, version })

export function createFakeApi(overrides: Partial<MixtapeApi> = {}, options: FakeApiOptions = {}): FakeApi {
  const albumSessions = new Map<string, FakeAlbumSession>()
  const shelf = new Map<string, FakeShelfRow>(
    (options.listenLater ?? []).map((entry) => [entry.id, { entry: { ...entry }, removed: false }]),
  )
  // Strictly increasing stamps keep the shelf order deterministic within one millisecond.
  let clock = 0
  const tick = () => new Date((clock = Math.max(Date.now(), clock + 1))).toISOString()
  const isSaved = (id: string) => shelf.get(id)?.removed === false
  const savedView = (album: ApiAlbum): ApiAlbum => ({ ...album, savedForLater: isSaved(album.id) })
  const albumState = (sessionId: string) => {
    const state = albumSessions.get(sessionId)
    if (!state) throw notFound()
    return state
  }
  const currentPicks = (state: FakeAlbumSession) => state.history.get(state.session.queueVersion)!
  const pickView = (state: FakeAlbumSession): AlbumPickResponse => {
    const current = currentPicks(state)
    return {
      version: current.version,
      pick: current.pick && savedView(current.pick),
      runnersUp: current.runnersUp.map(savedView),
      passed: current.passed.map(savedView),
    }
  }
  const pushPicks = (state: FakeAlbumSession, next: Omit<AlbumPickResponse, 'version'>) => {
    const version = state.session.queueVersion + 1
    state.history.set(version, { ...next, version })
    state.session = { ...state.session, queueVersion: version, updatedAt: tick() }
    return pickView(state)
  }
  const offeredReason = (sessionId: string, albumId: string): string | null => {
    const history = albumSessions.get(sessionId)?.history
    if (!history) return null
    const offered = [...history.values()]
      .sort((a, b) => b.version - a.version)
      .flatMap((picks) => [picks.pick, ...picks.runnersUp])
      .find((item) => item?.id === albumId)
    return offered?.reason ?? null
  }
  const sortedShelf = () =>
    [...shelf.values()]
      .filter((row) => !row.removed)
      .map((row) => ({ ...row.entry }))
      .sort((a, b) => {
        if ((a.listenedAt === null) !== (b.listenedAt === null)) return a.listenedAt === null ? -1 : 1
        return (b.listenedAt ?? b.savedAt).localeCompare(a.listenedAt ?? a.savedAt)
      })
  const albumTurn = (sessionId: string, text: string) => {
    const state = albumState(sessionId)
    const current = currentPicks(state)
    const version = current.version + 1
    const createdAt = tick()
    const djMessage: ApiMessage = { id: `${sessionId}-dj-${version}`, role: 'dj', content: demoAlbumRefineReply, queueVersion: version, createdAt }
    state.messages.push({ id: `${sessionId}-user-${version}`, role: 'user', content: text, createdAt }, djMessage)
    const picks = pushPicks(state, {
      pick: atVersion(demoAlbumRefinedPick, version),
      runnersUp: current.runnersUp.map((album) => atVersion(album, version)),
      passed: [...(current.pick ? [current.pick] : []), ...current.passed],
    })
    return { djMessage: { ...djMessage }, ...picks }
  }
  const queueState = new Map<string, ApiQueueTrack[]>()
  const createdSessions = new Map<string, CreateSessionResponse>()
  const funnelEvents: FunnelEventInput[] = []
  const listeningImports = new Map<string, FakeListeningImport>()
  const playlistSyncs = new Map<string, { playlists: number; entries: number }>()
  const musicSources: ApiMusicSource[] = []
  let interviewCompletedAt: string | null = null
  let interview: { artists: number; notes: number } | null = null
  let artistSeeds: ApiArtistSeed[] = []
  let seedTracks: ApiSeedTrack[] = []
  const stamp = () => new Date().toISOString()
  const listeningImport = (importId: string) => {
    const run = listeningImports.get(importId)
    if (!run) throw new Error('fake listening import not begun')
    return run
  }
  const playlistSync = (syncId: string) => {
    const run = playlistSyncs.get(syncId)
    if (!run) throw new Error('fake playlist sync not begun')
    return run
  }
  const currentQueue = (sessionId: string) => {
    const existing = queueState.get(sessionId)
    if (existing) return existing.map((track) => ({ ...track }))
    const initial = queueFor(sessionId)
    queueState.set(sessionId, initial)
    return initial.map((track) => ({ ...track }))
  }
  const api: MixtapeApi = {
    transcribe: async () => ({ text: 'An evening mix', language: 'en' }),
    listSessions: async () => {
      const albums: ApiSessionSummary[] = [...albumSessions.values()]
        .map((state) => {
          const pick = currentPicks(state).pick
          return {
            ...state.session,
            trackCount: 0,
            durationMs: 0,
            pick: pick && { title: pick.title, artist: pick.artist, artwork: pick.artwork },
          }
        })
        .sort((a, b) => b.updatedAt.localeCompare(a.updatedAt))
      return { sessions: [...albums, ...summaries.map((session) => ({ ...session }))] }
    },
    getSuggestions: async()=>({enabled:true,suggestion:null,dismissed:false}),
    selectSuggestion: async()=>{throw new Error('No suggestion')},
    dismissSuggestion: async()=>({ok:true}),
    saveSuggestionPreference: async enabled=>({enabled}),
    playbackPreferences: async()=>({enabled:false,revision:0}),
    savePlaybackPreference: async enabled=>({enabled,revision:1}),
    clearPlaybackEvidence: async()=>({enabled:false,revision:1}),
    sendPlaybackEvidence: async()=>({accepted:true}),
    listMixVersions: async () => ({ currentVersion: 1, versions: [], nextBefore: null }),
    readMixVersion: async () => { throw new Error('No historical fixture') },
    restoreMixVersion: async () => { throw new Error('No historical fixture') },
    getSession: async (sessionId): Promise<SessionDetailResponse> => {
      const album = albumSessions.get(sessionId)
      if (album) {
        return { session: { ...album.session }, messages: album.messages.map((message) => ({ ...message })), ...pickView(album) }
      }
      const created = createdSessions.get(sessionId)
      if (created) {
        return {
          session: { ...created.session },
          messages: created.messages.map((message) => ({ ...message })),
          queue: currentQueue(sessionId),
        }
      }
      const session = summaries.find((item) => item.id === sessionId) ?? summaries[0]
      return { session: { ...session }, messages: messagesFor(sessionId), queue: currentQueue(sessionId) }
    },
    createSession: async (prompt, _seed, _arc, kind): Promise<CreateSessionResponse> => {
      if (kind === 'album') {
        const createdAt = tick()
        const id = albumSessions.size === 0 ? 'created-album-session' : `created-album-session-${albumSessions.size + 1}`
        const state: FakeAlbumSession = {
          session: { id, title: prompt, status: 'active', queueVersion: 0, notPersonal: false, updatedAt: createdAt, kind: 'album' },
          messages: [
            { id: `${id}-user-1`, role: 'user', content: prompt, createdAt },
            { id: `${id}-dj-1`, role: 'dj', content: demoAlbumReply, queueVersion: 1, createdAt },
          ],
          history: new Map(),
        }
        albumSessions.set(id, state)
        const picks = pushPicks(state, {
          pick: atVersion(demoAlbumPick, 1),
          runnersUp: demoAlbumRunnersUp.map((album) => atVersion(album, 1)),
          passed: [],
        })
        return { session: { ...state.session }, messages: state.messages.map((message) => ({ ...message })), ...picks }
      }
      const createdAt = new Date().toISOString()
      const created: CreateSessionResponse = {
        session: {
          id: 'created-session',
          title: prompt,
          status: 'active',
          queueVersion: 1,
          notPersonal: false,
          updatedAt: createdAt,
        },
        messages: [
          { id: 'created-user', role: 'user', content: prompt, createdAt },
          { id: 'created-dj', role: 'dj', content: 'I made a first pass for this moment.', queueVersion: 1, createdAt },
        ],
        // A created session carries the DJ's first pass, as the real API does.
        queue: demoQueue.slice(0, 1).map(apiTrack),
      }
      createdSessions.set(created.session.id, created)
      return created
    },
    sendMessage: async (sessionId, text) => albumSessions.has(sessionId) ? albumTurn(sessionId, text) : ({
      djMessage: {
        id: 'reply-message',
        role: 'dj',
        content: 'I kept the opening intact, then reshaped the middle around that feeling.',
        queueVersion: 4,
        createdAt: new Date().toISOString(),
      },
      queue: demoQueue.map(apiTrack),
      queueVersion: 4,
    }),
    applyQueueOps: async (sessionId, ops, expectedVersion = 3) => {
      const queue = currentQueue(sessionId)
      for (const op of ops) {
        if (op.op === 'remove') {
          queue.splice(op.position, 1)
        } else {
          const [moved] = queue.splice(op.from, 1)
          queue.splice(op.to, 0, moved)
        }
      }
      queue.forEach((track, position) => {
        track.position = position
      })
      queueState.set(sessionId, queue.map((track) => ({ ...track })))
      return {
        queueVersion: expectedVersion + 1,
        requested: 0,
        added: 0,
        removed: ops.filter((op) => op.op === 'remove').length,
        queue,
      }
    },
    choosePick: async (sessionId, input, expectedVersion) => {
      const state = albumState(sessionId)
      const current = currentPicks(state)
      if (expectedVersion !== undefined && expectedVersion !== current.version) {
        throw new ApiError(409, { error: 'stale', version: current.version })
      }
      const version = current.version + 1
      const previous = current.pick ? [current.pick] : []
      if ('albumId' in input) {
        const chosen = current.runnersUp.find((album) => album.id === input.albumId)
        if (!chosen) throw notFound()
        return pushPicks(state, {
          pick: atVersion(chosen, version),
          runnersUp: current.runnersUp.filter((album) => album.id !== chosen.id).map((album) => atVersion(album, version)),
          passed: [...previous, ...current.passed],
        })
      }
      const restored = state.history.get(input.version)
      if (!restored) throw notFound()
      return pushPicks(state, {
        pick: restored.pick && atVersion(restored.pick, version),
        runnersUp: restored.runnersUp.map((album) => atVersion(album, version)),
        passed: [...previous, ...current.passed].filter((album) => album.id !== restored.pick?.id),
      })
    },
    listListenLater: async () => ({ entries: sortedShelf() }),
    saveForLater: async (albumId, sessionId) => {
      const album = demoAlbums.find((item) => item.id === albumId)
      if (!album) throw notFound()
      // As the server: a named source must be an album session that offered this album.
      if (sessionId && offeredReason(sessionId, albumId) === null) throw notFound()
      const existing = shelf.get(albumId)
      if (!existing) {
        const entry = toDemoListenLaterEntry(album, { savedAt: tick() })
        shelf.set(albumId, { entry, removed: false })
      } else if (existing.removed) {
        existing.removed = false
        existing.entry = { ...existing.entry, savedAt: tick(), sessionId: sessionId ?? existing.entry.sessionId }
      } else {
        // A repeat keeps the saved date and source, only filling a source it never had.
        existing.entry = { ...existing.entry, sessionId: existing.entry.sessionId ?? sessionId ?? null }
      }
      const row = shelf.get(albumId)!
      if (!existing && sessionId) row.entry.sessionId = sessionId
      // The why is read off the source session, as the server's join does.
      row.entry.reason = row.entry.sessionId ? offeredReason(row.entry.sessionId, albumId) : null
      return { entry: { ...row.entry } }
    },
    unsaveForLater: async (albumId) => {
      if (!demoAlbums.some((item) => item.id === albumId)) throw notFound()
      const row = shelf.get(albumId)
      if (row) row.removed = true
      return { ok: true }
    },
    markListened: async (albumId) => {
      const row = shelf.get(albumId)
      if (!row || row.removed) throw notFound()
      row.entry.listenedAt ??= tick()
      return { entry: { ...row.entry } }
    },
    getMusicKitToken: async () => ({ developerToken: 'fake-developer-token', expiresAt: 1_788_138_000 }),
    recordSessionEvent: async () => ({ ok: true }),
    recordPlaylistCreation: async () => ({ ok: true }),
    updateSession: async (sessionId, updates) => {
      const session = summaries.find((item) => item.id === sessionId) ?? summaries[0]
      return { session: { ...session, ...updates } }
    },
    selectPlaylistSeed: async () => { throw new Error('Configure playlist inspiration for this scenario') },
    confirmPlaylistTaste: async () => { throw new Error('Configure taste confirmation for this scenario') },
    listMemories: async () => ({ memories: [] }),
    deleteMemory: async () => ({ ok: true }),
    getMusicCollectionSummary: async () => ({ apple: { songs: null, playlists: 0, librarySyncedAt: null }, spotify: { playlists: 0 } }),
    listPlaylists: async () => ({ playlists: [], nextCursor: null, total: 0 }),
    getPlaylist: async () => {
      throw new Error('fake playlist detail not configured')
    },
    beginLibrarySync: async () => ({ syncId: 'library-sync', expiresAt: Date.now() + 60_000 }),
    putLibrarySongs: async (_syncId, songs) => ({ accepted: songs.length }),
    putLibraryRecentTracks: async (_syncId, catalogIds) => ({ accepted: catalogIds.length }),
    completeLibrarySync: async () => ({
      songs: 0,
      catalogResolved: 0,
      playCountsObserved: 0,
      recentTracks: 0,
    }),
    beginPlaylistSync: async () => {
      const syncId = `playlist-sync-${playlistSyncs.size + 1}`
      playlistSyncs.set(syncId, { playlists: 0, entries: 0 })
      return { syncId, expiresAt: Date.now() + 60_000 }
    },
    putPlaylists: async (syncId, playlists) => {
      playlistSync(syncId).playlists += playlists.length
      return { accepted: playlists.length }
    },
    putPlaylistEntries: async (syncId, _playlistAppleId, entries) => {
      playlistSync(syncId).entries += entries.length
      return { accepted: entries.length }
    },
    completePlaylistSync: async (syncId) => {
      const run = playlistSync(syncId)
      return { playlists: run.playlists, entries: run.entries, resolvedEntries: 0, unresolvedEntries: run.entries }
    },
    getSpotifyCollectionReview: async () => ({library:{ids:[],fingerprint:'0'.repeat(64)},playlists:[]}),
    beginListeningImport: async (input): Promise<ListeningImportStart> => {
      const importId = `listening-import-${listeningImports.size + 1}`
      listeningImports.set(importId, {
        source: input.source,
        package: input.package,
        tracks: 0,
        days: 0,
        libraryTracks: 0,
        artists: 0,
        unresolvedRows: input.unresolvedRows,
        unresolvedPlays: input.unresolvedPlays,
        dayKeys: [],
      })
      if (!musicSources.some((source) => source.source === input.source)) {
        musicSources.push({
          source: input.source, connectedAt: stamp(), lastImportedAt: null, ledgerFrom: null, ledgerTo: null, packages: [],
        })
      }
      return { importId, expiresAt: Date.now() + 60_000 }
    },
    putListeningTracks: async (importId, tracks) => {
      listeningImport(importId).tracks += tracks.length
      return { accepted: tracks.length }
    },
    putListeningDays: async (importId, days) => {
      const run = listeningImport(importId)
      run.days += days.length
      run.dayKeys.push(...days.map((row) => row.day))
      return { accepted: days.length }
    },
    putListeningLibrary: async (importId, tracks) => {
      listeningImport(importId).libraryTracks += tracks.length
      return { accepted: tracks.length }
    },
    putListeningArtists: async (importId, artists) => {
      listeningImport(importId).artists += artists.length
      return { accepted: artists.length }
    },
    completeListeningImport: async (importId) => {
      const run = listeningImport(importId)
      const days = [...run.dayKeys].sort()
      const ledgerFrom = days[0] ?? null
      const ledgerTo = days[days.length - 1] ?? null
      for (const source of musicSources) {
        if (source.source !== run.source) continue
        source.lastImportedAt = stamp()
        if (!source.packages.includes(run.package)) source.packages = [...source.packages, run.package].sort()
        if (ledgerFrom !== null) {
          source.ledgerFrom = source.ledgerFrom === null || ledgerFrom < source.ledgerFrom ? ledgerFrom : source.ledgerFrom
          source.ledgerTo = source.ledgerTo === null || (ledgerTo !== null && ledgerTo > source.ledgerTo) ? ledgerTo : source.ledgerTo
        }
      }
      return {
        tracks: run.tracks,
        days: run.days,
        libraryTracks: run.libraryTracks,
        artists: run.artists,
        unresolvedRows: run.unresolvedRows,
        unresolvedPlays: run.unresolvedPlays,
        ledgerFrom,
        ledgerTo,
        likedRemoved: 0,
        likedRemovalSkipped: false,
      }
    },
    deleteListeningSource: async (source) => {
      const index = musicSources.findIndex((item) => item.source === source)
      if (index >= 0) musicSources.splice(index, 1)
      return { deletedDays: 0, deletedTracks: 0, unlibraried: 0 }
    },
    getOnboarding: async () => {
      const firstAt = (type: FunnelEventInput['type']) => (funnelEvents.some((event) => event.type === type) ? stamp() : null)
      return {
        userId: 'user-1',
        sources: musicSources.map((source) => ({ ...source, packages: [...source.packages] })),
        hasLibrary: false,
        chosenService: funnelEvents.some((event) => event.type === 'chose_spotify') ? 'spotify' : null,
        markedRequestedAt: firstAt('marked_requested'),
        interviewCompletedAt,
        importCompletedAt: firstAt('import_completed'),
        interview: interview ? { ...interview } : null,
      }
    },
    getMusicSources: async () => ({ sources: musicSources.map((source) => ({ ...source, packages: [...source.packages] })) }),
    postFunnelEvent: async (event) => {
      funnelEvents.push({ ...event })
      return { ok: true }
    },
    postInterview: async (answers) => {
      artistSeeds = [
        ...artistSeeds.filter((seed) => seed.source !== 'interview'),
        ...answers.neverSkip.map((name) => ({ name, spotifyId: null, source: 'interview' as const, createdAt: stamp() })),
      ]
      const saved = [answers.playsMost, answers.listensWhen, answers.neverWants, answers.era]
        .filter((answer) => answer.trim().length > 0).length + (answers.neverSkip.length > 0 ? 1 : 0)
      interviewCompletedAt = stamp()
      interview = { artists: answers.neverSkip.length, notes: saved }
      return { seeds: answers.neverSkip.length, notes: { saved, duplicate: 0, capped: 0 } }
    },
    getMe: async () => ({ user: { id: 'listener-1', isAnonymous: false }, merged: null, albumPicks: true }),
    getArtistSeeds: async () => ({ seeds: artistSeeds.map((seed) => ({ ...seed })) }),
    putArtistSeeds: async (names) => {
      artistSeeds = [
        ...artistSeeds.filter((seed) => seed.source !== 'interview'),
        ...names.map((name) => ({ name, spotifyId: null, source: 'interview' as const, createdAt: stamp() })),
      ]
      return { seeds: artistSeeds.map((seed) => ({ ...seed })) }
    },
    getSeedTracks: async () => ({ tracks: seedTracks.map((track) => ({ ...track })) }),
    postSeedTracks: async (spotifyIds) => {
      const resolved = [...new Set(spotifyIds)].map((spotifyId) => ({
        spotifyId, trackId: `seed-${spotifyId}`, title: `Track ${spotifyId}`, artist: 'Artist',
      }))
      for (const track of resolved) {
        if (!seedTracks.some((existing) => existing.trackId === track.trackId)) {
          seedTracks.push({ ...track, album: null })
        }
      }
      return { resolved, unresolved: [] }
    },
    deleteSeedTrack: async (trackId) => {
      const before = seedTracks.length
      seedTracks = seedTracks.filter((track) => track.trackId !== trackId)
      if (seedTracks.length === before) throw new Error('fake seed track not found')
      return { removed: true, deleted: true }
    },
  }

  const merged: MixtapeApi = { ...api, ...overrides }
  const calls: FakeApiCall[] = []
  const recorded = Object.fromEntries(
    (Object.keys(merged) as (keyof MixtapeApi)[]).map((method) => [
      method,
      (...args: unknown[]) => {
        calls.push({ method, args })
        return (merged[method] as (...inner: unknown[]) => unknown)(...args)
      },
    ]),
  ) as unknown as MixtapeApi
  return Object.assign(recorded, { calls })
}
