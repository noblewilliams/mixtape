import { useEffect, useMemo, useRef, useState } from 'react'
import { Conversation } from './components/Conversation'
import { Home } from './components/Home'
import { NewTapeDialog, SaveDialog, SyncOverlay, Toast } from './components/Overlays'
import { QueuePanel } from './components/QueuePanel'
import { Sidebar } from './components/Sidebar'
import { demoQueue, demoSessions, makeConversationFor } from './data/demo'
import type { AppView, CollectionView, DjMessage, DjSession, QueueTrack } from './domain'

type DialogState = 'new-tape' | 'save-playlist' | 'sync' | null

const DJ_REPLY_DELAY_MS = 800

export function App() {
  const [sessions, setSessions] = useState<DjSession[]>(demoSessions)
  const [activeSessionId, setActiveSessionId] = useState(demoSessions[0].id)
  const [activeView, setActiveView] = useState<AppView>('session')
  const [collectionView, setCollectionView] = useState<CollectionView>('list')
  const [messagesBySession, setMessagesBySession] = useState<Record<string, DjMessage[]>>(() => ({
    [demoSessions[0].id]: makeConversationFor(demoSessions[0]),
  }))
  const [queuesBySession, setQueuesBySession] = useState<Record<string, QueueTrack[]>>(() => ({
    [demoSessions[0].id]: demoQueue,
  }))
  const [thinkingSessionId, setThinkingSessionId] = useState<string | null>(null)
  const [dialog, setDialog] = useState<DialogState>(null)
  const [queueOpen, setQueueOpen] = useState(false)
  const [playing, setPlaying] = useState(false)
  const [toast, setToast] = useState('')
  const replyTimer = useRef<ReturnType<typeof setTimeout> | null>(null)
  const toastTimer = useRef<ReturnType<typeof setTimeout> | null>(null)

  const activeSession = useMemo(
    () => sessions.find((session) => session.id === activeSessionId) ?? sessions[0],
    [activeSessionId, sessions],
  )
  const activeMessages = messagesBySession[activeSession.id] ?? makeConversationFor(activeSession)
  const activeQueue = queuesBySession[activeSession.id] ?? (activeSession.trackCount > 0 ? demoQueue : [])

  useEffect(
    () => () => {
      if (replyTimer.current) clearTimeout(replyTimer.current)
      if (toastTimer.current) clearTimeout(toastTimer.current)
    },
    [],
  )

  function announce(message: string) {
    setToast(message)
    if (toastTimer.current) clearTimeout(toastTimer.current)
    toastTimer.current = setTimeout(() => setToast(''), 2800)
  }

  function openSession(id: string) {
    setActiveSessionId(id)
    setActiveView('session')
    setQueueOpen(false)
    setPlaying(false)
  }

  function createTape(title: string) {
    const id = `local-${Date.now()}`
    const session: DjSession = {
      id,
      title,
      status: 'active',
      queueVersion: 0,
      updatedAt: new Date().toISOString(),
      ageLabel: 'just now',
      trackCount: 0,
      durationLabel: '0 min',
      caseColor: '#596454',
      stockColor: '#f2ede2',
    }
    setSessions((current) => [session, ...current])
    setMessagesBySession((current) => ({ ...current, [id]: [] }))
    setQueuesBySession((current) => ({ ...current, [id]: [] }))
    setActiveSessionId(id)
    setActiveView('session')
    setDialog(null)
    announce('Blank tape ready. Tell the DJ what belongs on it.')
  }

  function sendMessage(text: string) {
    const sessionId = activeSession.id
    const userMessage: DjMessage = {
      id: `${sessionId}-user-${Date.now()}`,
      role: 'user',
      content: text,
      createdAt: new Date().toISOString(),
    }

    setMessagesBySession((current) => ({
      ...current,
      [sessionId]: [...(current[sessionId] ?? makeConversationFor(activeSession)), userMessage],
    }))
    setThinkingSessionId(sessionId)

    if (replyTimer.current) clearTimeout(replyTimer.current)
    replyTimer.current = setTimeout(() => {
      const reply: DjMessage = {
        id: `${sessionId}-dj-${Date.now()}`,
        role: 'dj',
        content:
          'I hear the change. I would keep the opening intact, then reshape the middle around that feeling before the tape settles again.',
        queueVersion: activeSession.queueVersion,
        createdAt: new Date().toISOString(),
      }
      setMessagesBySession((current) => ({
        ...current,
        [sessionId]: [...(current[sessionId] ?? []), reply],
      }))
      setThinkingSessionId(null)
    }, DJ_REPLY_DELAY_MS)
  }

  function togglePlayback() {
    const nextPlaying = !playing
    setPlaying(nextPlaying)
    announce(nextPlaying ? 'Tape playing locally for this prototype' : 'Tape paused')
  }

  function savePlaylist(name: string) {
    setDialog(null)
    announce('Playlist ready for Apple Music')
    void name
  }

  return (
    <div className={`app-shell ${activeView === 'home' ? 'app-shell--home' : ''}`}>
      <Sidebar
        sessions={sessions}
        activeSessionId={activeSession.id}
        activeView={activeView}
        onOpenSession={openSession}
        onOpenHome={() => setActiveView('home')}
        onNewTape={() => setDialog('new-tape')}
        onSync={() => setDialog('sync')}
      />

      {activeView === 'home' ? (
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
            thinking={thinkingSessionId === activeSession.id}
            onSend={sendMessage}
            onOpenQueue={() => setQueueOpen(true)}
          />
          <QueuePanel
            session={activeSession}
            tracks={activeQueue}
            playing={playing}
            open={queueOpen}
            onTogglePlay={togglePlayback}
            onSave={() => setDialog('save-playlist')}
            onClose={() => setQueueOpen(false)}
          />
        </>
      )}

      {dialog === 'new-tape' ? <NewTapeDialog onClose={() => setDialog(null)} onCreate={createTape} /> : null}
      {dialog === 'save-playlist' ? (
        <SaveDialog defaultName={activeSession.title} onClose={() => setDialog(null)} onSave={savePlaylist} />
      ) : null}
      {dialog === 'sync' ? <SyncOverlay onClose={() => setDialog(null)} /> : null}
      {toast ? <Toast message={toast} /> : null}
    </div>
  )
}
