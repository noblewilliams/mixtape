import { useEffect, useRef, useState, type ReactNode } from 'react'
import { PromptComposer, PromptKept } from './PromptComposer'
import type { Transcribe } from './useVoicePrompt'
import { CloseIcon, QuoteIcon } from './Icons'
import { useMixDraft } from '../lib/mix-draft'
import { useSharedRestorableState } from '../lib/workspace-restore'
import { DjWorkingLine } from './DjWorkingLine'
import type { TurnWork } from './djWorkingLines'
import type { EnergyArc } from './EnergyJourney'
import { composeQuotedMessage, quoteLabel, type QuotedSong } from '../lib/mix-quote'

/**
 * The quoted songs, on one row that scrolls sideways by hand and follows each
 * new quote to the end of the row.
 */
export function QuoteChips({ quotes, onRemove }: { quotes: QuotedSong[]; onRemove: (song: QuotedSong) => void }) {
  const row = useRef<HTMLUListElement>(null)
  const count = useRef(quotes.length)
  useEffect(() => {
    const grew = quotes.length > count.current
    count.current = quotes.length
    const node = row.current
    if (!grew || !node) return
    // A frame later, once the toast and the field have settled; a re-render mid-way cuts a smooth scroll short.
    const frame = requestAnimationFrame(() => {
      const reduce = window.matchMedia?.('(prefers-reduced-motion: reduce)').matches
      if (typeof node.scrollTo === 'function') node.scrollTo({ left: node.scrollWidth, behavior: reduce ? 'auto' : 'smooth' })
      else node.scrollLeft = node.scrollWidth
    })
    return () => cancelAnimationFrame(frame)
  }, [quotes.length])
  if (quotes.length === 0) return null
  return (
    <ul className="quote-chips" ref={row} aria-label="Quoted songs">
      {quotes.map((song) => (
        <li className="quote-chip" key={song.trackId ?? quoteLabel(song)}>
          <QuoteIcon filled width={12} height={12} />
          <span>{quoteLabel(song)}</span>
          <button type="button" aria-label={`Remove quote: ${quoteLabel(song)}`} onClick={() => onRemove(song)}>
            <CloseIcon width={11} height={11} />
          </button>
        </li>
      ))}
    </ul>
  )
}

/** A sent turn's quotes, drawn as quotes above the listener's words. */
export function QuotedSongLines({ quotes }: { quotes: QuotedSong[] }) {
  return (
    <span className="turn-quotes">
      {quotes.map((song, index) => (
        <span className="turn-quote" key={`${index}-${quoteLabel(song)}`}>
          <QuoteIcon width={11} height={11} />
          <span>{quoteLabel(song)}</span>
        </span>
      ))}
    </span>
  )
}

export type MixComposerProps = {
  sessionId: string
  /** Sends the whole message, quote lines first; a PromptKept rejection puts it back. */
  onSend: (message: string) => void | Promise<void>
  /** Stops the turn; the text it answers (the sent message) comes back to the draft. */
  onStop?: () => string | void
  busy: boolean
  transcribe: Transcribe
  tools?: ReactNode
  inputPlaceholder?: string
  /** Focus the field (a quote was just added from the tape). */
  focusKey?: number
}

/** A mix's composer, wherever it is drawn: one shared draft, quotes included. */
export function MixComposer({ sessionId, onSend, onStop, busy, transcribe, tools, inputPlaceholder, focusKey }: MixComposerProps) {
  const draft = useMixDraft(sessionId)
  const box = useRef<HTMLDivElement>(null)
  useEffect(() => {
    if (focusKey) box.current?.querySelector<HTMLTextAreaElement>('textarea')?.focus()
  }, [focusKey])
  return (
    <div className="mix-composer" ref={box}>
      <PromptComposer
        draft={draft.text}
        setDraft={draft.setText}
        accessory={draft.quotes.length ? <QuoteChips quotes={draft.quotes} onRemove={draft.unquote} /> : undefined}
        sendsEmpty={draft.quotes.length > 0}
        onSubmit={async (text) => {
          const message = composeQuotedMessage(draft.quotes, text)
          const request = onSend(message)
          draft.clear()
          // A kept prompt (the consent dialog answered, or a stop) comes back to an empty
          // field, quotes and all; a draft started meanwhile is kept.
          try { await request } catch (cause) {
            if (cause instanceof PromptKept) draft.restore(message)
            throw cause
          }
        }}
        transcribe={transcribe}
        onStop={onStop && (() => {
          const text = onStop()
          if (text) draft.restore(text)
        })}
        busy={busy}
        inputLabel="Message your DJ"
        sendLabel="Send message"
        inputPlaceholder={inputPlaceholder}
        submitError="Couldn’t send your message. Your text is still here—try again."
        tools={tools}
      />
    </div>
  )
}

export type TapeComposerProps = {
  sessionId: string
  /** The shape the mix's version already has; a pick waiting in the conversation wins. */
  currentShape?: EnergyArc | null
  /** The newest DJ turn, so a reply to a message sent from the tape can be read here. */
  lastReply?: { id: string; content: string }
  thinking: boolean
  working?: TurnWork
  onSend: (message: string, shape?: EnergyArc) => void | Promise<void>
  onStop?: () => string | undefined
  busy: boolean
  transcribe: Transcribe
}

/**
 * The composer at the foot of the tape (decision 2026-11-22): talk to the DJ
 * without leaving the songs. While a turn sent from here is out it shows what
 * the DJ is doing; once it lands, the DJ's reply, until the next message.
 */
export function TapeComposer({ sessionId, currentShape, lastReply, thinking, working, onSend, onStop, busy, transcribe }: TapeComposerProps) {
  // The conversation's pending shape pick rides from here too.
  const [pendingShape] = useSharedRestorableState<EnergyArc | null>(`conversation.${sessionId}.shapePick`, null)
  const shape = pendingShape ?? currentShape ?? undefined
  // The DJ turn that was newest when a message went out from the tape; a newer one is its reply.
  const [sentAfter, setSentAfter] = useState<string | null | undefined>(undefined)
  const reply = sentAfter !== undefined && !thinking && lastReply && lastReply.id !== sentAfter ? lastReply.content : null
  return (
    <>
      {thinking && sentAfter !== undefined ? (
        <p className="tape-working" aria-hidden="true"><DjWorkingLine work={working} /></p>
      ) : reply ? (
        <p className="tape-reply" role="status">{reply}</p>
      ) : null}
      <MixComposer
        sessionId={sessionId}
        onSend={(message) => {
          setSentAfter(lastReply?.id ?? null)
          return shape ? onSend(message, shape) : onSend(message)
        }}
        onStop={onStop && (() => { setSentAfter(undefined); return onStop() })}
        busy={busy}
        transcribe={transcribe}
        inputPlaceholder="Tell the DJ what to change…"
      />
    </>
  )
}
