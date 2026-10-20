import type { MusicService } from './ChooseService'
import { FirstRunPage, Pill } from './FirstRunPage'

export type AddMethod = 'apple-sync' | 'exportify' | 'spotify-export'
export const METHOD_HEADLINE = 'How do you want to add it?'
export const METHOD_SPOTIFY_LINE =
  'Exportify brings your playlists and likes. The data export adds what you actually played.'
export const METHOD_FOOT = 'You can add more later from Library.'

type Props = {
  service: MusicService
  onChoose: (method: AddMethod) => void
  onBack: () => void
  focusHeading?: boolean
}

/**
 * Step 2 of 3. The web has no Apple Media Services export reader (the Apple
 * adapter exists on iOS only), so Apple offers the library sync alone here.
 */
export function ChooseMethod({ service, onChoose, onBack, focusHeading }: Props) {
  return (
    <FirstRunPage background="step-2" step={2} headline={METHOD_HEADLINE} onBack={onBack} focusHeading={focusHeading}>
      {service === 'spotify' ? <p className="fr-line">{METHOD_SPOTIFY_LINE}</p> : null}
      <div className="fr-acts">
        {service === 'apple' ? (
          <Pill onClick={() => onChoose('apple-sync')}>Sync my library</Pill>
        ) : (
          <>
            <Pill onClick={() => onChoose('exportify')}>Exportify, a few minutes</Pill>
            <Pill onClick={() => onChoose('spotify-export')}>Spotify data export, a few days</Pill>
          </>
        )}
      </div>
      <p className="fr-foot fr-foot--quiet">{METHOD_FOOT}</p>
    </FirstRunPage>
  )
}
