import { eq } from 'drizzle-orm'
import { djPauses } from '../db/schema'
import type { Db } from '../db/types'
import { LlmError, type LlmComplete } from './llm'
import { TITLE_MODEL } from './title'

// Automatic DJ pause (decisions 2026-11-17). The first model call Anthropic
// refuses for billing (credits spent) writes a dj_pauses row; while it exists
// the server answers DJ sends with 503 dj_paused and /health says djPaused,
// exactly as the manual DJ_PAUSED switch does. The cron probe makes one tiny
// call per run while paused and deletes the row once the model answers, so a
// top-up reopens the DJ within a cron interval and nobody has to deploy.
//
// Everything here fails open: a database error reads as "not paused" and a
// failed trip is swallowed, so this can never take the DJ down by itself.

const BILLING = 'anthropic_billing'

// Each Worker isolate keeps the last answer this long: /health polls and DJ
// sends read it, and one query per isolate per 30 s is plenty. The value is
// the same for every listener, so holding it across requests leaks nothing.
export const AUTO_PAUSE_CACHE_MS = 30_000
let cached: { paused: boolean; at: number } | null = null

export function resetAutoPauseCache(): void {
  cached = null
}

export async function readAutoPause(db: Db, now = Date.now()): Promise<boolean> {
  if (cached && now - cached.at < AUTO_PAUSE_CACHE_MS) return cached.paused
  try {
    const rows = await db.select({ id: djPauses.id }).from(djPauses).where(eq(djPauses.id, BILLING))
    cached = { paused: rows.length > 0, at: now }
    return cached.paused
  } catch {
    console.error('dj auto-pause read failed')
    return cached?.paused ?? false
  }
}

export async function tripAutoPause(db: Db): Promise<void> {
  cached = { paused: true, at: Date.now() }
  try {
    await db.insert(djPauses).values({ id: BILLING }).onConflictDoNothing()
    console.log('dj auto-pause tripped', JSON.stringify({ cause: BILLING }))
  } catch {
    console.error('dj auto-pause trip failed')
  }
}

export async function clearAutoPause(db: Db): Promise<void> {
  await db.delete(djPauses).where(eq(djPauses.id, BILLING))
  cached = { paused: false, at: Date.now() }
}

// Wraps a model client: a billing refusal trips the pause, then the original
// error goes on to the caller unchanged (its turn still fails as before).
export function pauseOnBilling<A extends unknown[], R>(
  fn: (...args: A) => Promise<R>,
  onBilling: () => Promise<void>,
): (...args: A) => Promise<R> {
  return async (...args) => {
    try {
      return await fn(...args)
    } catch (e) {
      if (e instanceof LlmError && e.billing) await onBilling().catch(() => undefined)
      throw e
    }
  }
}

// One cron run's check. Reads the table directly (not the cache) and, only
// while paused, spends one tiny titling-model call. Any failure keeps the
// pause: an overload proves nothing about credits.
export async function probeAutoPause(db: Db, complete: LlmComplete): Promise<'open' | 'cleared' | 'still_paused'> {
  const rows = await db.select({ id: djPauses.id }).from(djPauses).where(eq(djPauses.id, BILLING))
  if (rows.length === 0) return 'open'
  try {
    await complete({ system: 'Reply with the single word ok.', prompt: 'ok', model: TITLE_MODEL, maxTokens: 8, timeoutMs: 15_000, maxRetries: 0 })
  } catch {
    return 'still_paused'
  }
  await clearAutoPause(db)
  console.log('dj auto-pause cleared', JSON.stringify({ cause: BILLING }))
  return 'cleared'
}
