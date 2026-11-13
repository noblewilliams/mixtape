// "Where do you listen?" (decisions 2026-11-06): Spotify or Apple Music as
// one choice. The mix rail asks inline; the shared mix page asks in a modal
// (board docs/mockups/2026-11-13-shared-mixes.html, W4/W5). The answer is the
// caller's to remember (writePlaysOn).
import type { PlaysOn } from '../lib/plays-on'
import { AppleMusicMark, SpotifyMark } from './ProviderMarks'
import { ConnectMusicButton } from './TapeActions'

export const ASK_TITLE = 'Where do you listen?'

type ServiceChoiceProps = {
  /** The rail: titled group, Spotify leading. The modal: two marked rows, Apple Music first, titled by the dialog. */
  variant: 'rail' | 'modal'
  onChoose: (choice: PlaysOn) => void
}

export function ServiceChoice({ variant, onChoose }: ServiceChoiceProps) {
  if (variant === 'modal') {
    return (
      <div className="service-choices">
        <button className="service-choice" type="button" onClick={() => onChoose('apple')}>
          <span className="service-mark service-mark--apple"><AppleMusicMark /></span>Apple Music
        </button>
        <button className="service-choice" type="button" onClick={() => onChoose('spotify')}>
          <span className="service-mark service-mark--spotify"><SpotifyMark /></span>Spotify
        </button>
      </div>
    )
  }
  return (
    <div className="rail-actions rail-ask" role="group" aria-label={ASK_TITLE}>
      <p className="rail-ask-title">{ASK_TITLE}</p>
      <button className="btn primary" type="button" onClick={() => onChoose('spotify')}>
        Play on Spotify
      </button>
      <ConnectMusicButton state="disconnected" onClick={() => onChoose('apple')} />
      <p className="rail-hint">We’ll remember it. You can change it in Settings.</p>
    </div>
  )
}
