import { useRef, type KeyboardEvent } from 'react'
import type { SessionKind } from '../domain'

const options: { id: SessionKind; label: string }[] = [{ id: 'mix', label: 'Mix' }, { id: 'album', label: 'Album' }]

export function ModeControl({ value, onChange, disabled = false }: { value: SessionKind; onChange: (mode: SessionKind) => void; disabled?: boolean }) {
  const buttons = useRef<(HTMLButtonElement | null)[]>([])
  function onKeyDown(event: KeyboardEvent, index: number) {
    const step = event.key === 'ArrowRight' || event.key === 'ArrowDown' ? 1 : event.key === 'ArrowLeft' || event.key === 'ArrowUp' ? -1 : 0
    if (!step) return
    event.preventDefault()
    const next = (index + step + options.length) % options.length
    onChange(options[next].id)
    buttons.current[next]?.focus()
  }
  return <div className="mode-control" data-mode={value} role="radiogroup" aria-label="What to make">
    {options.map((option, index) => <button key={option.id} ref={node => { buttons.current[index] = node }} type="button" role="radio"
      aria-checked={value === option.id} tabIndex={value === option.id ? 0 : -1} disabled={disabled}
      onClick={() => onChange(option.id)} onKeyDown={event => onKeyDown(event, index)}>{option.label}</button>)}
  </div>
}
