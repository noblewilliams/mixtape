import { useRestorableState, useWorkspaceRestoring } from './lib/workspace-restore'
import { RoutineSuggestions } from './components/RoutineSuggestions'
import { PlaybackController } from './playback/controller'
import { PlaybackPanel } from './components/PlaybackPanel'
import { MixEnergySummary, type EnergyArc } from './components/EnergyJourney'
import { useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore, type CSSProperties } from 'react'
import {
  ApiError,
  type ApiQueueTrack,
  type ApiPlaylistSeed,
  type ApiPlaylistSummary,
  type InterviewResponse,
  type ListeningImportSource,
  type MixtapeApi,
  type OnboardingResponse,
  type QueueOp,
  type QueueOpsResponse,
  type SessionDetailResponse,
} from './api/client'
import { toDjMessage, toDjSession, toQueueTrack } from './api/mappers'
import type { AuthUser } from './components/AuthGate'
import { AccountDialog, type AccountBridge } from './components/AccountDialog'
import { ChooseServiceDialog } from './components/ChooseServiceDialog'
import { MixHistory } from './components/MixHistory'
import { Conversation } from './components/Conversation'
import { HomeDashboard } from './components/HomeDashboard'
import { AppSettings } from './components/AppSettings'
import { Home } from './components/Home'
import { InterviewDialog } from './components/InterviewDialog'
import { NewTapeDialog, SaveDialog, Toast } from './components/Overlays'
import { QueuePanel } from './components/QueuePanel'
import { PlaylistAttachment, type PlaylistAttachmentValue } from './components/PlaylistAttachment'
import { MemoryControls } from './components/MemoryControls'
import './components/web-controls.css'
import { Sidebar } from './components/Sidebar'
import { YourMusicView, type MusicSection } from './components/YourMusicView'
import { createMusicSyncService } from './sync/music-sync-service'
import { createMusicSyncRun } from './sync/music-sync-run'
import { createUploadGate } from './sync/upload-gate'
import type { AppView, CollectionView, DjMessage, DjSession, QueueTrack } from './domain'
import { createImportRun } from './import/import-run'
import { createListeningImportService } from './import/import-service'
import { createLazyParser, createPageParser, type PageParser } from './import/page-parser'
import { MusicKitClientError, type MusicKitClient } from './musickit/client'
import type { AuthProvider } from './lib/auth-provider'
import { postFunnelEventOnce } from './lib/funnel-once'
import { clearServiceChoice, readServiceChoice, writeServiceChoice, type ServiceChoice } from './lib/service-preference'

type DialogState = 'new-tape' | 'save-playlist' | 'account' | 'interview' | null
type MusicConnectionState = 'disconnected' | 'connecting' | 'connected' | 'error'
type ToastState = { message: string; tone: 'success' | 'error' | 'info' }

type AppProps = {
  api: MixtapeApi
  accountAuth: AccountBridge
  lastSignInProvider: AuthProvider | null
  musicKit: MusicKitClient
  user: AuthUser
  onSignOut: () => void
  /** The export parser the import page drives; the lazy Worker parser unless a test injects one. */
  importParser?: PageParser
}

function accountCallback(): { dialog: boolean; message: string; tone: 'success' | 'error' } {
  const params = new URLSearchParams(window.location.search)
  const callbackProvider = params.get('provider') ?? params.get('account_error')
  const provider = callbackProvider === 'apple' ? 'Apple' : 'Google'
  if (params.get('account') === 'linked') {
    return { dialog: true, message: `${provider} is now another way into this Mixtape account.`, tone: 'success' }
  }
  if (params.get('account_error')) {
    return { dialog: true, message: `${provider} could not be linked. Nothing changed.`, tone: 'error' }
  }
  return { dialog: false, message: '', tone: 'success' }
}

function errorCopy(error: unknown): string {
  if (error instanceof ApiError && error.status === 401) return 'Your session has ended. Sign in again to keep listening.'
  if (error instanceof ApiError && error.message && !error.message.startsWith('Request failed')) return error.message
  return 'Something interrupted the connection. Please try again.'
}

function detailToState(detail: SessionDetailResponse) {
  return {
    session: toDjSession(detail.session, detail.queue),
    messages: detail.messages.map(toDjMessage),
    queue: detail.queue.map(toQueueTrack),
  }
}

function durationLabel(tracks: QueueTrack[]) {
  const minutes = Math.max(0, Math.round(tracks.reduce((sum, track) => sum + (track.durationMs ?? 0), 0) / 60_000))
  return `${minutes} min`
}

function paintChannels(hex: string) {
  const value = hex.replace('#', '')
  return [value.slice(0, 2), value.slice(2, 4), value.slice(4, 6)]
    .map((channel) => Number.parseInt(channel, 16))
    .join(', ')
}

/**
 * A completed listening export, the gate for `first_personal_mix`: the
 * funnel's `import_completed` timestamp, or an export source that has
 * imported. An `apple_live` library sync never counts.
 */
function hasCompletedImport(onboarding: OnboardingResponse | null) {
  if (!onboarding) return false
  return Boolean(
    onboarding.importCompletedAt ||
      onboarding.sources.some(
        (source) => (source.source === 'spotify_export' || source.source === 'apple_export') && source.lastImportedAt,
      ),
  )
}

function conflictSnapshot(error: unknown): { queue: ApiQueueTrack[]; queueVersion: number } | null {
  if (!(error instanceof ApiError) || error.status !== 409 || typeof error.payload !== 'object' || !error.payload) {
    return null
  }
  const payload = error.payload as Record<string, unknown>
  if (!Array.isArray(payload.queue) || typeof payload.queueVersion !== 'number') return null
  return { queue: payload.queue as ApiQueueTrack[], queueVersion: payload.queueVersion }
}

export function App(props: AppProps) { return <SignedInWorkspace key={props.user.id} {...props} /> }

function SignedInWorkspace({ api, accountAuth, lastSignInProvider, musicKit, user, onSignOut, importParser }: AppProps) {
  const restoring = useWorkspaceRestoring()
  const [onboardingRefreshed, setOnboardingRefreshed] = useState(false)
  const refreshedSessions = useRef(new Set<string>())
  const contentRevision = useRef<Record<string, number>>({})
  const callback = useMemo(accountCallback, [])
  const uploadGate = useMemo(createUploadGate, [user.id])
  // One parser, one import service, and one import run for the signed-in
  // user's life. The Worker behind the parser is spawned on the first read
  // and released after each run; the run outlives the import page so an
  // upload keeps going while the listener is on Home or in a session.
  const parser = useMemo(() => importParser ?? createLazyParser(createPageParser), [importParser])
  const importService = useMemo(() => createListeningImportService({ api, parser }), [api, parser])
  const refreshRef = useRef<() => Promise<void>>(async () => undefined)
  const importRun = useMemo(
    () => createImportRun({ importService, parser, uploadGate, onImported: () => refreshRef.current() }),
    // A new run per signed-in user, never shared across sign-ins.
    [importService, parser, uploadGate, user.id],
  )
  useEffect(() => () => importRun.dispose(), [importRun])
  const [playlistSeeds, setPlaylistSeeds] = useRestorableState<Record<string, ApiPlaylistSeed | undefined>>('playlistSeeds', {})
  const [mixShapes, setMixShapes] = useState<Record<string, EnergyArc | null>>({})
  const [newSeed, setNewSeed] = useState<PlaylistAttachmentValue | null>(null)
  const [seedBusy, setSeedBusy] = useState<string | null>(null)
  const seedWrites = useRef(new Set<string>())
  const seedRevision = useRef<Record<string, number>>({})
  const [collectionError, setCollectionError] = useState('')
  const [sessions, setSessions] = useRestorableState<DjSession[]>('sessions', [])
  const [historyVersion, setHistoryVersion] = useState<number | undefined>()
  const [historySessionId, setHistorySessionId] = useState<string | null>(null)
  const [activeSessionId, setActiveSessionId] = useRestorableState<string | null>('activeSessionId', null)
  const [activeView, setActiveView] = useRestorableState<AppView>('activeView', 'home')
  useEffect(() => { if (historySessionId && (activeView !== 'session' || historySessionId !== activeSessionId)) setHistorySessionId(null) }, [activeView, activeSessionId, historySessionId])
  const navigation = useRef({ activeSessionId, activeView })
  navigation.current = { activeSessionId, activeView }
  const [musicSection, setMusicSection] = useRestorableState<MusicSection>('musicSection', 'playlists')
  const [musicRevision, setMusicRevision] = useState(0)
  const [showArchived, setShowArchived] = useRestorableState('showArchived', false)
  const [archiveUndo, setArchiveUndo] = useState<string | null>(null)
  const metadataRevision = useRef<Record<string, number>>({})
  const sessionWrites = useRef(new Set<string>())
  const controlLife = useRef(new AbortController())
  useEffect(() => { controlLife.current = new AbortController(); return () => controlLife.current.abort() }, [])
  useEffect(() => { if (!archiveUndo) return; const timer = setTimeout(() => setArchiveUndo(null), 3000); return () => clearTimeout(timer) }, [archiveUndo])
  const [collectionView, setCollectionView] = useRestorableState<CollectionView>('collectionView', 'list')
  const [messagesBySession, setMessagesBySession] = useRestorableState<Record<string, DjMessage[]>>('messagesBySession', {})
  const [queuesBySession, setQueuesBySession] = useRestorableState<Record<string, QueueTrack[]>>('queuesBySession', {})
  const [loadingCollection, setLoadingCollection] = useState(true)
  const [loadingSessionId, setLoadingSessionId] = useState<string | null>(null)
  const [thinkingSessionId, setThinkingSessionId] = useState<string | null>(null)
  const [creatingTape, setCreatingTape] = useState(false)
  const [dialog, setDialog] = useState<DialogState>(callback.dialog ? 'account' : null)
  const [queueOpen, setQueueOpen] = useState(false)
  const playback = useMemo(() => new PlaybackController(api,musicKit,user.id), [api,musicKit,user.id])
  const playerState = useSyncExternalStore(playback.subscribe,playback.getState)
  const playing = playerState.sample.status === 'playing' && playerState.sessionId === activeSessionId && playerState.version === sessions.find(s => s.id === activeSessionId)?.queueVersion
  useEffect(() => {void playback.initialize();return () => playback.dispose()},[playback])
  const [playbackBusy, setPlaybackBusy] = useState(false)
  const [playlistBusy, setPlaylistBusy] = useState(false)
  const [playlistError, setPlaylistError] = useState('')
  const [musicConnection, setMusicConnection] = useState<MusicConnectionState>('disconnected')
  const syncRun = useMemo(() => createMusicSyncRun({
    gate: uploadGate,
    service: createMusicSyncService({ api, musicKit: { ...musicKit,
      connect: async () => {
        try { await musicKit.connect(); setMusicConnection('connected') }
        catch (error) { setMusicConnection('error'); throw error }
      },
      snapshot: async (options) => {
        try { return await musicKit.snapshot(options) }
        catch (error) {
          if (error instanceof MusicKitClientError && ['authorization_failed', 'not_connected'].includes(error.code)) setMusicConnection('disconnected')
          throw error
        }
      },
    } }),
    onPublished: () => refreshRef.current(),
  }), [api, musicKit, uploadGate])
  useEffect(() => () => syncRun.dispose(), [syncRun])
  const [error, setError] = useState('')
  const [toast, setToast] = useState<ToastState | null>(null)
  const [onboarding, setOnboarding] = useRestorableState<OnboardingResponse | null>('onboarding', null)
  // The device-side choice covers what the server cannot know yet (an Apple
  // choice before any sync, a Spotify choice whose funnel event is in flight).
  const [localChoice, setLocalChoice] = useState<ServiceChoice | null>(() => readServiceChoice(user.id))
  const [interviewStatus, setInterviewStatus] = useState('')
  // The one-playlist-run gate: a Spotify upload in flight holds the Apple sync entry points shut.
  const importBusy = useSyncExternalStore(importRun.subscribe, () => importRun.getState().kind === 'uploading')
  const uploadOwner = useSyncExternalStore(uploadGate.subscribe, uploadGate.getOwner)
  const toastTimer = useRef<ReturnType<typeof setTimeout> | null>(null)
  const queueVersions = useRef<Record<string, number>>({})
  const queueMutationChains = useRef<Record<string, Promise<void>>>({})

  const activeSession = useMemo(
    () => sessions.find((session) => session.id === activeSessionId) ?? null,
    [activeSessionId, sessions],
  )
  const effectiveOnboarding = useMemo<OnboardingResponse | null>(
    () =>
      onboarding && onboarding.chosenService === null && localChoice
        ? { ...onboarding, chosenService: localChoice }
        : onboarding,
    [onboarding, localChoice],
  )
  const signOut = useCallback(() => {
    importRun.dispose()
    syncRun.dispose()
    clearServiceChoice(user.id)
    onSignOut()
  }, [importRun, syncRun, onSignOut, user.id])
  const activeMessages = activeSession ? messagesBySession[activeSession.id] ?? [] : []
  const activeQueue = activeSession ? queuesBySession[activeSession.id] ?? [] : []
  const contentPaint = activeView === 'session' && activeSession ? activeSession.caseColor : '#45596d'
  const shellStyle = {
    '--content-paint': contentPaint,
    '--content-paint-rgb': paintChannels(contentPaint),
  } as CSSProperties

  useEffect(() => {
    for (const session of sessions) queueVersions.current[session.id] = session.queueVersion
  }, [sessions])

  // Closing the tab mid-upload would lose the run; the browser asks first.
  useEffect(() => {
    if (!uploadOwner) return
    const guard = (event: BeforeUnloadEvent) => {
      event.preventDefault()
      event.returnValue = ''
    }
    window.addEventListener('beforeunload', guard)
    return () => window.removeEventListener('beforeunload', guard)
  }, [uploadOwner])

  useEffect(() => {
    let cancelled = false

    async function loadCollection() {
      const metadataAtStart = { ...metadataRevision.current }
      const idsAtStart = new Set(sessions.map(session => session.id))
      setLoadingCollection(true)
      try {
        const result = await api.listSessions()
        if (cancelled) return
        setSessions(current => [
          ...current.filter(item => !idsAtStart.has(item.id) && !result.sessions.some(session => session.id === item.id)),
          ...result.sessions.map(session => {
            const prior = current.find(item => item.id === session.id)
            const changed = (metadataRevision.current[session.id] ?? 0) !== (metadataAtStart[session.id] ?? 0)
            return { ...toDjSession(session), ...(prior && (queuesBySession[session.id] || refreshedSessions.current.has(session.id)) ? { queueVersion: prior.queueVersion, trackCount: prior.trackCount, durationLabel: prior.durationLabel } : {}), ...(changed && prior ? { title: prior.title, status: prior.status, caseColor: prior.caseColor } : {}) }
          }),
        ])
        setCollectionError('')

      } catch (requestError) {
        if (!cancelled) setCollectionError(errorCopy(requestError))
        if (requestError instanceof ApiError && requestError.status === 401 && !cancelled) signOut()
      } finally {
        if (!cancelled) setLoadingCollection(false)
      }
    }

    void loadCollection()
    return () => {
      cancelled = true
    }
  }, [api, signOut])

  useEffect(() => {
    let cancelled = false

    async function loadOnboarding() {
      try {
        const result = await api.getOnboarding()
        if (!cancelled) {
          setOnboarding(result)
          setOnboardingRefreshed(true)
        }
      } catch (requestError) {
        // Any other failure falls through: onboarding never locks a listener out.
        if (requestError instanceof ApiError && requestError.status === 401 && !cancelled) signOut()
      }
    }

    void loadOnboarding()
    return () => {
      cancelled = true
    }
  }, [api, signOut])

  useEffect(
    () => () => {
      if (toastTimer.current) clearTimeout(toastTimer.current)
    },
    [],
  )

  useEffect(() => {
    if (!callback.dialog) return
    const url = new URL(window.location.href)
    url.searchParams.delete('account')
    url.searchParams.delete('account_error')
    url.searchParams.delete('provider')
    url.searchParams.delete('error')
    window.history.replaceState({}, '', `${url.pathname}${url.search}${url.hash}`)
  }, [callback.dialog])

  function announce(message: string, tone: ToastState['tone'] = 'success') {
    setToast({ message, tone })
    if (toastTimer.current) clearTimeout(toastTimer.current)
    toastTimer.current = setTimeout(() => setToast(null), 2800)
  }

  async function refreshOnboarding() {
    try {
      setOnboarding(await api.getOnboarding())
    } catch (requestError) {
      if (requestError instanceof ApiError && requestError.status === 401) signOut()
    }
    setMusicRevision((revision) => revision + 1)
  }
  refreshRef.current = refreshOnboarding

  function chooseApple() {
    writeServiceChoice(user.id, 'apple')
    setLocalChoice('apple')
    setMusicSection('apple')
    setActiveView('music')
  }

  function chooseSpotify() {
    writeServiceChoice(user.id, 'spotify')
    setLocalChoice('spotify')
    setActiveView('music')
    setMusicSection('spotify')
    setQueueOpen(false)
    void api
      .postFunnelEvent({ type: 'chose_spotify', surface: 'web' })
      .catch(() => undefined)
      .then(() => refreshOnboarding())
  }

  function openMusic() {
    setMusicSection('playlists')
    setActiveView('music')
    setQueueOpen(false)
  }

  async function removeSource(source: ListeningImportSource) {
    try {
      await api.deleteListeningSource(source)
      await refreshOnboarding()
      announce(source === 'spotify_export' ? 'Your Spotify data is gone from Mixtape.' : 'The Apple Music export is gone from Mixtape.')
    } catch (requestError) {
      announce('Couldn’t remove that source. Try again.', 'error')
      if (requestError instanceof ApiError && requestError.status === 401) signOut()
    }
  }

  function completeInterview(response: InterviewResponse) {
    const notes = response.notes.saved
    const artists = response.seeds
    setDialog(null)
    setInterviewStatus(`Saved ${notes} ${notes === 1 ? 'note' : 'notes'}, ${artists} ${artists === 1 ? 'artist' : 'artists'}`)
    void refreshOnboarding()
  }

  // An empty queue is not a mix; both surfaces skip the milestone for it.
  function notePersonalMix(session: { notPersonal: boolean }, queueLength: number) {
    if (queueLength > 0 && !session.notPersonal && hasCompletedImport(effectiveOnboarding)) {
      postFunnelEventOnce(api, user.id, 'first_personal_mix')
    }
  }

  // A message turn returns no session summary, so the session is read again
  // afterwards to learn whether the DJ went corpus-mode (`notPersonal`). Only
  // that flag is taken from the read: the turn's own response already carries
  // the queue and its version, and a queue op may have moved on since.
  async function refreshSessionAfterTurn(sessionId: string) {
    const signal = controlLife.current.signal
    try {
      const revision = seedRevision.current[sessionId] ?? 0
      const detail = await api.getSession(sessionId)
      if (signal.aborted) return
      if ((seedRevision.current[sessionId] ?? 0) === revision) setPlaylistSeeds(current => ({ ...current, [sessionId]: detail.playlistSeed }))
      setSessions((current) =>
        current.map((session) =>
          session.id === sessionId ? { ...session, notPersonal: detail.session.notPersonal } : session,
        ),
      )
      notePersonalMix(detail.session, detail.queue.length)
    } catch (requestError) {
      if (signal.aborted) return
      if (requestError instanceof ApiError && requestError.status === 401) signOut()
    }
  }

  function activeAppleIds(): string[] | null {
    const ids = activeQueue.flatMap((track) => (track.appleId ? [track.appleId] : []))
    if (ids.length !== activeQueue.length) {
      announce('This mix still has unmatched songs. Ask the DJ to refresh it, then try again.', 'error')
      return null
    }
    return ids
  }

  async function loadSession(sessionId: string, isCancelled: () => boolean = () => controlLife.current.signal.aborted) {
    const revision = contentRevision.current[sessionId] ?? 0
    const cancelled = () => isCancelled() || revision !== (contentRevision.current[sessionId] ?? 0)
    const cached = Boolean(messagesBySession[sessionId] && queuesBySession[sessionId])
    if (cached && refreshedSessions.current.has(sessionId)) return
    if (!cached) setLoadingSessionId(sessionId)
    const metadataAtStart = metadataRevision.current[sessionId] ?? 0
    try {
      const detail = await api.getSession(sessionId)
      if (cancelled()) return
      const mapped = detailToState(detail)
      refreshedSessions.current.add(sessionId)
      setPlaylistSeeds(current => ({ ...current, [sessionId]: detail.playlistSeed }))
      setSessions((current) => current.map((session) => (session.id === sessionId ? { ...mapped.session, ...((metadataRevision.current[sessionId] ?? 0) !== metadataAtStart ? { title: session.title, status: session.status, caseColor: session.caseColor } : {}) } : session)))
      setMessagesBySession((current) => ({ ...current, [sessionId]: mapped.messages }))
      setQueuesBySession((current) => ({ ...current, [sessionId]: mapped.queue }))
      setError('')
    } catch (requestError) {
      if (!cancelled()) setError(errorCopy(requestError))
      if (requestError instanceof ApiError && requestError.status === 401 && !cancelled()) signOut()
    } finally {
      if (!isCancelled()) setLoadingSessionId(null)
    }
  }

  async function retryCollection() {
    if (loadingCollection) return
    setLoadingCollection(true)
    const signal = controlLife.current.signal
    const metadataAtStart = { ...metadataRevision.current }
    const idsAtStart = new Set(sessions.map(session => session.id))
    try {
      const result = await api.listSessions()
      if (!signal.aborted) { setSessions(current => [...current.filter(item => !idsAtStart.has(item.id) && !result.sessions.some(session => session.id === item.id)), ...result.sessions.map(session => { const prior = current.find(item => item.id === session.id); const changed = (metadataRevision.current[session.id] ?? 0) !== (metadataAtStart[session.id] ?? 0); return { ...toDjSession(session), ...(prior && (queuesBySession[session.id] || refreshedSessions.current.has(session.id)) ? { queueVersion: prior.queueVersion, trackCount: prior.trackCount, durationLabel: prior.durationLabel } : {}), ...(changed && prior ? { title: prior.title, status: prior.status, caseColor: prior.caseColor } : {}) } })]); setCollectionError('') }
    } catch (e) {
      if (!signal.aborted) { setCollectionError(errorCopy(e)); if (e instanceof ApiError && e.status === 401) signOut() }
    } finally { if (!signal.aborted) setLoadingCollection(false) }
  }

  async function updateMix(id: string, updates: { title?: string; status?: 'active' | 'archived'; caseColor?: string }) {
    if (sessionWrites.current.has(id)) throw new Error('Session update in progress')
    sessionWrites.current.add(id)
    metadataRevision.current[id] = (metadataRevision.current[id] ?? 0) + 1
    const signal = controlLife.current.signal
    try {
      const result = await api.updateSession(id, updates, signal)
      if (signal.aborted) return
      metadataRevision.current[id] = (metadataRevision.current[id] ?? 0) + 1
      setSessions((current) => current.map((session) => session.id === id ? { ...session, caseColor: result.session.caseColor ?? session.caseColor, title: result.session.title, status: result.session.status, updatedAt: result.session.updatedAt } : session))
      if (updates.status === 'archived') {
        if (navigation.current.activeSessionId === id && navigation.current.activeView === 'session') { setActiveView('home'); setActiveSessionId(null) }
        setArchiveUndo(id)
      } else if (updates.status === 'active') setArchiveUndo(null)
    } catch (e) {
      if (!signal.aborted && e instanceof ApiError && e.status === 401) signOut()
      throw e
    } finally { sessionWrites.current.delete(id) }
  }

  useEffect(() => {
    if (restoring || navigation.current.activeView !== 'session') return
    const id = navigation.current.activeSessionId
    if (!id) return
    let cancelled = false
    void loadSession(id, () => cancelled)
    return () => { cancelled = true }
  }, [api, restoring])

  function openSession(id: string) {
    setActiveSessionId(id)
    setActiveView('session')
    setQueueOpen(false)
    void loadSession(id)
  }

  async function connectAppleMusic() {
    if (musicConnection === 'connecting') return
    setMusicConnection('connecting')
    try {
      await musicKit.connect()
      setMusicConnection('connected')
    } catch {
      setMusicConnection('error')
    }
  }

  function attachmentValue(seed: ApiPlaylistSeed | undefined): PlaylistAttachmentValue | null {
    return seed?.playlistId ? { playlistId: seed.playlistId, name: seed.name ?? 'Unavailable playlist', source: seed.source ?? 'apple', excludeSourceTracks: seed.excludeSourceTracks, ...(seed.status !== 'none' ? { status: seed.status } : {}) } : null
  }

  async function reloadInspiration(id: string) {
    const signal = controlLife.current.signal
    const revision = seedRevision.current[id] ?? 0
    try {
      const detail = await api.getSession(id)
      if (!signal.aborted && (seedRevision.current[id] ?? 0) === revision) {
        setPlaylistSeeds(state => ({ ...state, [id]: detail.playlistSeed }))
        if (!detail.playlistSeed) throw new Error('Inspiration is not available yet')
      }
    } catch (error) {
      if (!signal.aborted && error instanceof ApiError && error.status === 401) signOut()
      throw error
    }
  }

  async function selectInspiration(id: string, value: PlaylistAttachmentValue | null) {
    const current = playlistSeeds[id]
    if (!current || seedWrites.current.has(id)) throw new Error('Inspiration not ready')
    seedWrites.current.add(id)
    contentRevision.current[id] = (contentRevision.current[id] ?? 0) + 1
    setSeedBusy(id)
    seedRevision.current[id] = (seedRevision.current[id] ?? 0) + 1
    const signal = controlLife.current.signal
    try {
      const result = await api.selectPlaylistSeed(id, { playlistId: value?.playlistId ?? null, excludeSourceTracks: value?.excludeSourceTracks ?? false, expectedRevision: current.revision }, signal)
      if (!signal.aborted) setPlaylistSeeds(state => ({ ...state, [id]: result.playlistSeed }))
    } catch (e) {
      if (!signal.aborted) {
        if (e instanceof ApiError && e.status === 401) signOut()
        else {
          try { const detail = await api.getSession(id); if (!signal.aborted) setPlaylistSeeds(state => ({ ...state, [id]: detail.playlistSeed })) }
          catch { if (!signal.aborted) setPlaylistSeeds(state => ({ ...state, [id]: undefined })) }
        }
      }
      throw e
    } finally { if (!signal.aborted) setSeedBusy(null); seedWrites.current.delete(id); seedRevision.current[id] = (seedRevision.current[id] ?? 0) + 1 }
  }

  function inspireFromPlaylist(playlist: ApiPlaylistSummary) {
    setNewSeed({ playlistId: playlist.id, name: playlist.name, source: playlist.source, excludeSourceTracks: false })
    setDialog('new-tape')
  }

  async function createTape(prompt: string, useInspiration = true, propagateError = false, shape?: EnergyArc) {
    if (creatingTape) return
    const signal = controlLife.current.signal
    setCreatingTape(true)
    try {
      const response = await api.createSession(prompt, useInspiration && newSeed ? { playlistId: newSeed.playlistId, excludeSourceTracks: newSeed.excludeSourceTracks } : undefined, shape)
      if (signal.aborted) return
      setNewSeed(null)
      setPlaylistSeeds(current => ({ ...current, [response.session.id]: response.playlistSeed }))
      const mapped = detailToState(response)
      setSessions((current) => [mapped.session, ...current.filter((session) => session.id !== mapped.session.id)])
      setMessagesBySession((current) => ({ ...current, [mapped.session.id]: mapped.messages }))
      setQueuesBySession((current) => ({ ...current, [mapped.session.id]: mapped.queue }))
      setActiveSessionId(mapped.session.id)
      setActiveView('session')
      setDialog(null)
      setError('')
      announce('Your new tape is ready.')
      notePersonalMix(response.session, response.queue.length)
    } catch (requestError) {
      if (signal.aborted) return
      setError(errorCopy(requestError))
      if (requestError instanceof ApiError && requestError.status === 401) signOut()
      if (propagateError) throw requestError
    } finally {
      if (!signal.aborted) setCreatingTape(false)
    }
  }

  async function sendMessage(text: string, shape?: EnergyArc) {
    const signal = controlLife.current.signal
    if (!activeSession || seedWrites.current.has(activeSession.id)) return
    const sessionId = activeSession.id
    contentRevision.current[sessionId] = (contentRevision.current[sessionId] ?? 0) + 1
    const metadataAtStart = metadataRevision.current[sessionId] ?? 0
    const userMessage: DjMessage = {
      id: `${sessionId}-pending-${Date.now()}`,
      role: 'user',
      content: text,
      createdAt: new Date().toISOString(),
    }

    setMessagesBySession((current) => ({
      ...current,
      [sessionId]: [...(current[sessionId] ?? []), userMessage],
    }))
    setThinkingSessionId(sessionId)
    setError('')

    try {
      const response = await api.sendMessage(sessionId, text, shape)
      if (signal.aborted) return
      const queue = response.queue.map(toQueueTrack)
      setMessagesBySession((current) => ({
        ...current,
        [sessionId]: [...(current[sessionId] ?? []), toDjMessage(response.djMessage)],
      }))
      setQueuesBySession((current) => ({ ...current, [sessionId]: queue }))
      setSessions((current) =>
        current.map((session) =>
          session.id === sessionId
            ? toDjSession(
                {
                  ...session,
                  title: (metadataRevision.current[sessionId] ?? 0) === metadataAtStart ? response.sessionTitle ?? session.title : session.title,
                  queueVersion: response.queueVersion,
                  updatedAt: new Date().toISOString(),
                },
                response.queue,
              )
            : session,
        ),
      )
      void refreshSessionAfterTurn(sessionId)
    } catch (requestError) {
      if (signal.aborted) return
      const message = errorCopy(requestError)
      setMessagesBySession((current) => ({
        ...current,
        [sessionId]: [
          ...(current[sessionId] ?? []),
          { id: `${sessionId}-error-${Date.now()}`, role: 'dj', content: message, createdAt: new Date().toISOString() },
        ],
      }))
      if (requestError instanceof ApiError && requestError.status === 401) signOut()
    } finally {
      if (!signal.aborted) setThinkingSessionId(null)
    }
  }

  function previewQueue(sessionId: string, nextTracks: QueueTrack[]) {
    contentRevision.current[sessionId] = (contentRevision.current[sessionId] ?? 0) + 1
    const normalized = nextTracks.map((track, position) => ({ ...track, position }))
    setQueuesBySession((current) => ({ ...current, [sessionId]: normalized }))
    setSessions((current) =>
      current.map((session) =>
        session.id === sessionId
          ? { ...session, trackCount: normalized.length, durationLabel: durationLabel(normalized) }
          : session,
      ),
    )
  }

  function applyQueueSnapshot(sessionId: string, queueVersion: number, queue: ApiQueueTrack[]) {
    contentRevision.current[sessionId] = (contentRevision.current[sessionId] ?? 0) + 1
    const mappedQueue = queue.map(toQueueTrack)
    queueVersions.current[sessionId] = queueVersion
    setQueuesBySession((current) => ({ ...current, [sessionId]: mappedQueue }))
    setSessions((current) =>
      current.map((session) =>
        session.id === sessionId
          ? toDjSession(
              {
                id: session.id,
                caseColor: session.caseColor,
                title: session.title,
                status: session.status,
                queueVersion,
                notPersonal: session.notPersonal,
                updatedAt: new Date().toISOString(),
              },
              queue,
            )
          : session,
      ),
    )
  }

  async function refreshQueueAfterFailure(sessionId: string, error: unknown) {
    const conflict = conflictSnapshot(error)
    if (conflict) {
      applyQueueSnapshot(sessionId, conflict.queueVersion, conflict.queue)
      return
    }
    try {
      const detail = await api.getSession(sessionId)
      applyQueueSnapshot(sessionId, detail.session.queueVersion, detail.queue)
    } catch (refreshError) {
      setError(errorCopy(refreshError))
      if (refreshError instanceof ApiError && refreshError.status === 401) signOut()
    }
  }

  function commitQueueOp(sessionId: string, op: QueueOp): Promise<void> {
    const previous = queueMutationChains.current[sessionId] ?? Promise.resolve()
    const operation = previous.catch(() => undefined).then(async () => {
      const expectedVersion = queueVersions.current[sessionId]
      try {
        const response: QueueOpsResponse = await api.applyQueueOps(sessionId, [op], expectedVersion)
        applyQueueSnapshot(sessionId, response.queueVersion, response.queue)
        setError('')
      } catch (requestError) {
        await refreshQueueAfterFailure(sessionId, requestError)
        if (requestError instanceof ApiError && requestError.status === 401) signOut()
        throw requestError
      }
    })
    queueMutationChains.current[sessionId] = operation.catch(() => undefined)
    return operation
  }

  async function togglePlayback() {
    if (!activeSession || playbackBusy) return
    const sessionId = activeSession.id
    const ids = activeAppleIds()
    if (!ids) return

    setPlaybackBusy(true)
    try {
      if (playing) await playback.command('pause')
      else if(playerState.sessionId===sessionId && playerState.version===activeSession.queueVersion && playerState.tracks.length) await playback.command('resume')
      else {
        const started=await playback.start(sessionId,activeSession.queueVersion,activeSession.title,activeQueue)
        if(started) void api.recordSessionEvent(sessionId, 'played').catch(() => undefined)
      }
    } catch {
      announce(`Apple Music couldn’t ${playing ? 'pause' : 'play'} this mix. Try again in a moment.`, 'error')
    } finally {
      setPlaybackBusy(false)
    }
  }

  async function savePlaylist(name: string) {
    if (!activeSession) return
    const sessionId = activeSession.id
    const ids = activeAppleIds()
    if (!ids) return

    setPlaylistBusy(true)
    setPlaylistError('')
    try {
      await musicKit.createPlaylist(name, ids, (libraryId) => {
        void api.recordPlaylistCreation(sessionId, libraryId).catch(() => undefined)
      })
      setDialog(null)
      announce(`“${name}” is now in Apple Music.`)
      void api.recordSessionEvent(sessionId, 'saved_playlist').catch(() => undefined)
    } catch {
      setPlaylistError('Apple Music couldn’t create this playlist. Check your subscription and try again.')
    } finally {
      setPlaylistBusy(false)
    }
  }


  return (
    <div className={`app-shell ${activeView !== 'session' || !activeSession ? 'app-shell--home' : ''}`} style={shellStyle}>
      <Sidebar activeView={activeView}
        onOpenHome={() => setActiveView('home')}
        onOpenMusic={openMusic}
        onOpenMixes={() => { setShowArchived(false); setActiveView('mixes') }}
        onOpenSettings={() => setActiveView('settings')}
      />

      {activeView === 'settings' ? <AppSettings api={api} playback={playback} userName={user.name} signInMethod={lastSignInProvider} onAccount={() => setDialog('account')} onMemories={() => setActiveView('memories')} onSignOut={signOut}/> : activeView === 'home' ? <HomeDashboard
        sessions={sessions} loading={loadingCollection} error={collectionError} busy={creatingTape}
        onRetry={() => void retryCollection()} onOpenSession={openSession} onOpenMixes={() => { setShowArchived(false); setActiveView('mixes') }}
        onSubmit={prompt => createTape(prompt, false, true)} transcribe={(audio,signal) => api.transcribe(audio,signal)}
        suggestions={<RoutineSuggestions key={user.id} api={api} busy={creatingTape} onCreate={prompt => createTape(prompt, false, true)}/>}
        player={<PlaybackPanel controller={playback}/>}
        onColor={(id,color) => updateMix(id,{caseColor:color})} onRename={(id,title) => updateMix(id,{title})} onArchive={id => updateMix(id,{status:'archived'})}
      /> : activeView === 'memories' ? <MemoryControls api={api} onClose={() => setActiveView('settings')} onSessionExpired={signOut} /> : activeView === 'music' ? (
        <YourMusicView
          api={api}
          onInspire={inspireFromPlaylist}
          importRun={importRun}
          syncRun={syncRun}
          uploadGate={uploadGate}
          section={musicSection}
          onSection={setMusicSection}
          connected={musicConnection === 'connected'}
          revision={musicRevision}
          onSessionExpired={signOut}
          interviewStatus={interviewStatus}
          onRefresh={refreshOnboarding}
          onOpenInterview={() => setDialog('interview')}
          onNewTape={() => setDialog('new-tape')}
          onRemoveSource={(source) => void removeSource(source)}
        />
      ) : activeView !== 'session' || !activeSession ? (
        <Home
          loading={loadingCollection}
          error={collectionError}
          onRetry={() => void retryCollection()}
          player={<PlaybackPanel controller={playback} />}
          sessions={sessions.filter((session) => session.status === (showArchived ? 'archived' : 'active'))}
          archived={showArchived}
          onArchived={setShowArchived}
          onColor={(id, color) => updateMix(id, { caseColor: color })}
          onRename={(id, title) => updateMix(id, { title })}
          onArchive={(id) => updateMix(id, { status: 'archived' })}
          onRestore={(id) => updateMix(id, { status: 'active' })}
          collectionView={collectionView}
          onChangeCollectionView={setCollectionView}
          onOpenSession={openSession}
          onNewTape={() => setActiveView('home')}
        />
      ) : (
        <>
          {historySessionId && <MixHistory initialVersion={historyVersion} key={`${historySessionId}-${historyVersion ?? "list"}`} api={api} sessionId={historySessionId} onClose={() => setHistorySessionId(null)} onSessionExpired={signOut} onRestored={() => loadSession(historySessionId)} />}
          {!historySessionId && <Conversation
            key={activeSession.id}
            currentShape={mixShapes[`${activeSession.id}:${activeSession.queueVersion}`]}
            transcribe={(audio, signal) => api.transcribe(audio, signal)}
            selectionBusy={seedBusy === activeSession.id}
            attachment={<PlaylistAttachment api={api} onReload={!playlistSeeds[activeSession.id] ? () => reloadInspiration(activeSession.id) : undefined} value={attachmentValue(playlistSeeds[activeSession.id])} disabled={!playlistSeeds[activeSession.id] || thinkingSessionId === activeSession.id} onSelect={(value) => selectInspiration(activeSession.id, value)} onSessionExpired={signOut} />}
            onColor={color => updateMix(activeSession.id, { caseColor: color })}
            onRename={(title) => updateMix(activeSession.id, { title })}
            onArchive={() => updateMix(activeSession.id, { status: 'archived' }).catch((e) => { announce('Couldn’t archive this mix. Try again.', 'error'); throw e })}
            session={activeSession}
            messages={activeMessages}
            loading={loadingSessionId === activeSession.id}
            thinking={thinkingSessionId === activeSession.id}
            player={<PlaybackPanel controller={playback} />}
            energySummary={<MixEnergySummary onShape={shape => setMixShapes(current => ({ ...current, [`${activeSession.id}:${activeSession.queueVersion}`]: shape }))} key={`${activeSession.id}:${activeSession.queueVersion}`} api={api} sessionId={activeSession.id} version={activeSession.queueVersion} />}
            onSend={sendMessage}
            onOpenHistory={(version) => { setHistoryVersion(version); setHistorySessionId(activeSession.id) }}
            onOpenQueue={() => setQueueOpen(true)}
          />}
          <QueuePanel
            session={activeSession}
            tracks={activeQueue}
            playing={playing}
            playbackBusy={playbackBusy}
            musicConnection={musicConnection}
            open={queueOpen}
            onConnect={() => void connectAppleMusic()}
            onTogglePlay={() => void togglePlayback()}
            onSave={() => {
              setPlaylistError('')
              setDialog('save-playlist')
            }}
            onClose={() => setQueueOpen(false)}
            onPreviewTracks={(tracks) => previewQueue(activeSession.id, tracks)}
            onCommitQueueOp={(op) => commitQueueOp(activeSession.id, op)}
            onOutput={() => postFunnelEventOnce(api, user.id, 'first_output')}
          />
        </>
      )}

      {error ? <p className="app-error" role="alert">{error}</p> : null}
      {dialog === 'new-tape' ? (
        <NewTapeDialog attachment={<PlaylistAttachment api={api} value={newSeed} onSelect={async (value) => setNewSeed(value)} disabled={creatingTape} onSessionExpired={signOut} />} busy={creatingTape} onClose={() => { setDialog(null); setNewSeed(null) }} onCreate={(prompt, shape) => void createTape(prompt, true, false, shape)} />
      ) : null}
      {dialog === 'save-playlist' && activeSession ? (
        <SaveDialog
          busy={playlistBusy}
          error={playlistError}
          defaultName={activeSession.title}
          newToYouCount={activeQueue.filter((track) => track.newToYou).length}
          onClose={() => setDialog(null)}
          onSave={(name) => void savePlaylist(name)}
        />
      ) : null}
      {dialog === 'interview' ? (
        <InterviewDialog api={api} onClose={() => setDialog(null)} onComplete={completeInterview} />
      ) : null}
      {!restoring && onboardingRefreshed && effectiveOnboarding && effectiveOnboarding.chosenService === null ? (
        <ChooseServiceDialog onChooseApple={chooseApple} onChooseSpotify={chooseSpotify} />
      ) : null}
      {dialog === 'account' ? (
        <AccountDialog
          onMemories={() => { setDialog(null); setActiveView('memories') }}
          auth={accountAuth}
          lastUsed={lastSignInProvider}
          notice={callback.message}
          noticeTone={callback.tone}
          onClose={() => setDialog(null)}
        />
      ) : null}
      {archiveUndo && !toast && <Toast message="Mix archived" tone="info" action={{ label: 'Undo', onClick: () => void updateMix(archiveUndo, { status: 'active' }).catch(() => announce('Couldn’t restore the mix. Open Archived to retry.', 'error')) }} />}
      {toast ? <Toast message={toast.message} tone={toast.tone} /> : null}
    </div>
  )
}
