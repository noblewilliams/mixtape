import type {
  ApiArtistSeed,
  ApiMessage,
  ApiMusicSource,
  ApiQueueTrack,
  ApiSeedTrack,
  ApiSessionSummary,
  CreateSessionResponse,
  FunnelEventInput,
  ListeningImportStart,
  MixtapeApi,
  SessionDetailResponse,
} from '../api/client'
import { demoQueue, demoSessions, makeConversationFor } from '../data/demo'

const summaries: ApiSessionSummary[] = demoSessions.map((session) => ({
  id: session.id,
  title: session.title,
  status: session.status,
  queueVersion: session.queueVersion,
  notPersonal: session.notPersonal,
  updatedAt: session.updatedAt,
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
  tracks: number
  days: number
  libraryTracks: number
  artists: number
  unresolvedRows: number
  unresolvedPlays: number
  dayKeys: string[]
}

export function createFakeApi(overrides: Partial<MixtapeApi> = {}): FakeApi {
  const queueState = new Map<string, ApiQueueTrack[]>()
  const funnelEvents: FunnelEventInput[] = []
  const listeningImports = new Map<string, FakeListeningImport>()
  const musicSources: ApiMusicSource[] = []
  let artistSeeds: ApiArtistSeed[] = []
  let seedTracks: ApiSeedTrack[] = []
  const stamp = () => new Date().toISOString()
  const listeningImport = (importId: string) => {
    const run = listeningImports.get(importId)
    if (!run) throw new Error('fake listening import not begun')
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
    listSessions: async () => ({ sessions: summaries.map((session) => ({ ...session })) }),
    getSession: async (sessionId): Promise<SessionDetailResponse> => {
      const session = summaries.find((item) => item.id === sessionId) ?? summaries[0]
      return { session: { ...session }, messages: messagesFor(sessionId), queue: currentQueue(sessionId) }
    },
    createSession: async (prompt): Promise<CreateSessionResponse> => {
      const createdAt = new Date().toISOString()
      return {
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
        queue: [],
      }
    },
    sendMessage: async (_sessionId, _text) => ({
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
    getMusicKitToken: async () => ({ developerToken: 'fake-developer-token', expiresAt: 1_788_138_000 }),
    recordSessionEvent: async () => ({ ok: true }),
    updateSession: async (sessionId, updates) => {
      const session = summaries.find((item) => item.id === sessionId) ?? summaries[0]
      return { session: { ...session, ...updates } }
    },
    listMemories: async () => ({ memories: [] }),
    deleteMemory: async () => ({ ok: true }),
    listPlaylists: async () => ({ playlists: [], nextCursor: null }),
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
    beginPlaylistSync: async () => ({ syncId: 'playlist-sync', expiresAt: Date.now() + 60_000 }),
    putPlaylists: async (_syncId, playlists) => ({ accepted: playlists.length }),
    putPlaylistEntries: async (_syncId, _playlistAppleId, entries) => ({ accepted: entries.length }),
    completePlaylistSync: async () => ({
      playlists: 0,
      entries: 0,
      resolvedEntries: 0,
      unresolvedEntries: 0,
    }),
    beginListeningImport: async (input): Promise<ListeningImportStart> => {
      const importId = `listening-import-${listeningImports.size + 1}`
      listeningImports.set(importId, {
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
          source: input.source, connectedAt: stamp(), lastImportedAt: null, ledgerFrom: null, ledgerTo: null,
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
        source.lastImportedAt = stamp()
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
        sources: musicSources.map((source) => ({ ...source })),
        hasLibrary: false,
        chosenService: funnelEvents.some((event) => event.type === 'chose_spotify') ? 'spotify' : null,
        markedRequestedAt: firstAt('marked_requested'),
        interviewCompletedAt: null,
        importCompletedAt: firstAt('import_completed'),
      }
    },
    getMusicSources: async () => ({ sources: musicSources.map((source) => ({ ...source })) }),
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
      return { seeds: answers.neverSkip.length, notes: { saved, duplicate: 0, capped: 0 } }
    },
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
