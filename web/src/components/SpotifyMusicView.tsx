import { useRef, useState, useSyncExternalStore } from 'react'
import type {
  ListeningImportSource,
  MixtapeApi,
  OnboardingResponse,
} from '../api/client'
import type { ImportRun } from '../import/import-run'
import { recentDayLabel, spotifySource } from '../lib/onboarding'
import { ImportPanel, type ImportPanelHandle } from './ImportPanel'
import { MusicSourcesList } from './MusicSourcesList'

export const SPOTIFY_PRIVACY_URL = 'https://www.spotify.com/account/privacy/'
const MARK_FAILED = 'Couldn’t save that. Check your connection and try again.'

type SpotifyMusicViewProps = {
  embedded?: boolean
  uploadBlocked?: boolean
  api: MixtapeApi
  /** The app-owned import run; it outlives this view so an upload survives navigation. */
  importRun: ImportRun
  onboarding: OnboardingResponse
  interviewStatus: string
  onRefresh: () => Promise<void>
  onOpenInterview: () => void
  onNewTape: () => void
  onRemoveSource: (source: ListeningImportSource) => void
  onOpenDemo?: () => void
}

function RequestSteps() {
  return (
    <ol className="steps">
      <li>
        Open{' '}
        <a href={SPOTIFY_PRIVACY_URL} target="_blank" rel="noopener">
          spotify.com/account/privacy
        </a>{' '}
        and log in with the account that has your listening history. A laptop is
        easier than a phone for this part.
      </li>
      <li>
        Scroll to <b>Download your data</b>.
      </li>
      <li>
        Select <b>Account data</b> and <b>Extended streaming history</b>. Leave{' '}
        <i>Technical log information</i> unselected.
      </li>
      <li>
        Press <b>Request data</b>.
      </li>
      <li>
        Check your email. Spotify sends a <b>confirmation</b> message first.
        Open it and press <b>Confirm</b>. Nothing is prepared until you do, and
        this is the step most people miss.
      </li>
      <li>
        Wait. The two packages arrive as separate emails, each with a{' '}
        <b>Download</b> button, usually within days; the extended history can
        take up to 30. Each link expires after about two weeks, so download it
        when you see it.
      </li>
      <li>Save the ZIPs as they are. Don’t unzip them.</li>
      <li>
        Come back to Mixtape and give it each ZIP as it arrives. You don’t have
        to wait for both.
      </li>
    </ol>
  )
}

export function SpotifyMusicView({
  api,
  importRun,
  onboarding,
  interviewStatus,
  onRefresh,
  onOpenInterview,
  onNewTape,
  onRemoveSource,
  embedded = false,
  uploadBlocked = false,
}: SpotifyMusicViewProps) {
  const [deeper, setDeeper] = useState(false)
  const [marking, setMarking] = useState(false)
  const [markError, setMarkError] = useState('')
  const importRef = useRef<ImportPanelHandle>(null)
  const importState = useSyncExternalStore(
    importRun.subscribe,
    importRun.getState,
    importRun.getState,
  )
  const choosing = importState.kind === 'pick'
  const source = spotifySource(onboarding)
  const imported = Boolean(source?.lastImportedAt)
  const interviewDone = onboarding.interviewCompletedAt !== null
  async function markRequested() {
    setMarking(true)
    setMarkError('')
    try {
      await api.postFunnelEvent({ type: 'marked_requested', surface: 'web' })
      await onRefresh()
    } catch {
      setMarkError(MARK_FAILED)
    } finally {
      setMarking(false)
    }
  }
  const Container = embedded ? 'section' : 'main'
  return (
    <Container
      className={`music-view ${embedded ? 'music-view--embedded' : ''}`}
      aria-label={embedded ? 'Spotify import' : 'Your music'}
    >
      <header className="music-view-head">
        <div>
          <p className="quiet-kicker">Spotify · File import</p>
          <h1>
            {imported ? 'Your Spotify music' : 'Bring your Spotify music'}
          </h1>
          <p>
            Start with your playlists and Liked Songs. Add listening history
            whenever you like.
          </p>
        </div>
        <span className="status-chip">
          {importState.kind === 'done'
            ? 'Imported'
            : imported
              ? 'Manual refresh'
              : 'Ready to import'}
        </span>
      </header>
      <div className="music-view-scroll">
        {interviewStatus ? <p role="status">{interviewStatus}</p> : null}
        <section
          className={choosing ? 'card request-card' : 'import-stage'}
          aria-label="Export your saved music"
        >
          {choosing ? (
            <>
              <h2>Export your saved music</h2>
              <ol className="steps">
                <li>
                  <b>Open Exportify and connect Spotify.</b> Exportify opens in
                  your browser and asks for read access.
                </li>
                <li>
                  <b>Choose Export All.</b> Save the ZIP as it is. You can also
                  export individual playlists.
                </li>
                <li>
                  <b>Come back and choose the files.</b> Mixtape will show what
                  it found before importing.
                </li>
              </ol>
              <div className="btn-row">
                <a
                  className="btn primary"
                  href="https://exportify.app/"
                  target="_blank"
                  rel="noopener noreferrer"
                >
                  Open Exportify ↗
                </a>
                <span className="note">
                  Opens exportify.app outside Mixtape.
                </span>
              </div>
            </>
          ) : null}
          <ImportPanel
            mixLabel={
              interviewDone ? 'Make a mix' : 'Tell the DJ about your taste'
            }
            ref={importRef}
            run={importRun}
            onNewTape={interviewDone ? onNewTape : onOpenInterview}
            uploadBlocked={uploadBlocked}
          />
          {choosing ? (
            <>
              <p className="note">
                Read on this device first. Review the music before anything is
                uploaded.
              </p>
              <details>
                <summary>Exportify not working?</summary>
                <p>
                  Try again later, or use the official Spotify download under Go
                  deeper. If you already have an export, choose it above.
                </p>
              </details>
            </>
          ) : null}
        </section>
        <section className="card quiet">
          <h2>Go deeper with your history</h2>
          <p>Help the DJ learn your repeat favourites and past listening.</p>
          <button
            type="button"
            className="btn text-action"
            aria-expanded={deeper}
            onClick={() => setDeeper(!deeper)}
          >
            Go deeper →
          </button>
          {deeper ? (
            <>
              <RequestSteps />
              {onboarding.markedRequestedAt ? (
                <p role="status">
                  Requested {recentDayLabel(onboarding.markedRequestedAt)}. You
                  can import saved music above while Spotify prepares your
                  history.
                </p>
              ) : (
                <button
                  type="button"
                  className="btn"
                  disabled={marking}
                  onClick={() => void markRequested()}
                >
                  {marking ? 'Saving…' : 'I’ve requested it'}
                </button>
              )}
              {markError ? <p role="alert">{markError}</p> : null}
            </>
          ) : null}
        </section>
        {!interviewDone && choosing ? (
          <button
            className="btn text-action"
            type="button"
            onClick={onOpenInterview}
          >
            Tell the DJ about your taste
          </button>
        ) : null}
        {source ? (
          <MusicSourcesList
            sources={onboarding.sources}
            onImportAgain={() => importRef.current?.focus()}
            onRemove={onRemoveSource}
          />
        ) : null}
      </div>
    </Container>
  )
}
