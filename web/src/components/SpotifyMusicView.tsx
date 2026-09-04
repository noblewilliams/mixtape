import { useRef, useState } from 'react'
import type { ListeningImportSource, MixtapeApi, OnboardingResponse } from '../api/client'
import type { ListeningImportService } from '../import/import-service'
import type { PageParser } from '../import/page-parser'
import { elapsedWaitLabel, recentDayLabel, spotifyPackages, spotifySource, spotifyStatus } from '../lib/onboarding'
import { ImportPanel, type ImportPanelHandle } from './ImportPanel'
import { MusicSourcesList } from './MusicSourcesList'
import { PasteSongsBox } from './PasteSongsBox'

export const SPOTIFY_PRIVACY_URL = 'https://www.spotify.com/account/privacy/'
const MARK_FAILED = 'Couldn’t save that. Check your connection and try again.'

type SpotifyMusicViewProps = {
  api: MixtapeApi
  importService: ListeningImportService
  parser: PageParser
  onboarding: OnboardingResponse
  interviewStatus: string
  onRefresh: () => Promise<void>
  onOpenInterview: () => void
  onNewTape: () => void
  onRemoveSource: (source: ListeningImportSource) => void
  onImportBusyChange?: (busy: boolean) => void
  onOpenDemo?: () => void
}

function plural(count: number, noun: string) {
  return `${count} ${noun}${count === 1 ? '' : 's'}`
}

/** "4 notes, 6 artists. <sentence>" once the server reports counts; the sentence alone until then. */
function interviewDoneCopy(onboarding: OnboardingResponse, sentence: string): string {
  const counts = onboarding.interview
  return counts ? `${plural(counts.notes, 'note')}, ${plural(counts.artists, 'artist')}. ${sentence}` : sentence
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

function DemoTile({ onOpenDemo }: { onOpenDemo?: () => void }) {
  if (onOpenDemo) {
    return (
      <button className="mini" type="button" onClick={onOpenDemo}>
        <strong>Try a demo tape</strong>
        <small>See how refining a mix works.</small>
      </button>
    )
  }
  return (
    <button className="mini" type="button" disabled>
      <strong>Try a demo tape</strong>
      <small>Demo tape coming soon.</small>
    </button>
  )
}

export function SpotifyMusicView({
  api,
  importService,
  parser,
  onboarding,
  interviewStatus,
  onRefresh,
  onOpenInterview,
  onNewTape,
  onRemoveSource,
  onImportBusyChange,
  onOpenDemo,
}: SpotifyMusicViewProps) {
  const [marking, setMarking] = useState(false)
  const [markError, setMarkError] = useState('')
  const [pasteOpen, setPasteOpen] = useState(false)
  const importRef = useRef<ImportPanelHandle>(null)
  const stepsRef = useRef<HTMLElement>(null)

  const source = spotifySource(onboarding)
  const packages = spotifyPackages(source)
  const status = spotifyStatus(onboarding)
  const waiting = onboarding.markedRequestedAt !== null || source !== null
  const interviewDone = onboarding.interviewCompletedAt !== null
  const anyIn = packages.count > 0
  const allIn = packages.count === 2

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

  function focusDropZone() {
    importRef.current?.focus()
  }

  function showSteps() {
    stepsRef.current?.scrollIntoView?.({ block: 'start' })
    stepsRef.current?.focus()
  }

  const importedOn = source ? recentDayLabel(source.lastImportedAt ?? source.connectedAt) : ''
  const elapsed = allIn
    ? 'Data in'
    : onboarding.markedRequestedAt
      ? elapsedWaitLabel(onboarding.markedRequestedAt)
      : anyIn
        ? 'Data in'
        : 'Not requested'
  const nudge = allIn
    ? `Both packages imported ${importedOn}. Drop a newer ZIP any time to bring it up to date.`
    : packages.extended
      ? `Extended history imported ${importedOn}. Still waiting for the account data; check your inbox for the second email.`
      : packages.account
        ? `Account data imported ${importedOn}. Still waiting for the extended history; it can take up to 30 days.`
        : onboarding.markedRequestedAt
          ? `Requested ${recentDayLabel(onboarding.markedRequestedAt)}. Confirmation email clicked? If not, nothing is being prepared.`
          : ''

  return (
    <main className="music-view" aria-label="Your music">
      <header className="music-view-head">
        <div>
          <p className="quiet-kicker">Your music · Spotify</p>
          <h1>{anyIn ? 'Your Spotify data' : 'Get your listening data'}</h1>
          <p>
            {anyIn
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
          <section className={`card wait-panel ${anyIn ? '' : 'attention'}`} aria-labelledby="wait-title">
            <div className="wait-card">
              <div>
                <p className="quiet-kicker">{allIn ? 'Spotify' : 'Waiting for Spotify'}</p>
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
                    {interviewDoneCopy(
                      onboarding,
                      anyIn
                        ? 'The DJ can already make a mix from your likes and playlists.'
                        : 'The DJ can already make a mix from what it knows, clearly labeled.',
                    )}
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
                  {anyIn
                    ? 'Adds to what the DJ knows. Optional.'
                    : 'Select tracks in Spotify on your computer, copy, paste here.'}
                </small>
              </button>
              <DemoTile onOpenDemo={onOpenDemo} />
            </div>

            {anyIn ? (
              <div className="btn-row">
                <button className="btn primary" type="button" onClick={onNewTape}>
                  Make a mix
                </button>
                <button className="btn" type="button" onClick={focusDropZone}>
                  {allIn ? 'Drop a newer ZIP' : 'Drop the other ZIP'}
                </button>
              </div>
            ) : null}

            <ImportPanel
              ref={importRef}
              importService={importService}
              parser={parser}
              onRefresh={onRefresh}
              onNewTape={onNewTape}
              onBusyChange={onImportBusyChange}
            />
          </section>
        ) : (
          <>
            <section className="card quiet wait-panel" aria-labelledby="pre-title">
              <div className="wait-card">
                <div>
                  <p className="quiet-kicker">Spotify</p>
                  <h2 className="elapsed" id="pre-title">
                    Not requested
                  </h2>
                  <p>The DJ can’t make a personal mix until your data arrives. Ask Spotify now; it takes two minutes.</p>
                </div>
                <span className="status-chip">
                  <span className="dot" aria-hidden="true" />
                  Not requested
                </span>
              </div>

              <div className="mini-grid">
                {interviewDone ? (
                  <div className="mini done">
                    <strong>Interview done</strong>
                    <small>
                      {interviewDoneCopy(onboarding, 'The DJ can already make a mix from what it knows, clearly labeled.')}
                    </small>
                  </div>
                ) : (
                  <button className="mini" type="button" onClick={onOpenInterview}>
                    <strong>Tell the DJ about your taste</strong>
                    <small>Five short questions. Required before any mix.</small>
                  </button>
                )}
                <div className="mini quiet">
                  <strong>Not personal yet</strong>
                  <small>
                    {interviewDone
                      ? 'The DJ can offer a mix from what it already knows, clearly labeled.'
                      : 'Once the interview is done, the DJ can offer a mix from what it already knows, clearly labeled.'}
                  </small>
                </div>
                <DemoTile onOpenDemo={onOpenDemo} />
              </div>

              <div className="btn-row">
                <button className="btn primary" type="button" onClick={showSteps}>
                  Show me the steps
                </button>
              </div>
            </section>

            <section
              className="card request-card"
              aria-label="How to get your listening data"
              ref={stepsRef}
              tabIndex={-1}
            >
              <RequestSteps />
              <div className="btn-row">
                <button className="btn primary" type="button" onClick={() => void markRequested()} disabled={marking}>
                  {marking ? 'Marking…' : 'I’ve requested it'}
                </button>
                <span className="note note--inline">
                  Marks today so Mixtape can show how long you’ve waited. No email from Mixtape; Spotify’s two emails are
                  the signal.
                </span>
              </div>
              {markError ? (
                <p className="dialog-error" role="alert">
                  {markError}
                </p>
              ) : null}
            </section>
          </>
        )}

        {waiting && pasteOpen ? <PasteSongsBox api={api} /> : null}

        {onboarding.sources.length > 0 ? (
          <MusicSourcesList sources={onboarding.sources} onImportAgain={focusDropZone} onRemove={onRemoveSource} />
        ) : null}
      </div>
    </main>
  )
}
