import { eq } from 'drizzle-orm'
import { describe, expect, it, vi } from 'vitest'
import {
  ARTWORK_REFRESH_MS,
  ARTWORK_MALFORMED_RETRY_MS,
  ARTWORK_NO_MATCH_RETRY_MS,
  ARTWORK_RATE_LIMIT_RETRY_MS,
  ARTWORK_UPSTREAM_RETRY_MS,
  runArtworkBatch,
  artworkStatus,
  type ArtworkDeps,
} from '../../src/artwork/runner'
import { AppleCatalogError, type CatalogSong } from '../../src/musickit/catalog'
import {
  enrichmentFailures,
  trackArtworkStatus,
  tracks,
} from '../../src/db/schema'
import { createTestDb, type TestDb } from '../helpers/db'

const NOW = new Date('2026-08-31T12:00:00.000Z')
const OLD = new Date(NOW.getTime() - ARTWORK_REFRESH_MS - 1)

function song(appleId: string, bgColor = 'a1b2c3'): CatalogSong {
  return {
    appleId,
    isrc: null,
    title: `Song ${appleId}`,
    artist: 'Artist',
    album: 'Album',
    artwork: {
      url: `https://is1-ssl.mzstatic.com/image/thumb/${appleId}/{w}x{h}.{f}`,
      width: 3000,
      height: 3000,
      bgColor,
    },
  }
}

function deps(getSongs: ArtworkDeps['catalog']['getSongs']): ArtworkDeps {
  return {
    storefront: 'ng',
    catalog: { getSongs: vi.fn(getSongs) },
    now: () => NOW,
  }
}

async function seed(
  db: TestDb,
  appleId: string | null,
  options: {
    createdAt?: Date
    artwork?: boolean
    fresh?: boolean
  } = {},
) {
  const [row] = await db
    .insert(tracks)
    .values({
      appleId,
      title: `Track ${appleId ?? 'local'}`,
      artist: 'Artist',
      createdAt: options.createdAt,
      ...(options.artwork
        ? {
            artworkUrlTemplate: 'https://is1-ssl.mzstatic.com/image/thumb/known/{w}x{h}.{f}',
            artworkWidth: 1000,
            artworkHeight: 1000,
            artworkBgColor: 'abcdef',
            artworkFetchedAt: options.fresh ? NOW : OLD,
          }
        : {}),
    })
    .returning()
  return row
}

describe('runArtworkBatch', () => {
  it('refreshes one recorded catalog market per pass and keeps the default for legacy tracks', async () => {
    const db = await createTestDb()
    const gb = await seed(db, 'gb-song', { createdAt: new Date('2026-01-01T00:00:00Z') })
    await db.update(tracks).set({ appleCatalogStorefront: 'gb' }).where(eq(tracks.id, gb.id))
    await seed(db, 'legacy-song', { createdAt: new Date('2026-01-02T00:00:00Z') })
    const getSongs = vi.fn(async (_storefront: string, ids: readonly string[]) => new Map(ids.map(id => [id, song(id)])))
    expect(await runArtworkBatch(db, deps(getSongs), 300)).toMatchObject({ processed: 1, matched: 1, remaining: 1 })
    expect(getSongs).toHaveBeenNthCalledWith(1, 'gb', ['gb-song'])
    expect(await runArtworkBatch(db, deps(getSongs), 300)).toMatchObject({ processed: 1, matched: 1, remaining: 0 })
    expect(getSongs).toHaveBeenNthCalledWith(2, 'ng', ['legacy-song'])
  })

  it('selects only Apple tracks with missing or stale artwork in deterministic order', async () => {
    const db = await createTestDb()
    await seed(db, 'third', { createdAt: new Date('2026-01-03T00:00:00Z') })
    await seed(db, null, { createdAt: new Date('2026-01-01T00:00:00Z') })
    await seed(db, 'fresh', { artwork: true, fresh: true, createdAt: new Date('2026-01-01T00:00:00Z') })
    await seed(db, 'first', { createdAt: new Date('2026-01-01T00:00:00Z') })
    await seed(db, 'second', { artwork: true, createdAt: new Date('2026-01-02T00:00:00Z') })
    const getSongs = vi.fn(async (_storefront: string, ids: readonly string[]) =>
      new Map(ids.map((id) => [id, song(id)])),
    )

    const result = await runArtworkBatch(db, deps(getSongs), 10)

    expect(getSongs).toHaveBeenCalledOnce()
    expect(getSongs.mock.calls[0][0]).toBe('ng')
    expect(getSongs.mock.calls[0][1]).toEqual(['first', 'second', 'third'])
    expect(result).toEqual({ processed: 3, matched: 3, missing: 0, failed: 0, remaining: 0 })
  })

  it('never sends more than 300 IDs in its single Apple request', async () => {
    const db = await createTestDb()
    for (let i = 0; i < 305; i++) await seed(db, `song-${String(i).padStart(3, '0')}`)
    const getSongs = vi.fn(async (_storefront: string, _ids: readonly string[]) =>
      new Map<string, CatalogSong>(),
    )

    const result = await runArtworkBatch(db, deps(getSongs), 999)

    expect(getSongs).toHaveBeenCalledOnce()
    expect(getSongs.mock.calls[0][1]).toHaveLength(300)
    expect(result.processed).toBe(300)
    expect(result.remaining).toBe(5)
  })

  it('serializes concurrent runs so they cannot fetch the same candidate', async () => {
    const db = await createTestDb()
    await seed(db, 'one', { createdAt: new Date('2026-01-01T00:00:00Z') })
    await seed(db, 'two', { createdAt: new Date('2026-01-02T00:00:00Z') })
    let releaseFirst!: () => void
    const firstMayFinish = new Promise<void>((resolve) => { releaseFirst = resolve })
    let firstStarted!: () => void
    const firstDidStart = new Promise<void>((resolve) => { firstStarted = resolve })
    const requested: string[][] = []

    const firstRun = runArtworkBatch(
      db,
      deps(async (_storefront, ids) => {
        requested.push([...ids])
        firstStarted()
        await firstMayFinish
        return new Map(ids.map((id) => [id, song(id)]))
      }),
      1,
    )
    await firstDidStart
    const secondRun = runArtworkBatch(
      db,
      deps(async (_storefront, ids) => {
        requested.push([...ids])
        return new Map(ids.map((id) => [id, song(id)]))
      }),
      1,
    )
    releaseFirst()

    const results = await Promise.all([firstRun, secondRun])

    expect(requested).toEqual([['one'], ['two']])
    expect(results.map((result) => result.matched)).toEqual([1, 1])
  })

  it('prevents a late concurrent failure from recreating retry state after success', async () => {
    const db = await createTestDb()
    await seed(db, 'one')
    let releaseSuccess!: () => void
    const successMayFinish = new Promise<void>((resolve) => { releaseSuccess = resolve })
    let successStarted!: () => void
    const successDidStart = new Promise<void>((resolve) => { successStarted = resolve })
    const lateFailure = vi.fn(async () => {
      throw new AppleCatalogError('upstream', 503)
    })

    const successfulRun = runArtworkBatch(
      db,
      deps(async (_storefront, ids) => {
        successStarted()
        await successMayFinish
        return new Map(ids.map((id) => [id, song(id)]))
      }),
      1,
    )
    await successDidStart
    const overlappingRun = runArtworkBatch(db, deps(lateFailure), 1)
    releaseSuccess()

    const [, second] = await Promise.all([successfulRun, overlappingRun])

    expect(second).toEqual({ processed: 0, matched: 0, missing: 0, failed: 0, remaining: 0 })
    expect(lateFailure).not.toHaveBeenCalled()
    expect(await db.select().from(trackArtworkStatus)).toEqual([])
  })

  it('updates valid artwork and clears prior retry state', async () => {
    const db = await createTestDb()
    const track = await seed(db, 'one')
    await db.insert(trackArtworkStatus).values({
      trackId: track.id,
      attempts: 2,
      lastCategory: 'upstream',
      nextAttemptAt: new Date('2026-01-01T00:00:00Z'),
      updatedAt: new Date('2026-01-01T00:00:00Z'),
    })

    const result = await runArtworkBatch(
      db,
      deps(async () => new Map([['one', song('one')]])),
      10,
    )

    const [updated] = await db.select().from(tracks).where(eq(tracks.id, track.id))
    expect(updated).toMatchObject({
      artworkWidth: 3000,
      artworkHeight: 3000,
      artworkBgColor: 'a1b2c3',
      artworkFetchedAt: NOW,
    })
    expect(updated.artworkUrlTemplate).toContain('/one/')
    expect(await db.select().from(trackArtworkStatus)).toEqual([])
    expect(result.matched).toBe(1)
  })

  it('does not erase known artwork when a later catalog result has null artwork', async () => {
    const db = await createTestDb()
    const track = await seed(db, 'one', { artwork: true })
    const withoutArtwork = { ...song('one'), artwork: null }

    const result = await runArtworkBatch(
      db,
      deps(async () => new Map([['one', withoutArtwork]])),
      10,
    )

    const [updated] = await db.select().from(tracks).where(eq(tracks.id, track.id))
    expect(updated.artworkUrlTemplate).toContain('/known/')
    expect(updated.artworkBgColor).toBe('abcdef')
    expect(updated.artworkFetchedAt).toEqual(OLD)
    expect(result).toMatchObject({ processed: 1, matched: 0, missing: 0, failed: 1 })
    expect(await db.select().from(trackArtworkStatus)).toMatchObject([
      { trackId: track.id, attempts: 1, lastCategory: 'malformed' },
    ])
  })

  it('does not erase known optional metadata during a valid artwork refresh', async () => {
    const db = await createTestDb()
    const track = await seed(db, 'one', { artwork: true })
    const refreshed = song('one')
    refreshed.artwork = {
      ...refreshed.artwork!,
      height: null,
      bgColor: null,
    }

    const result = await runArtworkBatch(
      db,
      deps(async () => new Map([['one', refreshed]])),
      10,
    )

    const [updated] = await db.select().from(tracks).where(eq(tracks.id, track.id))
    expect(updated.artworkUrlTemplate).toContain('/one/')
    expect(updated.artworkWidth).toBe(3000)
    expect(updated.artworkHeight).toBe(1000)
    expect(updated.artworkBgColor).toBe('abcdef')
    expect(updated.artworkFetchedAt).toEqual(NOW)
    expect(result).toMatchObject({ processed: 1, matched: 1, missing: 0, failed: 0 })
  })

  it('ignores an unrequested response ID', async () => {
    const db = await createTestDb()
    const requested = await seed(db, 'requested')
    const untouched = await seed(db, 'other', { artwork: true, fresh: true })

    await runArtworkBatch(
      db,
      deps(async () => new Map([
        ['requested', song('requested')],
        ['other', song('other', '123456')],
        ['unknown', song('unknown')],
      ])),
      1,
    )

    const [updatedRequested] = await db.select().from(tracks).where(eq(tracks.id, requested.id))
    const [updatedOther] = await db.select().from(tracks).where(eq(tracks.id, untouched.id))
    expect(updatedRequested.artworkUrlTemplate).toContain('/requested/')
    expect(updatedOther.artworkBgColor).toBe('abcdef')
  })

  it('records no-match separately and processes partial batches safely', async () => {
    const db = await createTestDb()
    await seed(db, 'matched', { createdAt: new Date('2026-01-01T00:00:00Z') })
    await seed(db, 'missing', { createdAt: new Date('2026-01-02T00:00:00Z') })
    await seed(db, 'malformed', { createdAt: new Date('2026-01-03T00:00:00Z') })
    const malformed = { ...song('malformed'), artwork: null }

    const result = await runArtworkBatch(
      db,
      deps(async () => new Map([
        ['matched', song('matched')],
        ['malformed', malformed],
      ])),
      10,
    )

    expect(result).toEqual({ processed: 3, matched: 1, missing: 1, failed: 1, remaining: 0 })
    const statuses = await db.select().from(trackArtworkStatus)
    expect(statuses.map((row) => row.lastCategory).sort()).toEqual(['malformed', 'no_match'])
    expect(statuses.find((row) => row.lastCategory === 'no_match')?.nextAttemptAt).toEqual(
      new Date(NOW.getTime() + ARTWORK_NO_MATCH_RETRY_MS),
    )
    expect(statuses.find((row) => row.lastCategory === 'malformed')?.nextAttemptAt).toEqual(
      new Date(NOW.getTime() + ARTWORK_MALFORMED_RETRY_MS),
    )
  })

  it.each([
    ['rate_limit', 429, ARTWORK_RATE_LIMIT_RETRY_MS],
    ['upstream', 503, ARTWORK_UPSTREAM_RETRY_MS],
    ['timeout', undefined, ARTWORK_UPSTREAM_RETRY_MS],
  ] as const)('records fixed %s failures for the whole attempted batch', async (category, status, retryAfterMs) => {
    const db = await createTestDb()
    await seed(db, 'one')
    await seed(db, 'two')

    const result = await runArtworkBatch(
      db,
      deps(async () => { throw new AppleCatalogError(category, status) }),
      10,
    )

    expect(result).toMatchObject({ processed: 2, matched: 0, missing: 0, failed: 2 })
    const statuses = await db.select().from(trackArtworkStatus)
    expect(statuses).toHaveLength(2)
    expect(statuses.every((row) => row.lastCategory === category)).toBe(true)
    expect(statuses.every((row) => row.nextAttemptAt.getTime() === NOW.getTime() + retryAfterMs)).toBe(true)
  })

  it('keeps artwork attempts independent from feature and meaning failures', async () => {
    const db = await createTestDb()
    const track = await seed(db, 'one')
    await db.insert(enrichmentFailures).values([
      { trackId: track.id, stage: 'features', error: 'fixed', attempts: 2 },
      { trackId: track.id, stage: 'meaning', error: 'fixed', attempts: 1 },
    ])

    await runArtworkBatch(
      db,
      deps(async () => { throw new AppleCatalogError('upstream', 500) }),
      10,
    )

    expect(await db.select().from(enrichmentFailures)).toMatchObject([
      { stage: 'features', attempts: 2 },
      { stage: 'meaning', attempts: 1 },
    ])
  })

  it('retries only status rows whose next attempt is due', async () => {
    const db = await createTestDb()
    const due = await seed(db, 'due')
    const later = await seed(db, 'later')
    await db.insert(trackArtworkStatus).values([
      {
        trackId: due.id,
        attempts: 1,
        lastCategory: 'upstream',
        nextAttemptAt: new Date(NOW.getTime() - 1),
        updatedAt: OLD,
      },
      {
        trackId: later.id,
        attempts: 1,
        lastCategory: 'no_match',
        nextAttemptAt: new Date(NOW.getTime() + 60_000),
        updatedAt: OLD,
      },
    ])
    const getSongs = vi.fn(async (_storefront: string, _ids: readonly string[]) =>
      new Map([['due', song('due')]]),
    )

    await runArtworkBatch(db, deps(getSongs), 10)

    expect(getSongs.mock.calls[0][1]).toEqual(['due'])
    expect(await db.select().from(trackArtworkStatus).where(eq(trackArtworkStatus.trackId, later.id))).toHaveLength(1)
  })

  it('reports total, covered, missing, and currently retryable counts', async () => {
    const db = await createTestDb()
    await seed(db, 'covered', { artwork: true, fresh: true })
    await seed(db, 'due')
    const delayed = await seed(db, 'delayed')
    await seed(db, null)
    await db.insert(trackArtworkStatus).values({
      trackId: delayed.id,
      attempts: 1,
      lastCategory: 'no_match',
      nextAttemptAt: new Date(NOW.getTime() + 60_000),
      updatedAt: OLD,
    })

    await expect(artworkStatus(db, NOW)).resolves.toEqual({
      tracks: 4,
      withArtwork: 1,
      missingArtwork: 3,
      retryable: 1,
    })
  })
})
