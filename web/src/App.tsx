import { useRestorableState, useWorkspaceRestoring } from './lib/workspace-restore'
import { RoutineSuggestions } from './components/RoutineSuggestions'
import { PlaybackController } from './playback/controller'
import { PlaybackPanel } from './components/PlaybackPanel'
import { MixEnergySummary, type EnergyArc } from './components/EnergyJourney'
import { useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore, type CSSProperties } from 'react'
import {
  AnonymousCapError,
  ApiError,
  isAiConsentRequired,
  REMAKE_TEXT,
  type AddMusicOffer,
  type AlbumPickResponse,
  type ApiQueueTrack,
  type ApiPlaylistSeed,
  type ChoosePickInput,
  type ApiPlaylistSummary,
  type CreateSessionResponse,
  type InitialPlaylistSeed,
  type InterviewResponse,
  type MergedMode,
  type ListeningImportSource,
  type MixtapeApi,
  type OnboardingResponse,
  type QueueOp,
  type QueueOpsResponse,
  type SendMessageOptions,
  type SendMessageResponse,
  type SessionDetailResponse,
  type TurnProgress,
  ShareNameRequiredError,
} from './api/client'
import { nextWorkingStep, type TurnWork, type WorkingStep } from './components/djWorkingLines'
import { toAlbumPickState, toDjMessage, toDjSession, toListenLaterEntry, toQueueTrack } from './api/mappers'
import { AlbumPanel } from './components/AlbumPanel'
import { AiConsentDialog, AiConsentGate } from './components/AiConsent'
import { useMediaQuery } from './lib/use-media-query'
import { SignInPage, signInHeadline, type AuthBridge, type AuthUser, type SignInVariant } from './components/AuthGate'
import { BackButton } from './components/first-run/FirstRunPage'
import { KeepSheet, keepSheetSeen, markKeepSheetSeen } from './components/first-run/KeepSheet'
import { PromptKept } from './components/PromptComposer'
import { AccountDialog, type AccountBridge } from './components/AccountDialog'
import { FirstRun } from './components/first-run/FirstRun'
import type { FirstRunServices } from './components/first-run/services'
import type { MusicService } from './components/first-run/ChooseService'
import type { AddMethod } from './components/first-run/ChooseMethod'
import { MixHistory } from './components/MixHistory'
import { Conversation } from './components/Conversation'
import type { MusicDoorInput } from './components/MusicDoor'
import { HomeDashboard } from './components/HomeDashboard'
import { AppSettings } from './components/AppSettings'
import { Home, type MixesTab } from './components/Home'
import { placeOnShelf } from './components/ListenLaterList'
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
import type { AlbumPick, AlbumPickState, AppView, CollectionView, DjMessage, DjSession, ListenLaterEntry, QueueTrack, SessionKind, SharedMixRow } from './domain'
import { SharedMixPage, type SharedMixPlayer } from './components/SharedMixPage'
import { ShareLinkCache, shareLink, sharePendingLink, type ShareOutcome } from './lib/share-link'
import { createImportRun } from './import/import-run'
import { createListeningImportService } from './import/import-service'
import { createLazyParser, createPageParser, type PageParser } from './import/page-parser'
import { MusicKitClientError, type MusicKitClient } from './musickit/client'
import { browserAuthPreferences, type AuthPreferenceStore, type AuthProvider } from './lib/auth-provider'
import { clearFunnelFlags, hasPostedFunnelEvent, postFunnelEventOnce } from './lib/funnel-once'
import { clearKeptPrompt, keepPrompt, readKeptPrompt } from './lib/kept-prompt'
import type { DraftSeed, ModeSeed } from './components/HomeComposer'
import { clearServiceChoice, readServiceChoice, writeServiceChoice, type ServiceChoice } from './lib/service-preference'
import { usePlaysOn, writePlaysOn } from './lib/plays-on'
import { addMusicFacts, addMusicRoute, type AddMusicTarget } from './lib/add-music-route'
import { createMusicAddedWatch, type MusicAddedToken } from './lib/music-added-watch'
import { NamePage, NamePageHold } from './components/first-run/NamePage'
import { clearNamePageSettled, markNamePageSettled, mayAskName } from './lib/name-page'

type DialogState = 'new-tape' | 'save-playlist' | 'account' | 'interview' | null
type MusicConnectionState = 'disconnected' | 'connecting' | 'connected' | 'error'
type ToastAction = { label: string; onClick: () => void }
type ToastState = { message: string; tone: 'success' | 'error' | 'info'; action?: ToastAction }
/**
 * The add flow over the shell: Library's Add your music (Step 1, ends in
 * Library), or a mix's (the router's page, ends back on the mix, with the mix
 * panel open again if it was, and its own music_added_from_mix watch).
 */
type AddMusicRun =
  | { from: 'library' }
  | { from: 'mix'; startAt?: AddMethod; watch: MusicAddedToken | null; queueWasOpen: boolean }

type AppProps = {
  api: MixtapeApi
  accountAuth: AccountBridge
  lastSignInProvider: AuthProvider | null
  musicKit: MusicKitClient
  user: AuthUser
  onSignOut: () => void
  /** Local-only sign-out after the account is deleted (no server call); falls back to onSignOut. */
  onAccountDeleted?: () => void
  /** The export parser the import page drives; the lazy Worker parser unless a test injects one. */
  importParser?: PageParser
  /** The mix the first run just made, seeded the way a new tape is. */
  initialSession?: CreateSessionResponse
  /** Fallback when only the id is known: the mix is read and opened. */
  initialSessionId?: string
  /** The provider sign-in behind the Keep sheet, the cap and the You row (anonymous listeners). */
  signInAuth?: Pick<AuthBridge, 'signIn'>
  signInPreferences?: AuthPreferenceStore
  /** Re-reads the session after a sign-in returns, so the shell re-renders as the account. */
  refetchSession?: () => void | Promise<void>
  /** A sign-in from the cap or the Keep pill that came back failed (anonymous listeners only). */
  signInError?: string
  /**
   * After a turn's stream dropped and the immediate read found no reply: how
   * long before the one more read. Inside the server's 30 s waitUntil grace;
   * tests shorten it.
   */
  landedReplyRereadMs?: number
}

type SignInPageState = Exclude<SignInVariant, 'welcome'>

/** The second read after a dropped turn stream: inside the 30 s the server gives a turn whose client left. */
const LANDED_REPLY_REREAD_MS = 25_000

/** How long a nameless account waits behind the sign-in image for GET /me before the workspace opens. */
const NAME_HOLD_MS = 3500

/** The name page reached from Share (approved board 2026-11-13 shared-mixes, copy locked). */
const SHARE_NAME_LINE = 'Whoever opens your link will see your first name.'

const NO_SIGN_IN: Pick<AuthBridge, 'signIn'> = { signIn: async () => ({ error: 'Sign-in is not available here.' }) }

/** The merge notice (board C4), once, after an anonymous session joined an account. */
export function mergeNotice(merged: MergedMode | null): string | null {
  if (merged === 'mixes_only') return 'Your mixes are in. This account already had a library, so we kept that one.'
  if (merged === 'library_kept') return 'This account already had a library, so we kept that one.'
  return null
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

/** The pick state an album response carries; null for a mix (or an older server). */
function albumStateOf(response: Partial<AlbumPickResponse>): AlbumPickState | null {
  if (typeof response.version !== 'number') return null
  return toAlbumPickState({ version: response.version, pick: response.pick ?? null, runnersUp: response.runnersUp ?? [], passed: response.passed ?? [] })
}

function detailToState(detail: SessionDetailResponse) {
  const session = toDjSession(detail.session, detail.queue)
  const albums = session.kind === 'album' ? albumStateOf(detail) : null
  return {
    // The server keeps one counter for a session; an album's pick version is its queue version.
    session: albums ? { ...session, queueVersion: albums.version, pick: albums.pick && albumSummary(albums.pick) } : session,
    messages: detail.messages.map(toDjMessage),
    queue: (detail.queue ?? []).map(toQueueTrack),
    albums,
  }
}

function albumSummary(album: AlbumPick) {
  return { title: album.title, artist: album.artist, artworkUrl: album.artworkUrl, artworkBgColor: album.artworkBgColor }
}

/** Saved state follows the album, wherever it sits in the shortlist. */
function withSaved(state: AlbumPickState, albumId: string, saved: boolean): AlbumPickState {
  const flip = (album: AlbumPick) => (album.id === albumId ? { ...album, savedForLater: saved } : album)
  return { ...state, pick: state.pick && flip(state.pick), runnersUp: state.runnersUp.map(flip), passed: state.passed.map(flip) }
}

/**
 * A Spotify-only listener on the web: chose Spotify, has no live Apple
 * library, and has not connected Apple Music in this browser. They get the
 * Spotify search in place of Play now; anyone with an Apple path keeps it.
 */
function isSpotifyOnly(onboarding: OnboardingResponse | null, musicConnection: MusicConnectionState): boolean {
  return onboarding?.chosenService === 'spotify'
    && !onboarding.sources.some((source) => source.source === 'apple_live')
    && musicConnection !== 'connected'
}

/**
 * Nothing says where this listener listens: no service chosen and no live
 * Apple library. The mix rail then asks (decisions 2026-11-06), unless this
 * browser already remembers an answer.
 */
function needsServiceChoice(onboarding: OnboardingResponse | null): boolean {
  if (onboarding?.sources.some((source) => source.source === 'apple_live')) return false
  return onboarding?.chosenService !== 'spotify' && onboarding?.chosenService !== 'apple'
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

function SignedInWorkspace({ api, accountAuth, lastSignInProvider, musicKit, user, onSignOut, onAccountDeleted, importParser, initialSession, initialSessionId, signInAuth = NO_SIGN_IN, signInPreferences = browserAuthPreferences, refetchSession, signInError = '', landedReplyRereadMs = LANDED_REPLY_REREAD_MS }: AppProps) {
  const anonymous = user.isAnonymous === true
  const restoring = useWorkspaceRestoring()
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
  const [storedMixesTab, setMixesTab] = useRestorableState<MixesTab>('mixesTab', 'active')
  // A stored tab from another version must not break the page.
  const mixesTab: MixesTab = storedMixesTab === 'archived' || storedMixesTab === 'listen-later' ? storedMixesTab : 'active'
  const [archiveUndo, setArchiveUndo] = useState<string | null>(null)
  const metadataRevision = useRef<Record<string, number>>({})
  const sessionWrites = useRef(new Set<string>())
  const controlLife = useRef(new AbortController())
  useEffect(() => { controlLife.current = new AbortController(); return () => controlLife.current.abort() }, [])
  useEffect(() => { if (!archiveUndo) return; const timer = setTimeout(() => setArchiveUndo(null), 3000); return () => clearTimeout(timer) }, [archiveUndo])
  const [collectionView, setCollectionView] = useRestorableState<CollectionView>('collectionView', 'list')
  // Shared mixes (spec 2026-11-13 shared-mixes). Per account: the workspace is
  // keyed by user id, so a sign-out or another account starts these empty.
  const [sharedRows, setSharedRows] = useState<SharedMixRow[]>([])
  const sharedReads = useRef(0)
  // Bumped by each Remove: a list read that started before it is stale.
  const sharedRemovals = useRef(0)
  // Which of this listener's mixes have an active share (GET /sessions/:id `shared`).
  const [sharedSessions, setSharedSessions] = useState<Record<string, boolean>>({})
  // The saved share open read-only inside Mixes, by token.
  const [openSharedToken, setOpenSharedToken] = useState<string | null>(null)
  // The name page reached from Share (no Skip), with the mix to share once a name is saved.
  const [shareNameFor, setShareNameFor] = useState<string | null>(null)
  // Links made this page load, per mix and queue version: sharing one again
  // opens the sheet straight from the tap.
  const shareUrls = useRef(new ShareLinkCache())
  const sharing = useRef(false)
  const [messagesBySession, setMessagesBySession] = useRestorableState<Record<string, DjMessage[]>>('messagesBySession', {})
  const [queuesBySession, setQueuesBySession] = useRestorableState<Record<string, QueueTrack[]>>('queuesBySession', {})
  const [albumsBySession, setAlbumsBySession] = useRestorableState<Record<string, AlbumPickState>>('albumsBySession', {})
  // Honest-failure refinements from the last turn; gone with the next one, so never restored.
  const [suggestionsBySession, setSuggestionsBySession] = useState<Record<string, string[]>>({})
  // The history pill the last turn offered; gone with the next turn, as the suggestions are.
  const [addMusicBySession, setAddMusicBySession] = useState<Record<string, AddMusicOffer | undefined>>({})
  // A remake from the tap until its post-turn reads land: the door steps aside meanwhile.
  const [remakingSessionId, setRemakingSessionId] = useState<string | null>(null)
  // The latest post-turn read per session: an earlier, slower one must not land over it.
  const turnReads = useRef<Record<string, number>>({})
  const [albumBusy, setAlbumBusy] = useState<string | null>(null)
  const savingAlbums = useRef(new Set<string>())
  // The shell drops its third column at this width; the album panel then folds into the conversation.
  const narrow = useMediaQuery('(max-width: 1020px)')
  const [loadingCollection, setLoadingCollection] = useState(true)
  const [loadingSessionId, setLoadingSessionId] = useState<string | null>(null)
  const [thinkingSessionId, setThinkingSessionId] = useState<string | null>(null)
  // The mix turn in flight per session, for the DJ's working line: when it went
  // out and its step once its stream opened. Lives here, not in the
  // conversation, so leaving the mix and coming back keeps the step; gone when
  // the turn ends, so never restored. `turn` keeps a late turn from clearing a newer one.
  const [turnWork, setTurnWork] = useState<Record<string, TurnWork & { turn: number }>>({})
  const turnCount = useRef(0)
  // Sessions with a turn out right now, read synchronously by work that outlives a render.
  const turnsOut = useRef(new Set<string>())
  // The one later read per session after a dropped turn stream; cleared on unmount.
  const landedRereads = useRef(new Map<string, ReturnType<typeof setTimeout>>())
  useEffect(() => () => {
    landedRereads.current.forEach(clearTimeout)
    landedRereads.current.clear()
  }, [])
  /** A turn is out for this session: the single album marker, or a mix turn's own entry. */
  const turnOut = (sessionId: string) => thinkingSessionId === sessionId || turnWork[sessionId] !== undefined
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
  // A published sync's onboarding read in flight: until it lands, the music
  // door still reads the sync as running rather than flashing its first state.
  const [syncLanding, setSyncLanding] = useState(false)
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
    onPublished: async () => {
      setSyncLanding(true)
      try { await refreshRef.current() } finally { setSyncLanding(false) }
    },
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
  const clearLocalAccount = useCallback(() => {
    importRun.dispose()
    syncRun.dispose()
    clearServiceChoice(user.id)
  }, [importRun, syncRun, user.id])
  const signOut = useCallback(() => {
    clearLocalAccount()
    onSignOut()
  }, [clearLocalAccount, onSignOut])
  const accountDeleted = useCallback(() => {
    clearLocalAccount()
    signInPreferences.forget()
    clearFunnelFlags(user.id)
    clearNamePageSettled(user.id)
    ;(onAccountDeleted ?? onSignOut)()
  }, [clearLocalAccount, signInPreferences, user.id, onAccountDeleted, onSignOut])
  // Settings shows the new name once the session re-read lands.
  const updateName = accountAuth.updateName
  // The write is what counts: a failed re-read must not report the save as failed.
  const saveName = useMemo(() => updateName && (async (name: string) => {
    await updateName(name)
    await Promise.resolve(refetchSession?.()).catch(() => undefined)
  }), [updateName, refetchSession])
  // Where this browser's mixes play: the listener's answer, else Spotify for a
  // Spotify-only listener. With neither, the mix rail asks.
  const playsOn = usePlaysOn()
  const spotifyLed = playsOn === 'spotify' || (playsOn === null && isSpotifyOnly(effectiveOnboarding, musicConnection))
  const askService = playsOn === null && !spotifyLed && needsServiceChoice(effectiveOnboarding)
  const activeMessages = activeSession ? messagesBySession[activeSession.id] ?? [] : []
  const activeQueue = activeSession ? queuesBySession[activeSession.id] ?? [] : []
  const activeIsAlbum = activeSession?.kind === 'album'
  const activeAlbums = activeSession && activeIsAlbum ? albumsBySession[activeSession.id] : undefined
  // Load MusicKit while Connect Apple Music is on screen, so the tap reaches
  // Apple's sign-in window inside Safari's user-activation window.
  const appleConnectOffered = musicConnection === 'disconnected'
    && !spotifyLed
    && (activeIsAlbum ? Boolean(activeAlbums?.pick?.appleId) : activeQueue.some((track) => track.appleId))
  useEffect(() => {
    if (appleConnectOffered) void musicKit.prepare?.().catch(() => undefined)
  }, [appleConnectOffered, musicKit])
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

  // Saved shares, read alongside the mixes and again each time Mixes opens,
  // so a share its sender stopped drops out on the next read.
  const inMixes = activeView === 'mixes'
  useEffect(() => {
    if (restoring || (!inMixes && sharedReads.current > 0)) return
    sharedReads.current += 1
    let cancelled = false
    const removalsAtStart = sharedRemovals.current
    api.listSharedMixes().then(
      // A read from before a Remove could bring the removed row back.
      (rows) => { if (!cancelled && removalsAtStart === sharedRemovals.current) setSharedRows(rows) },
      // The list works without them; a later read tries again.
      () => undefined,
    )
    return () => { cancelled = true }
  }, [api, inMixes, restoring])

  useEffect(() => { if (activeView !== 'mixes') setOpenSharedToken(null) }, [activeView])

  useEffect(() => {
    let cancelled = false

    async function loadOnboarding() {
      try {
        const result = await api.getOnboarding()
        if (!cancelled) {
          setOnboarding(result)
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

  // While the merge notice shows, a new tape's own toast does not replace it.
  const noticeHeld = useRef(false)
  function announce(message: string, tone: ToastState['tone'] = 'success', duration = 2800, action?: ToastAction) {
    // Behind the name page (or its hold) the shell is inert and a toast goes unheard: keep the latest for after.
    if (nameGateRef.current !== 'off') {
      deferredToast.current = { message, tone, duration, action }
      return
    }
    setToast({ message, tone, ...(action ? { action } : {}) })
    if (toastTimer.current) clearTimeout(toastTimer.current)
    toastTimer.current = setTimeout(() => { noticeHeld.current = false; setToast(null) }, duration)
  }

  // The merge result reaches the client once, on GET /me, and the server
  // clears it on read. Read once per account workspace: on load, and after a
  // sign-in from the in-app page (the new account remounts the workspace).
  const mergeRead = useRef(false)
  const [albumPicks, setAlbumPicks] = useState(false)
  // The name page (2026-11-02 profile name): GET /me's askName decides. An
  // account that may be asked waits behind the sign-in image ('hold') rather
  // than flashing the workspace first; the merge notice waits for the answer.
  const canSaveName = Boolean(accountAuth.updateName)
  const [heldForName] = useState(() => canSaveName && mayAskName(user))
  const [nameGate, setNameGateState] = useState<'hold' | 'ask' | 'off'>(heldForName ? 'hold' : 'off')
  const nameGateRef = useRef(nameGate)
  const heldNotice = useRef<string | null>(null)
  const deferredToast = useRef<{ message: string; tone: ToastState['tone']; duration: number; action?: ToastAction } | null>(null)
  // AI consent (docs/superpowers/plans/2026-11-02-ai-consent-and-privacy.md):
  // when /me says no, the dialog shows once over the app; Not now closes it
  // for this page load, and anything that would reach the DJ re-opens it
  // instead of sending. Until /me answers (or when it fails) nothing is gated.
  const consentMissing = useRef(false)
  const [consentOpen, setConsentOpen] = useState(false)
  const consentReady = useCallback(() => {
    if (!consentMissing.current) return true
    setConsentOpen(true)
    return false
  }, [])
  // The server's 403 ai_consent_required (a listener /me never asked, such as
  // an anonymous one): the same dialog, and later sends are gated here too.
  // After Agree the listener sends again themselves; nothing is re-sent.
  const consentRequired = useCallback(() => {
    consentMissing.current = true
    setConsentOpen(true)
  }, [])
  const transcribe = useCallback((audio: File, signal: AbortSignal) => api.transcribe(audio, signal).catch((cause: unknown) => {
    if (!isAiConsentRequired(cause)) throw cause
    consentRequired()
    throw new PromptKept()
  }), [api, consentRequired])
  async function grantConsent() {
    await api.grantAiConsent()
    consentMissing.current = false
    setConsentOpen(false)
  }
  useEffect(() => {
    if (restoring || anonymous || mergeRead.current) return
    mergeRead.current = true
    // A hanging /me must not strand the listener on the hold: the workspace
    // opens after a moment, and a late askName still opens the page over it.
    const holdTimer = heldForName ? setTimeout(() => { if (nameGateRef.current === 'hold') setNameGate('off') }, NAME_HOLD_MS) : undefined
    void Promise.resolve()
      .then(() => api.getMe())
      .then(({ merged, albumPicks, askName, aiConsent }) => {
        clearTimeout(holdTimer)
        setAlbumPicks(albumPicks)
        const asking = askName && canSaveName
        // The consent dialog waits for the name page: one question at a time.
        if (!aiConsent) {
          consentMissing.current = true
          if (!asking) setConsentOpen(true)
        }
        const notice = mergeNotice(merged)
        if (asking) heldNotice.current = notice
        setNameGate(asking ? 'ask' : 'off')
        if (!asking && heldForName) markNamePageSettled(user.id)
        if (notice && !asking) showMergeNotice(notice)
      })
      .catch(() => {
        clearTimeout(holdTimer)
        if (nameGateRef.current === 'hold') setNameGate('off')
      })
  }, [restoring, anonymous])

  /** Moves the gate; opening the workspace plays what waited behind it (the merge notice wins over a tape toast). */
  function setNameGate(next: 'hold' | 'ask' | 'off') {
    nameGateRef.current = next
    setNameGateState(next)
    if (next !== 'off') return
    const notice = heldNotice.current
    const toast = deferredToast.current
    heldNotice.current = null
    deferredToast.current = null
    if (notice) showMergeNotice(notice)
    else if (toast) announce(toast.message, toast.tone, toast.duration, toast.action)
  }

  function showMergeNotice(notice: string) {
    announce(notice, 'success', 6000)
    noticeHeld.current = true
  }

  /** Continue (after the save) or Skip: the workspace, then any held notice, with focus on the workspace's heading. */
  function closeNamePage() {
    setNameGate('off')
    if (consentMissing.current) setConsentOpen(true)
    // After the shell stops being inert.
    requestAnimationFrame(() => {
      const heading = document.querySelector<HTMLElement>('.app-shell main h1, .app-shell h1')
      if (!heading) return
      if (!heading.hasAttribute('tabindex')) heading.tabIndex = -1
      heading.focus({ preventScroll: true })
    })
  }

  function saveFromNamePage() {
    markNamePageSettled(user.id)
    closeNamePage()
  }

  // Skip moves on at once; only a recorded flag settles the page on this
  // browser, so after a failed write the next launch holds and asks again.
  function skipNamePage() {
    const mark = accountAuth.markNamePrompted
    if (mark) void mark().then(() => markNamePageSettled(user.id), () => undefined)
    closeNamePage()
  }

  // Keep this mix, the sign-in page over the shell, and the cap.
  const [keepSheet, setKeepSheet] = useState(false)
  const [signInPage, setSignInPage] = useState<SignInPageState | null>(null)
  // Whether the sign-in page came from a new mix's sheet: it then offers Skip, go to my mix.
  const [signInFromMix, setSignInFromMix] = useState(false)
  const [signInPageError, setSignInPageError] = useState('')
  const [draftSeed, setDraftSeed] = useState<DraftSeed | null>(null)
  // Find an album's Album mode lasts one visit to Home: leaving Home spends it.
  const [modeSeed, setModeSeed] = useState<ModeSeed | null>(null)
  useEffect(() => { if (activeView !== 'home') setModeSeed(null) }, [activeView])
  const signInOpener = useRef<HTMLElement | null>(null)
  const sheetShown = useRef(false)
  const mixReplySeen = useRef(false)
  // The sheet is a history entry so the browser's back closes it as Not now.
  // A mix handed over by the first run arrives while the first run is still
  // folding its own entries back (an async history.go), so that entry is
  // pushed once the fold's popstate lands, or after a short wait.
  const awaitingFold = useRef(Boolean(initialSession))
  const [sheetEntry, setSheetEntry] = useState(false)

  /** An anonymous listener's mix reply: the first-mix funnel and, once per session, the sheet. */
  function noteMixReply(queueLength: number) {
    if (!anonymous) return
    const first = !mixReplySeen.current && !hasPostedFunnelEvent(user.id, 'first_mix_made') && !hasPostedFunnelEvent(user.id, 'first_mix_refused')
    mixReplySeen.current = true
    if (queueLength === 0) {
      if (first) postFunnelEventOnce(api, user.id, 'first_mix_refused')
      return
    }
    postFunnelEventOnce(api, user.id, 'first_mix_made')
    if (sheetShown.current || keepSheetSeen()) return
    sheetShown.current = true
    markKeepSheetSeen()
    signInOpener.current = document.activeElement instanceof HTMLElement ? document.activeElement : null
    setKeepSheet(true)
    postFunnelEventOnce(api, user.id, 'keep_sheet_shown')
  }

  function withState(marker: Record<string, unknown>) {
    const current = window.history.state
    return { ...(current && typeof current === 'object' ? current : {}), ...marker }
  }

  useEffect(() => {
    if (!keepSheet || sheetEntry) return
    const push = () => {
      awaitingFold.current = false
      window.history.pushState(withState({ mixtapeKeepSheet: true }), '')
      setSheetEntry(true)
    }
    if (!awaitingFold.current) return push()
    let done = false
    const once = () => {
      if (done) return
      done = true
      window.removeEventListener('popstate', once)
      clearTimeout(timer)
      push()
    }
    window.addEventListener('popstate', once)
    const timer = setTimeout(once, 800)
    return () => {
      done = true
      window.removeEventListener('popstate', once)
      clearTimeout(timer)
    }
  }, [keepSheet, sheetEntry])

  // Browser back while the sheet is open: Not now.
  useEffect(() => {
    if (!keepSheet || !sheetEntry) return
    const onPop = () => dismissSheet(true)
    window.addEventListener('popstate', onPop)
    return () => window.removeEventListener('popstate', onPop)
  }, [keepSheet, sheetEntry])

  function openSignIn(variant: SignInPageState, options: { replace?: boolean; error?: string; fromMix?: boolean } = {}) {
    if (!keepSheet) signInOpener.current = document.activeElement instanceof HTMLElement ? document.activeElement : null
    setQueueOpen(false)
    setSignInPageError(options.error ?? '')
    setSignInFromMix(options.fromMix ?? false)
    setSignInPage(variant)
    const state = withState({ mixtapeKeepSheet: undefined, mixtapeSignIn: variant })
    if (options.replace) window.history.replaceState(state, '')
    else window.history.pushState(state, '')
  }

  function keepFromSheet() {
    setKeepSheet(false)
    postFunnelEventOnce(api, user.id, 'keep_sheet_signed_in')
    // The sheet's entry becomes the sign-in page's, so back returns to the mix.
    const replace = sheetEntry
    setSheetEntry(false)
    openSignIn('keep', { replace, fromMix: true })
  }

  function dismissSheet(fromHistory = false) {
    setKeepSheet(false)
    postFunnelEventOnce(api, user.id, 'keep_sheet_dismissed')
    // Not now, Escape, the handle or the backdrop fold the sheet's entry back;
    // its listener is gone by the time that pop lands.
    if (sheetEntry && !fromHistory) window.history.back()
    setSheetEntry(false)
    requestAnimationFrame(() => signInOpener.current?.focus())
  }

  // The sign-in page is a history entry: the outlined back and the browser's
  // back both close it. Back from the cap leaves the prompt in the field and
  // drops the copy kept for after the redirect.
  useEffect(() => {
    if (!signInPage) return
    const before = document.title
    document.title = signInHeadline(signInPage)
    document.getElementById('auth-title')?.focus({ preventScroll: true })
    const onPop = () => {
      if (signInPage === 'cap') clearKeptPrompt()
      setSignInPage(null)
      requestAnimationFrame(() => signInOpener.current?.focus())
    }
    window.addEventListener('popstate', onPop)
    return () => {
      window.removeEventListener('popstate', onPop)
      document.title = before
    }
  }, [signInPage])

  // After a sign-in from the cap page, the kept mix is sent once the
  // account's workspace is ready. An anonymous load means the sign-in did not
  // take: with a sign-in error the page reopens with it (the cap page with the
  // prompt back in the field, or the Keep variant); without one a stale kept
  // prompt is dropped.
  const keptHandled = useRef(false)
  useEffect(() => {
    if (restoring || keptHandled.current) return
    keptHandled.current = true
    const kept = readKeptPrompt()
    if (anonymous && signInError) {
      if (kept) {
        setActiveView('home')
        setDraftSeed({ text: kept.prompt, id: Date.now() })
        openSignIn('cap', { error: signInError })
      } else openSignIn('keep', { error: signInError })
      return
    }
    if (!kept) return
    clearKeptPrompt()
    if (!anonymous) void createTape(kept.prompt, false, false, kept.shape ?? undefined, kept.inspiration)
  }, [restoring])

  // music_added_from_mix: armed per router-opened run, heard on every onboarding read.
  const musicWatch = useMemo(
    () =>
      createMusicAddedWatch({
        gate: uploadGate,
        syncRun,
        importRun,
        refresh: () => refreshRef.current(),
        record: () => void api.postFunnelEvent({ type: 'music_added_from_mix', surface: 'web' }).catch(() => undefined),
      }),
    [api, uploadGate, syncRun, importRun],
  )
  useEffect(() => () => musicWatch.clear(), [musicWatch])

  async function refreshOnboarding() {
    try {
      const next = await api.getOnboarding()
      setOnboarding(next)
      musicWatch.observe(next.musicReady)
    } catch (requestError) {
      if (requestError instanceof ApiError && requestError.status === 401) signOut()
    }
    setMusicRevision((revision) => revision + 1)
  }
  refreshRef.current = refreshOnboarding

  // Library's Add your music: the first run's Step 1 to 3 pages over the
  // shell, on the same runs, returning to Library when they finish. A mix's
  // Add your music opens the same flow at the router's page (openAddMusicFor).
  const [addingMusic, setAddingMusic] = useState<AddMusicRun | null>(null)
  // The control that opened the flow gets focus back when it ends.
  const addMusicOpener = useRef<HTMLElement | null>(null)
  const addMusicServices = useMemo<FirstRunServices>(
    () => ({ api, syncRun, importRun, ensureSession: () => Promise.resolve() }),
    [api, syncRun, importRun],
  )

  function recordServiceChoice(service: MusicService) {
    writeServiceChoice(user.id, service)
    setLocalChoice(service)
    if (service === 'spotify') {
      void api
        .postFunnelEvent({ type: 'chose_spotify', surface: 'web' })
        .catch(() => undefined)
        .then(() => refreshOnboarding())
    }
  }

  function openAddMusic() {
    // Music added from Library is not counted as added from a mix.
    musicWatch.clear()
    addMusicOpener.current = document.activeElement instanceof HTMLElement ? document.activeElement : null
    setQueueOpen(false)
    setAddingMusic({ from: 'library' })
  }

  function finishAddingMusic() {
    setAddingMusic(null)
    setActiveView('music')
    void refreshOnboarding()
    // After the shell stops being inert.
    requestAnimationFrame(() => addMusicOpener.current?.focus())
  }

  /**
   * A mix's Add your music (the door, its sync retry, the history pill),
   * routed by addMusicRoute to the add flow at the right page, or Step 1.
   * Called by the door and the pill (W2).
   */
  function openAddMusicFor(target: AddMusicTarget) {
    const route = addMusicRoute(target, addMusicFacts(playsOn, effectiveOnboarding))
    if (route.kind === 'none') return
    void api
      .postFunnelEvent({ type: target === 'history' ? 'music_chip_tapped' : 'music_door_tapped', surface: 'web' })
      .catch(() => undefined)
    addMusicOpener.current = document.activeElement instanceof HTMLElement ? document.activeElement : null
    // Only a known false can turn true; an unread or older onboarding arms nothing.
    const watch = musicWatch.arm(effectiveOnboarding?.musicReady)
    setAddingMusic({ from: 'mix', startAt: route.startAt, watch, queueWasOpen: queueOpen })
    setQueueOpen(false)
  }

  /** Back on the mix it was opened from, with the door's state read again. */
  function finishAddingMusicForMix(run: Extract<AddMusicRun, { from: 'mix' }>) {
    setAddingMusic(null)
    // The phone shell's mix panel held the opener: open it again before focusing.
    if (run.queueWasOpen) setQueueOpen(true)
    musicWatch.settle(run.watch)
    // After the shell stops being inert and the panel is visible again.
    requestAnimationFrame(() => refocusMix(run.queueWasOpen))
  }

  /**
   * Back on the mix after the add flow: the control that opened it, else (the
   * door changed state and that control is gone) the door's current action,
   * else the composer.
   */
  function refocusMix(inPanel: boolean) {
    const opener = addMusicOpener.current
    if (opener?.isConnected && !opener.matches(':disabled')) return opener.focus()
    const doors = inPanel ? '.queue-panel .banner--door' : '.conversation-panel .music-door'
    const action = document.querySelector<HTMLElement>(`${doors} button:not(:disabled)`)
    const composer = document.querySelector<HTMLElement>('.conversation-panel .composer-area textarea')
    ;(action ?? composer)?.focus()
  }

  /** A transcript line, by its message id (the listener's lines take focus). */
  function focusTurn(messageId: string) {
    const line = [...document.querySelectorAll<HTMLElement>('.conversation-panel [data-turn-id]')].find((element) => element.dataset.turnId === messageId)
    line?.focus()
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
  // `known`: a read already made (a reply adopted after a dropped stream), used instead of a new one.
  async function refreshSessionAfterTurn(sessionId: string, known?: SessionDetailResponse) {
    const signal = controlLife.current.signal
    const read = (turnReads.current[sessionId] ?? 0) + 1
    turnReads.current[sessionId] = read
    const stale = () => turnReads.current[sessionId] !== read
    try {
      const revision = seedRevision.current[sessionId] ?? 0
      const detail = known ?? await api.getSession(sessionId)
      if (signal.aborted || stale()) return
      if ((seedRevision.current[sessionId] ?? 0) === revision) setPlaylistSeeds(current => ({ ...current, [sessionId]: detail.playlistSeed }))
      setSessions((current) =>
        current.map((session) =>
          session.id === sessionId ? { ...session, notPersonal: detail.session.notPersonal } : session,
        ),
      )
      const albums = (detail.session.kind ?? 'mix') === 'album' ? albumStateOf(detail) : null
      if (albums) {
        // Only a newer read replaces the turn's own pick state: the counter only moves forward.
        const held = albumsBySessionRef.current[sessionId]
        if (held && albums.version <= held.version) return
        // A save or unsave still in flight keeps its optimistic state over the read.
        const inFlight = [held?.pick, ...(held?.runnersUp ?? []), ...(held?.passed ?? [])]
          .filter((album): album is AlbumPick => Boolean(album && savingAlbums.current.has(album.id)))
        applyAlbumState(sessionId, inFlight.reduce((state, album) => withSaved(state, album.id, album.savedForLater), albums))
        return
      }
      notePersonalMix(detail.session, detail.queue?.length ?? 0)
    } catch (requestError) {
      if (signal.aborted || stale()) return
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

  async function loadSession(sessionId: string, isCancelled: () => boolean = () => controlLife.current.signal.aborted, force = false) {
    const revision = contentRevision.current[sessionId] ?? 0
    const cancelled = () => isCancelled() || revision !== (contentRevision.current[sessionId] ?? 0)
    const cached = Boolean(messagesBySession[sessionId] && queuesBySession[sessionId])
    if (cached && refreshedSessions.current.has(sessionId) && !force) return
    if (!cached) setLoadingSessionId(sessionId)
    const metadataAtStart = metadataRevision.current[sessionId] ?? 0
    try {
      const detail = await api.getSession(sessionId)
      if (cancelled()) return
      const mapped = detailToState(detail)
      refreshedSessions.current.add(sessionId)
      setPlaylistSeeds(current => ({ ...current, [sessionId]: detail.playlistSeed }))
      setSharedSessions((current) => ({ ...current, [sessionId]: detail.shared === true }))
      // Stopped on another device: a link made here is revoked.
      if (detail.shared !== true) shareUrls.current.forget(sessionId)
      setSessions((current) => current.map((session) => (session.id === sessionId ? { ...mapped.session, ...((metadataRevision.current[sessionId] ?? 0) !== metadataAtStart ? { title: session.title, status: session.status, caseColor: session.caseColor } : {}) } : session)))
      setMessagesBySession((current) => ({ ...current, [sessionId]: mapped.messages }))
      setQueuesBySession((current) => ({ ...current, [sessionId]: mapped.queue }))
      if (mapped.albums) setAlbumsBySession((current) => ({ ...current, [sessionId]: mapped.albums! }))
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
      // A share snapshots the title: a renamed mix needs a new link.
      if (updates.title !== undefined) shareUrls.current.forget(id)
      if (updates.status === 'archived') {
        if (navigation.current.activeSessionId === id && navigation.current.activeView === 'session') { setActiveView('home'); setActiveSessionId(null) }
        setArchiveUndo(id)
      } else if (updates.status === 'active') setArchiveUndo(null)
    } catch (e) {
      if (!signal.aborted && e instanceof ApiError && e.status === 401) signOut()
      throw e
    } finally { sessionWrites.current.delete(id) }
  }

  /**
   * Share (spec Sender): POST /sessions/:id/share, then the share sheet or
   * the clipboard. A 409 name_required opens the name page with no Skip;
   * saving there shares again. Called straight from the tap: Safari spends
   * the tap's activation on the first await, so a link not yet made goes
   * through sharePendingLink, and a sheet refused after the wait offers its
   * own Share button (a fresh tap).
   */
  async function shareMix(sessionId: string) {
    if (sharing.current) return
    const session = sessions.find((item) => item.id === sessionId)
    const title = session?.title ?? 'Mix'
    const version = session?.queueVersion ?? 0
    sharing.current = true
    try {
      const cached = shareUrls.current.get(sessionId, version)
      if (cached) {
        const outcome = await shareLink(cached, title).catch(() => null)
        reportShare(outcome, cached, title)
        return
      }
      const pending = api.shareSession(sessionId).then((result) => result.url)
      const delivered = sharePendingLink(pending, title)
      let url: string
      try {
        url = await pending
      } catch (cause) {
        delivered.catch(() => undefined)
        if (cause instanceof ShareNameRequiredError && saveName) { setShareNameFor(sessionId); return }
        if (cause instanceof ApiError && cause.status === 401) { signOut(); return }
        announce('Couldn’t share this mix. Try again.', 'error')
        return
      }
      shareUrls.current.set(sessionId, version, url)
      setSharedSessions((current) => ({ ...current, [sessionId]: true }))
      reportShare(await delivered.catch(() => null), url, title)
    } finally {
      sharing.current = false
    }
  }

  function reportShare(outcome: ShareOutcome | null, url: string, title: string) {
    if (outcome === 'copied') announce('Link copied', 'success')
    else if (outcome === 'blocked') {
      announce('Link ready', 'info', 10_000, {
        label: 'Share',
        onClick: () => {
          if (toastTimer.current) clearTimeout(toastTimer.current)
          setToast(null)
          void shareLink(url, title).then(
            (next) => reportShare(next === 'blocked' ? null : next, url, title),
            () => reportShare(null, url, title),
          )
        },
      })
    } else if (outcome === null) announce('Couldn’t share this mix. Try again.', 'error')
  }

  async function stopSharing(sessionId: string) {
    try {
      await api.stopSharing(sessionId)
    } catch (cause) {
      if (cause instanceof ApiError && cause.status === 401) signOut()
      throw cause
    }
    shareUrls.current.forget(sessionId)
    setSharedSessions((current) => ({ ...current, [sessionId]: false }))
  }

  function shareAfterName() {
    const sessionId = shareNameFor
    setShareNameFor(null)
    markNamePageSettled(user.id)
    if (sessionId) void shareMix(sessionId)
  }

  /** Remove (spec Recipient): deletes this listener's save, never the share. */
  async function removeSharedMix(token: string) {
    try {
      await api.removeSharedMix(token)
    } catch (cause) {
      if (cause instanceof ApiError && cause.status === 401) signOut()
      throw cause
    }
    sharedRemovals.current += 1
    setSharedRows((rows) => rows.filter((row) => row.token !== token))
    setOpenSharedToken((open) => (open === token ? null : open))
  }

  // The in-app view plays a share through the app's own MusicKit and controller;
  // the listener already has a session, so there is none to make.
  const sharedPlayer = useMemo<SharedMixPlayer>(() => ({ ensureSession: async () => undefined, musicKit, playback }), [musicKit, playback])
  const sharedSession = useMemo(() => ({ isPending: false, userId: user.id }), [user.id])

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

  // The first run's mix opens from its own response, as a new tape does; the
  // personal-mix milestone waits for the onboarding read it depends on.
  const openedInitial = useRef(false)
  const pendingInitialMilestone = useRef<CreateSessionResponse | null>(null)
  useEffect(() => {
    if (restoring || openedInitial.current) return
    if (initialSession) {
      openedInitial.current = true
      adoptNewSession(initialSession)
      pendingInitialMilestone.current = initialSession
    } else if (initialSessionId) {
      openedInitial.current = true
      openSession(initialSessionId)
    }
  }, [restoring, initialSession, initialSessionId])
  useEffect(() => {
    const pending = pendingInitialMilestone.current
    if (!pending || !onboarding) return
    pendingInitialMilestone.current = null
    notePersonalMix(pending.session, pending.queue?.length ?? 0)
  }, [onboarding, effectiveOnboarding])

  /** True once Apple Music is connected in this browser. */
  async function connectAppleMusic(): Promise<boolean> {
    if (musicConnection === 'connecting') return false
    setMusicConnection('connecting')
    try {
      await musicKit.connect()
      setMusicConnection('connected')
      return true
    } catch {
      setMusicConnection('error')
      return false
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

  /** A new mix's response becomes workspace state and the open session. */
  function adoptNewSession(response: CreateSessionResponse) {
    setPlaylistSeeds(current => ({ ...current, [response.session.id]: response.playlistSeed }))
    const mapped = detailToState(response)
    setSessions((current) => [mapped.session, ...current.filter((session) => session.id !== mapped.session.id)])
    setMessagesBySession((current) => ({ ...current, [mapped.session.id]: mapped.messages }))
    setQueuesBySession((current) => ({ ...current, [mapped.session.id]: mapped.queue }))
    if (mapped.albums) setAlbumsBySession((current) => ({ ...current, [mapped.session.id]: mapped.albums! }))
    setSuggestionsBySession((current) => ({ ...current, [mapped.session.id]: response.suggestions ?? [] }))
    setAddMusicBySession((current) => ({ ...current, [mapped.session.id]: response.addMusic }))
    setActiveSessionId(mapped.session.id)
    setActiveView('session')
    setDialog(null)
    setError('')
    const album = mapped.session.kind === 'album'
    if (!noticeHeld.current) announce(album ? 'Your album pick is ready.' : 'Your new tape is ready.')
    // The first-mix funnel and the Keep sheet are mix milestones.
    if (!album) noteMixReply(response.queue?.length ?? 0)
  }

  /** `inspiration` overrides the dialog's seed (the kept mix re-sent after sign-in). */
  async function createTape(prompt: string, useInspiration = true, propagateError = false, shape?: EnergyArc, inspiration?: InitialPlaylistSeed | null, kind: SessionKind = 'mix') {
    if (creatingTape) return
    // New mix, a routine suggestion, an album ask: the dialog answers and the prompt stays where it was.
    if (!consentReady()) {
      if (propagateError) throw new PromptKept()
      return
    }
    const signal = controlLife.current.signal
    setCreatingTape(true)
    const seed = inspiration !== undefined
      ? inspiration ?? undefined
      : useInspiration && newSeed ? { playlistId: newSeed.playlistId, excludeSourceTracks: newSeed.excludeSourceTracks } : undefined
    try {
      const response = kind === 'album' ? await api.createSession(prompt, seed, undefined, 'album') : await api.createSession(prompt, seed, shape)
      if (signal.aborted) return
      setNewSeed(null)
      adoptNewSession(response)
      if ((response.session.kind ?? 'mix') === 'mix') notePersonalMix(response.session, response.queue?.length ?? 0)
    } catch (requestError) {
      if (signal.aborted) return
      if (isAiConsentRequired(requestError)) {
        // The prompt stays where it was typed (the New mix dialog stays open).
        consentRequired()
        if (propagateError) throw new PromptKept()
        return
      }
      if (requestError instanceof AnonymousCapError) {
        // The composer stays as it is; the sign-in page answers (board C2).
        postFunnelEventOnce(api, user.id, 'cap_reached')
        keepPrompt({ prompt, inspiration: seed ?? null, shape: shape ?? null })
        // From New mix: the dialog closes as the sign-in page opens; the kept
        // record carries its seed and shape.
        setDialog(null)
        openSignIn('cap')
        if (propagateError) throw new PromptKept()
        return
      }
      setError(errorCopy(requestError))
      if (requestError instanceof ApiError && requestError.status === 401) signOut()
      if (propagateError) throw requestError
    } finally {
      if (!signal.aborted) setCreatingTape(false)
    }
  }

  /**
   * `keepPrompt`: a consent 403 rejects with PromptKept so the composer puts the text back.
   * `turn.remake`: the door's Remake with my music rides the same turn; `turn.onSent`
   * hears the listener's line once it is drawn, only when the send goes out.
   */
  async function sendMessage(text: string, shape?: EnergyArc, keepPrompt = false, turn: { remake?: boolean; onSent?: (messageId: string) => void } = {}) {
    const signal = controlLife.current.signal
    if (!activeSession || seedWrites.current.has(activeSession.id)) return
    if (!consentReady()) return
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
    setSuggestionsBySession((current) => ({ ...current, [sessionId]: [] }))
    setAddMusicBySession((current) => ({ ...current, [sessionId]: undefined }))
    turn.onSent?.(userMessage.id)

    const isAlbum = activeSession.kind === 'album'
    const hadMix = (queuesBySession[sessionId]?.length ?? 0) > 0
    const remaking = turn.remake === true && !isAlbum
    const remakeSettled = () => setRemakingSessionId((current) => (current === sessionId ? null : current))
    // A mix turn asks for its steps (spec 2026-11-13 dj-turn-steps); an album turn keeps its static line.
    const turnId = (turnCount.current += 1)
    const stream: { step: WorkingStep | null } = { step: null }
    const onProgress = (progress: TurnProgress) => {
      const next = nextWorkingStep(stream.step, progress, Date.now())
      if (next === stream.step || signal.aborted) return
      stream.step = next
      setTurnWork((current) => (current[sessionId]?.turn === turnId ? { ...current, [sessionId]: { ...current[sessionId], step: next } } : current))
    }
    if (!isAlbum) setTurnWork((current) => ({ ...current, [sessionId]: { turn: turnId, startedAt: Date.now(), step: null } }))
    turnsOut.current.add(sessionId)
    clearTimeout(landedRereads.current.get(sessionId))
    landedRereads.current.delete(sessionId)
    const options: SendMessageOptions | undefined = isAlbum ? undefined : { ...(remaking ? { remake: true } : {}), onProgress }
    // What the transcript held before this turn, to tell a reply that landed after a dropped stream.
    const knownMessages = new Set((messagesBySession[sessionId] ?? []).map((message) => message.id))
    const turnRevision = contentRevision.current[sessionId]
    let recover: (() => void) | undefined
    if (remaking) {
      // Counted only now, past the consent and seed checks: this remake is going out.
      setRemakingSessionId(sessionId)
      void api.postFunnelEvent({ type: 'remake_tapped', surface: 'web' }).catch(() => undefined)
    }
    try {
      const response = options ? await api.sendMessage(sessionId, text, shape, options) : await api.sendMessage(sessionId, text, shape)
      if (signal.aborted) return
      landReply(sessionId, response, { isAlbum, hadMix, metadataAtStart })
      const reread = refreshSessionAfterTurn(sessionId)
      // A remake waits for both reads: whether the mix is personal now, and
      // whether the music is ready at all (if not, the door's first state).
      if (remaking) void Promise.all([reread, refreshOnboarding()]).finally(remakeSettled)
    } catch (requestError) {
      if (signal.aborted) return
      // Nothing to wait for: the door comes back with Remake, under the error line.
      if (remaking) remakeSettled()
      if (isAiConsentRequired(requestError)) {
        // Nothing reached the DJ: the pending turn goes, no error turn is added.
        setMessagesBySession((current) => ({
          ...current,
          [sessionId]: (current[sessionId] ?? []).filter((message) => message.id !== userMessage.id),
        }))
        consentRequired()
        if (keepPrompt) throw new PromptKept()
        return
      }
      // The stream opened and then dropped: the server has this turn and is
      // likely still running it, so it fails as a server-side turn does (the
      // same line), and the session is read for a reply that lands meanwhile.
      const dropped = stream.step !== null && requestError instanceof TypeError
      const errorId = `${sessionId}-error-${Date.now()}`
      setMessagesBySession((current) => ({
        ...current,
        [sessionId]: [
          ...(current[sessionId] ?? []),
          { id: errorId, role: 'dj', content: errorCopy(requestError), createdAt: new Date().toISOString() },
        ],
      }))
      // Once this turn is no longer out (the finally below).
      if (dropped) recover = () => recoverDroppedTurn(sessionId, { known: knownMessages, revision: turnRevision, metadataAtStart, hadMix, remaking, errorId })
      else if (requestError instanceof ApiError && requestError.status === 401) signOut()
      else if (isAlbum) {
        // A version can land before an album turn fails; the error then carries the new pick state.
        const payload = requestError instanceof ApiError && typeof requestError.payload === 'object' && requestError.payload
          ? requestError.payload as Partial<AlbumPickResponse>
          : null
        const landed = payload && typeof payload.version === 'number' && 'pick' in payload ? albumStateOf(payload) : null
        if (landed) applyAlbumState(sessionId, landed)
        else void refreshSessionAfterTurn(sessionId)
      }
    } finally {
      turnsOut.current.delete(sessionId)
      recover?.()
      if (!signal.aborted) {
        // Only this session's marker: a turn in another mix may have taken it since.
        setThinkingSessionId((current) => (current === sessionId ? null : current))
        setTurnWork((current) => {
          if (current[sessionId]?.turn !== turnId) return current
          const { [sessionId]: _ended, ...rest } = current
          return rest
        })
      }
    }
  }

  /** What a turn's reply sets, from the turn's own answer or from a reply adopted after a dropped stream. */
  function landReply(sessionId: string, response: SendMessageResponse, { isAlbum, hadMix, metadataAtStart }: { isAlbum: boolean; hadMix: boolean; metadataAtStart: number }) {
    const queue = (response.queue ?? []).map(toQueueTrack)
    const albums = isAlbum ? albumStateOf(response) : null
    // A refusal answered with more artists: the first mix lands on this turn.
    if (!hadMix && !isAlbum) noteMixReply(queue.length)
    setMessagesBySession((current) => ({
      ...current,
      [sessionId]: [...(current[sessionId] ?? []), toDjMessage(response.djMessage)],
    }))
    setQueuesBySession((current) => ({ ...current, [sessionId]: queue }))
    if (albums) setAlbumsBySession((current) => ({ ...current, [sessionId]: albums }))
    if (response.suggestions?.length) setSuggestionsBySession((current) => ({ ...current, [sessionId]: response.suggestions! }))
    if (response.addMusic) setAddMusicBySession((current) => ({ ...current, [sessionId]: response.addMusic }))
    setSessions((current) =>
      current.map((session) => {
        if (session.id !== sessionId) return session
        const { pick: _pick, ...rest } = session
        const next = toDjSession(
          {
            ...rest,
            title: (metadataRevision.current[sessionId] ?? 0) === metadataAtStart ? response.sessionTitle ?? session.title : session.title,
            queueVersion: albums?.version ?? response.queueVersion ?? session.queueVersion,
            updatedAt: new Date().toISOString(),
          },
          response.queue,
        )
        return albums ? { ...next, pick: albums.pick && albumSummary(albums.pick) } : next
      }),
    )
  }

  /**
   * After a mix turn's stream dropped once it had opened: the server has the
   * turn, persists the listener's line at its start, and gets up to 30 s more
   * to finish. So the session is read at once and, if no reply is there yet,
   * once more `landedReplyRereadMs` later. A read is adopted only when it ends
   * in a DJ reply this transcript has not seen, and only while nothing else
   * changed the mix, no turn is out for it and the workspace still holds it.
   * Adopting takes the reply as a turn's own answer would (the GET carries no
   * suggestions or history pill) and drops the failure line.
   */
  function recoverDroppedTurn(sessionId: string, turn: { known: Set<string>; revision: number | undefined; metadataAtStart: number; hadMix: boolean; remaking: boolean; errorId: string }) {
    const signal = controlLife.current.signal
    const current = () => !signal.aborted
      && contentRevision.current[sessionId] === turn.revision
      && !turnsOut.current.has(sessionId)
      && sessionsRef.current.some((session) => session.id === sessionId)
    const later = () => {
      landedRereads.current.set(sessionId, setTimeout(() => {
        landedRereads.current.delete(sessionId)
        void read(false)
      }, landedReplyRereadMs))
    }
    async function read(first: boolean) {
      if (!current()) return
      let detail: SessionDetailResponse
      try {
        detail = await api.getSession(sessionId)
      } catch (requestError) {
        if (signal.aborted) return
        if (requestError instanceof ApiError && requestError.status === 401) signOut()
        else if (first && current()) later()
        return
      }
      if (!current()) return
      const last = detail.messages.at(-1)
      if (!last || last.role !== 'dj' || turn.known.has(last.id)) {
        if (first) later()
        return
      }
      setMessagesBySession((messages) => ({ ...messages, [sessionId]: (messages[sessionId] ?? []).filter((message) => message.id !== turn.errorId) }))
      landReply(sessionId, { djMessage: last, queue: detail.queue ?? [], queueVersion: detail.session.queueVersion, sessionTitle: detail.session.title }, { isAlbum: false, hadMix: turn.hadMix, metadataAtStart: turn.metadataAtStart })
      void refreshSessionAfterTurn(sessionId, detail)
      if (turn.remaking) void refreshOnboarding()
    }
    void read(true)
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
      applyQueueSnapshot(sessionId, detail.session.queueVersion, detail.queue ?? [])
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

  // The latest pick state for async work that outlives a render (a refresh landing after a pick).
  const albumsBySessionRef = useRef(albumsBySession)
  albumsBySessionRef.current = albumsBySession
  // The latest sessions, for a read after a dropped turn stream that lands after renders.
  const sessionsRef = useRef(sessions)
  sessionsRef.current = sessions

  function applyAlbumState(sessionId: string, state: AlbumPickState) {
    contentRevision.current[sessionId] = (contentRevision.current[sessionId] ?? 0) + 1
    queueVersions.current[sessionId] = state.version
    setAlbumsBySession((current) => ({ ...current, [sessionId]: state }))
    setSessions((current) => current.map((session) => session.id === sessionId
      ? { ...session, queueVersion: state.version, pick: state.pick && albumSummary(state.pick) }
      : session))
  }

  /** Pick this (a runner-up) or Go back (an earlier version): no model call, one counter bump. */
  async function choosePick(input: ChoosePickInput) {
    if (!activeSession || albumBusy) return
    const sessionId = activeSession.id
    const signal = controlLife.current.signal
    setAlbumBusy(sessionId)
    try {
      const response = await api.choosePick(sessionId, input, activeSession.queueVersion)
      if (signal.aborted) return
      applyAlbumState(sessionId, toAlbumPickState(response))
      setSuggestionsBySession((current) => ({ ...current, [sessionId]: [] }))
    } catch (requestError) {
      if (signal.aborted) return
      if (requestError instanceof ApiError && requestError.status === 409) {
        await loadSession(sessionId, undefined, true)
        announce('This album pick moved on. Showing the latest.', 'info')
      } else {
        announce('Couldn’t change the album. Try again.', 'error')
        if (requestError instanceof ApiError && requestError.status === 401) signOut()
      }
    } finally {
      if (!signal.aborted) setAlbumBusy(null)
    }
  }

  function markAlbumSaved(sessionId: string, albumId: string, saved: boolean) {
    setAlbumsBySession((current) => current[sessionId] ? { ...current, [sessionId]: withSaved(current[sessionId], albumId, saved) } : current)
  }

  async function saveAlbum(sessionId: string, albumId: string) {
    // A second press while the first is in flight, or a save of a saved album, is a no-op.
    if (savingAlbums.current.has(albumId)) return
    savingAlbums.current.add(albumId)
    const signal = controlLife.current.signal
    markAlbumSaved(sessionId, albumId, true)
    try {
      await api.saveForLater(albumId, sessionId, signal)
      if (signal.aborted) return
      announce('On your Listen later shelf.', 'success', 4000, { label: 'Undo', onClick: () => { setToast(null); void unsaveAlbum(sessionId, albumId) } })
    } catch (requestError) {
      if (signal.aborted) return
      markAlbumSaved(sessionId, albumId, false)
      announce('Couldn’t save this album. Try again.', 'error')
      if (requestError instanceof ApiError && requestError.status === 401) signOut()
    } finally {
      savingAlbums.current.delete(albumId)
    }
  }

  async function unsaveAlbum(sessionId: string, albumId: string) {
    if (savingAlbums.current.has(albumId)) return
    savingAlbums.current.add(albumId)
    const signal = controlLife.current.signal
    markAlbumSaved(sessionId, albumId, false)
    try {
      await api.unsaveForLater(albumId, signal)
    } catch (requestError) {
      if (signal.aborted) return
      markAlbumSaved(sessionId, albumId, true)
      announce('Couldn’t remove this album. Try again.', 'error')
      if (requestError instanceof ApiError && requestError.status === 401) signOut()
    } finally {
      savingAlbums.current.delete(albumId)
    }
  }

  function toggleAlbumSaved(album: AlbumPick) {
    if (!activeSession) return
    // Unsaving from the filled state shows no toast; saving offers Undo.
    if (album.savedForLater) void unsaveAlbum(activeSession.id, album.id)
    else void saveAlbum(activeSession.id, album.id)
  }

  // Listen later in Mixes (board W6, W7). The shelf is read each time its tab opens, so saves and
  // unsaves made from the album panel since the last visit show up without a shared cache.
  const [listenLater, setListenLater] = useState<ListenLaterEntry[] | null>(null)
  const [listenLaterError, setListenLaterError] = useState('')
  const [shelfReads, setShelfReads] = useState(0)
  // Albums whose shelf request is in flight: their row's actions wait, so nothing is dropped unseen.
  const [shelfPending, setShelfPending] = useState<string[]>([])
  // GET /me's flag is server-wide; the shelf is an account's, so anonymous listeners never see it.
  const shelfOn = albumPicks && !anonymous
  const mixesShown = activeView === 'mixes' || (activeView === 'session' && !activeSession)
  const shelfOpen = shelfOn && mixesTab === 'listen-later' && mixesShown
  useEffect(() => {
    if (!shelfOpen || restoring) return
    const controller = new AbortController()
    setListenLaterError('')
    api.listListenLater(controller.signal)
      .then(({ entries }) => { if (!controller.signal.aborted) setListenLater(entries.map(toListenLaterEntry)) })
      .catch((requestError) => {
        if (controller.signal.aborted) return
        setListenLaterError(errorCopy(requestError))
        if (requestError instanceof ApiError && requestError.status === 401) signOut()
      })
    return () => controller.abort()
  }, [api, shelfOpen, restoring, shelfReads])

  /** Claims an album for one shelf request; false while another is in flight (its row's actions are disabled meanwhile). */
  function beginShelfRequest(albumId: string) {
    if (savingAlbums.current.has(albumId)) return false
    savingAlbums.current.add(albumId)
    setShelfPending((current) => [...current, albumId])
    return true
  }

  function endShelfRequest(albumId: string) {
    savingAlbums.current.delete(albumId)
    setShelfPending((current) => current.filter((id) => id !== albumId))
  }

  function updateShelf(update: (entries: ListenLaterEntry[]) => ListenLaterEntry[]) {
    setListenLater((current) => current && update(current))
  }

  /** Keeps any album panel holding this album in step with the shelf. */
  function markSavedEverywhere(albumId: string, saved: boolean) {
    setAlbumsBySession((current) => Object.fromEntries(Object.entries(current).map(([id, state]) => [id, withSaved(state, albumId, saved)])))
  }

  /** Remove is soft on the server, so Undo is a plain save back. */
  async function removeFromShelf(entry: ListenLaterEntry) {
    if (!beginShelfRequest(entry.id)) return
    const signal = controlLife.current.signal
    updateShelf((entries) => entries.filter((item) => item.id !== entry.id))
    markSavedEverywhere(entry.id, false)
    try {
      await api.unsaveForLater(entry.id, signal)
      if (signal.aborted) return
      announce('Removed from Listen later.', 'success', 4000, { label: 'Undo', onClick: () => { setToast(null); void restoreToShelf(entry) } })
    } catch (requestError) {
      if (signal.aborted) return
      updateShelf((entries) => placeOnShelf(entries, entry))
      markSavedEverywhere(entry.id, true)
      announce('Couldn’t remove this album. Try again.', 'error')
      if (requestError instanceof ApiError && requestError.status === 401) signOut()
    } finally {
      endShelfRequest(entry.id)
    }
  }

  async function restoreToShelf(entry: ListenLaterEntry) {
    if (!beginShelfRequest(entry.id)) return
    const signal = controlLife.current.signal
    // A save back is a new save on the server: it lands at the top, so the row does too.
    updateShelf((entries) => placeOnShelf(entries, { ...entry, savedAt: new Date().toISOString() }))
    markSavedEverywhere(entry.id, true)
    try {
      const { entry: saved } = await api.saveForLater(entry.id, entry.sessionId ?? undefined, signal)
      if (signal.aborted) return
      updateShelf((entries) => placeOnShelf(entries, toListenLaterEntry(saved)))
    } catch (requestError) {
      if (signal.aborted) return
      updateShelf((entries) => entries.filter((item) => item.id !== entry.id))
      markSavedEverywhere(entry.id, false)
      announce('Couldn’t save this album. Try again.', 'error')
      if (requestError instanceof ApiError && requestError.status === 401) signOut()
    } finally {
      endShelfRequest(entry.id)
    }
  }

  async function markShelfListened(entry: ListenLaterEntry) {
    if (entry.listenedAt || !beginShelfRequest(entry.id)) return
    const signal = controlLife.current.signal
    // Only rows still on the shelf move: a removal that landed meanwhile stays removed.
    const replace = (next: ListenLaterEntry) => updateShelf((entries) => entries.some((item) => item.id === next.id) ? placeOnShelf(entries, next) : entries)
    replace({ ...entry, listenedAt: new Date().toISOString() })
    try {
      const { entry: saved } = await api.markListened(entry.id, signal)
      if (signal.aborted) return
      replace(toListenLaterEntry(saved))
    } catch (requestError) {
      if (signal.aborted) return
      replace(entry)
      announce('Couldn’t mark this album. Try again.', 'error')
      if (requestError instanceof ApiError && requestError.status === 401) signOut()
    } finally {
      endShelfRequest(entry.id)
    }
  }

  function findAnAlbum() {
    setModeSeed({ kind: 'album', id: Date.now() })
    setActiveView('home')
  }

  /**
   * Play now queues the whole album in Apple Music. No session event and no
   * playback evidence for albums in this phase: the evidence model is keyed
   * by mix positions, which an album does not have.
   */
  async function playAlbum(album: Pick<AlbumPick, 'appleId'>) {
    if (playbackBusy) return
    const failed = () => announce('Apple Music couldn’t play this album. Try again in a moment.', 'error')
    if (!album.appleId) return failed()
    setPlaybackBusy(true)
    try {
      if (musicConnection !== 'connected' && !(await connectAppleMusic())) return failed()
      // Ends any mix the controller is metering, so the album is never counted against it.
      await playback.stop()
      await musicKit.playAlbum(album.appleId)
    } catch {
      announce('Apple Music couldn’t play this album. Try again in a moment.', 'error')
    } finally {
      setPlaybackBusy(false)
    }
  }

  function takeSuggestion(text: string) {
    if (text === 'Add my music') openAddMusic()
    else void sendMessage(text)
  }

  /**
   * The door's Remake with my music: the listener's own line through the
   * usual send path, flagged as a remake. The post-turn read then learns
   * whether the mix is personal now, and the door and banner go if it is.
   */
  function remake() {
    if (!activeSession || activeSession.kind === 'album' || turnOut(activeSession.id) || remakingSessionId === activeSession.id) return
    // The phone shell's panel covers the conversation; the remake shows there,
    // and focus leaves the closing panel for the listener's new line.
    const fromPanel = narrow && queueOpen
    setQueueOpen(false)
    void sendMessage(REMAKE_TEXT, undefined, false, {
      remake: true,
      onSent: fromPanel ? (messageId) => requestAnimationFrame(() => focusTurn(messageId)) : undefined,
    })
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


  // One panel for both placements: the shell's third column, or folded into the conversation.
  const albumPanel = (inline: boolean) => activeAlbums ? (
    <AlbumPanel
      state={activeAlbums}
      spotifyOnly={spotifyLed}
      busy={playbackBusy || albumBusy === activeSession?.id}
      onPlay={(album) => void playAlbum(album)}
      onToggleSaved={toggleAlbumSaved}
      onPick={(albumId) => void choosePick({ albumId })}
      inline={inline}
    />
  ) : null

  // A catalog mix's door: the line under the last DJ turn and, in the phone
  // shell, the panel's banner. Same listener facts as the add-music router.
  const addMusicListener = addMusicFacts(playsOn, effectiveOnboarding)
  const musicDoor: MusicDoorInput | undefined = activeSession && !activeIsAlbum ? {
    onboarding: effectiveOnboarding,
    syncRun,
    syncLanding,
    platform: addMusicListener.platform,
    onAddMusic: openAddMusicFor,
    onRemake: remake,
    busy: turnOut(activeSession.id) || loadingSessionId === activeSession.id || seedBusy === activeSession.id,
    pending: remakingSessionId === activeSession.id,
  } : undefined
  // The history pill shows only where the router has a page for it (Spotify, on the web).
  const historyPill = activeSession && addMusicBySession[activeSession.id] === 'history' && addMusicRoute('history', addMusicListener).kind !== 'none'
    ? () => openAddMusicFor('history')
    : undefined

  return (
    <AiConsentGate.Provider value={consentReady}>
    <div className={`app-shell ${activeView !== 'session' || !activeSession ? 'app-shell--home' : ''}`} style={shellStyle} inert={addingMusic !== null || keepSheet || signInPage !== null || nameGate !== 'off' || shareNameFor !== null}>
      <Sidebar activeView={activeView}
        onOpenHome={() => setActiveView('home')}
        onOpenMusic={openMusic}
        onOpenMixes={() => { setMixesTab('active'); setOpenSharedToken(null); setActiveView('mixes') }}
        onOpenSettings={() => setActiveView('settings')}
      />

      {activeView === 'settings' ? <AppSettings api={api} playback={playback} userName={user.name} signInMethod={lastSignInProvider} saveName={saveName} onAccount={() => setDialog('account')} onMemories={() => setActiveView('memories')} onSignOut={signOut} onAccountDeleted={accountDeleted} anonymous={anonymous} onSignIn={() => openSignIn('keep')}/> : activeView === 'home' ? <HomeDashboard
        sessions={sessions} loading={loadingCollection} error={collectionError} busy={creatingTape}
        onRetry={() => void retryCollection()} onOpenSession={openSession} onOpenMixes={() => { setMixesTab('active'); setActiveView('mixes') }}
        albumPicks={albumPicks} anonymous={anonymous} onSubmit={(prompt, { kind, shape }) => createTape(prompt, false, true, shape, undefined, kind)} transcribe={transcribe} draftSeed={draftSeed} modeSeed={modeSeed}
        suggestions={<RoutineSuggestions key={user.id} api={api} busy={creatingTape} onCreate={prompt => createTape(prompt, false, true).catch((cause) => { if (!(cause instanceof PromptKept)) throw cause })}/>}
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
          onAddMusic={openAddMusic}
        />
      ) : activeView === 'mixes' && openSharedToken ? (
        <section className="home-panel shared-in-app" aria-label="Shared mix">
          <SharedMixPage
            key={openSharedToken}
            token={openSharedToken}
            api={api}
            session={sharedSession}
            player={sharedPlayer}
            onOwner={(_userId, sessionId) => openSession(sessionId)}
            embedded={{ onBack: () => setOpenSharedToken(null), onRemove: () => removeSharedMix(openSharedToken) }}
          />
        </section>
      ) : activeView !== 'session' || !activeSession ? (
        <Home
          loading={loadingCollection}
          error={collectionError}
          onRetry={() => void retryCollection()}
          player={<PlaybackPanel controller={playback} />}
          sessions={sessions.filter((session) => session.status === (mixesTab === 'archived' ? 'archived' : 'active'))}
          sharedRows={sharedRows}
          onOpenShared={setOpenSharedToken}
          onRemoveShared={removeSharedMix}
          tab={mixesTab}
          onTab={setMixesTab}
          albumPicks={shelfOn}
          shelf={shelfOn ? {
            entries: listenLater,
            error: listenLaterError,
            spotifyOnly: spotifyLed,
            busy: playbackBusy,
            pendingIds: shelfPending,
            onRetry: () => setShelfReads((count) => count + 1),
            onFindAlbum: findAnAlbum,
            onOpen: openSession,
            onPlay: (entry) => void playAlbum(entry),
            onMarkListened: (entry) => void markShelfListened(entry),
            onRemove: (entry) => void removeFromShelf(entry),
          } : undefined}
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
            transcribe={transcribe}
            selectionBusy={seedBusy === activeSession.id}
            attachment={<PlaylistAttachment api={api} onReload={!playlistSeeds[activeSession.id] ? () => reloadInspiration(activeSession.id) : undefined} value={attachmentValue(playlistSeeds[activeSession.id])} disabled={!playlistSeeds[activeSession.id] || turnOut(activeSession.id)} onSelect={(value) => selectInspiration(activeSession.id, value)} onSessionExpired={signOut} />}
            onColor={color => updateMix(activeSession.id, { caseColor: color })}
            onRename={(title) => updateMix(activeSession.id, { title })}
            onArchive={() => updateMix(activeSession.id, { status: 'archived' }).catch((e) => { announce('Couldn’t archive this mix. Try again.', 'error'); throw e })}
            onShare={!activeIsAlbum && activeQueue.length > 0 ? () => void shareMix(activeSession.id) : undefined}
            onStopSharing={!activeIsAlbum && sharedSessions[activeSession.id] ? () => stopSharing(activeSession.id) : undefined}
            session={activeSession}
            messages={activeMessages}
            loading={loadingSessionId === activeSession.id}
            thinking={turnOut(activeSession.id)}
            working={turnWork[activeSession.id]}
            player={<PlaybackPanel controller={playback} />}
            energySummary={activeIsAlbum ? undefined : <MixEnergySummary onShape={shape => setMixShapes(current => ({ ...current, [`${activeSession.id}:${activeSession.queueVersion}`]: shape }))} key={`${activeSession.id}:${activeSession.queueVersion}`} api={api} sessionId={activeSession.id} version={activeSession.queueVersion} />}
            onSend={(text, shape) => sendMessage(text, shape, true)}
            onOpenHistory={activeIsAlbum ? undefined : (version) => { setHistoryVersion(version); setHistorySessionId(activeSession.id) }}
            onOpenQueue={activeIsAlbum ? undefined : () => setQueueOpen(true)}
            kind={activeSession.kind}
            passed={activeAlbums?.passed}
            onGoBack={(version) => void choosePick({ version })}
            suggestions={suggestionsBySession[activeSession.id]}
            onSuggestion={takeSuggestion}
            musicDoor={musicDoor}
            musicDoorCovered={narrow && queueOpen}
            onAddHistory={historyPill}
            inlinePanel={activeIsAlbum && narrow && activeAlbums ? albumPanel(true) : undefined}
            inlinePanelVersion={activeAlbums?.version}
            onBack={() => { setMixesTab('active'); setActiveView('mixes') }}
          />}
          {activeIsAlbum ? (narrow ? null : activeAlbums ? albumPanel(false) : <aside className="album-panel" aria-label="The album" />) : <QueuePanel
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
            spotifyOnly={spotifyLed}
            askService={askService}
            onChooseService={writePlaysOn}
            narrow={narrow}
            musicDoor={musicDoor}
          />}
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
      {dialog === 'account' && !anonymous ? (
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
      {toast ? <Toast message={toast.message} tone={toast.tone} action={toast.action} /> : null}
    </div>
    {addingMusic ? (
      <FirstRun
        mode="add"
        startAt={addingMusic.from === 'mix' ? addingMusic.startAt : undefined}
        services={addMusicServices}
        onChooseService={recordServiceChoice}
        onDone={addingMusic.from === 'mix' ? () => finishAddingMusicForMix(addingMusic) : finishAddingMusic}
      />
    ) : null}
    {keepSheet ? <KeepSheet onKeep={keepFromSheet} onNotNow={() => dismissSheet()} /> : null}
    {signInPage ? (
      <div className="first-run fr-root fr-root--over" data-testid="sign-in-over-shell">
        <div className="fr-sign-in">
          <BackButton onBack={() => window.history.back()} className="fr-back--over" />
          <SignInPage
            auth={signInAuth}
            preferences={signInPreferences}
            lastUsed={lastSignInProvider}
            error={signInPageError}
            onStart={() => setSignInPageError('')}
            variant={signInPage}
            onSignedIn={() => { void refetchSession?.() }}
            onSkip={signInFromMix && signInPage === 'keep' ? () => window.history.back() : undefined}
          />
        </div>
      </div>
    ) : null}
    {nameGate === 'hold' ? (
      <div className="first-run fr-root fr-root--over"><NamePageHold /></div>
    ) : nameGate === 'ask' && saveName ? (
      <div className="first-run fr-root fr-root--over" data-testid="name-page">
        <div className="fr-stage fr-stage--fade"><NamePage saveName={saveName} onSaved={saveFromNamePage} onSkip={skipNamePage} /></div>
      </div>
    ) : null}
    {shareNameFor && saveName ? (
      <div className="first-run fr-root fr-root--over" data-testid="share-name-page">
        <BackButton onBack={() => setShareNameFor(null)} className="fr-back--over" />
        <div className="fr-stage fr-stage--fade"><NamePage saveName={saveName} onSaved={shareAfterName} line={SHARE_NAME_LINE} /></div>
      </div>
    ) : null}
    {consentOpen ? <AiConsentDialog onAgree={grantConsent} onNotNow={() => setConsentOpen(false)} /> : null}
    </AiConsentGate.Provider>
  )
}
