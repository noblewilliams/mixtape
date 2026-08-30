import { PlayIcon, PlusIcon } from './Icons'
import type { ReactNode } from 'react'

type PlayButtonProps = {
  playing: boolean
  disabled?: boolean
  onClick: () => void
}

export function PlayButton({ playing, disabled = false, onClick }: PlayButtonProps) {
  return (
    <button
      className={`transport-button ${playing ? 'is-playing' : ''}`}
      type="button"
      disabled={disabled}
      onClick={onClick}
      aria-label={playing ? 'Pause tape' : 'Play tape'}
    >
      <span className="transport-reel" aria-hidden="true">
        <PlayIcon paused={playing} />
      </span>
      <span>{playing ? 'Pause tape' : 'Play tape'}</span>
      <span className="transport-meter" aria-hidden="true" />
    </button>
  )
}

type LabelButtonProps = {
  children: ReactNode
  onClick: () => void
  disabled?: boolean
  className?: string
  ariaLabel?: string
}

export function LabelButton({ children, onClick, disabled = false, className = '', ariaLabel }: LabelButtonProps) {
  return (
    <button
      className={`label-button ${className}`.trim()}
      type="button"
      disabled={disabled}
      onClick={onClick}
      aria-label={ariaLabel}
    >
      <span className="label-button-hole" aria-hidden="true" />
      <span>{children}</span>
    </button>
  )
}

export function NewTapeCompactButton({ onClick }: { onClick: () => void }) {
  return (
    <button className="compact-new-tape" type="button" onClick={onClick} aria-label="Make a new tape">
      <PlusIcon />
      <span>New tape</span>
    </button>
  )
}
