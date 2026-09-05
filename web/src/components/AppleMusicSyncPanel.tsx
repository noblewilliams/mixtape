import { useSyncExternalStore } from 'react'
import type { MusicCollectionSummary } from '../api/client'
import type { MusicSyncRun } from '../sync/music-sync-run'
import type { UploadOwner } from '../sync/upload-gate'
import { musicDate } from './PlaylistBrowser'

type Props = {
  run: MusicSyncRun
  owner: UploadOwner | null
  connected: boolean
  summary: MusicCollectionSummary | null
  onBrowse: () => void
  onSpotify: () => void
  onSources: () => void
  onSignIn: () => void
}
export function AppleMusicSyncPanel({
  run,
  owner,
  connected,
  summary,
  onBrowse,
  onSpotify,
  onSources,
  onSignIn,
}: Props) {
  const state = useSyncExternalStore(run.subscribe, run.getState)
  const running = state.kind === 'running' || state.kind === 'cancelling'
  const progress = running ? state.progress : null
  const result = state.kind === 'result' ? state.result : null
  const busy = owner === 'spotify'
  const synced = Boolean(summary?.apple.librarySyncedAt)
  let title = connected
    ? 'Your Apple music is ready'
    : synced
      ? 'Authorize this browser to sync'
      : 'Connect when you’re ready'
  let copy = connected
    ? 'Browse what you’ve synced, or refresh it from this browser.'
    : synced
      ? 'Your account already has Apple music. To refresh it here, connect Apple Music in this browser.'
      : 'Apple Music opens a permission step. Then we’ll read your library and playlists and bring them into Mixtape.'
  let status = connected ? 'This browser authorized' : 'Browser not authorized'
  let action = connected ? 'Sync now' : 'Connect Apple Music'
  let tone = 'wait'
  let perform = run.start
  if (busy) {
    title = 'Spotify is importing right now'
    copy =
      'Let that upload finish or cancel it before starting Apple sync. You can keep browsing in the meantime.'
    status = 'Another upload is running'
  }
  if (running) {
    title =
      progress?.stage === 'uploading_library'
        ? 'Bringing in your songs'
        : progress?.stage === 'uploading_playlists'
          ? 'Songs saved. Playlists next.'
          : progress?.stage === 'saving_library' || progress?.stage === 'saving_playlists'
            ? 'Confirming what was saved'
            : progress?.stage === 'authorizing'
              ? 'Connecting Apple Music'
              : 'Reading your Apple library'
    copy =
      progress?.stage === 'uploading_playlists'
        ? 'Your songs are ready. Previous playlists stay available until this playlist snapshot finishes.'
        : 'Keep this tab open. You can browse Mixtape while we collect your music.'
    status = state.kind === 'cancelling' ? 'Stopping safely…' : 'Sync running'
  }
  if (state.kind === 'cancelled') {
    title = 'Sync cancelled'
    copy =
      'This attempt stopped before any new music was saved. Your previous completed songs and playlists are unchanged.'
    status = 'Cancelled'
    action = 'Start again'
  }
  if (state.kind === 'error') {
    status = 'Not saved'
    tone = 'err'
    action = 'Retry sync'
    title = 'Connection lost'
    copy =
      'This attempt stopped before saving changes. Your previous completed music is still available. Reconnect, then try again.'
    if (state.failure === 'permission') {
      title = 'Apple Music wasn’t connected'
      copy =
        'You can try the permission step again whenever you’re ready. Your Mixtape account and previously synced music are unchanged.'
      action = 'Try connecting again'
    }
    if (state.failure === 'unavailable') {
      title = 'Apple Music couldn’t load'
      copy =
        'Check your connection and try loading it again. You can still browse music already saved to your Mixtape account.'
    }
    if (state.failure === 'session') {
      title = 'Sign in again to sync'
      copy = 'Your Mixtape session has ended. Your previously saved music stays in your account.'
      action = 'Sign in again'
      perform = onSignIn
    }
  }
  if (result?.kind === 'complete') {
    title = 'Your music is in'
    copy = 'Your songs and playlists are ready to browse and use in Mixtape.'
    status = 'Sync complete'
    tone = 'ok'
    action = 'Browse playlists'
    perform = () => {
      run.reset()
      onBrowse()
    }
  }
  if (result?.kind === 'partial') {
    title = 'Songs saved. Playlists need another try.'
    copy =
      'The new songs are available. We’ve kept your previous completed playlists because this playlist sync didn’t finish.'
    status = 'Partly complete'
    action = 'Retry sync'
  }
  if (result?.kind === 'unconfirmed') {
    title = 'Checking what was saved'
    copy =
      'We lost the confirmation from the server. This sync may have saved changes; check before starting another upload.'
    status = 'Result unconfirmed'
    action = 'Check again'
    perform = run.check
  }
  if (result && result.kind !== 'complete' && result.failure === 'session') {
    action = 'Sign in again'
    perform = onSignIn
  }
  const upload = progress?.stage === 'uploading_library' || progress?.stage === 'uploading_playlists'
  const noun =
    progress?.stage === 'uploading_playlists' || progress?.stage === 'playlist_tracks'
      ? 'playlist entries'
      : progress?.stage === 'playlists'
        ? 'playlists'
        : progress?.stage === 'recent_tracks'
          ? 'recent tracks'
          : 'songs'
  const songs = result?.kind === 'complete' ? result.songs : result?.library?.songs
  return (
    <div className="ym-work">
      <button className="btn ym-back" onClick={onSources}>
        ← Sources
      </button>
      <header className="ym-work-head">
        <p className="quiet-kicker">Your music</p>
        <h2>Apple Music</h2>
        <p>Sync songs and playlists into Mixtape.</p>
      </header>
      {running ? (
        <div className="ym-steps">
          <span>Read music</span>
          <span>Save songs</span>
          <span>Save playlists</span>
        </div>
      ) : null}
      <section className="card ym-stage" aria-live="polite" aria-atomic="true">
        <span className={`status-chip ${tone}`}>{status}</span>
        <h3>{title}</h3>
        <p>{copy}</p>
        {progress &&
        !['authorizing', 'saving_library', 'saving_playlists', 'complete'].includes(progress.stage) ? (
          <>
            {upload && progress.total !== undefined && progress.total > 0 ? (
              <progress value={progress.completed} max={progress.total} aria-label={`${noun} uploaded`} />
            ) : null}
            <p className="ym-stage-line">
              {progress.completed.toLocaleString()}
              {progress.total !== undefined ? ` of ${progress.total.toLocaleString()}` : ''} {noun}{' '}
              {upload ? 'uploaded' : 'read'}
              {!upload && progress.total === undefined ? ' · total not known yet' : ''}
              {upload && progress.total
                ? ` · ${Math.floor((progress.completed / progress.total) * 100)}% of ${noun}`
                : ''}
            </p>
          </>
        ) : null}
        {songs !== undefined ? (
          <div className="ym-metrics">
            <div>
              <strong>{songs.toLocaleString()}</strong>
              <span>songs saved</span>
            </div>
            <div>
              <strong>
                {result?.kind === 'complete'
                  ? result.playlists.toLocaleString()
                  : result?.kind === 'unconfirmed' && result.stage === 'playlists'
                    ? 'Unconfirmed'
                    : 'Unchanged'}
              </strong>
              <span>{result?.kind === 'complete' ? 'playlists saved' : 'previous playlists'}</span>
            </div>
          </div>
        ) : null}
        {!running && !result && summary?.apple.librarySyncedAt ? (
          <p className="ym-small">
            {summary.apple.songs !== null ? `${summary.apple.songs.toLocaleString()} songs · ` : ''}
            {summary.apple.playlists} playlists
            <br />
            Last completed songs sync · {musicDate(summary.apple.librarySyncedAt)}
          </p>
        ) : null}
        {!running && !result ? (
          <p className="ym-notice">
            This won’t change your Apple library or create playlists. Apple Music on the web doesn’t provide
            lifetime play counts, so we won’t invent them.
          </p>
        ) : null}
        {result?.kind === 'complete' && result.excludedLibrarySongs > 0 ? (
          <p className="ym-notice">
            {result.excludedLibrarySongs} local or unavailable songs couldn’t be added as playable catalog
            tracks. Their playlist entries are still shown, in order.
          </p>
        ) : null}
        {result?.kind === 'unconfirmed' ? (
          <p className="ym-notice">
            Keep this tab open while we confirm the result.
            {result.failure === 'conflict'
              ? ' The server could not confirm this older run. Another device may have replaced it; browse saved music before trying again.'
              : ''}
          </p>
        ) : null}
        <div className="btn-row">
          {!running ? (
            <button className="btn primary" disabled={busy} onClick={perform}>
              {action}
            </button>
          ) : null}
          <button
            className="btn"
            onClick={result?.kind === 'complete' ? () => {
              run.reset()
              onSources()
            } : onBrowse}
          >
            {result?.kind === 'complete' ? 'Back to sources' : 'Browse saved music'}
          </button>
          {busy ? (
            <button className="btn" onClick={onSpotify}>
              View Spotify import
            </button>
          ) : null}
          {running ? (
            <button className="btn" disabled={state.kind === 'cancelling'} onClick={run.cancel}>
              {state.kind === 'cancelling' ? 'Stopping…' : 'Cancel sync'}
            </button>
          ) : null}
        </div>
      </section>
    </div>
  )
}
