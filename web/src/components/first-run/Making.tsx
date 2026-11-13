import { useEffect, useState } from 'react'
import { useMediaQuery } from '../../lib/use-media-query'
import { Cassette } from '../Cassette'
import { DjWorkingLine } from '../DjWorkingLine'
import type { TurnWork } from '../djWorkingLines'
import { FirstRunPage } from './FirstRunPage'

export const MAKING_HEADLINE = 'Making your mix.'
export const MAKING_LINE = 'This takes about a minute.'
/** What assistive tech hears, once: the step line under MAKING_LINE moves too often to be read. */
export const MAKING_ANNOUNCEMENT = 'The DJ is listening. This takes about a minute.'

/**
 * The wait while the DJ makes the first mix (a 20 to 60 second turn). The
 * request cannot be cancelled, so there is no back button and nothing to
 * press; a refresh here would cancel the turn, which is why the page exists.
 *
 * Under the line, the DJ's working line (turn steps, 2026-11-13): the first
 * turn's steps once its stream opens, the timed lines until then. `working`
 * is held by the flow, so going back and returning to the running mix keeps
 * the step.
 */
export function Making({ focusHeading, working }: { focusHeading?: boolean; working?: TurnWork }) {
  const still = useMediaQuery('(prefers-reduced-motion: reduce)')
  // Filled after mount so the polite region announces the line once. It sits
  // outside the busy page, which assistive tech may hold announcements for.
  const [announce, setAnnounce] = useState('')
  useEffect(() => setAnnounce(MAKING_ANNOUNCEMENT), [])
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
        <p className="fr-step" aria-hidden="true"><DjWorkingLine work={working} /></p>
      </FirstRunPage>
      <p className="sr-only" role="status" aria-live="polite">{announce}</p>
    </div>
  )
}
