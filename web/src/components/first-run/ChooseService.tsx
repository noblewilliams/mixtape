import { AppleMusicMark, SpotifyMark } from '../ProviderMarks'
import { FirstRunPage, Pill } from './FirstRunPage'

export type MusicService = 'apple' | 'spotify'
export const SERVICE_HEADLINE = 'Which do you use?'
export const SERVICE_LINE = 'Mixes get better when the DJ knows your music.'

type Props = {
  onChoose: (service: MusicService) => void
  onSkip: () => void
  onBack: () => void
  focusHeading?: boolean
}

/** Step 1 of 3. A tap on a service advances; there is no Continue. */
export function ChooseService({ onChoose, onSkip, onBack, focusHeading }: Props) {
  return (
    <FirstRunPage background="step-1" step={1} headline={SERVICE_HEADLINE} onBack={onBack} focusHeading={focusHeading}>
      <p className="fr-line">{SERVICE_LINE}</p>
      <div className="fr-acts">
        <Pill onClick={() => onChoose('apple')}>
          <span className="fr-mark fr-mark--apple"><AppleMusicMark /></span>Apple Music
        </Pill>
        <Pill onClick={() => onChoose('spotify')}>
          <span className="fr-mark fr-mark--spotify"><SpotifyMark /></span>Spotify
        </Pill>
      </div>
      <p className="fr-foot">
        <button type="button" className="fr-link" onClick={onSkip}>Skip for now</button>
      </p>
    </FirstRunPage>
  )
}
