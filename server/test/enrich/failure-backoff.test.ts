import { describe, it, expect, vi } from 'vitest'
import { eq } from 'drizzle-orm'
import { createTestDb, type TestDb } from '../helpers/db'
import { okDeps, OK_FEATURES } from '../helpers/enrich-fixtures'
import { enrichTrack, type EnrichDeps } from '../../src/enrich/pipeline'
import { runEnrichmentBatch, enrichmentStatus, MAX_ATTEMPTS } from '../../src/enrich/runner'
import {
  MAX_TRANSIENT_ATTEMPTS,
  TRANSIENT_BACKOFF_CAP_HOURS,
  TRANSIENT_PREFIX,
} from '../../src/enrich/failures'
import { EnrichSourceError } from '../../src/enrich/types'
import { workersAiEmbedder } from '../../src/enrich/embedder'
import { fetchLyrics } from '../../src/enrich/lrclib'
import type { FetchLike } from '../../src/enrich/types'
import { tracks, trackFeatures, trackMeanings, enrichmentFailures } from '../../src/db/schema'

const HOUR = 3_600_000

async function seedTrack(db: TestDb, title = 'T') {
  const [t] = await db.insert(tracks).values({ appleId: `a-${title}`, title, artist: 'A', durationMs: 200_000, genre: 'Pop' }).returning()
  return t
}

// A track whose meaning is already done, so only the features stage decides
// whether it is selected.
async function seedFeaturesOnly(db: TestDb, title = 'T') {
  const t = await seedTrack(db, title)
  await db.insert(trackMeanings).values({ trackId: t.id, embedding: null, lyricsSource: 'lrclib', instrumental: true })
  return t
}

async function seedFailure(
  db: TestDb,
  trackId: string,
  opts: { stage?: 'features' | 'meaning'; error: string; attempts: number; ageHours: number },
) {
  await db.insert(enrichmentFailures).values({
    trackId,
    stage: opts.stage ?? 'features',
    error: opts.error,
    attempts: opts.attempts,
    lastAt: new Date(Date.now() - opts.ageHours * HOUR),
  })
}

async function storedError(db: TestDb, stage: 'features' | 'meaning') {
  const [row] = await db.select().from(enrichmentFailures).where(eq(enrichmentFailures.stage, stage))
  return row?.error
}

function throwing(e: unknown): Partial<EnrichDeps> {
  return { features: async () => { throw e } }
}

describe('failure classification', () => {
  it.each([
    ['HTTP 429', new EnrichSourceError('reccobeats', 'search HTTP 429', 429)],
    ['HTTP 500', new EnrichSourceError('reccobeats', 'search HTTP 500', 500)],
    ['HTTP 503', new EnrichSourceError('lrclib', 'HTTP 503', 503)],
    ['a timeout', new DOMException('The operation was aborted due to timeout', 'TimeoutError')],
    ['an abort', new DOMException('This operation was aborted', 'AbortError')],
    ['a source network failure', new EnrichSourceError('reccobeats', 'features fetch failed', undefined, { transient: true })],
  ])('prefixes %s as transient and keeps the existing text', async (_label, error) => {
    const db = await createTestDb()
    const t = await seedTrack(db)
    await enrichTrack(db, { ...okDeps, ...throwing(error) }, t)
    const text = await storedError(db, 'features')
    expect(text?.startsWith(TRANSIENT_PREFIX)).toBe(true)
    const rest = text!.slice(TRANSIENT_PREFIX.length)
    expect(rest).toBe(error instanceof EnrichSourceError ? String(error) : `internal: ${(error as Error).name}`)
  })

  it('prefixes an embedding binding failure as transient', async () => {
    const db = await createTestDb()
    const t = await seedTrack(db)
    const embed = workersAiEmbedder({ run: async () => { throw new Error('binding down') } })
    await enrichTrack(db, { ...okDeps, embed }, t)
    expect(await storedError(db, 'meaning')).toBe(`${TRANSIENT_PREFIX}EnrichSourceError: embedder: AI binding failed (Error)`)
  })

  it.each([
    ['HTTP 400', new EnrichSourceError('reccobeats', 'search HTTP 400', 400), 'EnrichSourceError: reccobeats: search HTTP 400'],
    ['HTTP 403', new EnrichSourceError('lrclib', 'HTTP 403', 403), 'EnrichSourceError: lrclib: HTTP 403'],
    ['HTTP 404', new EnrichSourceError('itunes', 'HTTP 404', 404), 'EnrichSourceError: itunes: HTTP 404'],
    ['a malformed response', new EnrichSourceError('reccobeats', 'malformed search JSON'), 'EnrichSourceError: reccobeats: malformed search JSON'],
    ['an unknown internal error', new Error('Failed query: secret'), 'internal: Error'],
    ['a stray TypeError', new TypeError('x is undefined'), 'internal: TypeError'],
    // Pinned as today: only 429 and 5xx are transient, so 408 and 425 are not.
    ['HTTP 408', new EnrichSourceError('lrclib', 'HTTP 408', 408), 'EnrichSourceError: lrclib: HTTP 408'],
    ['HTTP 425', new EnrichSourceError('lrclib', 'HTTP 425', 425), 'EnrichSourceError: lrclib: HTTP 425'],
  ])('stores %s as permanent, unprefixed', async (_label, error, expected) => {
    const db = await createTestDb()
    const t = await seedTrack(db)
    await enrichTrack(db, { ...okDeps, ...throwing(error) }, t)
    expect(await storedError(db, 'features')).toBe(expected)
  })

  it('stores a timeout while reading the body as transient, and an unparseable body as permanent', async () => {
    const bodyTimesOut = { ok: true, status: 200, json: async () => { throw new DOMException('timed out', 'TimeoutError') } } as unknown as Response
    const timedOut: FetchLike = async () => bodyTimesOut
    const db = await createTestDb()
    const t = await seedTrack(db)
    await enrichTrack(db, { ...okDeps, lyrics: (key) => fetchLyrics(key, timedOut) }, t)
    expect(await storedError(db, 'meaning')).toBe(`${TRANSIENT_PREFIX}EnrichSourceError: lrclib: body read failed (TimeoutError)`)

    const garbled: FetchLike = async () => new Response('<html>', { status: 200 })
    const db2 = await createTestDb()
    const t2 = await seedTrack(db2)
    await enrichTrack(db2, { ...okDeps, lyrics: (key) => fetchLyrics(key, garbled) }, t2)
    expect(await storedError(db2, 'meaning')).toBe('EnrichSourceError: lrclib: malformed JSON')
  })

  it('stores the no-match and no-lyrics misses as permanent', async () => {
    const db = await createTestDb()
    const t = await seedTrack(db)
    await enrichTrack(db, { ...okDeps, features: async () => null, lyrics: async () => null }, t)
    expect(await storedError(db, 'features')).toBe('no acceptable match')
    expect(await storedError(db, 'meaning')).toBe('no lyrics found')
  })

  it('stores an unexpected embedding response as permanent', async () => {
    const db = await createTestDb()
    const t = await seedTrack(db)
    const embed = workersAiEmbedder({ run: async () => ({}) })
    await enrichTrack(db, { ...okDeps, embed }, t)
    expect(await storedError(db, 'meaning')).toBe('internal: Error')
  })

  it('keeps the 500-character cap with the prefix included', async () => {
    const db = await createTestDb()
    const t = await seedTrack(db)
    await enrichTrack(db, { ...okDeps, ...throwing(new EnrichSourceError('reccobeats', 'x'.repeat(900), 503)) }, t)
    const text = await storedError(db, 'features')
    expect(text).toHaveLength(500)
    expect(text?.startsWith(TRANSIENT_PREFIX)).toBe(true)
  })

  it('still increments attempts and sets last_at on a transient failure', async () => {
    const db = await createTestDb()
    const t = await seedTrack(db)
    await seedFailure(db, t.id, { error: `${TRANSIENT_PREFIX}old`, attempts: 2, ageHours: 5 })
    const before = Date.now()
    await enrichTrack(db, { ...okDeps, ...throwing(new EnrichSourceError('lrclib', 'HTTP 503', 503)) }, t)
    const [row] = await db.select().from(enrichmentFailures)
    expect(row.attempts).toBe(3)
    expect(row.lastAt.getTime()).toBeGreaterThanOrEqual(before - 1000)
  })
})

describe('transient backoff selection', () => {
  it('exports the policy constants', () => {
    expect(MAX_ATTEMPTS).toBe(3)
    expect(MAX_TRANSIENT_ATTEMPTS).toBe(8)
    expect(TRANSIENT_BACKOFF_CAP_HOURS).toBe(24)
    expect(TRANSIENT_PREFIX).toBe('transient: ')
  })

  it('does not re-select a stage that just failed transiently', async () => {
    const db = await createTestDb()
    await seedFeaturesOnly(db)
    const features = vi.fn(async () => { throw new EnrichSourceError('reccobeats', 'search HTTP 503', 503) })
    expect(await runEnrichmentBatch(db, { ...okDeps, features }, 5))
      .toEqual({ processed: 1, features: 0, meaning: 0, remaining: 0, cooling: 1 })
    expect(await runEnrichmentBatch(db, { ...okDeps, features }, 5))
      .toEqual({ processed: 0, features: 0, meaning: 0, remaining: 0, cooling: 1 })
    expect(features).toHaveBeenCalledTimes(1)
  })

  // attempts -> hours: 1, 2, 4, 8, 16, 24, 24
  it.each([[1, 1], [2, 2], [3, 4], [4, 8], [5, 16], [6, 24], [7, 24]])(
    'after %i transient attempts waits %i hours',
    async (attempts, hours) => {
      const db = await createTestDb()
      const t = await seedFeaturesOnly(db)
      await seedFailure(db, t.id, { error: `${TRANSIENT_PREFIX}x`, attempts, ageHours: hours - 0.1 })
      expect(await runEnrichmentBatch(db, okDeps, 5)).toMatchObject({ processed: 0, remaining: 0, cooling: 1 })
      await db.update(enrichmentFailures).set({ lastAt: new Date(Date.now() - (hours + 0.1) * HOUR) })
      expect(await runEnrichmentBatch(db, okDeps, 5)).toMatchObject({ processed: 1, features: 1, remaining: 0, cooling: 0 })
    },
  )

  it('exhausts a transient stage at 8 attempts, not at 3', async () => {
    const db = await createTestDb()
    const t = await seedFeaturesOnly(db)
    await seedFailure(db, t.id, { error: `${TRANSIENT_PREFIX}x`, attempts: MAX_TRANSIENT_ATTEMPTS - 1, ageHours: 48 })
    expect((await enrichmentStatus(db)).exhausted).toBe(0)
    const failing = { ...okDeps, ...throwing(new EnrichSourceError('lrclib', 'HTTP 503', 503)) }
    expect(await runEnrichmentBatch(db, failing, 5)).toMatchObject({ processed: 1, remaining: 0, cooling: 0 })
    const [row] = await db.select().from(enrichmentFailures)
    expect(row.attempts).toBe(MAX_TRANSIENT_ATTEMPTS)
    await db.update(enrichmentFailures).set({ lastAt: new Date(Date.now() - 72 * HOUR) })
    expect(await runEnrichmentBatch(db, okDeps, 5)).toMatchObject({ processed: 0, remaining: 0, cooling: 0 })
    expect((await enrichmentStatus(db)).exhausted).toBe(1)
  })

  it('exhausts a permanent stage at 3 attempts with no backoff before that', async () => {
    const db = await createTestDb()
    const t = await seedFeaturesOnly(db)
    await seedFailure(db, t.id, { error: 'no acceptable match', attempts: MAX_ATTEMPTS - 1, ageHours: 0 })
    expect(await runEnrichmentBatch(db, { ...okDeps, features: async () => null }, 5))
      .toMatchObject({ processed: 1, remaining: 0, cooling: 0 })
    expect(await runEnrichmentBatch(db, okDeps, 5)).toMatchObject({ processed: 0, remaining: 0, cooling: 0 })
    expect((await enrichmentStatus(db)).exhausted).toBe(1)
  })

  it('a permanent failure after transient ones exhausts the stage once attempts reach 3', async () => {
    const db = await createTestDb()
    const t = await seedFeaturesOnly(db)
    await seedFailure(db, t.id, { error: `${TRANSIENT_PREFIX}x`, attempts: 3, ageHours: 48 })
    const notFound = { ...okDeps, ...throwing(new EnrichSourceError('reccobeats', 'search HTTP 400', 400)) }
    expect(await runEnrichmentBatch(db, notFound, 5)).toMatchObject({ processed: 1, remaining: 0, cooling: 0 })
    const [row] = await db.select().from(enrichmentFailures)
    expect(row).toMatchObject({ attempts: 4, error: 'EnrichSourceError: reccobeats: search HTTP 400' })
    expect(await runEnrichmentBatch(db, okDeps, 5)).toMatchObject({ processed: 0, remaining: 0, cooling: 0 })
    expect((await enrichmentStatus(db)).exhausted).toBe(1)
  })

  it('allows a permanent failure followed by transient ones up to 8 attempts in total', async () => {
    const db = await createTestDb()
    const t = await seedFeaturesOnly(db)
    await seedFailure(db, t.id, { error: 'no acceptable match', attempts: 2, ageHours: 0 })
    const failing = { ...okDeps, ...throwing(new EnrichSourceError('reccobeats', 'search HTTP 503', 503)) }
    for (let attempts = 3; attempts <= MAX_TRANSIENT_ATTEMPTS; attempts++) {
      await db.update(enrichmentFailures).set({ lastAt: new Date(Date.now() - 48 * HOUR) })
      expect(await runEnrichmentBatch(db, failing, 5)).toMatchObject({ processed: 1 })
      const [row] = await db.select().from(enrichmentFailures)
      expect(row.attempts).toBe(attempts)
      expect(row.error.startsWith(TRANSIENT_PREFIX)).toBe(true)
    }
    await db.update(enrichmentFailures).set({ lastAt: new Date(Date.now() - 48 * HOUR) })
    expect(await runEnrichmentBatch(db, okDeps, 5)).toMatchObject({ processed: 0, remaining: 0, cooling: 0 })
    expect((await enrichmentStatus(db)).exhausted).toBe(1)
  })

  it('a cooling high-priority track does not hold the batch: limit 1 takes the due low-priority track', async () => {
    const db = await createTestDb()
    for (const title of ['hot-1', 'hot-2']) {
      const [t] = await db.insert(tracks).values({ appleId: title, title, artist: 'A', enrichPriority: 9 }).returning()
      await db.insert(trackMeanings).values({ trackId: t.id, embedding: null, lyricsSource: 'lrclib', instrumental: true })
      await seedFailure(db, t.id, { error: `${TRANSIENT_PREFIX}x`, attempts: 1, ageHours: 0 })
    }
    await db.insert(tracks).values({ appleId: 'cold', title: 'cold', artist: 'A', enrichPriority: 0 })
    const features = vi.fn(async () => OK_FEATURES)
    expect(await runEnrichmentBatch(db, { ...okDeps, features }, 1))
      .toEqual({ processed: 1, features: 1, meaning: 1, remaining: 0, cooling: 2 })
    expect(features).toHaveBeenCalledExactlyOnceWith(expect.objectContaining({ title: 'cold' }))
  })

  it('treats old unprefixed rows as before: retried at once below 3, exhausted at 3', async () => {
    const db = await createTestDb()
    const a = await seedFeaturesOnly(db, 'below')
    const b = await seedFeaturesOnly(db, 'at')
    await seedFailure(db, a.id, { error: 'EnrichSourceError: lrclib: HTTP 503', attempts: 2, ageHours: 0 })
    await seedFailure(db, b.id, { error: 'EnrichSourceError: lrclib: HTTP 503', attempts: 3, ageHours: 0 })
    const features = vi.fn(async () => OK_FEATURES)
    expect(await runEnrichmentBatch(db, { ...okDeps, features }, 5))
      .toEqual({ processed: 1, features: 1, meaning: 0, remaining: 0, cooling: 0 })
    expect(features).toHaveBeenCalledExactlyOnceWith(expect.objectContaining({ title: 'below' }))
    expect((await enrichmentStatus(db)).exhausted).toBe(1)
  })

  it('a cooling stage does not block the other stage, and is skipped while it runs', async () => {
    const db = await createTestDb()
    const t = await seedTrack(db)
    await seedFailure(db, t.id, { error: `${TRANSIENT_PREFIX}x`, attempts: 1, ageHours: 0 })
    const features = vi.fn(async () => OK_FEATURES)
    expect(await runEnrichmentBatch(db, { ...okDeps, features }, 5))
      .toEqual({ processed: 1, features: 0, meaning: 1, remaining: 0, cooling: 1 })
    expect(features).not.toHaveBeenCalled()
    expect(await db.select().from(trackMeanings)).toHaveLength(1)
    expect(await db.select().from(trackFeatures)).toHaveLength(0)
  })

  it('a cooling stage alone does not make a track a candidate', async () => {
    const db = await createTestDb()
    const t = await seedTrack(db)
    await seedFailure(db, t.id, { stage: 'features', error: `${TRANSIENT_PREFIX}x`, attempts: 2, ageHours: 0 })
    await seedFailure(db, t.id, { stage: 'meaning', error: `${TRANSIENT_PREFIX}x`, attempts: 1, ageHours: 0 })
    expect(await runEnrichmentBatch(db, okDeps, 5)).toEqual({ processed: 0, features: 0, meaning: 0, remaining: 0, cooling: 1 })
  })

  it('reports remaining (due now) and cooling (waiting on backoff) without counting a track twice', async () => {
    const db = await createTestDb()
    await seedTrack(db, 'due')
    const cooling = await seedFeaturesOnly(db, 'cooling')
    await seedFailure(db, cooling.id, { error: `${TRANSIENT_PREFIX}x`, attempts: 1, ageHours: 0 })
    const exhausted = await seedFeaturesOnly(db, 'exhausted')
    await seedFailure(db, exhausted.id, { error: 'no acceptable match', attempts: 3, ageHours: 0 })
    // features cooling, meaning still due: counts once, as remaining.
    const mixed = await seedTrack(db, 'mixed')
    await seedFailure(db, mixed.id, { error: `${TRANSIENT_PREFIX}x`, attempts: 1, ageHours: 0 })
    expect(await runEnrichmentBatch(db, okDeps, 0)).toEqual({ processed: 0, features: 0, meaning: 0, remaining: 2, cooling: 1 })
  })
})
