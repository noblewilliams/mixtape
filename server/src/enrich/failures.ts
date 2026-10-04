import { sql, type SQL, type SQLChunk } from 'drizzle-orm'
import { EnrichSourceError } from './types'

// Retry policy for enrichment_failures rows, in one place so the runner's
// candidate query, its skip_* flags, its remaining/cooling counts, the status
// endpoint and analyze-previews all agree on what "exhausted" means.
//
// A permanent failure (no match, no lyrics, a 4xx, a malformed response, an
// unknown internal error) is retried at once and gives up at MAX_ATTEMPTS.
// A transient one (429, 5xx, timeout, abort, network failure, AI binding
// failure) says nothing about the track, so it waits out an exponential
// backoff before the next try and gives up only at MAX_TRANSIENT_ATTEMPTS.
// The latest failure decides: rows are stored with TRANSIENT_PREFIX on the
// error text, and rows written before this policy have no prefix and keep
// the permanent rule.
export const MAX_ATTEMPTS = 3
export const MAX_TRANSIENT_ATTEMPTS = 8
export const TRANSIENT_BACKOFF_CAP_HOURS = 24
export const TRANSIENT_PREFIX = 'transient: '

export function isTransientFailure(e: unknown): boolean {
  if (e instanceof EnrichSourceError) return e.transient
  // A source that lets a timeout or abort through unwrapped. DOMException is
  // checked by name, not by class, since runtimes disagree on its prototype.
  const name = typeof e === 'object' && e !== null ? (e as { name?: unknown }).name : undefined
  return name === 'TimeoutError' || name === 'AbortError'
}

// All constants below are inlined, not bound: a bound parameter inside CASE
// would be typed text, and these are fixed numbers, never user input.
const PREFIX = sql.raw(`'${TRANSIENT_PREFIX}'`)
const PERMANENT_LIMIT = sql.raw(String(MAX_ATTEMPTS))
const TRANSIENT_LIMIT = sql.raw(String(MAX_TRANSIENT_ATTEMPTS))
const CAP_HOURS = sql.raw(String(TRANSIENT_BACKOFF_CAP_HOURS))
// Smallest exponent whose power of two reaches the cap, so the power below is
// bounded by itself and never grows with attempts.
const MAX_EXPONENT = sql.raw(String(Math.ceil(Math.log2(TRANSIENT_BACKOFF_CAP_HOURS))))

// Each predicate takes the alias of an enrichment_failures row that may be
// absent (a LEFT JOIN miss), and is false rather than NULL in that case, so
// NOT(...) behaves.
function transient(ef: SQLChunk): SQL {
  return sql`starts_with(${ef}.error, ${PREFIX})`
}

// Given up on: no further attempt, ever (until the row is cleared).
export function failureExhausted(alias: string): SQL {
  const ef = sql.identifier(alias)
  return sql`(${ef}.track_id IS NOT NULL AND ${ef}.attempts >= CASE WHEN ${transient(ef)} THEN ${TRANSIENT_LIMIT} ELSE ${PERMANENT_LIMIT} END)`
}

// Waiting out its backoff: last_at + 1h x least(24, 2^(attempts - 1)), so
// 1h, 2h, 4h, 8h, 16h, 24h, 24h. Never true for an exhausted row.
// Backoff counts total attempts, so a stage with earlier permanent failures starts further along the schedule.
export function failureCooling(alias: string): SQL {
  const ef = sql.identifier(alias)
  return sql`(${ef}.track_id IS NOT NULL AND ${transient(ef)} AND ${ef}.attempts < ${TRANSIENT_LIMIT}
    AND now() < ${ef}.last_at + interval '1 hour' * LEAST(${CAP_HOURS}, power(2, LEAST(GREATEST(${ef}.attempts, 1) - 1, ${MAX_EXPONENT}))))`
}

// Not eligible this run, for either reason. A stage is eligible when its
// output row is missing and this is false.
export function failureBlocked(alias: string): SQL {
  return sql`(${failureExhausted(alias)} OR ${failureCooling(alias)})`
}
