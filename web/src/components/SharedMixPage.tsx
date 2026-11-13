// The public page for a shared mix link, /m/<token> (spec 2026-11-13
// shared-mixes, "Recipient on the web"; board W1–W7). It renders outside
// AuthGate: no sign-in, no first run. It calls only the public share
// endpoints, never one that needs AI consent.
import { useEffect, useRef, useState } from 'react'
import { SharedMixGoneError, type MixtapeApi } from '../api/client'
import { durationLabel } from '../api/mappers'
import type { QueueTrack, SharedMix, SharedMixTrack } from '../domain'
import { albumArtworkSource } from '../lib/album-format'
import { readPlaysOn, writePlaysOn, type PlaysOn } from '../lib/plays-on'
import { openMixOnNextLoad } from '../lib/workspace-restore'
import type { MusicKitClient } from '../musickit/client'
import type { PlaybackController } from '../playback/controller'
import { Cassette } from './Cassette'
import { PlayIcon } from './Icons'
import { Toast } from './Overlays'
import { SharedPlayModal, type SharedPlayStep } from './SharedPlayModal'
import { useSpotifyHandoff } from './SpotifyHandoff'
import './shared-mix-page.css'

/** The browser's session as far as this page needs it: a user id only when requests carry a session. */
export type SharedMixSession = { isPending: boolean; userId: string | null }

/**
 * What Play on Apple Music needs (task W2). `ensureSession` comes first: the
 * MusicKit developer token is served only to a session.
 *
 * Safari opens Apple's sign-in window only while the tap's user activation
 * lasts, so `connect()` must be the first thing a tap does. A browser that
 * already has a session prepares MusicKit on load and plays in one tap; a
 * first-time visitor gets ready in the dialog, then taps Connect Apple Music
 * (decisions 2026-11-13, "a first Apple Music play takes a second tap").
 * Visiting never makes a session.
 */
export type SharedMixPlayer = {
  ensureSession: () => Promise<void>
  /** Starts loading the MusicKit script, which needs no session. */
  preload?: () => void
  musicKit: Pick<MusicKitClient, 'connect' | 'prepare'>
  playback: Pick<PlaybackController, 'start'>
}

type Notice = { message: string; tone: 'info' | 'error' }

const NOTICE_MS = 4000
// The app's own copy for these failures (App.togglePlayback, QueuePanel's
// connect error); never the raw error.
const PLAY_FAILED = 'Apple Music couldn’t play this mix. Try again in a moment.'
const CONNECT_FAILED = 'Apple Music didn’t connect. Try again.'
const NO_APPLE_SONGS = 'Apple Music couldn’t play this mix.'

type SharedMixPageProps = {
  token: string
  api: Pick<MixtapeApi, 'getSharedMix' | 'saveSharedMix'>
  session: SharedMixSession
  /** Play on Apple Music; without it the Apple path does nothing (previews). */
  player?: SharedMixPlayer
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

/** The share as the playback controller's queue: it skips songs without an Apple id. */
function queueTracks(mix: SharedMix): QueueTrack[] {
  return mix.tracks.map((track, index) => ({
    position: index,
    trackId: `${mix.token}:${index}`,
    appleId: track.appleId ?? null,
    spotifyId: null,
    title: track.title,
    artist: track.artist,
    durationMs: track.durationMs,
  }))
}

export function SharedMixPage({ token, api, session, player, onOwner, appUrl = import.meta.env.BASE_URL, downloadUrl = '/' }: SharedMixPageProps) {
  const [state, setState] = useState<PageState>({ kind: 'loading' })
  const [attempt, setAttempt] = useState(0)
  // The dialog: null is closed.
  const [step, setStep] = useState<SharedPlayStep | null>(null)
  const [starting, setStarting] = useState(false)
  // MusicKit is configured, so connect() reaches authorize() with no await.
  const [appleReady, setAppleReady] = useState(false)
  // Play made a session (useSession catches up later).
  const sessionMade = useRef(false)
  // Each getting-ready run; closing the dialog abandons the one in flight.
  const readyRun = useRef(0)
  // The read that loaded this page: a later session change doesn't read again.
  const loadedKey = useRef<string | null>(null)
  const [notice, setNotice] = useState<Notice | null>(null)
  const noticeTimer = useRef<ReturnType<typeof setTimeout> | null>(null)
  // One read per token, session and attempt, even when React runs effects twice:
  // the public read is rate-limited per IP.
  const reading = useRef<{ key: string; result: Promise<SharedMix> } | null>(null)
  const saved = useRef<string | null>(null)
  const redirected = useRef(false)
  const { isPending, userId } = session

  useEffect(() => {
    // Wait for the session check, so a session (and so isOwner) rides along.
    if (isPending) return
    // Loaded already: the session Play just made changes nothing on screen,
    // and a failed re-read must never replace a mix mid-playback.
    if (loadedKey.current === `${token}|${attempt}`) {
      // A session arrived after a read without one: the share joins its Mixes.
      if (userId && state.kind === 'loaded' && !state.mix.isOwner && saved.current !== token) {
        saved.current = token
        api.saveSharedMix(token).catch(() => undefined)
      }
      return
    }
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
        loadedKey.current = `${token}|${attempt}`
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
    // `state` is read only once loaded, to save; it never starts a read.
  }, [api, token, isPending, userId, attempt, onOwner, appUrl])

  useEffect(() => {
    if (state.kind !== 'loaded') return
    const previous = document.title
    document.title = `${state.mix.title} · Mixtape`
    return () => { document.title = previous }
  }, [state])

  useEffect(() => () => { if (noticeTimer.current) clearTimeout(noticeTimer.current) }, [])

  // MusicKit ahead of the tap. The script needs no session, so it loads on any
  // visit; configuring needs the developer token, so only a browser that
  // already has a session prepares. Never for a Spotify listener.
  const preloaded = useRef(false)
  useEffect(() => {
    if (!player || preloaded.current || readPlaysOn() === 'spotify') return
    preloaded.current = true
    player.preload?.()
  }, [player])
  const preparing = useRef(false)
  useEffect(() => {
    if (!player || isPending || !userId || preparing.current || readPlaysOn() === 'spotify') return
    preparing.current = true
    void (player.musicKit.prepare?.() ?? Promise.resolve()).then(() => setAppleReady(true), () => undefined)
  }, [player, isPending, userId])

  function announce(message: string, tone: Notice['tone']) {
    setNotice({ message, tone })
    if (noticeTimer.current) clearTimeout(noticeTimer.current)
    noticeTimer.current = setTimeout(() => setNotice(null), NOTICE_MS)
  }

  const spotify = useSpotifyHandoff({
    songs: () => (state.kind === 'loaded' ? state.mix.tracks : []),
    onResult: (message) => announce(message, 'info'),
  })

  function saveOnce(mix: SharedMix) {
    // A session now exists, so the share joins its Mixes, once (the read
    // effect saves too when the session reaches it; the ref keeps it to one).
    if (!mix.isOwner && saved.current !== token) {
      saved.current = token
      api.saveSharedMix(token).catch(() => undefined)
    }
  }

  /** Synchronous up to authorize(): call it straight from a click. */
  function connectAndPlay(mix: SharedMix) {
    if (!player) return
    const connecting = player.musicKit.connect()
    readyRun.current += 1
    setStep(null)
    setStarting(true)
    void (async () => {
      try {
        try {
          await connecting
        } catch {
          announce(CONNECT_FAILED, 'error')
          return
        }
        const started = await player.playback.start(`shared:${mix.token}`, 0, mix.title, queueTracks(mix))
        if (!started) announce(PLAY_FAILED, 'error')
      } finally {
        setStarting(false)
      }
    })()
  }

  /** A first play: a session, then MusicKit, then Connect Apple Music in the dialog. */
  async function getAppleReady(mix: SharedMix) {
    if (!player) return
    const run = ++readyRun.current
    setStep('readying')
    try {
      if (!userId && !sessionMade.current) {
        // No session (the anonymous limit, or offline): no token, so no Apple Music.
        await player.ensureSession()
        sessionMade.current = true
      }
      if (readyRun.current !== run) return
      saveOnce(mix)
      await player.musicKit.prepare?.()
    } catch {
      if (readyRun.current === run) setStep('failed')
      return
    }
    if (readyRun.current !== run) return
    setAppleReady(true)
    setStep('connect')
  }

  function playOnApple(mix: SharedMix) {
    if (!player || starting) return
    if (!mix.tracks.some((track) => track.appleId)) {
      setStep(null)
      announce(NO_APPLE_SONGS, 'error')
      return
    }
    if ((userId || sessionMade.current) && appleReady) {
      saveOnce(mix)
      connectAndPlay(mix)
      return
    }
    void getAppleReady(mix)
  }

  function playWith(choice: PlaysOn, mix: SharedMix) {
    if (choice === 'spotify') spotify.start()
    else playOnApple(mix)
  }

  function play(mix: SharedMix) {
    if (starting) return
    const choice = readPlaysOn()
    if (choice) playWith(choice, mix)
    else setStep('choose')
  }

  function choose(choice: PlaysOn, mix: SharedMix) {
    writePlaysOn(choice)
    setStep(null)
    playWith(choice, mix)
  }

  function closeDialog() {
    readyRun.current += 1
    setStep(null)
  }

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
              <button className="transport-button shared-play" type="button" disabled={state.mix.tracks.length === 0} aria-disabled={starting || undefined} aria-busy={starting || undefined} onClick={() => play(state.mix)}>
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
          {step && (
            <SharedPlayModal
              step={step}
              failure={PLAY_FAILED}
              onChoose={(choice) => choose(choice, state.mix)}
              onConnect={() => connectAndPlay(state.mix)}
              onRetry={() => void getAppleReady(state.mix)}
              onClose={closeDialog}
            />
          )}
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
      {spotify.explainer}
      {notice && <Toast message={notice.message} tone={notice.tone} />}
    </div>
  )
}
