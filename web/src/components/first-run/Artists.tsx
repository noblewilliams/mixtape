import { useId, useRef, useState } from 'react'
import { CloseIcon } from '../Icons'
import { FirstRunPage, Pill } from './FirstRunPage'

export const ARTISTS_HEADLINE = 'Who do you love?'
export const ARTISTS_LINE = 'Three artists is enough. The DJ borrows from the shared catalogue until your music is in.'
const PLACEHOLDERS = ['First artist', 'Second artist', 'Third artist'] as const

type Field = { value: string; chip: boolean }

type Props = {
  /** Chips kept from an earlier visit (back from a later page). */
  initial?: string[]
  onContinue: (names: string[]) => void
  onBack: () => void
  busy?: boolean
  error?: string
  focusHeading?: boolean
}

/**
 * Three plain fields; each becomes a chip in place once entered (Enter or
 * leaving the field). Continue counts every filled field, so a third name
 * still being typed is enough.
 */
export function Artists({ initial = [], onContinue, onBack, busy = false, error, focusHeading }: Props) {
  const hint = useId()
  const form = useRef<HTMLFormElement>(null)
  const [fields, setFields] = useState<Field[]>(() =>
    PLACEHOLDERS.map((_, index) => ({ value: initial[index] ?? '', chip: Boolean(initial[index]?.trim()) })),
  )
  const names = fields.map((field) => field.value.trim()).filter(Boolean)
  const ready = names.length >= 3 && !busy
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
        onSubmit={(event) => {
          event.preventDefault()
          if (ready) onContinue(names)
        }}
      >
        {fields.map((field, index) => (
          <div className="fr-afield" key={PLACEHOLDERS[index]}>
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
              <input
                type="text"
                aria-label={PLACEHOLDERS[index]}
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
            )}
          </div>
        ))}
        {error ? <p className="fr-status fr-status--err" role="alert">{error}</p> : null}
        <div className="fr-acts">
          <Pill type="submit" go disabled={!ready} describedBy={ready ? undefined : hint}>Continue</Pill>
        </div>
        <span className="sr-only" id={hint}>Add three artists.</span>
      </form>
    </FirstRunPage>
  )
}
