import { useEffect, useRef, useState, useSyncExternalStore } from 'react'
import type { MixtapeApi, PlaybackPreferences } from '../api/client'
import type { PlaybackController } from '../playback/controller'
import { useRestorableState, useWorkspaceRestoring } from '../lib/workspace-restore'
import { PlaybackPanel } from './PlaybackPanel'
import { ControlModal } from './ControlModal'
import { PRIVACY_POLICY_URL } from './AiConsent'

type Props = {
  api: MixtapeApi
  playback: PlaybackController
  userName: string
  signInMethod: string | null
  onAccount: () => void
  onMemories: () => void
  onSignOut: () => void
  /** After DELETE /me succeeds: clear local state without a server sign-out (every session is gone). */
  onAccountDeleted: () => void
  /** An anonymous listener: one sign-in row instead of the identity block, no Sign out. */
  anonymous?: boolean
  /** The anonymous row: opens the sign-in page. */
  onSignIn?: () => void
}

export const SIGN_IN_ROW = 'Sign in to keep your mixes'

export function AppSettings({
  api,
  playback,
  userName,
  signInMethod,
  onAccount,
  onMemories,
  onSignOut,
  onAccountDeleted,
  anonymous = false,
  onSignIn,
}: Props) {
  const player = useSyncExternalStore(playback.subscribe, playback.getState)
  const [enabled, setEnabled] = useRestorableState<boolean | null>('settings.recommendations', null)
  const restoring = useWorkspaceRestoring()
  const [lastPlaybackPreferences, setLastPlaybackPreferences] = useRestorableState<PlaybackPreferences | null>('settings.playback', null)
  const displayedPlaybackPreferences = player.preferences ?? lastPlaybackPreferences
  useEffect(() => {
    if (player.preferences && !restoring) setLastPlaybackPreferences(player.preferences)
  }, [player.preferences, restoring, setLastPlaybackPreferences])
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [message, setMessage] = useState('')
  const [reload, setReload] = useState(0)
  const [deleting, setDeleting] = useState(false)
  const [reading, setReading] = useState(true)
  const mounted = useRef(true)

  useEffect(() => {
    if (restoring) return
    mounted.current = true
    let cancelled = false
    setReading(true)
    setError('')
    void api.getSuggestions(Intl.DateTimeFormat().resolvedOptions().timeZone)
      .then(result => {
        if (!cancelled) setEnabled(result.enabled)
      })
      .catch(() => {
        if (!cancelled) setError('Couldn’t load recommendation preferences.')
      })
      .finally(() => {
        if (!cancelled) setReading(false)
      })
    return () => {
      cancelled = true
      mounted.current = false
    }
  }, [api, reload, restoring])

  async function save(kind: 'learning' | 'recommendations', value: boolean) {
    if (busy || restoring || (kind === 'learning' && !player.preferences)) return
    setBusy(true)
    setError('')
    setMessage('')
    try {
      if (kind === 'learning') {
        await playback.preference(value)
      } else {
        const result = await api.saveSuggestionPreference(value)
        if (mounted.current) setEnabled(result.enabled)
      }
      if (mounted.current) setMessage('Listening preferences saved.')
    } catch {
      if (mounted.current) {
        setError('Couldn’t confirm the change. Retry to check your current preferences.')
      }
    } finally {
      if (mounted.current) setBusy(false)
    }
  }

  const privacyRow = (
    <div className="setting-row setting-row--action">
      <a className="wc-text settings-link" href={PRIVACY_POLICY_URL} target="_blank" rel="noopener noreferrer">Privacy policy</a>
    </div>
  )

  return (
    <main className="app-settings">
      <h1>Settings</h1>
      {anonymous ? (
        <button type="button" className="settings-sign-in-row" onClick={onSignIn}>
          <span>{SIGN_IN_ROW}</span>
          <svg viewBox="0 0 24 24" aria-hidden="true"><path d="m9 6 6 6-6 6" /></svg>
        </button>
      ) : null}
      {error && (
        <div className="home-inline-error" role="alert">
          <span>{error}</span>
          <button
            className="minimal-retry" disabled={busy}
            onClick={() => {
              setReload(n => n + 1)
              void playback.initialize()
            }}
          >
            Retry
          </button>
        </div>
      )}
      {message && <p role="status">{message}</p>}
      <section>
        <h2>Listening preferences</h2>
        <label className="setting-row">
          <span>
            <strong>Learn from my listening</strong>
            <small>Use playback in Mixtape to improve future mixes.</small>
          </span>
          <input
            type="checkbox"
            checked={displayedPlaybackPreferences?.enabled ?? false}
            disabled={busy || restoring || !player.preferences}
            onChange={e => void save('learning', e.target.checked)}
          />
        </label>
        {!player.preferences && !busy && !restoring && (
          <div className="home-inline-error">
            <span>Listening preferences are unavailable.</span>
            <button className="minimal-retry" disabled={busy} onClick={() => void playback.initialize()}>
              Retry
            </button>
          </div>
        )}
        <label className="setting-row">
          <span>
            <strong>Recommend mixes</strong>
            <small>Suggest a mix when a familiar listening moment comes around.</small>
          </span>
          <input
            type="checkbox"
            checked={enabled ?? false}
            disabled={busy || reading || restoring || enabled === null}
            onChange={e => void save('recommendations', e.target.checked)}
          />
        </label>
        <div className="setting-row">
          <span>
            <strong>Remembered preferences</strong>
            <small>Review what you’ve asked the DJ to remember.</small>
          </span>
          <button className="wc-text" onClick={onMemories}>Manage</button>
        </div>
        <div className="setting-row">
          <span>
            <strong>Listening history controls</strong>
            <small>Review or clear the activity used for learning.</small>
          </span>
          <PlaybackPanel controller={playback} settingsOnly />
        </div>
      </section>
      {anonymous ? <section>{privacyRow}</section> : <section>
        <h2>Account</h2>
        <div className="setting-row">
          <span>
            <strong>{userName}</strong>
            <small>
              {signInMethod
                ? `Signed in with ${signInMethod === 'apple' ? 'Apple' : 'Google'}`
                : 'Mixtape account'}
            </small>
          </span>
          <button className="wc-text" onClick={onAccount}>Manage account</button>
        </div>
        <div className="setting-row">
          <span>Sign out of Mixtape</span>
          <button className="wc-text" onClick={onSignOut}>Sign out</button>
        </div>
        {privacyRow}
        <div className="setting-row setting-row--action">
          <button className="wc-text wc-danger" onClick={() => setDeleting(true)}>Delete account</button>
        </div>
      </section>}
      {deleting && (
        <DeleteAccountDialog
          deleteAccount={() => api.deleteAccount()}
          onDeleted={onAccountDeleted}
          onClose={() => setDeleting(false)}
        />
      )}
    </main>
  )
}

export const DELETE_ACCOUNT_FAILED = 'Couldn’t delete your account. Try again.'

/** The one destructive confirmation; copy is fixed by the account-deletion plan. */
export function DeleteAccountDialog({
  deleteAccount,
  onDeleted,
  onClose,
}: {
  deleteAccount: () => Promise<unknown>
  onDeleted: () => void
  onClose: () => void
}) {
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const inFlight = useRef(false)
  const mounted = useRef(true)
  useEffect(() => {
    mounted.current = true
    return () => { mounted.current = false }
  }, [])

  async function confirm() {
    if (inFlight.current) return
    inFlight.current = true
    setBusy(true)
    setError('')
    try {
      await deleteAccount()
    } catch {
      inFlight.current = false
      if (mounted.current) {
        setBusy(false)
        setError(DELETE_ACCOUNT_FAILED)
      }
      return
    }
    onDeleted()
  }

  return (
    <ControlModal title="Delete your account?" alert onClose={() => { if (!inFlight.current) onClose() }}>
      <p>
        This permanently deletes your mixes, library, memories and listening history from Mixtape. Your Apple Music
        and Spotify libraries are not touched.
      </p>
      {error && <p className="wc-danger" role="alert">{error}</p>}
      <div className="wc-actions">
        <button className="wc-text" disabled={busy} onClick={onClose}>Cancel</button>
        <button className="wc-text wc-danger" disabled={busy} onClick={() => void confirm()}>
          {busy ? 'Deleting…' : 'Delete account'}
        </button>
      </div>
    </ControlModal>
  )
}
