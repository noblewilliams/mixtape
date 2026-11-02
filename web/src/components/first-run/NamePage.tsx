import { useEffect, useId, useLayoutEffect, useRef, useState, type CSSProperties } from 'react'
import { ErrorCircleIcon } from '../Icons'
import { NAME_SAVE_FAILED } from '../AppSettings'
import { applyNameEdit, nameLength, normalizeProfileName, PROFILE_NAME_MAX } from '../../lib/profile-name'
import { backgroundUrl, FastForwardGlyph, FirstRunPage } from './FirstRunPage'

export const NAME_PAGE_HEADLINE = 'What should we call you?'
export const NAME_PAGE_LINE = 'It shows in Settings, and the DJ may use it now and then.'
const CAP_LINE = 'Names stop at 40 characters.'

/** ?ui-preview only: open with the field (and the pill) already in this state. */
export type NamePageInitial = { draft: string; saving?: boolean; failed?: boolean }

type Props = {
  /** Writes the name and the asked flag; resolves once the session shows it. */
  saveName: (name: string) => Promise<void>
  onSaved: () => void
  /** Moves on at once; the caller records the flag and lets any running save finish. */
  onSkip: () => void
  initial?: NamePageInitial
}

/**
 * "What should we call you?" (board 2026-11-02 profile name, NW1 to NW6):
 * shown once after a sign-in that leaves the account with no usable name.
 * No back (the listener is signed in; Skip is the way past) and no autofocus
 * (one tap raises the keyboard). Continue keeps focus while dimmed.
 */
export function NamePage({ saveName, onSaved, onSkip, initial }: Props) {
  const [draft, setDraft] = useState(initial?.draft ?? '')
  const [saving, setSaving] = useState(initial?.saving ?? false)
  const [failed, setFailed] = useState(initial?.failed ?? false)
  const [cut, setCut] = useState(false)
  const [, setCaretTick] = useState(0)
  const hintId = useId()
  const countId = useId()
  const statusId = useId()
  const field = useRef<HTMLInputElement>(null)
  const pill = useRef<HTMLButtonElement>(null)
  const focusPill = useRef(initial?.failed ?? false)
  const pendingCaret = useRef<number | null>(null)
  // The draft when an IME composition began; the limit applies when it ends.
  const composeFrom = useRef<string | null>(null)
  const inFlight = useRef(false)
  const mounted = useRef(true)
  useEffect(() => {
    mounted.current = true
    return () => { mounted.current = false }
  }, [])

  useEffect(() => {
    const before = document.title
    document.title = NAME_PAGE_HEADLINE
    return () => { document.title = before }
  }, [])

  useLayoutEffect(() => {
    const caret = pendingCaret.current
    pendingCaret.current = null
    if (caret !== null && field.current) field.current.setSelectionRange(caret, caret)
  })
  useEffect(() => {
    if (!focusPill.current) return
    focusPill.current = false
    pill.current?.focus()
  })

  const name = normalizeProfileName(draft)
  const ready = name !== ''
  const length = nameLength(draft)
  const atCap = cut || length >= PROFILE_NAME_MAX

  function edit(prev: string, input: HTMLInputElement) {
    const result = applyNameEdit(prev, input.value, input.selectionEnd)
    setDraft(result.value)
    setCut(result.cut)
    if (result.value !== input.value) {
      pendingCaret.current = result.caret
      setCaretTick((tick) => tick + 1)
    }
  }

  async function submit() {
    if (inFlight.current || saving || !ready) return
    inFlight.current = true
    setSaving(true)
    setFailed(false)
    try {
      await saveName(name)
    } catch {
      inFlight.current = false
      if (mounted.current) {
        setSaving(false)
        setFailed(true)
        focusPill.current = true
      }
      return
    }
    inFlight.current = false
    if (mounted.current) onSaved()
  }

  return (
    <FirstRunPage background="sign-in" headline={NAME_PAGE_HEADLINE} focusHeading={!initial?.failed}>
      <p className="fr-line">{NAME_PAGE_LINE}</p>
      <form
        className="fr-nform"
        noValidate
        onSubmit={(event) => {
          event.preventDefault()
          void submit()
        }}
      >
        <div className="fr-nfield">
          <input
            ref={field}
            type="text"
            aria-label="Your name"
            aria-describedby={`${length >= 30 ? `${countId} ` : ''}${statusId}`}
            aria-invalid={failed || undefined}
            placeholder="Your name"
            autoComplete="name"
            autoCapitalize="words"
            autoCorrect="off"
            spellCheck={false}
            enterKeyHint="done"
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
              // Enter that ends an IME composition picks the candidate, never Continue.
              if (event.key === 'Enter' && (event.nativeEvent.isComposing || event.keyCode === 229 || composeFrom.current !== null)) {
                event.preventDefault()
              }
            }}
          />
          {length >= 30 ? <span className="fr-ncount" id={countId}>{length} of {PROFILE_NAME_MAX}</span> : null}
        </div>
        {failed ? (
          <p className="fr-status fr-status--err fr-nstatus" id={statusId} role="alert">
            <ErrorCircleIcon className="fr-status-icon" />{NAME_SAVE_FAILED}
          </p>
        ) : (
          <p className="fr-status fr-nstatus" id={statusId} aria-live="polite">{atCap ? CAP_LINE : ''}</p>
        )}
        <div className="fr-acts">
          {saving ? (
            <button ref={pill} type="button" className="fr-pill fr-pill--go fr-pill--busy" aria-busy="true">
              Saving<span className="fr-dots" aria-hidden="true"><i /><i /><i /></span>
            </button>
          ) : failed ? (
            <button ref={pill} type="submit" className="fr-pill fr-pill--go">Retry</button>
          ) : (
            <button
              ref={pill}
              type="submit"
              className={`fr-pill fr-pill--go${ready ? '' : ' fr-pill--off'}`}
              aria-disabled={ready ? undefined : true}
              aria-describedby={ready ? undefined : hintId}
            >
              Continue<FastForwardGlyph hollow={!ready} />
            </button>
          )}
        </div>
        <span className="sr-only" id={hintId}>Type a name.</span>
      </form>
      <p className="fr-foot">
        <button type="button" className="fr-link" onClick={onSkip}>Skip</button>
      </p>
    </FirstRunPage>
  )
}

/** The sign-in image alone, over the workspace while GET /me decides whether to ask. */
export function NamePageHold() {
  const style = { '--fr-bg': `url("${backgroundUrl('sign-in')}")` } as CSSProperties
  return <main className="fr-page fr-page--sign-in fr-hold" style={style} aria-busy="true" aria-label="Mixtape" data-testid="name-page-hold" />
}
