import { useEffect, useRef, useState, type FormEvent } from 'react'
import type { DjMessage, DjSession } from '../domain'
import { Cassette } from './Cassette'
import { MoreIcon, QueueIcon, SendIcon } from './Icons'

type ConversationProps = {
  session: DjSession
  messages: DjMessage[]
  loading?: boolean
  thinking: boolean
  onSend: (text: string) => void
  onOpenQueue: () => void
}

export function Conversation({ session, messages, loading = false, thinking, onSend, onOpenQueue }: ConversationProps) {
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
    if (!text || thinking) return
    onSend(text)
    setDraft('')
  }

  return (
    <main className="conversation-panel">
      <header className="conversation-header">
        <div>
          <p className="quiet-kicker">Current tape</p>
          <h1>{session.title}</h1>
          <p>
            Tape version {session.queueVersion} · {session.ageLabel}
          </p>
        </div>
        <div className="conversation-header-actions">
          <button className="queue-toggle" type="button" onClick={onOpenQueue} aria-label="Open your tape queue">
            <QueueIcon />
            <span>{session.trackCount}</span>
          </button>
          <button className="bare-icon-button" type="button" aria-label="Tape options">
            <MoreIcon />
          </button>
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
                <p className="queue-event">
                  Tape revised · version {message.queueVersion}
                  <span aria-hidden="true" />
                </p>
              ) : null}
            </div>
          ))
        )}

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
        <form className="composer" onSubmit={submit}>
          <span className="composer-stripe" aria-hidden="true" />
          <input
            aria-label="Message your DJ"
            value={draft}
            onChange={(event) => setDraft(event.target.value)}
            placeholder="Tell the DJ what to change…"
            maxLength={2000}
          />
          <button className="send-button" type="submit" disabled={!draft.trim() || thinking || loading} aria-label="Send message">
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
