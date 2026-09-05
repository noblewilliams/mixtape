import { useEffect, useRef, useState, useSyncExternalStore } from 'react'
import {
  ApiError,
  type ListeningImportSource,
  type MixtapeApi,
  type MusicCollectionSummary,
  type OnboardingResponse,
} from '../api/client'
import type { ImportRun } from '../import/import-run'
import type { MusicSyncRun } from '../sync/music-sync-run'
import type { UploadGate } from '../sync/upload-gate'
import { spotifyStatus, spotifySource, recentDayLabel } from '../lib/onboarding'
import { AppleMusicSyncPanel } from './AppleMusicSyncPanel'
import { MusicEmpty, PlaylistBrowser, musicDate } from './PlaylistBrowser'
import { SpotifyMusicView } from './SpotifyMusicView'
import './your-music.css'

export type MusicSection = 'auto' | 'playlists' | 'sources' | 'apple' | 'spotify'
type Props = {
  api: MixtapeApi
  section: MusicSection
  onSection: (section: MusicSection) => void
  syncRun: MusicSyncRun
  importRun: ImportRun
  uploadGate: UploadGate
  connected: boolean
  revision: number
  interviewStatus: string
  onRefresh: () => Promise<void>
  onOpenInterview: () => void
  onNewTape: () => void
  onRemoveSource: (source: ListeningImportSource) => void
  onSessionExpired: () => void
}
export function YourMusicView(props: Props) {
  const { api, section, onSection, uploadGate, syncRun, revision, onSessionExpired } = props
  const [data, setData] = useState<{
    summary: MusicCollectionSummary
    onboarding: OnboardingResponse
  } | null>(null)
  const [failed, setFailed] = useState(false)
  const [reload, setReload] = useState(0)
  const viewRef = useRef<HTMLElement>(null)
  const headingRef = useRef<HTMLHeadingElement>(null)
  const owner = useSyncExternalStore(uploadGate.subscribe, uploadGate.getOwner)
  const runState = useSyncExternalStore(syncRun.subscribe, syncRun.getState)
  const callbacks = useRef({ onSessionExpired, onSection })
  callbacks.current = { onSessionExpired, onSection }
  useEffect(() => {
    const controller = new AbortController()
    setFailed(false)
    void Promise.all([api.getMusicCollectionSummary(controller.signal), api.getOnboarding(controller.signal)])
      .then(([summary, onboarding]) => {
        if (!controller.signal.aborted) setData({ summary, onboarding })
      })
      .catch((error) => {
        if (!controller.signal.aborted) {
          setFailed(true)
          if (error instanceof ApiError && error.status === 401) callbacks.current.onSessionExpired()
        }
      })
    return () => controller.abort()
  }, [api, revision, reload])
  const current =
    section === 'auto'
      ? data &&
        (data.summary.apple.librarySyncedAt ||
          data.summary.apple.playlists ||
          data.summary.spotify.playlists ||
          data.onboarding.importCompletedAt)
        ? 'playlists'
        : 'sources'
      : section
  useEffect(() => {
    if (viewRef.current) viewRef.current.scrollTop = 0
    headingRef.current?.focus({ preventScroll: true })
  }, [current])
  const spotify = data ? spotifySource(data.onboarding) : null
  const status = data ? spotifyStatus(data.onboarding) : null
  const appleSaved = Boolean(data?.summary.apple.librarySyncedAt || data?.summary.apple.playlists)
  const hasResult = runState.kind === 'result'
  return (
    <main ref={viewRef} className="ym-view" aria-label="Your music">
      <header className="ym-header">
        <h1 ref={headingRef} tabIndex={-1}>
          Your music
        </h1>
        <p>The music you bring. The mixes you make.</p>
      </header>
      <nav className="ym-tabs" aria-label="Your music sections">
        <button
          onClick={() => onSection('playlists')}
          aria-current={current === 'playlists' ? 'page' : undefined}
        >
          Playlists
        </button>
        <button
          onClick={() => onSection('sources')}
          aria-current={current !== 'playlists' ? 'page' : undefined}
        >
          Sources
        </button>
      </nav>
      <div className="ym-content">
        {current === 'playlists' ? (
          <>
            {owner || hasResult ? (
              <div className="card ym-run-banner" role="status">
                <span>
                  {owner === 'spotify'
                    ? 'Spotify import running'
                    : owner === 'apple'
                      ? runState.kind === 'result'
                        ? 'Apple sync result unconfirmed'
                        : 'Apple sync running'
                      : 'Apple sync finished'}
                </span>
                <button className="btn" onClick={() => onSection(owner === 'spotify' ? 'spotify' : 'apple')}>
                  View progress
                </button>
              </div>
            ) : null}
            <PlaylistBrowser
              key={revision}
              api={api}
              onSources={() => onSection('sources')}
              onSessionExpired={onSessionExpired}
            />
          </>
        ) : current === 'apple' ? (
          <AppleMusicSyncPanel
            run={syncRun}
            owner={owner}
            connected={props.connected}
            summary={data?.summary ?? null}
            onBrowse={() => onSection('playlists')}
            onSources={() => onSection('sources')}
            onSpotify={() => onSection('spotify')}
            onSignIn={onSessionExpired}
          />
        ) : failed ? (
          <MusicEmpty
            title="Couldn’t load your sources"
            action="Try again"
            onAction={() => setReload((n) => n + 1)}
          >
            We couldn’t check what is connected to your account. Try again before adding or removing a source.
          </MusicEmpty>
        ) : !data ? (
          <div aria-busy="true" aria-label="Loading sources">
            <div className="card ym-skeleton" />
            <div className="card ym-skeleton" />
          </div>
        ) : current === 'spotify' ? (
          <>
            <button className="btn ym-back" onClick={() => onSection('sources')}>
              ← Sources
            </button>
            {owner === 'apple' ? (
              <div className="card ym-run-banner" role="status">
                <span>
                  Apple sync is running or checking its result. You can inspect a file now; upload when it
                  finishes.
                </span>
                <button className="btn" onClick={() => onSection('apple')}>
                  View progress
                </button>
              </div>
            ) : null}
            <SpotifyMusicView
              embedded
              api={api}
              importRun={props.importRun}
              uploadBlocked={owner === 'apple'}
              onboarding={data.onboarding}
              interviewStatus={props.interviewStatus}
              onRefresh={props.onRefresh}
              onOpenInterview={props.onOpenInterview}
              onNewTape={props.onNewTape}
              onRemoveSource={props.onRemoveSource}
            />
          </>
        ) : (
          <>
            <div className="ym-source-intro">
              <p className="quiet-kicker">Bring your music</p>
              <h2>A little more of you.</h2>
              <p>
                Connect Apple Music, import Spotify, or bring both. Your music helps shape the mixes you make
                here.
              </p>
            </div>
            <div className="ym-source-stack">
              <article className="card ym-source-card">
                <div className="ym-source-row">
                  <span className="ym-source-mark">AM</span>
                  <div className="ym-source-body">
                    <h3>Apple Music</h3>
                    <p>
                      {appleSaved ? (
                        <>
                          {data.summary.apple.songs !== null
                            ? `${data.summary.apple.songs.toLocaleString()} songs · `
                            : ''}
                          {data.summary.apple.playlists} playlists
                          {data.summary.apple.librarySyncedAt ? (
                            <>
                              <br />
                              Last completed songs sync · {musicDate(data.summary.apple.librarySyncedAt)}
                            </>
                          ) : null}
                        </>
                      ) : (
                        'Read your songs and playlists with Apple Music.'
                      )}
                    </p>
                  </div>
                  <span className={`status-chip ${appleSaved ? 'ok' : 'wait'}`}>
                    {owner === 'apple' ? 'Sync in progress' : appleSaved ? 'Synced' : 'Not connected'}
                  </span>
                </div>
                <div className="btn-row">
                  <button className={`btn ${appleSaved ? '' : 'primary'}`} onClick={() => onSection('apple')}>
                    {appleSaved ? 'Manage Apple Music' : 'Connect Apple Music'}
                  </button>
                </div>
              </article>
              <article className="card ym-source-card">
                <div className="ym-source-row">
                  <span className="ym-source-mark">SP</span>
                  <div className="ym-source-body">
                    <h3>Spotify</h3>
                    <p>
                      {spotify ? (
                        <>
                          Imported {recentDayLabel(spotify.lastImportedAt ?? spotify.connectedAt)} ·{' '}
                          {data.summary.spotify.playlists} playlists
                          <br />
                          Re-import any time.
                        </>
                      ) : (
                        'Bring listening history and playlists from your Spotify data.'
                      )}
                    </p>
                  </div>
                  <span className={`status-chip ${status?.tone ?? 'wait'}`}>
                    {status?.label ?? 'Not imported'}
                  </span>
                </div>
                <div className="btn-row">
                  <button className="btn" onClick={() => onSection('spotify')}>
                    {spotify || data.onboarding.markedRequestedAt ? 'Continue Spotify import' : 'Get started'}
                  </button>
                </div>
              </article>
            </div>
            <p className="ym-notice">
              Adding a source does not remove the other. Apple access is authorized in each browser; music
              already synced to your Mixtape account stays available.
            </p>
          </>
        )}
      </div>
    </main>
  )
}
