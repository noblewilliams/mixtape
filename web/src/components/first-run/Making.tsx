import { useEffect, useState } from 'react'
import { useMediaQuery } from '../../lib/use-media-query'
import { Cassette } from '../Cassette'
import { FirstRunPage } from './FirstRunPage'

export const MAKING_HEADLINE = 'Making your mix.'
export const MAKING_LINE = 'The DJ is listening. This takes about a minute.'

/**
 * The wait while the DJ makes the first mix (a 20 to 60 second turn). The
 * request cannot be cancelled, so there is no back button and nothing to
 * press; a refresh here would cancel the turn, which is why the page exists.
 */
export function Making({ focusHeading }: { focusHeading?: boolean }) {
  const still = useMediaQuery('(prefers-reduced-motion: reduce)')
  // Filled after mount so the polite region announces the line once. It sits
  // outside the busy page, which assistive tech may hold announcements for.
  const [announce, setAnnounce] = useState('')
  useEffect(() => setAnnounce(MAKING_LINE), [])
  return (
    <div className="fr-making">
      <FirstRunPage
        background="welcome"
        headline={MAKING_HEADLINE}
        focusHeading={focusHeading}
        busy
        before={
          <div className="fr-hero" aria-hidden="true">
            <Cassette className="fr-cassette" loading={!still} labelled={false} />
          </div>
        }
      >
        <p className="fr-line">{MAKING_LINE}</p>
      </FirstRunPage>
      <p className="sr-only" role="status" aria-live="polite">{announce}</p>
    </div>
  )
}
