// Play on the shared mix page when this browser hasn't said where it listens
// (board docs/mockups/2026-11-13-shared-mixes.html, W4/W5), and a first Apple
// Music play: getting ready, then Connect Apple Music (decisions 2026-11-13,
// "a first Apple Music play takes a second tap"). Escape, Cancel and a click
// outside close it; focus returns to Play (ControlModal).
import type { PlaysOn } from '../lib/plays-on'
import { ControlModal } from './ControlModal'
import { ASK_TITLE, ServiceChoice } from './ServiceChoice'
import { ConnectMusicButton } from './TapeActions'
import './web-controls.css'

export type SharedPlayStep = 'choose' | 'readying' | 'connect' | 'failed'

const APPLE_TITLE = 'Apple Music'

type SharedPlayModalProps = {
  step?: SharedPlayStep
  onChoose: (choice: PlaysOn) => void
  /** Connect Apple Music: the click must reach authorize() before any await. */
  onConnect?: () => void
  onRetry?: () => void
  onClose: () => void
  /** The failure copy, the page's own (never the raw error). */
  failure?: string
}

export function SharedPlayModal({ step = 'choose', onChoose, onConnect, onRetry, onClose, failure }: SharedPlayModalProps) {
  const cancel = <button type="button" className="wc-text" onClick={onClose}>Cancel</button>
  // Keyed by step: each step mounts its own dialog, so focus lands on that
  // step's first stop (the heading, Connect, Try again) instead of on a
  // button that just left.
  if (step === 'choose') {
    return (
      <ControlModal key={step} title={ASK_TITLE} onClose={onClose} className="shared-play-modal" focusTitle>
        <p className="shared-play-line">We’ll remember it on this browser.</p>
        <ServiceChoice variant="modal" onChoose={onChoose} />
        <div className="wc-actions shared-play-foot">{cancel}</div>
      </ControlModal>
    )
  }
  return (
    <ControlModal key={step} title={APPLE_TITLE} onClose={onClose} className="shared-play-modal" focusTitle={step === 'readying'}>
      {step === 'readying' && <p className="shared-play-line" role="status">Getting Apple Music ready…</p>}
      {step === 'connect' && (
        <div className="shared-play-connect">
          <ConnectMusicButton state="disconnected" onClick={() => onConnect?.()} />
        </div>
      )}
      {step === 'failed' && <p className="shared-play-line shared-play-failed" role="alert">{failure}</p>}
      <div className="wc-actions shared-play-foot">
        {cancel}
        {step === 'failed' && <button type="button" className="wc-text" data-autofocus="" onClick={() => onRetry?.()}><strong>Try again</strong></button>}
      </div>
    </ControlModal>
  )
}
