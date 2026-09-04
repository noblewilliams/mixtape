import { useRef, useState } from 'react'
import type { ListeningImportSource, MixtapeApi, OnboardingResponse } from '../api/client'
import { elapsedWaitLabel, recentDayLabel, spotifySource, spotifyStatus } from '../lib/onboarding'
import { MusicSourcesList } from './MusicSourcesList'
import { PasteSongsBox } from './PasteSongsBox'

export const SPOTIFY_PRIVACY_URL = 'https://www.spotify.com/account/privacy/'

type SpotifyMusicViewProps = {
  api: MixtapeApi
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
        and log in with the account that has your listening history. A laptop is easier than a phone for this part.
      </li>
      <li>
        Scroll to <b>Download your data</b>.
      </li>
      <li>
        Select <b>Account data</b> and <b>Extended streaming history</b>. Leave <i>Technical log information</i> unselected.
      </li>
      <li>
        Press <b>Request data</b>.
      </li>
      <li>
        Check your email. Spotify sends a <b>confirmation</b> message first. Open it and press <b>Confirm</b>. Nothing is
        prepared until you do, and this is the step most people miss.
      </li>
      <li>
        Wait. The two packages arrive as separate emails, each with a <b>Download</b> button, usually within days; the
        extended history can take up to 30. Each link expires after about two weeks, so download it when you see it.
      </li>
      <li>Save the ZIPs as they are. Don’t unzip them.</li>
      <li>Come back to Mixtape and give it each ZIP as it arrives. You don’t have to wait for both.</li>
    </ol>
  )
}

export function SpotifyMusicView({
  api,
  onboarding,
  interviewStatus,
  onRefresh,
  onOpenInterview,
  onNewTape,
  onRemoveSource,
  onOpenDemo,
}: SpotifyMusicViewProps) {
  const [marking, setMarking] = useState(false)
  const [pasteOpen, setPasteOpen] = useState(false)
  const dropRef = useRef<HTMLDivElement>(null)

  const source = spotifySource(onboarding)
  const status = spotifyStatus(onboarding)
  const waiting = onboarding.markedRequestedAt !== null || source !== null
  const interviewDone = onboarding.interviewCompletedAt !== null

  async function markRequested() {
    setMarking(true)
    try {
      await api.postFunnelEvent({ type: 'marked_requested', surface: 'web' }).catch(() => undefined)
      await onRefresh()
    } finally {
      setMarking(false)
    }
  }

  function focusDropZone() {
    dropRef.current?.scrollIntoView?.({ block: 'center' })
    dropRef.current?.focus()
  }

  const elapsed = onboarding.markedRequestedAt ? elapsedWaitLabel(onboarding.markedRequestedAt) : 'Data in'
  const nudge = source
    ? source.ledgerFrom
      ? `Extended history imported ${recentDayLabel(source.lastImportedAt ?? source.connectedAt)}. Still waiting for the account data; check your inbox for the second email.`
      : `Account data imported ${recentDayLabel(source.lastImportedAt ?? source.connectedAt)}. Still waiting for the extended history; it can take up to 30 days.`
    : onboarding.markedRequestedAt
      ? `Requested ${recentDayLabel(onboarding.markedRequestedAt)}. Confirmation email clicked? If not, nothing is being prepared.`
      : ''

  return (
    <main className="music-view" aria-label="Your music">
      <header className="music-view-head">
        <div>
          <p className="quiet-kicker">Your music · Spotify</p>
          <h1>{source ? 'Your Spotify data' : 'Get your listening data'}</h1>
          <p>
            {source
              ? 'Read on this device. Only your plays and playlists were kept.'
              : 'Spotify prepares it and emails you. Mixtape reads the file on this device and keeps only your plays and playlists.'}
          </p>
        </div>
        <span className={`status-chip ${status.tone}`} role="status">
          <span className="dot" aria-hidden="true" />
          {status.label}
        </span>
      </header>

      <div className="music-view-scroll">
        {interviewStatus ? (
          <p className="view-status" role="status">
            {interviewStatus}
          </p>
        ) : null}

        {waiting ? (
          <section className={`card wait-panel ${source ? '' : 'attention'}`} aria-labelledby="wait-title">
            <div className="wait-card">
              <div>
                <p className="quiet-kicker">Waiting for Spotify</p>
                <h2 className="elapsed" id="wait-title">
                  {elapsed}
                </h2>
                <p>{nudge}</p>
              </div>
              <span className={`status-chip ${status.tone}`}>
                <span className="dot" aria-hidden="true" />
                {status.label}
              </span>
            </div>

            <div className="mini-grid">
              {interviewDone ? (
                <div className="mini done">
                  <strong>Interview done</strong>
                  <small>
                    {source
                      ? 'The DJ can already make a mix from your likes and playlists.'
                      : 'The DJ can already make a mix from what it knows, clearly labeled.'}
                  </small>
                </div>
              ) : (
                <button className="mini" type="button" onClick={onOpenInterview}>
                  <strong>Tell the DJ about your taste</strong>
                  <small>Five short questions. Required before your first mix.</small>
                </button>
              )}
              <button
                className="mini mini--desktop"
                type="button"
                onClick={() => setPasteOpen((open) => !open)}
                aria-expanded={pasteOpen}
              >
                <strong>Paste songs from Spotify</strong>
                <small>
                  {source
                    ? 'Adds to what the DJ knows. Optional.'
                    : 'Select tracks in Spotify on your computer, copy, paste here.'}
                </small>
              </button>
              {onOpenDemo ? (
                <button className="mini" type="button" onClick={onOpenDemo}>
                  <strong>Try a demo tape</strong>
                  <small>See how refining a mix works.</small>
                </button>
              ) : (
                <button className="mini" type="button" disabled>
                  <strong>Try a demo tape</strong>
                  <small>Coming with the import page.</small>
                </button>
              )}
            </div>

            {source ? (
              <div className="btn-row">
                <button className="btn primary" type="button" onClick={onNewTape}>
                  Make a mix
                </button>
                <button className="btn" type="button" onClick={focusDropZone}>
                  Drop the other ZIP
                </button>
              </div>
            ) : null}

            <div className="drop" ref={dropRef} tabIndex={-1} data-todo="import-page">
              <div>
                <strong>Drop a Spotify ZIP here</strong>
                <span>or choose a file · either package, in any order</span>
              </div>
            </div>
          </section>
        ) : (
          <section className="card request-card" aria-label="How to get your listening data">
            <RequestSteps />
            <div className="btn-row">
              <button className="btn primary" type="button" onClick={() => void markRequested()} disabled={marking}>
                {marking ? 'Marking…' : 'I’ve requested it'}
              </button>
              <span className="note note--inline">
                Marks today so Mixtape can show how long you’ve waited. No email from Mixtape; Spotify’s two emails are the
                signal.
              </span>
            </div>
          </section>
        )}

        {waiting && pasteOpen ? <PasteSongsBox api={api} /> : null}

        {onboarding.sources.length > 0 ? (
          <MusicSourcesList sources={onboarding.sources} onImportAgain={focusDropZone} onRemove={onRemoveSource} />
        ) : null}
      </div>
    </main>
  )
}
