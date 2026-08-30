import { useId, type CSSProperties } from 'react'

type CassetteProps = {
  title?: string
  caseColor?: string
  stockColor?: string
  className?: string
  loading?: boolean
  labelled?: boolean
}

function Hub({ x, loading, reverse = false }: { x: number; loading: boolean; reverse?: boolean }) {
  return (
    <g transform={`translate(${x} 61)`}>
      <g
        className={
          loading
            ? `cassette-hub cassette-hub--moving ${reverse ? 'cassette-hub--reverse' : ''}`
            : 'cassette-hub'
        }
      >
        <circle className="cassette-hub-ring" r="16" />
        {Array.from({ length: 8 }, (_, index) => (
          <rect
            className="cassette-tooth"
            key={index}
            x="-3"
            y="-15"
            width="6"
            height="6"
            rx="1"
            transform={`rotate(${index * 45})`}
          />
        ))}
        <circle className="cassette-hub-hole" r="5" />
      </g>
    </g>
  )
}

export function Cassette({
  title,
  caseColor = '#3f4851',
  stockColor = '#f2ede2',
  className = '',
  loading = false,
  labelled = true,
}: CassetteProps) {
  const titleId = useId()

  return (
    <div
      className={`cassette ${loading ? 'cassette--loading' : ''} ${className}`.trim()}
      style={{ '--cassette-case': caseColor, '--cassette-stock': stockColor } as CSSProperties}
    >
      {labelled && title ? <span className="cassette-title">{title}</span> : null}
      <svg
        viewBox="0 0 200 128"
        role={loading ? 'img' : undefined}
        aria-labelledby={loading ? titleId : undefined}
        aria-hidden={loading ? undefined : true}
      >
        {loading ? <title id={titleId}>Cassette hubs turning while your library is prepared</title> : null}
        <rect className="cassette-case" x="1" y="1" width="198" height="126" rx="9" />
        <rect className="cassette-edge" x="3" y="3" width="194" height="122" rx="7" />
        <rect className="cassette-stock" x="14" y="12" width="172" height="73" rx="5" />
        <line className="cassette-rule" x1="22" y1="31" x2="178" y2="31" />
        <rect className="cassette-stripe cassette-stripe--1" x="14" y="39" width="172" height="5" />
        <rect className="cassette-stripe cassette-stripe--2" x="14" y="44" width="172" height="5" />
        <rect className="cassette-stripe cassette-stripe--3" x="14" y="49" width="172" height="5" />
        <rect className="cassette-stripe cassette-stripe--4" x="14" y="54" width="172" height="5" />
        <rect className="cassette-stripe cassette-stripe--5" x="14" y="59" width="172" height="5" />
        <rect className="cassette-window" x="42" y="42" width="116" height="39" rx="7" />
        <rect className="cassette-tape-band" x="72" y="55" width="56" height="12" rx="2" />
        <Hub x={61} loading={loading} />
        <Hub x={139} loading={loading} reverse />
        <path className="cassette-lower" d="M48 89H152L164 119H36Z" />
        <circle className="cassette-guide" cx="58" cy="105" r="6" />
        <circle className="cassette-guide" cx="142" cy="105" r="6" />
        <rect className="cassette-metal" x="75" y="100" width="8" height="13" rx="2" />
        <rect className="cassette-metal" x="117" y="100" width="8" height="13" rx="2" />
        <circle className="cassette-screw" cx="100" cy="108" r="4" />
        <circle className="cassette-screw" cx="9" cy="9" r="3" />
        <circle className="cassette-screw" cx="191" cy="9" r="3" />
        <circle className="cassette-screw" cx="9" cy="119" r="3" />
        <circle className="cassette-screw" cx="191" cy="119" r="3" />
      </svg>
    </div>
  )
}
