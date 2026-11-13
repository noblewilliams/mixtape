// The public page for a shared mix link, /m/<token> (spec 2026-11-13
// shared-mixes, "Recipient on the web"; board W1–W7). It renders outside
// AuthGate: no sign-in, no first run. It calls only the public share
// endpoints, never one that needs AI consent.
import { useEffect, useRef, useState } from 'react'
import { SharedMixGoneError, type MixtapeApi } from '../api/client'
import { durationLabel } from '../api/mappers'
import type { SharedMix, SharedMixTrack } from '../domain'
import { albumArtworkSource } from '../lib/album-format'
import { openMixOnNextLoad } from '../lib/workspace-restore'
import { Cassette } from './Cassette'
import { PlayIcon } from './Icons'
import './shared-mix-page.css'

/** The browser's session as far as this page needs it: a user id only when requests carry a session. */
export type SharedMixSession = { isPending: boolean; userId: string | null }

type SharedMixPageProps = {
  token: string
  api: Pick<MixtapeApi, 'getSharedMix' | 'saveSharedMix'>
  session: SharedMixSession
  /** Play (task W2 fills this with the "Where do you listen?" flow). */
  onPlay?: (mix: SharedMix) => void
  /** The sharer opened their own link: open their mix in the app. */
  onOwner?: (userId: string, sessionId: string) => void
  /** The app, which opens into first run for a browser with no session. */
  appUrl?: string
  /** The existing install/download destination. */
  downloadUrl?: string
}

type PageState =
  | { kind: 'loading' }
  | { kind: 'loaded'; mix: SharedMix }
  | { kind: 'gone' }
  | { kind: 'failed' }

const goToOwnMix = (appUrl: string) => (userId: string, sessionId: string) => {
  openMixOnNextLoad(userId, sessionId)
  window.location.replace(appUrl)
}

function songDuration(milliseconds?: number) {
  if (milliseconds === undefined) return ''
  const minutes = Math.floor(milliseconds / 60_000)
  const seconds = Math.floor((milliseconds % 60_000) / 1000)
  return `${minutes}:${seconds.toString().padStart(2, '0')}`
}

function metaLine(tracks: SharedMixTrack[]) {
  const songs = `${tracks.length} ${tracks.length === 1 ? 'song' : 'songs'}`
  const known = tracks.reduce((total, track) => total + (track.durationMs ?? 0), 0)
  return known > 0 ? `${songs} · ${durationLabel(known)}` : songs
}

export function SharedMixPage({ token, api, session, onPlay = () => {}, onOwner, appUrl = import.meta.env.BASE_URL, downloadUrl = '/' }: SharedMixPageProps) {
  const [state, setState] = useState<PageState>({ kind: 'loading' })
  const [attempt, setAttempt] = useState(0)
  // One read per token, session and attempt, even when React runs effects twice:
  // the public read is rate-limited per IP.
  const reading = useRef<{ key: string; result: Promise<SharedMix> } | null>(null)
  const saved = useRef<string | null>(null)
  const redirected = useRef(false)
  const { isPending, userId } = session

  useEffect(() => {
    // Wait for the session check, so a session (and so isOwner) rides along.
    if (isPending) return
    const key = `${token}|${userId ?? ''}|${attempt}`
    if (reading.current?.key !== key) reading.current = { key, result: api.getSharedMix(token) }
    const { result } = reading.current
    let live = true
    result.then(
      (mix) => {
        if (!live) return
        if (mix.isOwner && mix.sessionId && userId) {
          // Stays on the loading state while the app opens their mix.
          if (!redirected.current) {
            redirected.current = true
            ;(onOwner ?? goToOwnMix(appUrl))(userId, mix.sessionId)
          }
          return
        }
        setState({ kind: 'loaded', mix })
        if (userId && saved.current !== token) {
          saved.current = token
          // Saving is a convenience for the listener's Mixes; the page works without it.
          api.saveSharedMix(token).catch(() => undefined)
        }
      },
      (error: unknown) => {
        if (live) setState({ kind: error instanceof SharedMixGoneError ? 'gone' : 'failed' })
      },
    )
    return () => { live = false }
  }, [api, token, isPending, userId, attempt, onOwner, appUrl])

  useEffect(() => {
    if (state.kind !== 'loaded') return
    const previous = document.title
    document.title = `${state.mix.title} · Mixtape`
    return () => { document.title = previous }
  }, [state])

  function retry() {
    setState({ kind: 'loading' })
    setAttempt((value) => value + 1)
  }

  const getTheApp = (
    <a className="label-button shared-label" href={downloadUrl}>
      <span className="label-button-hole" aria-hidden="true" />
      <span>Get the app</span>
    </a>
  )

  return (
    <div className="shared-page">
      <header className="shared-top"><span className="shared-wordmark">mixtape</span></header>
      {state.kind === 'loading' && (
        <main className="shared-main" aria-busy="true">
          {/* The one announcement; the cassette and skeletons are decoration. */}
          <p className="sr-only" role="status">Loading mix</p>
          <div className="shared-side" aria-hidden="true">
            <Cassette className="shared-cassette" loading labelled={false} />
            <span className="shared-skeleton shared-skeleton--title" />
            <span className="shared-skeleton shared-skeleton--line" />
          </div>
          <div className="shared-songs" aria-hidden="true">
            {Array.from({ length: 5 }, (_, index) => (
              <div className="shared-song" key={index}>
                <span className="shared-song-number" />
                <span className="shared-cover shared-skeleton" />
                <span className="shared-song-copy"><span className="shared-skeleton shared-skeleton--line" /></span>
                <span />
              </div>
            ))}
          </div>
        </main>
      )}
      {state.kind === 'loaded' && (
        <main className="shared-main">
          <section className="shared-side" aria-labelledby="shared-mix-title">
            <Cassette className="shared-cassette" caseColor={state.mix.caseColor} labelled={false} />
            <h1 id="shared-mix-title">{state.mix.title}</h1>
            <p className="shared-by">Shared by {state.mix.sharerName ?? 'a friend'}</p>
            <p className="shared-meta">{metaLine(state.mix.tracks)}</p>
            <div className="shared-actions">
              <button className="transport-button shared-play" type="button" disabled={state.mix.tracks.length === 0} onClick={() => onPlay(state.mix)}>
                <span className="transport-reel" aria-hidden="true"><PlayIcon /></span>
                <span>Play</span>
                <span className="transport-meter" aria-hidden="true" />
              </button>
              {getTheApp}
              <a className="shared-link" href={appUrl}>Make your own mix</a>
            </div>
          </section>
          <ol className="shared-songs" aria-label="Songs">
            {state.mix.tracks.map((track, index) => {
              const artwork = albumArtworkSource(track.artworkUrl, 36)
              return (
                <li className="shared-song" key={`${index}-${track.title}`}>
                  <span className="shared-song-number" aria-hidden="true">{index + 1}</span>
                  {artwork
                    ? <img className="shared-cover" src={artwork} alt="" loading="lazy" style={track.artworkBgColor ? { backgroundColor: `#${track.artworkBgColor}` } : undefined} />
                    : <span className="shared-cover shared-cover--empty" aria-hidden="true" />}
                  <span className="shared-song-copy"><strong>{track.title}</strong><small>{track.artist}</small></span>
                  <span className="shared-song-duration">{songDuration(track.durationMs)}</span>
                </li>
              )
            })}
          </ol>
        </main>
      )}
      {(state.kind === 'gone' || state.kind === 'failed') && (
        <main className="shared-gone">
          <Cassette className="shared-cassette shared-cassette--dim" labelled={false} />
          <div role={state.kind === 'gone' ? 'status' : 'alert'}>
            <h1>{state.kind === 'gone' ? 'This mix isn’t shared anymore.' : 'Couldn’t open this mix.'}</h1>
          </div>
          <div className="shared-gone-actions">
            {state.kind === 'gone'
              ? <><a className="label-button shared-label" href={appUrl}>Make your own mix</a>{getTheApp}</>
              : <button className="label-button shared-label" type="button" onClick={retry}>Try again</button>}
          </div>
        </main>
      )}
    </div>
  )
}
