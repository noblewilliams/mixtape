/**
 * funnel-report — read-only: prints the Spotify-listener funnel from
 * funnel_events (spec 2026-09-01 → Funnel): distinct users per step, step-to-
 * step conversion in funnel order, and the median days from a user's first
 * marked_requested to their first import_completed.
 *
 * Usage (from server/):  npm run funnel-report
 * Loads DATABASE_URL from .dev.vars (neon-http, the one-off script driver).
 * Writes nothing, so there is no --apply. Prints counts only, never ids.
 */
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { sql } from 'drizzle-orm'
import { neon } from '@neondatabase/serverless'
import { drizzle } from 'drizzle-orm/neon-http'
import * as schema from '../src/db/schema'
import { funnelEvents } from '../src/db/schema'
import type { Db } from '../src/db/types'
import { FUNNEL_EVENT_TYPES, type FunnelEventType } from '../src/seeds/contracts'
import { loadDevVars } from './lib/dev-vars'

export const FUNNEL_ORDER = FUNNEL_EVENT_TYPES

export type FunnelReport = {
  steps: Array<{ type: FunnelEventType; users: number }>
  conversions: Array<{ from: FunnelEventType; to: FunnelEventType; fromUsers: number; converted: number; rate: number | null }>
  requestToImport: { users: number; medianDays: number | null }
}

const DAY_SECONDS = 86_400

function median(values: number[]): number | null {
  if (values.length === 0) return null
  const sorted = [...values].sort((a, b) => a - b)
  const mid = Math.floor(sorted.length / 2)
  return sorted.length % 2 === 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
}

export async function computeFunnelReport(db: Db): Promise<FunnelReport> {
  // One row per (user, step) with the first time the step happened; repeat
  // events never count twice. Epoch seconds so both drivers hand back a
  // number-like value without timestamp parsing.
  const rows = await db
    .select({
      userId: funnelEvents.userId,
      type: funnelEvents.type,
      firstAt: sql<number | string>`extract(epoch from min(${funnelEvents.createdAt}))`,
    })
    .from(funnelEvents)
    .groupBy(funnelEvents.userId, funnelEvents.type)

  const firstAt = new Map<FunnelEventType, Map<string, number>>()
  for (const type of FUNNEL_ORDER) firstAt.set(type, new Map())
  for (const row of rows) firstAt.get(row.type)?.set(row.userId, Number(row.firstAt))

  const usersAt = (type: FunnelEventType) => firstAt.get(type)!
  const steps = FUNNEL_ORDER.map((type) => ({ type, users: usersAt(type).size }))

  const conversions = FUNNEL_ORDER.slice(0, -1).map((from, index) => {
    const to = FUNNEL_ORDER[index + 1]
    const fromUsers = usersAt(from).size
    let converted = 0
    for (const userId of usersAt(from).keys()) if (usersAt(to).has(userId)) converted += 1
    return { from, to, fromUsers, converted, rate: fromUsers === 0 ? null : converted / fromUsers }
  })

  const days: number[] = []
  for (const [userId, requestedAt] of usersAt('marked_requested')) {
    const importedAt = usersAt('import_completed').get(userId)
    if (importedAt !== undefined) days.push((importedAt - requestedAt) / DAY_SECONDS)
  }

  return { steps, conversions, requestToImport: { users: days.length, medianDays: median(days) } }
}

export function formatFunnelReport(report: FunnelReport): string {
  const width = Math.max(...FUNNEL_ORDER.map((type) => type.length))
  const lines = ['Funnel (distinct users per step)']
  for (const step of report.steps) lines.push(`  ${step.type.padEnd(width)}  ${step.users}`)
  lines.push('', 'Conversion (users who reached the step and then the next)')
  for (const conversion of report.conversions) {
    const rate = conversion.rate === null ? '-' : `${Math.round(conversion.rate * 100)}%`
    lines.push(`  ${conversion.from} -> ${conversion.to}: ${conversion.converted}/${conversion.fromUsers} (${rate})`)
  }
  const { users, medianDays } = report.requestToImport
  lines.push('', medianDays === null
    ? 'Median days from marked_requested to import_completed: no user has done both yet'
    : `Median days from marked_requested to import_completed: ${medianDays.toFixed(1)} (${users} user(s))`)
  return lines.join('\n')
}

async function main() {
  const env = loadDevVars()
  if (!env.DATABASE_URL) {
    console.error('DATABASE_URL missing from .dev.vars')
    process.exit(1)
  }
  // Never let a construction failure bubble its message up: an unstripped or
  // malformed DATABASE_URL makes neon() throw with the full connection string
  // (credentials included) embedded in it.
  let db: Db
  try {
    db = drizzle(neon(env.DATABASE_URL), { schema }) as unknown as Db
  } catch {
    console.error('invalid DATABASE_URL in .dev.vars')
    process.exit(1)
  }
  console.log(formatFunnelReport(await computeFunnelReport(db)))
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch(() => {
    // Fixed string only — a DB error's own message can carry connection details.
    console.error('funnel-report failed')
    process.exit(1)
  })
}
