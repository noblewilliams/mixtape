const dayMs = 86400000
const weekdays = [
  'Sunday',
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
]
const periods = ['nights', 'mornings', 'afternoons', 'evenings']
const briefs = {
  rise: {
    title: 'Build into the moment.',
    prompt: 'Make a mix that gradually builds in energy.',
    description: 'rising-energy',
  },
  fall: {
    title: 'Ease into a slower pace.',
    prompt: 'Make a mix that gradually winds down.',
    description: 'winding-down',
  },
  arc: {
    title: 'Build up, then settle in.',
    prompt: 'Make a mix that builds to a peak, then eases down.',
    description: 'build-and-settle',
  },
  steady: {
    title: 'Find a steady rhythm.',
    prompt: 'Make a mix with a steady energy throughout.',
    description: 'steady-energy',
  },
} as const
export type RoutineSuggestion = {
  id: string
  title: string
  prompt: string
  reason: string
}
export function localMoment(date: Date, timeZone: string) {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    weekday: 'long',
    hour: '2-digit',
    hourCycle: 'h23',
  }).formatToParts(date)
  const part = (name: string) => parts.find((p) => p.type === name)!.value
  return {
    date: `${part('year')}-${part('month')}-${part('day')}`,
    day: weekdays.indexOf(part('weekday')),
    period: Math.floor(Number(part('hour')) / 6),
  }
}
export function suggestRoutine(
  history: { createdAt: Date; energyArc: string | null }[],
  timeZone: string,
  now: Date,
): RoutineSuggestion | null {
  const current = localMoment(now, timeZone)
  const groups = new Map<keyof typeof briefs, Set<string>>()
  for (const row of history) {
    if (
      now.getTime() - row.createdAt.getTime() > 84 * dayMs ||
      row.createdAt > now ||
      !Object.hasOwn(briefs, row.energyArc ?? '')
    )
      continue
    const moment = localMoment(row.createdAt, timeZone)
    if (moment.day !== current.day || moment.period !== current.period) continue
    const arc = row.energyArc as keyof typeof briefs
    const days = groups.get(arc) ?? new Set<string>()
    days.add(moment.date)
    groups.set(arc, days)
  }
  const winner = [...groups]
    .filter(([, days]) => days.size >= 3)
    .sort((a, b) => b[1].size - a[1].size || a[0].localeCompare(b[0]))[0]
  if (!winner) return null
  const [arc, days] = winner
  const sorted = [...days].sort()
  if (Date.parse(sorted.at(-1)!) - Date.parse(sorted[0]) < 14 * dayMs)
    return null
  return {
    id: `${current.day}-${current.period}-${arc}`,
    title: briefs[arc].title,
    prompt: briefs[arc].prompt,
    reason: `You have made ${briefs[arc].description} mixes on ${days.size} ${weekdays[current.day]} ${periods[current.period]}.`,
  }
}
