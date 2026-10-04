import { useLayoutEffect, useRef, useState, type CSSProperties } from 'react'
import type { DjSession } from '../domain'
import './tape-rack.css'

function ink(color: string) {
  const rgb = color.replace('#', '').match(/.{2}/g)?.map(hex => {
    const value = parseInt(hex, 16) / 255
    return value <= .04045 ? value / 12.92 : ((value + .055) / 1.055) ** 2.4
  })
  return rgb && .2126 * rgb[0] + .7152 * rgb[1] + .0722 * rgb[2] < .179 ? '#ffffff' : '#17161a'
}

function Tape({ session, onOpen }: { session: DjSession; onOpen: () => void }) {
  const hash = Array.from(session.id).reduce((value, char) => (Math.imul(value, 31) + char.charCodeAt(0)) >>> 0, 0)
  const variant = hash % 4
  const cap = hash % 3 !== 2 ? ['#e3ad62', '#cec3a7', '#5d454d', '#d6c07c'][variant] : session.caseColor
  const end = hash % 3 === 0 ? ['#a25026', '#433b50', '#d9b884', '#334b40'][variant] : session.caseColor
  const duration = /^(?:(\d+) hr(?: )?)?(?:(\d+) min)?$/.exec(session.durationLabel)
  const minutes = duration ? Number(duration[1] || 0) * 60 + Number(duration[2] || 0) : 0
  return <button type="button" className={`rack-tape rack-variant-${variant}${minutes >= 100 ? ' rack-long-duration' : ''}`} onClick={onOpen}
    title={session.title} aria-label={`Open mix: ${session.title}`} style={{
      '--case': session.caseColor, '--ink': ink(session.caseColor), '--cap': cap,
      '--cap-ink': ink(cap), '--endcap': end, '--end-ink': ink(end),
    } as CSSProperties}>
    <span className="rack-insert">
      {hash % 5 !== 1 && <span className="rack-print-top" aria-hidden="true"><b>{variant === 1 ? 'CRX' : minutes || 'A'}</b><small>{minutes ? 'MIN' : 'SIDE'}<br />{minutes ? 'STEREO' : 'A'}</small></span>}
      <span className="rack-name">{session.title}</span>
      <span className="rack-print-bottom" aria-hidden="true"><b>{variant === 3 ? 'HF' : 'A'}</b><small>MIXTAPE<br />{variant === 3 ? 'NORMAL BIAS' : 'SIDE A'}</small></span>
    </span>
    <span className="rack-reflection" aria-hidden="true" />
  </button>
}

function Plant({ secondary = false }: { secondary?: boolean }) {
  return <span aria-hidden="true" className={`rack-plant${secondary ? ' rack-plant-secondary' : ''}`}><img alt="" src={`/rack/${secondary ? 'string-of-hearts' : 'pothos'}.webp`} /></span>
}

export function TapeRack({ sessions, onOpenSession }: { sessions: DjSession[]; onOpenSession: (id: string) => void }) {
  const cabinet = useRef<HTMLDivElement>(null)
  const [width, setWidth] = useState(0)
  const [bird] = useState(() => ({ row: Math.random(), before: Math.random() < .5 }))
  useLayoutEffect(() => {
    const element = cabinet.current
    if (!element) return
    setWidth(element.getBoundingClientRect().width)
    const observer = new ResizeObserver(entries => setWidth(entries[0].contentRect.width))
    observer.observe(element)
    return () => observer.disconnect()
  }, [])
  // Reserve the row padding, a plant and the bird on every row so their random location cannot split or overflow a group.
  // The reserve follows the stylesheet's 420px container rule, where all three shrink.
  const reserve = width && width <= 420 ? 12 + 138 : 28 + 170
  const capacity = Math.max(1, Math.floor(((width || 440) - reserve) / 47))
  const rows = Array.from({ length: Math.ceil(sessions.length / capacity) }, (_, index) => sessions.slice(index * capacity, (index + 1) * capacity))
  const birdRow = Math.floor(bird.row * rows.length)
  return <section className="tape-rack-scroll" aria-label="Tape closet">
    <div ref={cabinet} className="tape-rack">
      {rows.map((row, index) => {
        const trinket = index === birdRow ? <span className="rack-bird" aria-hidden="true"><img src="/rack/bird.webp" alt="" /></span> : null
        return <div className="rack-row" key={index}>
          {index > 0 && index === rows.length - 1 && <Plant secondary />}
          {bird.before && trinket}
          {row.map(session => <Tape key={session.id} session={session} onOpen={() => onOpenSession(session.id)} />)}
          {!bird.before && trinket}
          {index === 0 && <Plant />}
        </div>
      })}
    </div>
  </section>
}

export function TapeRackSkeleton() {
  return <section className="tape-rack-scroll" role="status" aria-label="Loading mixes">
    <div className="tape-rack"><div className="rack-row">
      {Array.from({ length: 3 }, (_, index) => <span key={index} className="rack-tape rack-ghost" aria-hidden="true"><span className="rack-insert" /></span>)}
      <span className="rack-bird" aria-hidden="true"><img src="/rack/bird.webp" alt="" /></span>
      <Plant />
    </div></div>
  </section>
}
