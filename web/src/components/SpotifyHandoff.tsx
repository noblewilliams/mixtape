// Play on Spotify (docs/mockups/approved/2026-09-04-web-spotify-import.md,
// amended in docs/decisions.md 2026-11-03 and 2026-11-06): copies
// "Artist - Title" lines and opens TuneMyMusic's free-text-to-Spotify page,
// which builds the playlist, since Spotify's own API is closed to apps our
// size. The first time on a browser, an explainer says what will happen.
// Used by the mix rail and the shared mix page.
import { useRef, useState } from 'react'
import { markSpotifyIntroSeen, spotifyIntroSeen } from '../lib/plays-on'
import { ControlModal } from './ControlModal'

export type SpotifySong = { title: string; artist: string }

const TRANSFER_TOOL_URL = 'https://www.tunemymusic.com/transfer/freetext-to-spotify'
const INTRO_TITLE = 'Make it a Spotify playlist'
const INTRO_GO = 'Copy songs and open TuneMyMusic'
// TuneMyMusic names every pasted list "My Playlist" and writes its own
// description; the name is an editable field on its review step, styled as
// plain text, so we point at it. No link or paste format can preset either.
const NAME_STEP =
  'tap “My Playlist” to give it this mix’s name, then connect Spotify. TuneMyMusic adds its own note to the description; you can edit it in Spotify.'
export const COPY_FAILED = 'Couldn’t copy on this browser.'

function introLine(count: number) {
  return count === 1
    ? `We’ll copy the song and open TuneMyMusic. Paste it in, ${NAME_STEP}`
    : `We’ll copy your ${count} songs and open TuneMyMusic. Paste them in, ${NAME_STEP}`
}

function copiedSongs(count: number) {
  return count === 1 ? 'Copied 1 song · paste it in, then rename “My Playlist”' : `Copied ${count} songs · paste them in, then rename “My Playlist”`
}

export async function copyText(text: string) {
  const clipboard = navigator.clipboard
  if (!clipboard || typeof clipboard.writeText !== 'function') return false
  try {
    await clipboard.writeText(text)
    return true
  } catch {
    return false
  }
}

type SpotifyHandoffOptions = {
  /** The songs at the moment of the tap (a getter, so a live reorder is honoured). */
  songs: () => SpotifySong[]
  /** The handoff happened (the tab opened). */
  onOutput?: () => void
  /** What to tell the listener once the copy settles. */
  onResult: (message: string) => void
}

/** `start` from a tap; render `explainer` (null unless it is showing). */
export function useSpotifyHandoff({ songs, onOutput, onResult }: SpotifyHandoffOptions) {
  const [introOpen, setIntroOpen] = useState(false)
  const latest = useRef({ songs, onOutput, onResult })
  latest.current = { songs, onOutput, onResult }

  async function handOff() {
    const lines = latest.current.songs().map((song) => `${song.artist} - ${song.title}`)
    // Start the clipboard write and open the tool in the same gesture frame:
    // the write needs this document still focused, the new tab needs the
    // user activation that an await would spend.
    const write = copyText(lines.join('\n'))
    window.open(TRANSFER_TOOL_URL, '_blank', 'noopener')
    latest.current.onOutput?.()
    const copied = await write
    latest.current.onResult(copied ? copiedSongs(lines.length) : COPY_FAILED)
  }

  function start() {
    if (!spotifyIntroSeen()) {
      setIntroOpen(true)
      return
    }
    void handOff()
  }

  const explainer = introOpen ? (
    <ControlModal title={INTRO_TITLE} onClose={() => setIntroOpen(false)}>
      <p>{introLine(songs().length)}</p>
      <div className="wc-actions">
        <button type="button" className="wc-text" onClick={() => setIntroOpen(false)}>Cancel</button>
        <button
          type="button"
          className="wc-text"
          data-autofocus
          onClick={() => {
            markSpotifyIntroSeen()
            setIntroOpen(false)
            void handOff()
          }}
        >
          {INTRO_GO}
        </button>
      </div>
    </ControlModal>
  ) : null

  return { start, explainer }
}
