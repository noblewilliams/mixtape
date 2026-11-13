import { useEffect, useState } from 'react'
import { nextWorkingLineAt, settleLine, workingLineAt, type ShownLine, type TurnWork } from './djWorkingLines'

/**
 * The line of what the DJ is doing on a mix turn, from `djWorkingLines`'
 * rules: the timed walk until the turn's stream opens, then its steps, each
 * line held at least the dwell. Only timers move it on, one per change of
 * line, never a tick; a mount reads the clock, so a turn already under way
 * (the conversation reopened) picks up from `work.startedAt` and its step's
 * arrival. Without `work` the clock starts at the mount.
 *
 * `seed` picks one line per phase and step; it defaults to when the turn went
 * out, so a remount picks the same lines. Tests pass their own.
 */
export function useDjWorkingLine(work?: TurnWork, seed?: number): string {
  const [mountedAt] = useState(() => Date.now())
  const startedAt = work?.startedAt ?? mountedAt
  const step = work?.step ?? null
  const pick = seed ?? startedAt
  const [shown, setShown] = useState<ShownLine>(() => {
    const now = Date.now()
    return { line: workingLineAt({ startedAt, step }, now, pick), since: now }
  })
  const [wake, setWake] = useState(0)

  useEffect(() => {
    const now = Date.now()
    const current: TurnWork = { startedAt, step }
    const settled = settleLine(shown, workingLineAt(current, now, pick), now)
    // A new line runs this again, to schedule from it.
    if (settled.shown !== shown) return setShown(settled.shown)
    const next = [settled.wakeAt, nextWorkingLineAt(current, now)].filter((at): at is number => at !== null)
    if (next.length === 0) return
    const timer = setTimeout(() => setWake((count) => count + 1), Math.max(0, Math.min(...next) - now))
    return () => clearTimeout(timer)
  }, [startedAt, step, pick, shown, wake])

  return shown.line
}

/**
 * The working line as text: one line, a short fade as it changes (none under
 * reduced motion), cut with an ellipsis at worst. Names render as plain text.
 * The caller hides it from assistive tech and says one steady line instead.
 */
export function DjWorkingLine({ work, seed }: { work?: TurnWork; seed?: number }) {
  const line = useDjWorkingLine(work, seed)
  return <span key={line} className="dj-working-line">{line}</span>
}
