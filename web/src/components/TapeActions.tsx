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
      aria-label={playing ? 'Pause' : 'Play now'}
    >
      <span className="transport-reel" aria-hidden="true">
        <PlayIcon paused={playing} />
      </span>
      <span>{playing ? 'Pause' : 'Play now'}</span>
      <span className="transport-meter" aria-hidden="true" />
    </button>
  )
}

type ConnectMusicButtonProps = {
  state: 'disconnected' | 'connecting' | 'retry'
  onClick: () => void
}

export function ConnectMusicButton({ state, onClick }: ConnectMusicButtonProps) {
  const connecting = state === 'connecting'
  const retrying = state === 'retry'
  const label = connecting ? 'Connecting Apple Music…' : retrying ? 'Try Apple Music again' : 'Connect Apple Music'
  const detail = connecting
    ? 'Authorization is handled by Apple'
    : retrying
      ? 'A subscription is required for full playback'
      : 'Apple will ask for music access'

  return (
    <button
      className={`connect-music-button ${connecting ? 'is-connecting' : ''}`}
      type="button"
      aria-label={label}
      disabled={connecting}
      onClick={onClick}
    >
      <span className="connect-music-reel" aria-hidden="true" />
      <span>
        {label}
        <small>{detail}</small>
      </span>
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
