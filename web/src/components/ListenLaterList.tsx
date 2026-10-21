import { useEffect, useRef, useState } from 'react'
import type { ListenLaterEntry } from '../domain'
import { albumLengthLabel, albumTypeLabel, spotifySearchUrl } from '../lib/album-format'
import { shortDate } from '../lib/onboarding'
import { AlbumCover } from './AlbumPanel'
import { PlayIcon } from './Icons'
import { SpotifyMark } from './ProviderMarks'

/**
 * Puts an entry where the server would list it: unlistened newest saved
 * first, then listened newest listened first. Replaces any row with its id.
 */
export function placeOnShelf(entries: ListenLaterEntry[], entry: ListenLaterEntry): ListenLaterEntry[] {
  const key = (item: ListenLaterEntry) => item.listenedAt ?? item.savedAt
  return [...entries.filter((item) => item.id !== entry.id), entry].sort((a, b) => {
    if ((a.listenedAt === null) !== (b.listenedAt === null)) return a.listenedAt === null ? -1 : 1
    return key(b).localeCompare(key(a))
  })
}

export type ListenLaterActions = {
  onOpen: (sessionId: string) => void
  onPlay: (entry: ListenLaterEntry) => void
  onMarkListened: (entry: ListenLaterEntry) => void
  onRemove: (entry: ListenLaterEntry) => void
}

type Props = ListenLaterActions & {
  /** In the server's order: unlistened newest saved first, then listened newest first. */
  entries: ListenLaterEntry[]
  /** Spotify-only listeners get the Spotify search in the play slot. */
  spotifyOnly: boolean
  /** Playback is in flight. */
  busy?: boolean
  /** Albums with a shelf request in flight: their Mark listened and Remove wait for it. */
  pendingIds?: string[]
}

/**
 * Board W6: "{artist} · {Type} · {year} · {length}"; a listened row trades year and length for its date.
 * The status word never truncates: the artist gives way first, as the New to you mark does.
 */
function Subline({ entry }: { entry: ListenLaterEntry }) {
  if (entry.listenedAt) {
    return <small className="shelf-sub--marked">
      {/* The space between the spans is for the accessible name; flex drops it, so CSS spaces the mark. */}
      <span className="shelf-who">{entry.artist} · {albumTypeLabel(entry.type)}</span>{' '}
      <span className="shelf-mark">· <b>Listened {shortDate(entry.listenedAt)}</b></span>
    </small>
  }
  const parts = [entry.artist, albumTypeLabel(entry.type), entry.releaseYear?.toString() ?? null, albumLengthLabel(entry.durationMs)]
  return <small>{parts.filter((part): part is string => Boolean(part)).join(' · ')}</small>
}

function ShelfRow({ entry, spotifyOnly, busy, pending, onOpen, onPlay, onMarkListened, onRemove }: ListenLaterActions & { entry: ListenLaterEntry; spotifyOnly: boolean; busy: boolean; pending: boolean }) {
  const [menu, setMenu] = useState(false)
  const menuElement = useRef<HTMLDivElement>(null)
  const menuButton = useRef<HTMLButtonElement>(null)
  // The same dismissal as the mix row's menu: outside press or Escape, focus back on the dots.
  useEffect(() => {
    if (!menu) return
    const outside = (e: PointerEvent) => {
      if (!menuElement.current?.contains(e.target as Node) && !menuButton.current?.contains(e.target as Node)) setMenu(false)
    }
    const escape = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        setMenu(false)
        menuButton.current?.focus()
      }
    }
    document.addEventListener('pointerdown', outside)
    document.addEventListener('keydown', escape)
    return () => {
      document.removeEventListener('pointerdown', outside)
      document.removeEventListener('keydown', escape)
    }
  }, [menu])
  const choose = (action: () => void) => () => { setMenu(false); action() }
  const { sessionId, title } = entry
  // The space keeps the title and subline apart in the button's accessible name; between blocks it draws nothing.
  const copy = <><strong>{title}</strong>{' '}<Subline entry={entry} /></>

  return (
    <li className={`shelf-row${entry.listenedAt ? ' shelf-row--listened' : ''}${menu ? ' has-menu' : ''}`}>
      <AlbumCover album={entry} size={56} className="shelf-cover" />
      {sessionId
        // Named by its own content, so the subline (and a listened date) is read with the title.
        ? <button type="button" className="shelf-open" onClick={() => onOpen(sessionId)}>{copy}</button>
        : <span className="shelf-open">{copy}</span>}
      {spotifyOnly ? (
        <a className="shelf-play" href={spotifySearchUrl(entry)} target="_blank" rel="noopener noreferrer" aria-label={`Open ${title} in Spotify`}><SpotifyMark /></a>
      ) : (
        <button type="button" className="shelf-play" aria-label={`Play ${title}`} disabled={busy} onClick={() => onPlay(entry)}><PlayIcon /></button>
      )}
      <button ref={menuButton} type="button" className="wc-text wc-more" aria-label={`Album actions for ${title}`} aria-expanded={menu} onClick={() => setMenu((value) => !value)}>•••</button>
      {menu && (
        <div ref={menuElement} className="wc-popover wc-session-menu" role="group" aria-label="Album actions">
          {sessionId && <button type="button" className="wc-text" onClick={choose(() => onOpen(sessionId))}>Open</button>}
          {!entry.listenedAt && <button type="button" className="wc-text" disabled={pending} onClick={choose(() => onMarkListened(entry))}>Mark listened</button>}
          <button type="button" className="wc-text" disabled={pending} onClick={choose(() => onRemove(entry))}>Remove</button>
        </div>
      )}
    </li>
  )
}

export function ListenLaterList({ entries, spotifyOnly, busy = false, pendingIds = [], ...actions }: Props) {
  const firstListened = entries.findIndex((entry) => entry.listenedAt !== null)
  return (
    <ul className="shelf-list" aria-label="Listen later">
      {entries.flatMap((entry, index) => {
        const row = <ShelfRow key={entry.id} entry={entry} spotifyOnly={spotifyOnly} busy={busy} pending={pendingIds.includes(entry.id)} {...actions} />
        // A label, not a row: presentation keeps the list's item count to albums.
        return index === firstListened ? [<li key="listened" className="shelf-section" role="presentation">Listened</li>, row] : [row]
      })}
    </ul>
  )
}
