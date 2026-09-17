import { useEffect, useState } from 'react'
import type { MixtapeApi, MixVersionDetail } from '../api/client'
import { ControlModal } from './ControlModal'
import './energy-journey.css'
export type EnergyArc = 'steady' | 'rise' | 'fall' | 'arc'
const shapes: Record<
  EnergyArc,
  { label: string; description: string; path: string }
> = {
  steady: {
    label: 'Steady',
    description: 'A consistent feel from start to finish.',
    path: 'M10 55 L290 55',
  },
  rise: {
    label: 'Build gradually',
    description: 'Begin gently and finish with more energy.',
    path: 'M10 90 C100 90 200 20 290 20',
  },
  fall: {
    label: 'Wind down',
    description: 'Start with a lift and settle toward the end.',
    path: 'M10 20 C100 20 200 90 290 90',
  },
  arc: {
    label: 'Build, then settle',
    description: 'Gentle start. Lift in the middle. Soft landing.',
    path: 'M10 90 C70 90 100 20 150 20 S230 90 290 90',
  },
}
export function energyBrief(text: string, arc: EnergyArc): string | null {
  const clean = text
    .replace(
      /(?:^|\n)Energy journey: (?:Steady|Build gradually|Wind down|Build, then settle)\.(?=\n|$)/g,
      '',
    )
    .trim()
  const next = `${clean ? `${clean}\n` : ''}Energy journey: ${shapes[arc].label}.`
  return next.length <= 2000 ? next : null
}
export function journeyMessage(status: string) {
  if (status === 'follows')
    return 'The opening, middle and ending broadly follow your shape.'
  if (status === 'mixed')
    return 'A gentler journey this time. This mix does not follow every part of the shape. Your song choices and exclusions still come first.'
  return 'There is not enough energy information to judge every transition. Your song choices and exclusions still come first.'
}
export function EnergyControl({
  text,
  onChange,
  disabled = false,
}: {
  text: string
  onChange: (text: string) => void
  disabled?: boolean
}) {
  const [open, setOpen] = useState(false)
  const [arc, setArc] = useState<EnergyArc>('arc')
  const [applied, setApplied] = useState(false)
  const next = energyBrief(text, arc)
  return (
    <div className="energy-control">
      <button
        type="button"
        className="wc-text"
        disabled={disabled}
        onClick={() => {
          setOpen(true)
          setApplied(false)
        }}
      >
        Energy journey
      </button>
      {applied && text.includes(`Energy journey: ${shapes[arc].label}.`) && (
        <span role="status">Shape added to your brief. Send when ready.</span>
      )}
      {open && (
        <ControlModal
          title="Give the mix a shape."
          onClose={() => setOpen(false)}
        >
          <div className="energy-preview">
            <h3>{shapes[arc].label}</h3>
            <p>{shapes[arc].description}</p>
            <svg
              viewBox="0 0 300 110"
              role="img"
              aria-label={`Target shape: ${shapes[arc].label}`}
            >
              <path d={shapes[arc].path} />
            </svg>
            <small>Target shape · not a measurement of your songs</small>
          </div>
          <div
            className="energy-choices"
            role="group"
            aria-label="Energy shapes"
          >
            {(Object.keys(shapes) as EnergyArc[]).map((key) => (
              <button
                key={key}
                type="button"
                className="energy-button"
                aria-pressed={arc === key}
                onClick={() => setArc(key)}
              >
                {shapes[key].label}
              </button>
            ))}
          </div>
          {next === null && (
            <p role="alert">Shorten your brief to make room for the shape.</p>
          )}
          <div className="energy-actions">
            <button
              type="button"
              className="energy-button"
              onClick={() => setOpen(false)}
            >
              Cancel
            </button>
            <button
              type="button"
              className="energy-button energy-primary"
              disabled={disabled || next === null}
              onClick={() => {
                if (next !== null && !disabled) {
                  onChange(next)
                  setOpen(false)
                  setApplied(true)
                }
              }}
            >
              Use this shape
            </button>
          </div>
        </ControlModal>
      )}
    </div>
  )
}
export function EnergyAssessment({
  detail,
}: {
  detail: Pick<MixVersionDetail, 'energyArc' | 'energyJourney'>
}) {
  if (!detail.energyArc || !detail.energyJourney) return null
  return (
    <aside className="energy-assessment" aria-label="Energy journey assessment">
      <strong>{shapes[detail.energyArc].label}</strong>
      <p>{journeyMessage(detail.energyJourney.status)}</p>
    </aside>
  )
}
export function MixEnergySummary({
  api,
  sessionId,
  version,
}: {
  api: MixtapeApi
  sessionId: string
  version: number
}) {
  const [detail, setDetail] = useState<MixVersionDetail | null>(null)
  useEffect(() => {
    let current = true
    setDetail(null)
    if (version > 0)
      void api.readMixVersion(sessionId, version).then(
        (result) => {
          if (current) setDetail(result)
        },
        () => {},
      )
    return () => {
      current = false
    }
  }, [api, sessionId, version])
  return detail ? <EnergyAssessment detail={detail} /> : null
}
