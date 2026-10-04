import { useEffect, useRef, useState, useSyncExternalStore } from 'react'
import type { MixtapeApi, PlaybackPreferences } from '../api/client'
import type { PlaybackController } from '../playback/controller'
import { useRestorableState, useWorkspaceRestoring } from '../lib/workspace-restore'
import { PlaybackPanel } from './PlaybackPanel'

type Props = {
  api: MixtapeApi
  playback: PlaybackController
  userName: string
  signInMethod: string | null
  onAccount: () => void
  onMemories: () => void
  onSignOut: () => void
}

export function AppSettings({
  api,
  playback,
  userName,
  signInMethod,
  onAccount,
  onMemories,
  onSignOut,
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

  return (
    <main className="app-settings">
      <h1>Settings</h1>
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
      <section>
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
      </section>
    </main>
  )
}
