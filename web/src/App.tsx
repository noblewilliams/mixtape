import { RoutineSuggestions } from './components/RoutineSuggestions'
import { PlaybackController } from './playback/controller'
import { PlaybackPanel } from './components/PlaybackPanel'
import { MixEnergySummary } from './components/EnergyJourney'
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
import { Cassette } from './components/Cassette'
import { ChooseServiceDialog } from './components/ChooseServiceDialog'
import { MixHistory } from './components/MixHistory'
import { Conversation } from './components/Conversation'
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
import { musicLinkLabel } from './lib/onboarding'
import { clearServiceChoice, readServiceChoice, writeServiceChoice, type ServiceChoice } from './lib/service-preference'

type DialogState = 'new-tape' | 'save-playlist' | 'account' | 'interview' | null
type MusicConnectionState = 'disconnected' | 'connecting' | 'connected' | 'error'
type ToastState = { message: string; tone: 'success' | 'error' }

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
  const [playlistSeeds, setPlaylistSeeds] = useState<Record<string, ApiPlaylistSeed | undefined>>({})
  const [newSeed, setNewSeed] = useState<PlaylistAttachmentValue | null>(null)
  const [seedBusy, setSeedBusy] = useState<string | null>(null)
  const seedWrites = useRef(new Set<string>())
  const seedRevision = useRef<Record<string, number>>({})
  const [sessions, setSessions] = useState<DjSession[]>([])
  const [historyVersion, setHistoryVersion] = useState<number | undefined>()
  const [historySessionId, setHistorySessionId] = useState<string | null>(null)
  const [activeSessionId, setActiveSessionId] = useState<string | null>(null)
  const [activeView, setActiveView] = useState<AppView>('home')
  useEffect(() => { if (historySessionId && (activeView !== 'session' || historySessionId !== activeSessionId)) setHistorySessionId(null) }, [activeView, activeSessionId, historySessionId])
  const navigation = useRef({ activeSessionId, activeView })
  navigation.current = { activeSessionId, activeView }
  const [musicSection, setMusicSection] = useState<MusicSection>('auto')
  const [musicRevision, setMusicRevision] = useState(0)
  const [showArchived, setShowArchived] = useState(false)
  const [archiveUndo, setArchiveUndo] = useState<string | null>(null)
  const metadataRevision = useRef<Record<string, number>>({})
  const sessionWrites = useRef(new Set<string>())
  const controlLife = useRef(new AbortController())
  useEffect(() => { controlLife.current = new AbortController(); return () => controlLife.current.abort() }, [])
  useEffect(() => { if (!archiveUndo) return; const timer = setTimeout(() => setArchiveUndo(null), 3000); return () => clearTimeout(timer) }, [archiveUndo])
  const [collectionView, setCollectionView] = useState<CollectionView>('list')
  const [messagesBySession, setMessagesBySession] = useState<Record<string, DjMessage[]>>({})
  const [queuesBySession, setQueuesBySession] = useState<Record<string, QueueTrack[]>>({})
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
  const [onboarding, setOnboarding] = useState<OnboardingResponse | null>(null)
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
      setLoadingCollection(true)
      try {
        const result = await api.listSessions()
        if (cancelled) return
        const active = result.sessions
          .filter((session) => session.status === 'active')
          .map((session) => toDjSession(session))
        setSessions(result.sessions.map((session) => toDjSession(session)))
        setError('')
        if (active.length > 0) {
          setActiveSessionId(active[0].id)
          setActiveView('session')
          void loadSession(active[0].id, () => cancelled)
        }
      } catch (requestError) {
        if (!cancelled) setError(errorCopy(requestError))
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
        if (!cancelled) setOnboarding(result)
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

  async function loadSession(sessionId: string, isCancelled: () => boolean = () => false) {
    if (messagesBySession[sessionId] && queuesBySession[sessionId]) return
    setLoadingSessionId(sessionId)
    const metadataAtStart = metadataRevision.current[sessionId] ?? 0
    try {
      const detail = await api.getSession(sessionId)
      if (isCancelled()) return
      const mapped = detailToState(detail)
      setPlaylistSeeds(current => ({ ...current, [sessionId]: detail.playlistSeed }))
      setSessions((current) => current.map((session) => (session.id === sessionId ? { ...mapped.session, ...((metadataRevision.current[sessionId] ?? 0) !== metadataAtStart ? { title: session.title, status: session.status } : {}) } : session)))
      setMessagesBySession((current) => ({ ...current, [sessionId]: mapped.messages }))
      setQueuesBySession((current) => ({ ...current, [sessionId]: mapped.queue }))
      setError('')
    } catch (requestError) {
      if (!isCancelled()) setError(errorCopy(requestError))
      if (requestError instanceof ApiError && requestError.status === 401 && !isCancelled()) signOut()
    } finally {
      if (!isCancelled()) setLoadingSessionId(null)
    }
  }

  async function updateMix(id: string, updates: { title?: string; status?: 'active' | 'archived' }) {
    if (sessionWrites.current.has(id)) throw new Error('Session update in progress')
    sessionWrites.current.add(id)
    metadataRevision.current[id] = (metadataRevision.current[id] ?? 0) + 1
    const signal = controlLife.current.signal
    try {
      const result = await api.updateSession(id, updates, signal)
      if (signal.aborted) return
      metadataRevision.current[id] = (metadataRevision.current[id] ?? 0) + 1
      setSessions((current) => current.map((session) => session.id === id ? { ...session, title: result.session.title, status: result.session.status, updatedAt: result.session.updatedAt } : session))
      if (updates.status === 'archived') {
        if (navigation.current.activeSessionId === id && navigation.current.activeView === 'session') { setActiveView('home'); setActiveSessionId(null) }
        setArchiveUndo(id)
      } else if (updates.status === 'active') setArchiveUndo(null)
    } catch (e) {
      if (!signal.aborted && e instanceof ApiError && e.status === 401) signOut()
      throw e
    } finally { sessionWrites.current.delete(id) }
  }

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

  async function createTape(prompt: string, useInspiration = true) {
    if (creatingTape) return
    const signal = controlLife.current.signal
    setCreatingTape(true)
    try {
      const response = await api.createSession(prompt, useInspiration && newSeed ? { playlistId: newSeed.playlistId, excludeSourceTracks: newSeed.excludeSourceTracks } : undefined)
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
    } finally {
      if (!signal.aborted) setCreatingTape(false)
    }
  }

  async function sendMessage(text: string) {
    const signal = controlLife.current.signal
    if (!activeSession || seedWrites.current.has(activeSession.id)) return
    const sessionId = activeSession.id
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
      const response = await api.sendMessage(sessionId, text)
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
    const mappedQueue = queue.map(toQueueTrack)
    queueVersions.current[sessionId] = queueVersion
    setQueuesBySession((current) => ({ ...current, [sessionId]: mappedQueue }))
    setSessions((current) =>
      current.map((session) =>
        session.id === sessionId
          ? toDjSession(
              {
                id: session.id,
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

  if (loadingCollection) {
    return (
      <main className="app-loading" aria-live="polite">
        <div>
          <Cassette loading labelled={false} />
          <p className="quiet-kicker">Your collection</p>
          <span>Opening your tapes…</span>
        </div>
      </main>
    )
  }

  return (
    <div className={`app-shell ${activeView !== 'session' || !activeSession ? 'app-shell--home' : ''}`} style={shellStyle}>
      <Sidebar
        sessions={sessions.filter((session) => session.status === 'active')}
        onRename={(id, title) => updateMix(id, { title })}
        onArchive={(id) => updateMix(id, { status: 'archived' })}
        onOpenArchived={() => { setShowArchived(true); setActiveView('home') }}
        activeSessionId={activeSession?.id ?? null}
        activeView={activeView}
        userName={user.name}
        musicLabel={musicLinkLabel(effectiveOnboarding)}
        onOpenSession={openSession}
        onOpenHome={() => { setShowArchived(false); setActiveView('home') }}
        onOpenMusic={openMusic}
        onNewTape={() => setDialog('new-tape')}
        onOpenAccount={() => setDialog('account')}
        onSync={() => {
          setMusicSection('apple')
          setActiveView('music')
        }}
        onSignOut={signOut}
        signInMethod={lastSignInProvider}
        syncDisabled={importBusy}
      />

      {activeView === 'memories' ? <MemoryControls api={api} onClose={() => setActiveView('home')} onSessionExpired={signOut} /> : activeView === 'music' ? (
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
          suggestions={<RoutineSuggestions key={user.id} api={api} busy={creatingTape} onCreate={prompt => createTape(prompt, false)} />}
          player={<PlaybackPanel controller={playback} />}
          sessions={sessions.filter((session) => session.status === (showArchived ? 'archived' : 'active'))}
          archived={showArchived}
          onArchived={setShowArchived}
          onRename={(id, title) => updateMix(id, { title })}
          onArchive={(id) => updateMix(id, { status: 'archived' })}
          onRestore={(id) => updateMix(id, { status: 'active' })}
          collectionView={collectionView}
          onChangeCollectionView={setCollectionView}
          onOpenSession={openSession}
          onNewTape={() => setDialog('new-tape')}
        />
      ) : (
        <>
          {historySessionId && <MixHistory initialVersion={historyVersion} key={`${historySessionId}-${historyVersion ?? "list"}`} api={api} sessionId={historySessionId} onClose={() => setHistorySessionId(null)} onSessionExpired={signOut} onRestored={() => loadSession(historySessionId)} />}
          {!historySessionId && <Conversation
            key={activeSession.id}
            selectionBusy={seedBusy === activeSession.id}
            attachment={<PlaylistAttachment api={api} onReload={!playlistSeeds[activeSession.id] ? () => reloadInspiration(activeSession.id) : undefined} value={attachmentValue(playlistSeeds[activeSession.id])} disabled={!playlistSeeds[activeSession.id] || thinkingSessionId === activeSession.id} onSelect={(value) => selectInspiration(activeSession.id, value)} onSessionExpired={signOut} />}
            onRename={(title) => updateMix(activeSession.id, { title })}
            onArchive={() => updateMix(activeSession.id, { status: 'archived' }).catch((e) => { announce('Couldn’t archive this mix. Try again.', 'error'); throw e })}
            session={activeSession}
            messages={activeMessages}
            loading={loadingSessionId === activeSession.id}
            thinking={thinkingSessionId === activeSession.id}
            player={<PlaybackPanel controller={playback} />}
            energySummary={<MixEnergySummary key={`${activeSession.id}:${activeSession.queueVersion}`} api={api} sessionId={activeSession.id} version={activeSession.queueVersion} />}
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
        <NewTapeDialog attachment={<PlaylistAttachment api={api} value={newSeed} onSelect={async (value) => setNewSeed(value)} disabled={creatingTape} onSessionExpired={signOut} />} busy={creatingTape} onClose={() => { setDialog(null); setNewSeed(null) }} onCreate={(prompt) => void createTape(prompt)} />
      ) : null}
      {dialog === 'save-playlist' && activeSession ? (
        <SaveDialog
          busy={playlistBusy}
          error={playlistError}
          defaultName={activeSession.title}
          onClose={() => setDialog(null)}
          onSave={(name) => void savePlaylist(name)}
        />
      ) : null}
      {dialog === 'interview' ? (
        <InterviewDialog api={api} onClose={() => setDialog(null)} onComplete={completeInterview} />
      ) : null}
      {effectiveOnboarding && effectiveOnboarding.chosenService === null ? (
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
      {archiveUndo && <div className="wc-undo" role="status">Mix archived.<button className="wc-text" onClick={() => void updateMix(archiveUndo, { status: 'active' }).catch(() => announce('Couldn’t restore the mix. Open Archived mixes to retry.', 'error'))}>Undo</button></div>}
      {toast ? <Toast message={toast.message} tone={toast.tone} /> : null}
    </div>
  )
}
