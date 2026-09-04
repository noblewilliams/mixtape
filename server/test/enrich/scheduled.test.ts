import { describe, it, expect, vi } from 'vitest'
import { createTestDb } from '../helpers/db'
import { okDeps } from '../helpers/enrich-fixtures'
import { handleScheduled, CRON_BATCH } from '../../src/enrich/scheduled'
import { tracks, trackFeatures } from '../../src/db/schema'
import type { ArtworkRunResult } from '../../src/artwork/runner'
import type { PlaylistCatalogResult } from '../../src/playlists/catalog-resolution'

const emptyCatalog: PlaylistCatalogResult = { processed: 0, matched: 0, missing: 0, failed: 0, linkedEntries: 0 }

describe('handleScheduled', () => {
  it('resolves playlist catalog identities before existing enrichment and artwork work', async () => {
    const db = await createTestDb()
    const order: string[] = []
    const catalog = { getSongs: async () => new Map() }
    const playlistCatalog = vi.fn(async () => { order.push('catalog'); return emptyCatalog })
    const enrichment = vi.fn(async () => { order.push('enrichment'); return { processed: 0, features: 0, meaning: 0, remaining: 0 } })
    const artwork = vi.fn(async () => { order.push('artwork'); return { processed: 0, matched: 0, missing: 0, failed: 0, remaining: 0 } })
    const result = await handleScheduled(db, { enrichment: okDeps, artwork: { storefront: 'ng', catalog } },
      { playlistCatalog, enrichment, artwork })
    expect(order).toEqual(['catalog', 'enrichment', 'artwork'])
    expect(result.playlistCatalog).toEqual(emptyCatalog)
    expect(playlistCatalog).toHaveBeenCalledWith(db, { catalog, now: undefined })
  })

  it('keeps existing maintenance running after catalog resolution fails, without returning the error text', async () => {
    const db = await createTestDb()
    const playlistCatalog = vi.fn(async () => { throw new Error('SECRET CATALOG SQL') })
    const artwork = vi.fn(async () => ({ processed: 0, matched: 0, missing: 0, failed: 0, remaining: 0 }))
    const result = await handleScheduled(db, { artwork: { storefront: 'ng', catalog: { getSongs: async () => new Map() } } },
      { playlistCatalog, artwork })
    expect(result.playlistCatalog).toEqual({ error: 'failed' })
    expect(artwork).toHaveBeenCalledOnce()
    expect(JSON.stringify(result)).not.toContain('SECRET CATALOG SQL')
  })

  it('processes a small batch', async () => {
    const db = await createTestDb()
    await db.insert(tracks).values({ appleId: 'c1', title: 'T', artist: 'A' })
    const r = await handleScheduled(db, { enrichment: okDeps })
    expect(r.enrichment).toMatchObject({ processed: 1 })
    expect(await db.select().from(trackFeatures)).toHaveLength(1)
  })

  it('caps at CRON_BATCH', async () => {
    const db = await createTestDb()
    for (let i = 0; i < CRON_BATCH + 3; i++) {
      await db.insert(tracks).values({ appleId: `c${i}`, title: 'T', artist: 'A' })
    }
    const r = await handleScheduled(db, { enrichment: okDeps })
    expect(r.enrichment).toMatchObject({ processed: CRON_BATCH })
  })

  it('runs artwork even when feature and meaning enrichment fails', async () => {
    const db = await createTestDb()
    const artworkResult: ArtworkRunResult = {
      processed: 1,
      matched: 1,
      missing: 0,
      failed: 0,
      remaining: 0,
    }
    const runEnrichment = vi.fn(async () => { throw new Error('secret feature failure') })
    const runArtwork = vi.fn(async () => artworkResult)

    const result = await handleScheduled(
      db,
      { enrichment: okDeps, artwork: { storefront: 'ng', catalog: { getSongs: async () => new Map() } } },
      { enrichment: runEnrichment, artwork: runArtwork },
    )

    expect(runEnrichment).toHaveBeenCalledOnce()
    expect(runArtwork).toHaveBeenCalledOnce()
    expect(result).toEqual({
      enrichment: { error: 'failed' },
      artwork: artworkResult,
      playlistCatalog: emptyCatalog,
      libraryCleanup: expect.objectContaining({ touchedRuns: 0 }),
      listeningCleanup: expect.objectContaining({ touchedRuns: 0 }),
      playlistCleanup: expect.objectContaining({ touchedRuns: 0 }),
    })
  })

  it('runs feature and meaning enrichment even when artwork fails', async () => {
    const db = await createTestDb()
    const enrichmentResult = { processed: 1, features: 1, meaning: 1, remaining: 0 }
    const runEnrichment = vi.fn(async () => enrichmentResult)
    const runArtwork = vi.fn(async () => { throw new Error('secret artwork failure') })

    const result = await handleScheduled(
      db,
      { enrichment: okDeps, artwork: { storefront: 'ng', catalog: { getSongs: async () => new Map() } } },
      { enrichment: runEnrichment, artwork: runArtwork },
    )

    expect(runEnrichment).toHaveBeenCalledOnce()
    expect(runArtwork).toHaveBeenCalledOnce()
    expect(result).toEqual({
      enrichment: enrichmentResult,
      artwork: { error: 'failed' },
      playlistCatalog: emptyCatalog,
      libraryCleanup: expect.objectContaining({ touchedRuns: 0 }),
      listeningCleanup: expect.objectContaining({ touchedRuns: 0 }),
      playlistCleanup: expect.objectContaining({ touchedRuns: 0 }),
    })
  })

  it('runs playlist cleanup even without enrichment or artwork dependencies', async () => {
    const db = await createTestDb()
    const playlistCleanup = vi.fn(async () => ({
      touchedRuns: 0,
      expiredRuns: 0,
      deletedEntries: 0,
      deletedPlaylists: 0,
      purgedRuns: 0,
    }))

    const result = await handleScheduled(db, {}, { playlistCleanup })

    expect(playlistCleanup).toHaveBeenCalledOnce()
    expect(result.playlistCleanup).toMatchObject({ touchedRuns: 0 })
  })

  it('runs library cleanup even without enrichment or artwork dependencies', async () => {
    const db = await createTestDb()
    const libraryCleanup = vi.fn(async () => ({
      touchedRuns: 1,
      expiredRuns: 1,
      deletedSongs: 0,
      deletedRecentTracks: 0,
      purgedRuns: 0,
    }))

    const result = await handleScheduled(db, {}, { libraryCleanup })

    expect(libraryCleanup).toHaveBeenCalledOnce()
    expect(result.libraryCleanup).toMatchObject({ expiredRuns: 1 })
  })

  it('runs listening cleanup even without enrichment or artwork dependencies', async () => {
    const db = await createTestDb()
    const listeningCleanup = vi.fn(async () => ({
      touchedRuns: 1,
      expiredRuns: 1,
      deletedTracks: 0,
      deletedDays: 0,
      deletedLibraryTracks: 0,
      deletedArtists: 0,
      purgedRuns: 0,
    }))

    const result = await handleScheduled(db, {}, { listeningCleanup })

    expect(listeningCleanup).toHaveBeenCalledOnce()
    expect(result.listeningCleanup).toMatchObject({ expiredRuns: 1 })
  })

  it('keeps library and playlist cleanup independent from listening cleanup failure', async () => {
    const db = await createTestDb()
    const listeningCleanup = vi.fn(async () => { throw new Error('secret listening cleanup failure') })
    const playlistCleanup = vi.fn(async () => ({
      touchedRuns: 0,
      expiredRuns: 0,
      deletedEntries: 0,
      deletedPlaylists: 0,
      purgedRuns: 0,
    }))

    const result = await handleScheduled(db, {}, { listeningCleanup, playlistCleanup })

    expect(playlistCleanup).toHaveBeenCalledOnce()
    expect(result).toEqual({
      libraryCleanup: expect.objectContaining({ touchedRuns: 0 }),
      listeningCleanup: { error: 'failed' },
      playlistCleanup: expect.objectContaining({ touchedRuns: 0 }),
    })
  })

  it('keeps playlist cleanup independent from library cleanup failure', async () => {
    const db = await createTestDb()
    const libraryCleanup = vi.fn(async () => { throw new Error('secret library cleanup failure') })
    const playlistCleanup = vi.fn(async () => ({
      touchedRuns: 0,
      expiredRuns: 0,
      deletedEntries: 0,
      deletedPlaylists: 0,
      purgedRuns: 0,
    }))

    const result = await handleScheduled(db, {}, { libraryCleanup, playlistCleanup })

    expect(playlistCleanup).toHaveBeenCalledOnce()
    expect(result).toEqual({
      libraryCleanup: { error: 'failed' },
      listeningCleanup: expect.objectContaining({ touchedRuns: 0 }),
      playlistCleanup: expect.objectContaining({ touchedRuns: 0 }),
    })
  })

  it('keeps playlist cleanup independent from enrichment failure', async () => {
    const db = await createTestDb()
    const enrichment = vi.fn(async () => { throw new Error('secret feature failure') })
    const playlistCleanup = vi.fn(async () => ({
      touchedRuns: 1,
      expiredRuns: 1,
      deletedEntries: 0,
      deletedPlaylists: 0,
      purgedRuns: 0,
    }))

    const result = await handleScheduled(db, { enrichment: okDeps }, {
      enrichment,
      playlistCleanup,
    })

    expect(result).toEqual({
      enrichment: { error: 'failed' },
      libraryCleanup: expect.objectContaining({ touchedRuns: 0 }),
      listeningCleanup: expect.objectContaining({ touchedRuns: 0 }),
      playlistCleanup: expect.objectContaining({ expiredRuns: 1 }),
    })
  })

  it('keeps enrichment independent from playlist cleanup failure', async () => {
    const db = await createTestDb()
    const enrichmentResult = { processed: 0, features: 0, meaning: 0, remaining: 0 }
    const enrichment = vi.fn(async () => enrichmentResult)
    const playlistCleanup = vi.fn(async () => { throw new Error('secret cleanup failure') })

    const result = await handleScheduled(db, { enrichment: okDeps }, {
      enrichment,
      playlistCleanup,
    })

    expect(result).toEqual({
      enrichment: enrichmentResult,
      libraryCleanup: expect.objectContaining({ touchedRuns: 0 }),
      listeningCleanup: expect.objectContaining({ touchedRuns: 0 }),
      playlistCleanup: { error: 'failed' },
    })
  })
})
