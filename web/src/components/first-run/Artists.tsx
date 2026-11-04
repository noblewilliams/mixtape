import { useId, useRef, useState } from 'react'
import { CloseIcon } from '../Icons'
import { FirstRunPage, Pill } from './FirstRunPage'

export const ARTISTS_HEADLINE = 'Who do you love?'
export const ARTISTS_LINE = 'Name a few and the DJ tailors your mix to them. Optional: skip and it works from what you asked for.'
export const ARTISTS_LABEL = 'Artists you love (optional)'
const PLACEHOLDERS = ['Type an artist', 'Another artist', 'One more'] as const
const NAMES = ['First artist', 'Second artist', 'Third artist'] as const

type Field = { value: string; chip: boolean }

type Props = {
  /** Chips kept from an earlier visit (back from a later page). */
  initial?: string[]
  /** Continue with what was entered; Skip for now sends none. */
  onContinue: (names: string[]) => void
  onBack: () => void
  busy?: boolean
  error?: string
  focusHeading?: boolean
}

/**
 * Three optional fields under a visible label; each becomes a chip in place
 * once entered (Enter or leaving the field). Continue counts every filled
 * field, so a name still being typed is enough; Skip for now goes on with none.
 */
export function Artists({ initial = [], onContinue, onBack, busy = false, error, focusHeading }: Props) {
  const hint = useId()
  const label = useId()
  const form = useRef<HTMLFormElement>(null)
  const [fields, setFields] = useState<Field[]>(() =>
    PLACEHOLDERS.map((_, index) => ({ value: initial[index] ?? '', chip: Boolean(initial[index]?.trim()) })),
  )
  const names = fields.map((field) => field.value.trim()).filter(Boolean)
  const ready = names.length > 0 && !busy
  const update = (index: number, next: Partial<Field>) =>
    setFields((current) => current.map((field, i) => (i === index ? { ...field, ...next } : field)))
  const commit = (index: number, advance = false) => {
    if (!fields[index].value.trim()) return
    update(index, { value: fields[index].value.trim(), chip: true })
    // The field became a chip; Enter carries on to the next empty one, or Continue.
    if (advance) {
      requestAnimationFrame(() => {
        const next = form.current?.querySelector<HTMLElement>('input') ?? form.current?.querySelector<HTMLElement>('button[type="submit"]')
        next?.focus()
      })
    }
  }
  return (
    <FirstRunPage background="artists" headline={ARTISTS_HEADLINE} onBack={onBack} focusHeading={focusHeading}>
      <p className="fr-line">{ARTISTS_LINE}</p>
      <form
        ref={form}
        className="fr-afields"
        aria-labelledby={label}
        onSubmit={(event) => {
          event.preventDefault()
          if (ready) onContinue(names)
        }}
      >
        <p className="fr-alabel" id={label}>{ARTISTS_LABEL}</p>
        {fields.map((field, index) => (
          <div className={`fr-afield${field.chip ? ' fr-afield--chip' : ''}`} key={NAMES[index]}>
            {field.chip ? (
              <span className="fr-achip">
                {field.value}
                <button
                  type="button"
                  className="fr-achip-x"
                  aria-label={`Remove ${field.value}`}
                  disabled={busy}
                  onClick={() => update(index, { value: '', chip: false })}
                >
                  <CloseIcon />
                </button>
              </span>
            ) : (
              <>
              <PenGlyph />
              <input
                type="text"
                aria-label={NAMES[index]}
                placeholder={PLACEHOLDERS[index]}
                maxLength={200}
                autoComplete="off"
                value={field.value}
                disabled={busy}
                onChange={(event) => update(index, { value: event.target.value })}
                onBlur={() => commit(index)}
                onKeyDown={(event) => {
                  if (event.key === 'Enter' && !event.nativeEvent.isComposing) {
                    event.preventDefault()
                    commit(index, true)
                  }
                }}
              />
              </>
            )}
          </div>
        ))}
        {error ? <p className="fr-status fr-status--err" role="alert">{error}</p> : null}
        <div className="fr-acts">
          <Pill type="submit" go disabled={!ready} describedBy={ready ? undefined : hint}>Continue</Pill>
        </div>
        <span className="sr-only" id={hint}>Add an artist, or skip for now.</span>
      </form>
      <p className="fr-foot">
        <button type="button" className="fr-link" disabled={busy} onClick={() => onContinue([])}>Skip for now</button>
      </p>
    </FirstRunPage>
  )
}

/** A small pencil: the field takes typing, unlike the paper pills around it. */
function PenGlyph() {
  return (
    <svg className="fr-afield-pen" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M4 20h4L19 9a2.8 2.8 0 0 0-4-4L4 16v4z" />
      <path d="m13.5 6.5 4 4" />
    </svg>
  )
}
