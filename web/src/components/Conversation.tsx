import { useRestorableState } from '../lib/workspace-restore'
import { TapeSettings } from './TapeSettings'
import { PromptComposer, type PromptComposerProps } from './PromptComposer'
import { EnergyControl, type EnergyArc } from './EnergyJourney'
import { useEffect, useRef, useState, type ReactNode } from 'react'
import type { DjMessage, DjSession } from '../domain'
import { InlineMixName } from './SessionControls'
import { Cassette } from './Cassette'
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
  onOpenQueue: () => void
}

const unavailableTranscription = async () => { throw new Error('Transcription unavailable') }

export function Conversation({ currentShape, transcribe = unavailableTranscription, selectionBusy = false, attachment, energySummary, player, onColor, onRename, onArchive, session, messages, loading = false, thinking, onSend, onOpenQueue, onOpenHistory }: ConversationProps) {
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

  useEffect(() => {
    if (conversationRef.current) {
      conversationRef.current.scrollTop = conversationRef.current.scrollHeight
    }
  }, [messages, thinking])

  return (
    <main className="conversation-panel">
      <header className="conversation-header">
        <div>
          <p className="quiet-kicker">Current tape</p>
          <h1><InlineMixName title={session.title} onRename={onRename ?? (() => Promise.resolve())} /></h1>
          <p>
            Tape version {session.queueVersion} · {session.ageLabel}
          </p>
        </div>
        <div className="conversation-header-actions wc-anchor" ref={menuRef}>
          <button className="queue-toggle" type="button" onClick={onOpenQueue} aria-label="Open your mix">
            <QueueIcon />
            <span>{session.trackCount}</span>
          </button>
          <button className="bare-icon-button" type="button" aria-label="Tape options" aria-expanded={options} onClick={() => setOptions((value) => !value)}>
            <MoreIcon />
          </button>
          {settings && onColor && <TapeSettings session={session} onColor={onColor} onClose={() => { setSettings(false); menuRef.current?.querySelector<HTMLButtonElement>('[aria-label="Tape options"]')?.focus() }} />}
          {options && <div className="wc-popover wc-session-menu">{onColor && <button className="wc-text" onClick={() => { setOptions(false); setSettings(true) }}>Tape settings</button>}<button className="wc-text" onClick={() => { setOptions(false); onOpenHistory?.() }}>Version history</button><button className="wc-text" onClick={() => { setOptions(false); void onArchive?.().catch(() => undefined) }}>Archive</button></div>}
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
              <p className={`conversation-turn conversation-turn--${message.role}`}>{message.content}</p>
              {message.role === 'dj' && message.queueVersion && index < messages.length - 1 ? (
                <button type="button" className="queue-event" style={{ minHeight: 44, cursor: 'pointer' }} onClick={() => onOpenHistory?.(message.queueVersion!)}>
                  Tape revised · version {message.queueVersion}
                  <span aria-hidden="true" />
                </button>
              ) : null}
            </div>
          ))
        )}

        {energySummary}
        {thinking ? (
          <div className="dj-thinking" aria-label="The DJ is listening">
            <span aria-hidden="true" />
            <span aria-hidden="true" />
            <span aria-hidden="true" />
            <small>The DJ is listening…</small>
          </div>
        ) : null}
      </div>

      <div className="composer-area">
        {player}
        <PromptComposer draft={draft} setDraft={setDraft}
          onSubmit={text => { const request = shape ? onSend(text, shape) : onSend(text); setDraft(''); return request }} transcribe={transcribe}
          busy={thinking || loading || selectionBusy}
          inputLabel="Message your DJ" sendLabel="Send message"
          inputPlaceholder="Tell the DJ what to change…"
          submitError="Couldn’t send your message. Your text is still here—try again."
          tools={<>{attachment}<EnergyControl compact value={shape ?? currentShape} onSelect={next => setPendingShape({ shape: next, version: session.queueVersion })} disabled={thinking || loading || selectionBusy} /></>}
        />
      </div>
    </main>
  )
}
