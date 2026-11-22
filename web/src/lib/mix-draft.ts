import { useCallback } from 'react'
import { useSharedRestorableState } from './workspace-restore'
import { sameSong, splitQuotedMessage, type QuotedSong } from './mix-quote'

/**
 * A mix's one unsent message: the words in the field and the songs quoted
 * above it. The conversation's composer and the tape's bind to the same draft,
 * so a quote picked on the tape is there back in the conversation and nothing
 * typed in one is lost by moving to the other.
 */
export function useMixDraft(sessionId: string) {
  // The text keeps the key the conversation's draft always had, so a restored tab still finds it.
  const [text, setText] = useSharedRestorableState(`conversation.${sessionId}.draft`, '')
  const [quotes, setQuotes] = useSharedRestorableState<QuotedSong[]>(`conversation.${sessionId}.quotes`, [])

  /** Pins a song above the field; a song already quoted stays put. Answers whether it was added. */
  const quote = useCallback((song: QuotedSong) => {
    let added = false
    setQuotes((current) => {
      if (current.some((item) => sameSong(item, song))) return current
      added = true
      return [...current, song]
    })
    return added
  }, [setQuotes])

  const unquote = useCallback((song: QuotedSong) => {
    setQuotes((current) => current.filter((item) => !sameSong(item, song)))
  }, [setQuotes])

  const clear = useCallback(() => {
    setText('')
    setQuotes([])
  }, [setText, setQuotes])

  /** Puts a sent message back (a stopped or kept turn), quotes and all, unless another was started. */
  const restore = useCallback((message: string) => {
    const split = splitQuotedMessage(message)
    let empty = false
    setText((current) => {
      empty = !current.trim()
      return empty ? split.text : current
    })
    if (empty) setQuotes((current) => (current.length ? current : split.quotes))
  }, [setText, setQuotes])

  return { text, setText, quotes, quote, unquote, clear, restore }
}

export type MixDraft = ReturnType<typeof useMixDraft>
