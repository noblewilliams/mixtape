import { useEffect, useMemo, useRef, useState } from 'react'
import { ApiError, type MixtapeApi, type SessionDetailResponse } from './api/client'
import { toDjMessage, toDjSession, toQueueTrack } from './api/mappers'
import type { AuthUser } from './components/AuthGate'
import { Cassette } from './components/Cassette'
import { Conversation } from './components/Conversation'
import { Home } from './components/Home'
import { NewTapeDialog, SaveDialog, SyncOverlay, Toast } from './components/Overlays'
import { QueuePanel } from './components/QueuePanel'
import { Sidebar } from './components/Sidebar'
import type { AppView, CollectionView, DjMessage, DjSession, QueueTrack } from './domain'
import type { MusicKitClient } from './musickit/client'

type DialogState = 'new-tape' | 'save-playlist' | 'sync' | null
type MusicConnectionState = 'disconnected' | 'connecting' | 'connected' | 'error'
type ToastState = { message: string; tone: 'success' | 'error' }

type AppProps = {
  api: MixtapeApi
  musicKit: MusicKitClient
  user: AuthUser
  onSignOut: () => void
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

export function App({ api, musicKit, user, onSignOut }: AppProps) {
  const [sessions, setSessions] = useState<DjSession[]>([])
  const [activeSessionId, setActiveSessionId] = useState<string | null>(null)
  const [activeView, setActiveView] = useState<AppView>('home')
  const [collectionView, setCollectionView] = useState<CollectionView>('list')
  const [messagesBySession, setMessagesBySession] = useState<Record<string, DjMessage[]>>({})
  const [queuesBySession, setQueuesBySession] = useState<Record<string, QueueTrack[]>>({})
  const [loadingCollection, setLoadingCollection] = useState(true)
  const [loadingSessionId, setLoadingSessionId] = useState<string | null>(null)
  const [thinkingSessionId, setThinkingSessionId] = useState<string | null>(null)
  const [creatingTape, setCreatingTape] = useState(false)
  const [dialog, setDialog] = useState<DialogState>(null)
  const [queueOpen, setQueueOpen] = useState(false)
  const [playing, setPlaying] = useState(false)
  const [playbackBusy, setPlaybackBusy] = useState(false)
  const [playlistBusy, setPlaylistBusy] = useState(false)
  const [playlistError, setPlaylistError] = useState('')
  const [musicConnection, setMusicConnection] = useState<MusicConnectionState>('disconnected')
  const [error, setError] = useState('')
  const [toast, setToast] = useState<ToastState | null>(null)
  const toastTimer = useRef<ReturnType<typeof setTimeout> | null>(null)

  const activeSession = useMemo(
    () => sessions.find((session) => session.id === activeSessionId) ?? null,
    [activeSessionId, sessions],
  )
  const activeMessages = activeSession ? messagesBySession[activeSession.id] ?? [] : []
  const activeQueue = activeSession ? queuesBySession[activeSession.id] ?? [] : []

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
        setSessions(active)
        setError('')
        if (active.length > 0) {
          setActiveSessionId(active[0].id)
          setActiveView('session')
          void loadSession(active[0].id, () => cancelled)
        }
      } catch (requestError) {
        if (!cancelled) setError(errorCopy(requestError))
        if (requestError instanceof ApiError && requestError.status === 401 && !cancelled) onSignOut()
      } finally {
        if (!cancelled) setLoadingCollection(false)
      }
    }

    void loadCollection()
    return () => {
      cancelled = true
    }
  }, [api, onSignOut])

  useEffect(
    () => () => {
      if (toastTimer.current) clearTimeout(toastTimer.current)
    },
    [],
  )

  function announce(message: string, tone: ToastState['tone'] = 'success') {
    setToast({ message, tone })
    if (toastTimer.current) clearTimeout(toastTimer.current)
    toastTimer.current = setTimeout(() => setToast(null), 2800)
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
    try {
      const detail = await api.getSession(sessionId)
      if (isCancelled()) return
      const mapped = detailToState(detail)
      setSessions((current) => current.map((session) => (session.id === sessionId ? mapped.session : session)))
      setMessagesBySession((current) => ({ ...current, [sessionId]: mapped.messages }))
      setQueuesBySession((current) => ({ ...current, [sessionId]: mapped.queue }))
      setError('')
    } catch (requestError) {
      if (!isCancelled()) setError(errorCopy(requestError))
      if (requestError instanceof ApiError && requestError.status === 401 && !isCancelled()) onSignOut()
    } finally {
      if (!isCancelled()) setLoadingSessionId(null)
    }
  }

  function openSession(id: string) {
    setActiveSessionId(id)
    setActiveView('session')
    setQueueOpen(false)
    setPlaying(false)
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

  async function createTape(prompt: string) {
    setCreatingTape(true)
    try {
      const response = await api.createSession(prompt)
      const mapped = detailToState(response)
      setSessions((current) => [mapped.session, ...current.filter((session) => session.id !== mapped.session.id)])
      setMessagesBySession((current) => ({ ...current, [mapped.session.id]: mapped.messages }))
      setQueuesBySession((current) => ({ ...current, [mapped.session.id]: mapped.queue }))
      setActiveSessionId(mapped.session.id)
      setActiveView('session')
      setDialog(null)
      setError('')
      announce('Your new tape is ready.')
    } catch (requestError) {
      setError(errorCopy(requestError))
      if (requestError instanceof ApiError && requestError.status === 401) onSignOut()
    } finally {
      setCreatingTape(false)
    }
  }

  async function sendMessage(text: string) {
    if (!activeSession) return
    const sessionId = activeSession.id
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
                  title: response.sessionTitle ?? session.title,
                  queueVersion: response.queueVersion,
                  updatedAt: new Date().toISOString(),
                },
                response.queue,
              )
            : session,
        ),
      )
    } catch (requestError) {
      const message = errorCopy(requestError)
      setMessagesBySession((current) => ({
        ...current,
        [sessionId]: [
          ...(current[sessionId] ?? []),
          { id: `${sessionId}-error-${Date.now()}`, role: 'dj', content: message, createdAt: new Date().toISOString() },
        ],
      }))
      if (requestError instanceof ApiError && requestError.status === 401) onSignOut()
    } finally {
      setThinkingSessionId(null)
    }
  }

  async function togglePlayback() {
    if (!activeSession || playbackBusy) return
    const sessionId = activeSession.id
    const ids = activeAppleIds()
    if (!ids) return

    setPlaybackBusy(true)
    try {
      if (playing) {
        await musicKit.pause()
        setPlaying(false)
      } else {
        await musicKit.play(ids)
        setPlaying(true)
        void api.recordSessionEvent(sessionId, 'played').catch(() => undefined)
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
      await musicKit.createPlaylist(name, ids)
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
    <div className={`app-shell ${activeView === 'home' || !activeSession ? 'app-shell--home' : ''}`}>
      <Sidebar
        sessions={sessions}
        activeSessionId={activeSession?.id ?? null}
        activeView={activeView}
        userName={user.name}
        onOpenSession={openSession}
        onOpenHome={() => setActiveView('home')}
        onNewTape={() => setDialog('new-tape')}
        onSync={() => setDialog('sync')}
        onSignOut={onSignOut}
      />

      {activeView === 'home' || !activeSession ? (
        <Home
          sessions={sessions}
          collectionView={collectionView}
          onChangeCollectionView={setCollectionView}
          onOpenSession={openSession}
          onNewTape={() => setDialog('new-tape')}
        />
      ) : (
        <>
          <Conversation
            session={activeSession}
            messages={activeMessages}
            loading={loadingSessionId === activeSession.id}
            thinking={thinkingSessionId === activeSession.id}
            onSend={sendMessage}
            onOpenQueue={() => setQueueOpen(true)}
          />
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
          />
        </>
      )}

      {error ? <p className="app-error" role="alert">{error}</p> : null}
      {dialog === 'new-tape' ? (
        <NewTapeDialog busy={creatingTape} onClose={() => setDialog(null)} onCreate={(prompt) => void createTape(prompt)} />
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
      {dialog === 'sync' ? <SyncOverlay onClose={() => setDialog(null)} /> : null}
      {toast ? <Toast message={toast.message} tone={toast.tone} /> : null}
    </div>
  )
}
