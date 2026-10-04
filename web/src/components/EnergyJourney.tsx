import { useEffect, useState } from 'react'
import type { EnergyArc, MixtapeApi, MixVersionDetail } from '../api/client'
import { ControlModal } from './ControlModal'
import './energy-journey.css'
export type { EnergyArc }
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
export function journeyMessage(status: string) {
  if (status === 'follows')
    return 'The opening, middle and ending broadly follow your shape.'
  if (status === 'mixed')
    return 'A gentler journey this time. This mix does not follow every part of the shape. Your song choices and exclusions still come first.'
  return 'There is not enough energy information to judge every transition. Your song choices and exclusions still come first.'
}
// The shape is a setting sent beside the message, never written into the brief.
export function EnergyControl({
  value,
  compact = false,
  onSelect,
  disabled = false,
}: {
  value?: EnergyArc | null
  compact?: boolean
  onSelect: (shape: EnergyArc) => void
  disabled?: boolean
}) {
  const [open, setOpen] = useState(false)
  const [arc, setArc] = useState<EnergyArc>('arc')
  return (
    <div className="energy-control">
      <button
        type="button"
        className="wc-text"
        disabled={disabled}
        aria-label={compact ? `Energy journey${value ? `: ${shapes[value].label}` : ''}` : undefined}
        title={compact ? value ? shapes[value].label : 'Choose a shape' : undefined}
        onClick={() => {
          setArc(value ?? 'arc')
          setOpen(true)
        }}
      >
        {compact ? <>{value && <svg className="composer-shape" viewBox="0 0 300 110" aria-hidden="true"><path d={shapes[value].path} /></svg>}<span>Shape</span></> : 'Energy journey'}
      </button>
      {value && (
        <span className={compact ? 'sr-only' : undefined} role="status">{shapes[value].label}</span>
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
          <div className="energy-actions">
            <button
              type="button"
              className="btn"
              onClick={() => setOpen(false)}
            >
              Cancel
            </button>
            <button
              type="button"
              className="btn primary"
              disabled={disabled}
              onClick={() => {
                if (!disabled) {
                  onSelect(arc)
                  setOpen(false)
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
  onShape,
}: {
  api: MixtapeApi
  sessionId: string
  version: number
  onShape?: (shape: EnergyArc | null) => void
}) {
  const [detail, setDetail] = useState<MixVersionDetail | null>(null)
  useEffect(() => {
    let current = true
    setDetail(null)
    if (version > 0)
      void api.readMixVersion(sessionId, version).then(
        (result) => {
          if (current) { setDetail(result); onShape?.(result.energyArc ?? null) }
        },
        () => {},
      )
    return () => {
      current = false
    }
  }, [api, sessionId, version])
  return detail ? <EnergyAssessment detail={detail} /> : null
}
