import { useEffect, useId, useLayoutEffect, useRef, useState, useSyncExternalStore } from 'react'
import type { MixtapeApi, PlaybackPreferences } from '../api/client'
import type { PlaybackController } from '../playback/controller'
import { useRestorableState, useWorkspaceRestoring } from '../lib/workspace-restore'
import { PlaybackPanel } from './PlaybackPanel'
import { ControlModal } from './ControlModal'
import './account-name.css'
import { applyNameEdit, nameLength, normalizeProfileName, PROFILE_NAME_MAX } from '../lib/profile-name'
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

export const NAME_SAVE_FAILED = 'Couldn’t save your name.'
// Long enough for a screen reader to read the newly focused Edit name first.
const ANNOUNCE_AFTER_FOCUS_MS = 250

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
  // The saved name, shown until the session re-read brings a new `name`, so
  // "Name saved" is never announced beside the old one.
  const [saved, setSaved] = useState<string | null>(null)
  const lastName = useRef(name)
  useEffect(() => {
    if (lastName.current === name) return
    lastName.current = name
    setSaved(null)
  }, [name])
  const shown = saved ?? name
  const named = shown.trim() !== ''
  const [draft, setDraft] = useState<string | null>(initialEdit?.draft ?? null)
  const [saving, setSaving] = useState(false)
  const [failed, setFailed] = useState(initialEdit?.failed ?? false)
  const [cut, setCut] = useState(false)
  const [announcement, setAnnouncement] = useState('')
  const [, setCaretTick] = useState(0)
  const hintId = useId()
  const field = useRef<HTMLInputElement>(null)
  const editButton = useRef<HTMLButtonElement>(null)
  const saveButton = useRef<HTMLButtonElement>(null)
  const focusAfter = useRef<'field' | 'edit' | 'retry' | null>(initialEdit ? (initialEdit.failed ? 'retry' : 'field') : null)
  const pendingCaret = useRef<number | null>(null)
  // The draft when an IME composition began; the limit applies when it ends.
  const composeFrom = useRef<string | null>(null)
  const announceTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined)
  const inFlight = useRef(false)
  const mounted = useRef(true)
  useEffect(() => {
    mounted.current = true
    return () => {
      mounted.current = false
      clearTimeout(announceTimer.current)
    }
  }, [])

  useLayoutEffect(() => {
    const caret = pendingCaret.current
    pendingCaret.current = null
    if (caret !== null && field.current) field.current.setSelectionRange(caret, caret)
  })
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
    clearTimeout(announceTimer.current)
    setAnnouncement('')
    setFailed(false)
    setCut(false)
    setDraft(shown)
    focusAfter.current = 'field'
  }

  function close() {
    if (inFlight.current) return
    composeFrom.current = null
    setDraft(null)
    setFailed(false)
    focusAfter.current = 'edit'
  }

  function edit(prev: string, input: HTMLInputElement) {
    const result = applyNameEdit(prev, input.value, input.selectionEnd)
    setDraft(result.value)
    setCut(result.cut)
    if (result.value !== input.value) {
      pendingCaret.current = result.caret
      setCaretTick(tick => tick + 1)
    }
  }

  async function save() {
    if (inFlight.current || draft === null || !saveName) return
    const next = normalizeProfileName(draft)
    inFlight.current = true
    clearTimeout(announceTimer.current)
    setSaving(true)
    setFailed(false)
    setAnnouncement('Saving…')
    try {
      await saveName(next)
    } catch {
      inFlight.current = false
      if (mounted.current) {
        setSaving(false)
        setFailed(true)
        setAnnouncement('')
        focusAfter.current = 'retry'
      }
      return
    }
    inFlight.current = false
    if (!mounted.current) return
    setSaving(false)
    setDraft(null)
    if (next !== name) setSaved(next)
    setAnnouncement('')
    focusAfter.current = 'edit'
    announceTimer.current = setTimeout(() => {
      if (mounted.current) setAnnouncement(next === '' ? 'Name removed' : 'Name saved')
    }, ANNOUNCE_AFTER_FOCUS_MS)
  }

  const length = draft === null ? 0 : nameLength(draft)
  const hint = cut || length >= PROFILE_NAME_MAX
    ? 'Names stop at 40 characters.'
    : draft?.trim() === ''
      ? 'Saving a blank name removes it.'
      : 'Up to 40 characters. Leave it blank to remove your name.'

  // One status element for both modes, so announcements land in a live region that already exists.
  return <>
    {draft === null ? (
      <div key="name" className="setting-row account-name">
        <span>
          <strong>{named ? shown : 'Your account'}</strong>
          <small>{signedInWith}</small>
        </span>
        <span className="setting-row-actions">
          {saveName ? (
            <button ref={editButton} className="wc-text" onClick={open}>
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
            onCompositionStart={() => { composeFrom.current = draft }}
            onCompositionEnd={(event) => {
              const from = composeFrom.current ?? draft
              composeFrom.current = null
              edit(from, event.currentTarget)
            }}
            onChange={(event) => {
              setFailed(false)
              const composing = composeFrom.current !== null || (event.nativeEvent as InputEvent).isComposing
              if (composing) setDraft(event.target.value)
              else edit(draft, event.target)
            }}
            onKeyDown={(event) => {
              if (event.nativeEvent.isComposing || event.keyCode === 229 || composeFrom.current !== null) return
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
            <small id={hintId}>Saving…</small>
          ) : failed ? (
            <small id={hintId} className="account-name-error" role="alert">
              <svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="9" /><path d="M12 7.5v6M12 17h.01" /></svg>
              {NAME_SAVE_FAILED}
            </small>
          ) : (
            <small id={hintId}>
              {hint}
              {length >= 30 ? <span className="account-name-count"> {length} of {PROFILE_NAME_MAX}</span> : null}
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
