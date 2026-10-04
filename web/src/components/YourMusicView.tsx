import { useRestorableState, useWorkspaceRestoring } from '../lib/workspace-restore'
import { AppleMark, SpotifyMark } from './ProviderMarks'
import { useEffect, useRef, useState, useSyncExternalStore } from 'react'
import {
  ApiError,
  type ApiPlaylistSummary,
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
import { Tabs } from './Tabs'
import './your-music.css'

export type MusicSection = 'auto' | 'playlists' | 'sources' | 'apple' | 'spotify'
type Props = {
  onInspire?: (playlist: ApiPlaylistSummary) => void
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
  const restoring = useWorkspaceRestoring()
  const [data, setData] = useRestorableState<{
    summary: MusicCollectionSummary
    onboarding: OnboardingResponse
  } | null>('library.summary', null)
  const [failed, setFailed] = useState(false)
  const [reload, setReload] = useState(0)
  const viewRef = useRef<HTMLElement>(null)
  const headingRef = useRef<HTMLHeadingElement>(null)
  const owner = useSyncExternalStore(uploadGate.subscribe, uploadGate.getOwner)
  const runState = useSyncExternalStore(syncRun.subscribe, syncRun.getState)
  const callbacks = useRef({ onSessionExpired, onSection })
  callbacks.current = { onSessionExpired, onSection }
  useEffect(() => {
    if (restoring) return
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
  }, [api, revision, reload, restoring])
  const current = section === 'auto' ? 'playlists' : section
  useEffect(() => {
    if (viewRef.current) viewRef.current.scrollTop = 0
    headingRef.current?.focus({ preventScroll: true })
  }, [current])
  const spotify = data ? spotifySource(data.onboarding) : null
  const status = data ? spotifyStatus(data.onboarding) : null
  const appleSaved = Boolean(data?.summary.apple.librarySyncedAt || data?.summary.apple.playlists)
  const hasResult = runState.kind === 'result'
  return (
    <main ref={viewRef} className="ym-view" aria-label="Library">
      <header className="ym-header">
        <h1 ref={headingRef} tabIndex={-1}>
          Library
        </h1>
        {(appleSaved || props.connected || spotify) && (
          <div className="library-source-badges" aria-label="Connected music sources">
            {(appleSaved || props.connected) && (
              <button className="library-source-badge" onClick={() => onSection('apple')}>
                <AppleMark /><span>Apple Music</span>{' '}
                <small>{props.connected ? 'Connected' : 'Library saved'}</small>
              </button>
            )}
            {spotify && (
              <button className="library-source-badge" onClick={() => onSection('spotify')}>
                <SpotifyMark /><span>Spotify</span>{' '}<small>Imported</small>
              </button>
            )}
          </div>
        )}
      </header>
      <Tabs
        label="Library sections"
        current={current === 'playlists' ? 'playlists' : 'sources'}
        onSelect={onSection}
        items={[{ id: 'playlists', label: 'Playlists' }, { id: 'sources', label: 'Sources' }]}
      />
      <div className="ym-content">
        {failed && data && <p role="status">Couldn’t refresh your sources. Your saved information is still here. <button className="minimal-retry" onClick={() => setReload(n => n + 1)}>Retry</button></p>}
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
              onInspire={props.onInspire}
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
        ) : failed && !data ? (
          <MusicEmpty
            title="Couldn’t load your sources"
            action="Try again"
            onAction={() => setReload((n) => n + 1)}
          >
            We couldn’t check what is connected to your account. Try again before adding or removing a source.
          </MusicEmpty>
        ) : !data ? (
          <div className="ym-source-stack" aria-busy="true" aria-label="Loading sources">
            {(['apple', 'spotify'] as const).map((provider) => (
              <article className="ym-source-item" key={provider}>
                <div className="ym-source-row">
                  <span className="ym-source-mark">{provider === 'apple' ? <AppleMark /> : <SpotifyMark />}</span>
                  <div className="ym-source-body">
                    <h3>{provider === 'apple' ? 'Apple Music' : 'Spotify'}</h3>
                    <div className="ym-source-placeholder" aria-hidden="true" />
                  </div>
                  <span className="status-chip">Checking…</span>
                  <button className="btn ym-source-action" disabled aria-label={provider === 'apple' ? 'Connect Apple Music' : 'Import Spotify'}>
                    {provider === 'apple' ? 'Connect' : 'Import'}
                  </button>
                </div>
              </article>
            ))}
          </div>
        ) : current === 'spotify' ? (
          <>
            <button className="ym-back" onClick={() => onSection('sources')}>
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
              <p>Connect Apple Music or import your Spotify playlists. Both help shape your mixes.</p>
            </div>
            <div className="ym-source-stack">
              <article className="ym-source-item">
                <div className="ym-source-row">
                  <span className="ym-source-mark"><AppleMark /></span>
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
                    {owner === 'apple' ? 'Sync in progress' : appleSaved ? 'Synced' : props.connected ? 'Connected' : 'Not connected'}
                  </span>
                  <button className="btn ym-source-action" aria-label={appleSaved ? 'Manage Apple Music' : 'Connect Apple Music'} onClick={() => onSection('apple')}>
                    {appleSaved ? 'Manage' : 'Connect'}
                  </button>
                </div>
              </article>
              <article className="ym-source-item">
                <div className="ym-source-row">
                  <span className="ym-source-mark"><SpotifyMark /></span>
                  <div className="ym-source-body">
                    <h3>Spotify</h3>
                    <p>
                      {spotify ? (
                        <>
                          Imported {recentDayLabel(spotify.lastImportedAt ?? spotify.connectedAt)} ·{' '}
                          {data.summary.spotify.playlists} playlists

                        </>
                      ) : (
                        'Bring listening history and playlists from your Spotify data.'
                      )}
                    </p>
                  </div>
                  <span className={`status-chip ${status?.tone ?? 'wait'}`}>
                    {status?.label ?? 'Not imported'}
                  </span>
                  <button className="btn ym-source-action" aria-label={spotify || data.onboarding.markedRequestedAt ? 'Continue Spotify import' : 'Import Spotify'} onClick={() => onSection('spotify')}>
                    {spotify || data.onboarding.markedRequestedAt ? 'Manage import' : 'Import'}
                  </button>
                </div>
              </article>
            </div>
            <p className="ym-notice">
              Spotify imports are snapshots, not a live connection. Adding a source keeps your existing music.
              Apple Music access is authorized in each browser.
            </p>
          </>
        )}
      </div>
    </main>
  )
}
