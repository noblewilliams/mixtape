import { Fragment, useState } from 'react'
import type { AlbumPick, AlbumPickState } from '../domain'
import { albumArtworkSource, albumByline, albumMetaParts, spotifySearchUrl } from '../lib/album-format'
import { BookmarkIcon, PlayIcon } from './Icons'

type AlbumPanelProps = {
  state: AlbumPickState
  /** Spotify-only listeners get the Spotify search link in place of Play now. */
  spotifyOnly: boolean
  /** Playback or a pick change is in flight. */
  busy?: boolean
  onPlay: (album: AlbumPick) => void
  onToggleSaved: (album: AlbumPick) => void
  onPick: (albumId: string) => void
  /** Folded into the conversation below the shell's three-column width (board W5). */
  inline?: boolean
  /** The runners-up start open (the preview harness's W4). */
  defaultExpanded?: boolean
}

/** A cover, or a quiet square in the artwork's own tint when the catalogue has none. */
export function AlbumCover({ album, size, className }: { album: Pick<AlbumPick, 'artworkUrl' | 'artworkBgColor'>; size: number; className: string }) {
  const source = albumArtworkSource(album.artworkUrl, size)
  if (source) return <img className={className} src={source} alt="" aria-hidden="true" width={size} height={size} />
  return <span className={`${className} album-cover--fallback`} aria-hidden="true" style={album.artworkBgColor ? { background: `#${album.artworkBgColor.replace('#', '')}` } : undefined} />
}

/** The words-only mark; the dot travels with it so the mark never truncates. */
function NewToYouMark() {
  return <span className="track-mark album-mark">&nbsp;· <b>New to you</b></span>
}

export function AlbumPanel({ state, spotifyOnly, busy = false, onPlay, onToggleSaved, onPick, inline = false, defaultExpanded = false }: AlbumPanelProps) {
  const [showRunners, setShowRunners] = useState(defaultExpanded)
  const { pick, runnersUp } = state

  return (
    <aside className={`album-panel${inline ? ' album-panel--inline' : ''}`} aria-label="The album">
      <header className="album-header">
        <p>The album</p>
        {pick ? <span>pick {state.version}</span> : null}
      </header>

      {!pick ? (
        <p className="album-empty">No album yet</p>
      ) : (
        <>
          <div className="album-card">
            <AlbumCover album={pick} size={96} className="album-cover" />
            <div className="album-copy">
              <strong>{pick.title}</strong>
              <span className="album-by">{pick.artist}</span>
              <span className="album-meta">{albumMetaParts(pick).map((part, index) => <Fragment key={index}>{index > 0 ? ' · ' : ''}<span className="album-meta-part">{part}</span></Fragment>)}{pick.newToYou ? <NewToYouMark /> : null}</span>
            </div>
            {pick.reason ? <p className="album-why">{pick.reason}</p> : null}
            <div className="album-actions">
              {spotifyOnly ? (
                <a className="album-open" href={spotifySearchUrl(pick)} target="_blank" rel="noopener noreferrer">Open in Spotify</a>
              ) : (
                <button className="album-play" type="button" disabled={busy} onClick={() => onPlay(pick)}>
                  <PlayIcon />
                  Play now
                </button>
              )}
              <button className="album-save" type="button" aria-pressed={pick.savedForLater} onClick={() => onToggleSaved(pick)}>
                <BookmarkIcon filled={pick.savedForLater} />
                {pick.savedForLater ? 'Saved for later' : 'Listen later'}
              </button>
            </div>
          </div>

          {runnersUp.length > 0 ? (
            <section className="album-runners">
              <div className="album-runners-head">
                <span>Two more it considered</span>
                {/* No height animation: the list appears at once, which also honours reduced motion. */}
                <button type="button" aria-expanded={showRunners} onClick={() => setShowRunners((value) => !value)}>
                  {showRunners ? 'Hide' : 'Show'}
                </button>
              </div>
              {showRunners ? (
                <ul className="album-runner-list">
                  {runnersUp.map((album) => (
                    <li className="album-runner" key={album.id}>
                      <AlbumCover album={album} size={40} className="album-runner-cover" />
                      <span className="album-runner-copy">
                        <strong>{album.title}</strong>
                        <small><span className="album-runner-who">{albumByline(album)}</span>{album.newToYou ? <NewToYouMark /> : null}</small>
                      </span>
                      <button className="album-pick-this" type="button" disabled={busy} onClick={() => onPick(album.id)}>Pick this</button>
                    </li>
                  ))}
                </ul>
              ) : null}
            </section>
          ) : null}
        </>
      )}
    </aside>
  )
}
