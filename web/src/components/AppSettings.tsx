import { useEffect, useId, useRef, useState, useSyncExternalStore } from 'react'
import type { MixtapeApi, PlaybackPreferences } from '../api/client'
import type { PlaybackController } from '../playback/controller'
import { useRestorableState, useWorkspaceRestoring } from '../lib/workspace-restore'
import { PlaybackPanel } from './PlaybackPanel'
import { ControlModal } from './ControlModal'
import './account-name.css'

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
  /** Writes the name (blank removes it) and resolves once the session shows it; no Edit name without it. */
  saveName?: (name: string) => Promise<void>
  /** ?ui-preview only: open with the name field already in this state. */
  initialNameEdit?: NameEdit
}

export type NameEdit = { draft: string; failed?: boolean }

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
  saveName,
  initialNameEdit,
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
      {anonymous ? null : <section>
        <h2>Account</h2>
        <AccountName
          name={userName}
          signedInWith={signInMethod
            ? `Signed in with ${signInMethod === 'apple' ? 'Apple' : 'Google'}`
            : 'Mixtape account'}
          onAccount={onAccount}
          saveName={saveName}
          initialEdit={initialNameEdit}
        />
        <div className="setting-row">
          <span>Sign out of Mixtape</span>
          <button className="wc-text" onClick={onSignOut}>Sign out</button>
        </div>
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

export const NAME_LIMIT = 40
export const NAME_SAVE_FAILED = 'Couldn’t save your name.'

/**
 * What the field accepts: line breaks and tabs become spaces, other control
 * and format characters go, and input stops at 40 characters by code point so
 * an emoji is never split. The server applies the full rule again on save.
 */
export function limitNameInput(value: string): { value: string; cut: boolean } {
  const cleaned = value.replace(/[\r\n\t]/g, ' ').replace(/[\p{Cc}\p{Cf}]/gu, '')
  const characters = Array.from(cleaned)
  return { value: characters.slice(0, NAME_LIMIT).join(''), cut: characters.length > NAME_LIMIT }
}

const nameLength = (value: string) => Array.from(value).length

/** Settings › Account identity row: the name (or "Your account") and its inline editor. */
function AccountName({
  name,
  signedInWith,
  onAccount,
  saveName,
  initialEdit,
}: {
  name: string
  signedInWith: string
  onAccount: () => void
  saveName?: (name: string) => Promise<void>
  initialEdit?: NameEdit
}) {
  const named = name.trim() !== ''
  const [draft, setDraft] = useState<string | null>(initialEdit?.draft ?? null)
  const [saving, setSaving] = useState(false)
  const [failed, setFailed] = useState(initialEdit?.failed ?? false)
  const [cut, setCut] = useState(false)
  const [announcement, setAnnouncement] = useState('')
  const hintId = useId()
  const field = useRef<HTMLInputElement>(null)
  const editButton = useRef<HTMLButtonElement>(null)
  const saveButton = useRef<HTMLButtonElement>(null)
  const focusAfter = useRef<'field' | 'edit' | 'retry' | null>(initialEdit ? (initialEdit.failed ? 'retry' : 'field') : null)
  const inFlight = useRef(false)
  const mounted = useRef(true)
  useEffect(() => {
    mounted.current = true
    return () => { mounted.current = false }
  }, [])

  useEffect(() => {
    const target = focusAfter.current
    focusAfter.current = null
    if (target === 'field' && field.current) {
      const input = field.current
      input.focus()
      input.setSelectionRange(input.value.length, input.value.length)
    }
    if (target === 'edit') editButton.current?.focus()
    if (target === 'retry') saveButton.current?.focus()
  })

  function open() {
    setAnnouncement('')
    setFailed(false)
    setCut(false)
    setDraft(name)
    focusAfter.current = 'field'
  }

  function close() {
    if (inFlight.current) return
    setDraft(null)
    setFailed(false)
    focusAfter.current = 'edit'
  }

  async function save() {
    if (inFlight.current || draft === null || !saveName) return
    const next = draft.trim()
    inFlight.current = true
    setSaving(true)
    setFailed(false)
    try {
      await saveName(next)
    } catch {
      inFlight.current = false
      if (mounted.current) {
        setSaving(false)
        setFailed(true)
        focusAfter.current = 'retry'
      }
      return
    }
    inFlight.current = false
    if (!mounted.current) return
    setSaving(false)
    setDraft(null)
    setAnnouncement(next === '' ? 'Name removed' : 'Name saved')
    focusAfter.current = 'edit'
  }

  const length = draft === null ? 0 : nameLength(draft)
  const hint = cut || length >= NAME_LIMIT
    ? 'Names stop at 40 characters.'
    : draft?.trim() === ''
      ? 'Saving a blank name removes it.'
      : 'Up to 40 characters. Leave it blank to remove your name.'

  // One status element for both modes, so the announcement lands in a live region that already exists.
  return <>
    {draft === null ? (
      <div key="name" className="setting-row account-name">
        <span>
          <strong>{named ? name : 'Your account'}</strong>
          <small>{signedInWith}</small>
        </span>
        <span className="setting-row-actions">
          {saveName ? (
            <button ref={editButton} className="wc-text" aria-label={named ? undefined : 'Add your name'} onClick={open}>
              {named ? 'Edit name' : 'Add name'}
            </button>
          ) : null}
          <button className="wc-text" onClick={onAccount}>Manage account</button>
        </span>
      </div>
    ) : (
      <div key="edit" className="setting-row account-name account-name--editing">
        <span className="account-name-edit">
          <input
            ref={field}
            className="account-name-field"
            aria-label="Your name"
            aria-describedby={hintId}
            aria-invalid={failed || undefined}
            placeholder="Your name"
            autoComplete="name"
            spellCheck={false}
            value={draft}
            readOnly={saving}
            onChange={(event) => {
              const limited = limitNameInput(event.target.value)
              setDraft(limited.value)
              setCut(limited.cut)
            }}
            onKeyDown={(event) => {
              if (event.key === 'Enter') {
                event.preventDefault()
                void save()
              }
              if (event.key === 'Escape') {
                event.preventDefault()
                close()
              }
            }}
          />
          {saving ? (
            <small id={hintId} role="status">Saving…</small>
          ) : failed ? (
            <small id={hintId} className="account-name-error" role="alert">
              <svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="9" /><path d="M12 7.5v6M12 17h.01" /></svg>
              {NAME_SAVE_FAILED}
            </small>
          ) : (
            <small id={hintId}>
              {hint}
              {length >= 30 ? <span className="account-name-count"> {length} of {NAME_LIMIT}</span> : null}
            </small>
          )}
        </span>
        <span className="setting-row-actions">
          <button ref={saveButton} className="wc-text account-name-save" disabled={saving} onClick={() => void save()}>
            {failed ? 'Retry' : 'Save'}
          </button>
          <button className="wc-text" disabled={saving} onClick={close}>Cancel</button>
        </span>
      </div>
    )}
    <p className="sr-only" role="status">{announcement}</p>
  </>
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
