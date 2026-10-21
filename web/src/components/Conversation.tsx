import { useRestorableState } from '../lib/workspace-restore'
import { TapeSettings } from './TapeSettings'
import { PromptComposer, type PromptComposerProps } from './PromptComposer'
import { EnergyControl, type EnergyArc } from './EnergyJourney'
import { useEffect, useRef, useState, type ReactNode } from 'react'
import type { AlbumPick, DjMessage, DjSession, SessionKind } from '../domain'
import { InlineMixName } from './SessionControls'
import { Cassette } from './Cassette'
import { AlbumCover } from './AlbumPanel'
import { MoreIcon, QueueIcon } from './Icons'

type ConversationProps = {
  currentShape?: EnergyArc | null
  transcribe?: PromptComposerProps['transcribe']
  selectionBusy?: boolean
  attachment?: ReactNode
  energySummary?: ReactNode
  player?: ReactNode
  onColor?: (color: string) => Promise<void>
  onRename?: (title: string) => Promise<void>
  onArchive?: () => Promise<void>
  session: DjSession
  messages: DjMessage[]
  loading?: boolean
  thinking: boolean
  onSend: (text: string, shape?: EnergyArc) => void | Promise<void>
  onOpenHistory?: (version?: number) => void
  /** Mix sessions only: opens the queue slide-over below the three-column width. */
  onOpenQueue?: () => void
  /** An album session has no Shape, no queue, no versions to browse; its picks live in the album panel. */
  kind?: SessionKind
  /** Album sessions: picks the listener moved past, shown as muted rows in the transcript. */
  passed?: AlbumPick[]
  onGoBack?: (version: number) => void
  /** Honest-failure refinements from the last turn, drawn as pills under the last DJ reply. */
  suggestions?: string[]
  onSuggestion?: (text: string) => void
  /** The album panel folded into the transcript (narrow widths), under the reply at this version. */
  inlinePanel?: ReactNode
  inlinePanelVersion?: number
}

/**
 * Where each passed album sits: above the user turn that led to the first
 * DJ reply past the album's version. A swap by Pick this has no such reply
 * yet, so it sits at the end of the transcript (-1).
 */
function passedPlacement(messages: DjMessage[], passed: AlbumPick[]): Map<number, AlbumPick[]> {
  const placed = new Map<number, AlbumPick[]>()
  for (const album of passed) {
    const reply = messages.findIndex((message) => message.role === 'dj' && (message.queueVersion ?? 0) > album.version)
    let anchor = -1
    if (reply >= 0) {
      anchor = reply
      for (let index = reply - 1; index >= 0; index -= 1) {
        if (messages[index].role === 'user') { anchor = index; break }
      }
    }
    placed.set(anchor, [...(placed.get(anchor) ?? []), album])
  }
  return placed
}

function PassedRow({ album, onGoBack }: { album: AlbumPick; onGoBack?: (version: number) => void }) {
  return (
    <div className="album-passed">
      <AlbumCover album={album} size={32} className="album-passed-cover" />
      <span className="album-passed-copy"><strong>{album.title}</strong>Passed over</span>
      <button type="button" onClick={() => onGoBack?.(album.version)}>Go back</button>
    </div>
  )
}

const unavailableTranscription = async () => { throw new Error('Transcription unavailable') }

export function Conversation({ currentShape, transcribe = unavailableTranscription, selectionBusy = false, attachment, energySummary, player, onColor, onRename, onArchive, session, messages, loading = false, thinking, onSend, onOpenQueue, onOpenHistory, kind = 'mix', passed = [], onGoBack, suggestions = [], onSuggestion, inlinePanel, inlinePanelVersion }: ConversationProps) {
  const album = kind === 'album'
  const [settings, setSettings] = useState(false)
  const [options, setOptions] = useState(false)
  const menuRef = useRef<HTMLDivElement>(null)
  useEffect(() => { if (!options) return; const close = (event: PointerEvent) => { if (!menuRef.current?.contains(event.target as Node)) setOptions(false) }; const escape = (event: KeyboardEvent) => { if (event.key === 'Escape') setOptions(false) }; document.addEventListener('pointerdown', close); document.addEventListener('keydown', escape); return () => { document.removeEventListener('pointerdown', close); document.removeEventListener('keydown', escape) } }, [options])
  const [draft, setDraft] = useRestorableState(`conversation.${session.id}.draft`, '')
  // A shape picked here waits as a setting for the next message; once a new
  // mix version lands, that version's own shape is the truth again.
  const [pendingShape, setPendingShape] = useRestorableState<{ shape: EnergyArc; version: number } | null>(`conversation.${session.id}.shape`, null)
  const shape = pendingShape?.version === session.queueVersion ? pendingShape.shape : undefined
  const conversationRef = useRef<HTMLDivElement>(null)
  // Oldest first, so rows sharing an anchor read forward in time (the server lists newest first).
  const placement = album ? passedPlacement(messages, [...passed].reverse()) : new Map<number, AlbumPick[]>()
  const lastDjIndex = messages.reduce((last, message, index) => (message.role === 'dj' ? index : last), -1)
  // The folded panel sits under the reply that produced the current pick, else at the end.
  const panelAnchor = inlinePanel
    ? messages.reduce((last, message, index) => (message.role === 'dj' && message.queueVersion === inlinePanelVersion ? index : last), -1)
    : -2

  useEffect(() => {
    if (conversationRef.current) {
      conversationRef.current.scrollTop = conversationRef.current.scrollHeight
    }
  }, [messages, thinking])

  return (
    <main className="conversation-panel">
      <header className="conversation-header">
        <div>
          <p className="quiet-kicker">{album ? 'Current album' : 'Current tape'}</p>
          <h1><InlineMixName title={session.title} onRename={onRename ?? (() => Promise.resolve())} /></h1>
          <p>
            {album ? `Pick ${session.queueVersion}` : `Tape version ${session.queueVersion}`} · {session.ageLabel}
          </p>
        </div>
        <div className="conversation-header-actions wc-anchor" ref={menuRef}>
          {album ? null : (
            <button className="queue-toggle" type="button" onClick={onOpenQueue} aria-label="Open your mix">
              <QueueIcon />
              <span>{session.trackCount}</span>
            </button>
          )}
          <button className="bare-icon-button" type="button" aria-label={album ? 'Album options' : 'Tape options'} aria-expanded={options} onClick={() => setOptions((value) => !value)}>
            <MoreIcon />
          </button>
          {settings && onColor && <TapeSettings session={session} onColor={onColor} onClose={() => { setSettings(false); menuRef.current?.querySelector<HTMLButtonElement>('.bare-icon-button')?.focus() }} />}
          {options && <div className="wc-popover wc-session-menu">{onColor && <button className="wc-text" onClick={() => { setOptions(false); setSettings(true) }}>{album ? 'Album settings' : 'Tape settings'}</button>}{album ? null : <button className="wc-text" onClick={() => { setOptions(false); onOpenHistory?.() }}>Version history</button>}<button className="wc-text" onClick={() => { setOptions(false); void onArchive?.().catch(() => undefined) }}>Archive</button></div>}
        </div>
      </header>

      <div className="conversation-scroll" ref={conversationRef} aria-live="polite">
        {loading ? (
          <div className="conversation-loading" role="status">
            <Cassette loading labelled={false} />
            <span>Opening this tape…</span>
          </div>
        ) : messages.length === 0 ? (
          <div className="blank-conversation">
            <span>Blank tape</span>
            <h2>What should this moment sound like?</h2>
            <p>Describe the room, the mood, the pace, or one song you want the DJ to start from.</p>
          </div>
        ) : (
          messages.map((message, index) => (
            <div className="conversation-turn-wrap" key={message.id}>
              {placement.get(index)?.map((item) => <PassedRow key={`passed-${item.id}`} album={item} onGoBack={onGoBack} />)}
              <p className={`conversation-turn conversation-turn--${message.role}`}>{message.content}</p>
              {index === panelAnchor ? inlinePanel : null}
              {index === lastDjIndex && suggestions.length > 0 ? (
                <div className="home-starters conversation-pills">
                  {suggestions.map((text) => (
                    <button key={text} type="button" disabled={thinking || loading} onClick={() => onSuggestion?.(text)}>{text}</button>
                  ))}
                </div>
              ) : null}
              {!album && message.role === 'dj' && message.queueVersion && index < messages.length - 1 ? (
                <button type="button" className="queue-event" style={{ minHeight: 44, cursor: 'pointer' }} onClick={() => onOpenHistory?.(message.queueVersion!)}>
                  Tape revised · version {message.queueVersion}
                  <span aria-hidden="true" />
                </button>
              ) : null}
            </div>
          ))
        )}

        {loading ? null : placement.get(-1)?.map((item) => <PassedRow key={`passed-${item.id}`} album={item} onGoBack={onGoBack} />)}
        {!loading && panelAnchor === -1 ? inlinePanel : null}
        {album ? null : energySummary}
        {thinking ? (
          <div className="dj-thinking" aria-label={album ? 'Finding your album' : 'The DJ is listening'}>
            <span aria-hidden="true" />
            <span aria-hidden="true" />
            <span aria-hidden="true" />
            <small>{album ? 'Finding your album · checking Apple Music' : 'The DJ is listening…'}</small>
          </div>
        ) : null}
      </div>

      <div className="composer-area">
        {player}
        <PromptComposer draft={draft} setDraft={setDraft}
          onSubmit={text => { const request = shape ? onSend(text, shape) : onSend(text); setDraft(''); return request }} transcribe={transcribe}
          busy={thinking || loading || selectionBusy}
          inputLabel="Message your DJ" sendLabel="Send message"
          inputPlaceholder={album ? 'Another? Older? Something you do not know?' : 'Tell the DJ what to change…'}
          submitError="Couldn’t send your message. Your text is still here—try again."
          tools={album ? <>{attachment}</> : <>{attachment}<EnergyControl compact value={shape ?? currentShape} onSelect={next => setPendingShape({ shape: next, version: session.queueVersion })} disabled={thinking || loading || selectionBusy} /></>}
        />
      </div>
    </main>
  )
}
