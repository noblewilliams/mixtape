import { EnergyControl } from './EnergyJourney'
import { useEffect, useRef, useState, type FormEvent, type ReactNode } from 'react'
import type { DjMessage, DjSession } from '../domain'
import { InlineMixName } from './SessionControls'
import { Cassette } from './Cassette'
import { MoreIcon, QueueIcon, SendIcon } from './Icons'

type ConversationProps = {
  selectionBusy?: boolean
  attachment?: ReactNode
  energySummary?: ReactNode
  player?: ReactNode
  onRename?: (title: string) => Promise<void>
  onArchive?: () => Promise<void>
  session: DjSession
  messages: DjMessage[]
  loading?: boolean
  thinking: boolean
  onSend: (text: string) => void
  onOpenHistory?: (version?: number) => void
  onOpenQueue: () => void
}

export function Conversation({ selectionBusy = false, attachment, energySummary, player, onRename, onArchive, session, messages, loading = false, thinking, onSend, onOpenQueue, onOpenHistory }: ConversationProps) {
  const [options, setOptions] = useState(false)
  const menuRef = useRef<HTMLDivElement>(null)
  useEffect(() => { if (!options) return; const close = (event: PointerEvent) => { if (!menuRef.current?.contains(event.target as Node)) setOptions(false) }; const escape = (event: KeyboardEvent) => { if (event.key === 'Escape') setOptions(false) }; document.addEventListener('pointerdown', close); document.addEventListener('keydown', escape); return () => { document.removeEventListener('pointerdown', close); document.removeEventListener('keydown', escape) } }, [options])
  const [draft, setDraft] = useState('')
  const conversationRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (conversationRef.current) {
      conversationRef.current.scrollTop = conversationRef.current.scrollHeight
    }
  }, [messages, thinking])

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const text = draft.trim()
    if (!text || thinking || selectionBusy) return
    onSend(text)
    setDraft('')
  }

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
          {options && <div className="wc-popover wc-session-menu"><button className="wc-text" onClick={() => { setOptions(false); onOpenHistory?.() }}>Version history</button><button className="wc-text" onClick={() => { setOptions(false); void onArchive?.().catch(() => undefined) }}>Archive</button></div>}
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
        <form className="composer" onSubmit={submit}>
          <span className="composer-stripe" aria-hidden="true" />
          {attachment}
          <EnergyControl text={draft} onChange={setDraft} disabled={thinking || loading || selectionBusy} />
          <textarea rows={2}
            aria-label="Message your DJ"
            value={draft}
            onChange={(event) => setDraft(event.target.value)}
            placeholder="Tell the DJ what to change…"
            maxLength={2000}
          />
          <button className="send-button" type="submit" disabled={!draft.trim() || thinking || loading || selectionBusy} aria-label="Send message">
            <span className="send-button-surface" aria-hidden="true">
              <SendIcon />
            </span>
          </button>
        </form>
        <p>Nothing is added to Apple Music until you ask.</p>
      </div>
    </main>
  )
}
