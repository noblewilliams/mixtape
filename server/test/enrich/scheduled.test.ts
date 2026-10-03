import { describe, it, expect, vi } from 'vitest'
import { readFileSync } from 'node:fs'
import { createTestDb } from '../helpers/db'
import { okDeps, OK_FEATURES } from '../helpers/enrich-fixtures'
import {
  handleScheduled,
  jobsForCron,
  CRON_BATCH,
  ENRICHMENT_CRON,
  MAINTENANCE_CRON,
} from '../../src/enrich/scheduled'
import worker from '../../src/index'
import { tracks, trackFeatures, trackMeanings } from '../../src/db/schema'
import type { PlaylistCatalogResult } from '../../src/playlists/catalog-resolution'

const emptyCatalog: PlaylistCatalogResult = { processed: 0, matched: 0, missing: 0, failed: 0, linkedEntries: 0 }
const emptyEnrichment = { processed: 0, features: 0, meaning: 0, remaining: 0 }
const emptyArtwork = { processed: 0, matched: 0, missing: 0, failed: 0, remaining: 0 }
const emptyIsrc = { processed: 0, linked: 0, missing: 0, ambiguous: 0, conflicts: 0, failed: 0, skipped: 0 }
const emptySpotifyArtwork = { processed: 0, matched: 0, spotify: 0, deezer: 0, missing: 0, failed: 0, skipped: 0, remaining: 0 }
const emptyTwins = { features: 0, meanings: 0 }
const catalog = { getSongs: async () => new Map(), getSongsByIsrc: async () => new Map() }
const allDeps = {
  enrichment: okDeps,
  artwork: { storefront: 'ng', catalog },
  appleIsrc: { catalog },
  spotifyArtwork: { spotify: { getArtwork: async () => null } },
}

function recordingRunners(order: string[]) {
  const cleanup = { touchedRuns: 0, expiredRuns: 0, purgedRuns: 0 }
  return {
    libraryCleanup: vi.fn(async () => { order.push('libraryCleanup'); return { ...cleanup, deletedSongs: 0, deletedRecentTracks: 0 } }),
    listeningCleanup: vi.fn(async () => {
      order.push('listeningCleanup')
      return { ...cleanup, deletedTracks: 0, deletedDays: 0, deletedLibraryTracks: 0, deletedArtists: 0 }
    }),
    playlistCleanup: vi.fn(async () => { order.push('playlistCleanup'); return { ...cleanup, deletedEntries: 0, deletedPlaylists: 0 } }),
    playlistCatalog: vi.fn(async () => { order.push('playlistCatalog'); return emptyCatalog }),
    twinCopy: vi.fn(async () => { order.push('twinCopy'); return emptyTwins }),
    enrichment: vi.fn(async () => { order.push('enrichment'); return emptyEnrichment }),
    appleIsrc: vi.fn(async () => { order.push('appleIsrc'); return emptyIsrc }),
    spotifyArtwork: vi.fn(async () => { order.push('spotifyArtwork'); return emptySpotifyArtwork }),
    artwork: vi.fn(async () => { order.push('artwork'); return emptyArtwork }),
  }
}

describe('cron dispatch', () => {
  it('declares exactly the two crons in wrangler.jsonc', () => {
    const config = readFileSync(new URL('../../wrangler.jsonc', import.meta.url), 'utf8')
    const crons = /"crons"\s*:\s*(\[[^\]]*\])/.exec(config)?.[1]
    expect(JSON.parse(crons ?? 'null')).toEqual([MAINTENANCE_CRON, ENRICHMENT_CRON])
    expect([MAINTENANCE_CRON, ENRICHMENT_CRON]).toEqual(['0 * * * *', '2 * * * *'])
  })

  it('maps each cron to its job set and anything else to none', () => {
    expect(jobsForCron(MAINTENANCE_CRON)).toBe('maintenance')
    expect(jobsForCron(ENRICHMENT_CRON)).toBe('enrichment')
    expect(jobsForCron('*/15 * * * *')).toBeNull()
    expect(jobsForCron('')).toBeNull()
  })

  it('an unknown cron runs nothing and logs a fixed marker', async () => {
    const log = vi.spyOn(console, 'log').mockImplementation(() => {})
    const waitUntil = vi.fn()
    // An empty env would throw at buildDb if dispatch reached it.
    await worker.scheduled({ cron: '5 * * * *', scheduledTime: 0 }, {} as never, { waitUntil } as never)
    expect(log).toHaveBeenCalledExactlyOnceWith('maintenance cron', JSON.stringify({ jobs: 'unknown' }))
    expect(waitUntil).not.toHaveBeenCalled()
    log.mockRestore()
  })
})

describe('handleScheduled', () => {
  it('the maintenance set runs cleanup, catalogue resolution and Apple artwork, in order, and nothing else', async () => {
    const db = await createTestDb()
    const order: string[] = []
    const result = await handleScheduled(db, 'maintenance', allDeps, recordingRunners(order))
    expect(order).toEqual([
      'libraryCleanup', 'listeningCleanup', 'playlistCleanup', 'playlistCatalog', 'artwork',
    ])
    expect(Object.keys(result).sort()).toEqual([
      'artwork', 'libraryCleanup', 'listeningCleanup', 'playlistCatalog', 'playlistCleanup',
    ])
  })

  it('the enrichment set runs twin copy, enrichment, Apple ISRC linking and the Spotify fallback, in order, and nothing else', async () => {
    const db = await createTestDb()
    const order: string[] = []
    const runners = recordingRunners(order)
    const result = await handleScheduled(db, 'enrichment', allDeps, runners)
    expect(order).toEqual(['twinCopy', 'enrichment', 'appleIsrc', 'spotifyArtwork'])
    expect(result).toEqual({
      twinCopy: emptyTwins, enrichment: emptyEnrichment, appleIsrc: emptyIsrc, spotifyArtwork: emptySpotifyArtwork,
    })
    expect(runners.twinCopy).toHaveBeenCalledWith(db)
    expect(runners.enrichment).toHaveBeenCalledWith(db, okDeps, CRON_BATCH)
  })

  it('resolves playlist catalog identities with the artwork catalogue', async () => {
    const db = await createTestDb()
    const playlistCatalog = vi.fn(async () => emptyCatalog)
    const result = await handleScheduled(db, 'maintenance', { artwork: { storefront: 'ng', catalog } },
      { playlistCatalog, artwork: vi.fn(async () => emptyArtwork) })
    expect(result.playlistCatalog).toEqual(emptyCatalog)
    expect(playlistCatalog).toHaveBeenCalledWith(db, { catalog, now: undefined })
  })

  it('keeps existing maintenance running after catalog resolution fails, without returning the error text', async () => {
    const db = await createTestDb()
    const playlistCatalog = vi.fn(async () => { throw new Error('SECRET CATALOG SQL') })
    const artwork = vi.fn(async () => emptyArtwork)
    const result = await handleScheduled(db, 'maintenance', { artwork: { storefront: 'ng', catalog } },
      { playlistCatalog, artwork })
    expect(result.playlistCatalog).toEqual({ error: 'failed' })
    expect(artwork).toHaveBeenCalledOnce()
    expect(JSON.stringify(result)).not.toContain('SECRET CATALOG SQL')
  })

  it('keeps enrichment running after twin copy fails, without returning the error text', async () => {
    const db = await createTestDb()
    const twinCopy = vi.fn(async () => { throw new Error('SECRET TWIN SQL') })
    const enrichment = vi.fn(async () => emptyEnrichment)
    const result = await handleScheduled(db, 'enrichment', { enrichment: okDeps }, { twinCopy, enrichment })
    expect(result.twinCopy).toEqual({ error: 'failed' })
    expect(enrichment).toHaveBeenCalledOnce()
    expect(JSON.stringify(result)).not.toContain('SECRET TWIN SQL')
  })

  it('keeps Apple ISRC linking running after enrichment fails, without returning the error text', async () => {
    const db = await createTestDb()
    const enrichment = vi.fn(async () => { throw new Error('secret feature failure') })
    const appleIsrc = vi.fn(async () => emptyIsrc)
    const result = await handleScheduled(db, 'enrichment', { enrichment: okDeps, appleIsrc: { catalog } },
      { twinCopy: vi.fn(async () => emptyTwins), enrichment, appleIsrc })
    expect(result).toEqual({ twinCopy: emptyTwins, enrichment: { error: 'failed' }, appleIsrc: emptyIsrc })
    expect(JSON.stringify(result)).not.toContain('secret feature failure')
  })

  it('fills a twin through the real copy so the enrichment batch skips it', async () => {
    const db = await createTestDb()
    const [donor] = await db.insert(tracks).values({ appleId: 'd1', title: 'T', artist: 'A', isrc: 'USUG11904206' }).returning()
    const { isrc: _i, matchedDurationMs: _m, ...cols } = OK_FEATURES
    await db.insert(trackFeatures).values({ trackId: donor.id, ...cols, source: 'reccobeats' })
    await db.insert(trackMeanings).values({ trackId: donor.id, embedding: null, lyricsSource: 'lrclib', instrumental: true })
    await db.insert(tracks).values({ spotifyId: '4uLU6hMCjMI75M1A2tKUQC', title: 'T', artist: 'A', isrc: 'USUG11904206' })
    const r = await handleScheduled(db, 'enrichment', { enrichment: okDeps })
    expect(r.twinCopy).toEqual({ features: 1, meanings: 1 })
    expect(r.enrichment).toMatchObject({ processed: 0, remaining: 0 })
  })

  it('processes a small batch', async () => {
    const db = await createTestDb()
    await db.insert(tracks).values({ appleId: 'c1', title: 'T', artist: 'A' })
    const r = await handleScheduled(db, 'enrichment', { enrichment: okDeps })
    expect(r.enrichment).toMatchObject({ processed: 1 })
    expect(await db.select().from(trackFeatures)).toHaveLength(1)
  })

  it('caps at CRON_BATCH', async () => {
    const db = await createTestDb()
    for (let i = 0; i < CRON_BATCH + 3; i++) {
      await db.insert(tracks).values({ appleId: `c${i}`, title: 'T', artist: 'A' })
    }
    const r = await handleScheduled(db, 'enrichment', { enrichment: okDeps })
    expect(r.enrichment).toMatchObject({ processed: CRON_BATCH })
  })

  it('runs the Spotify fallback even when Apple ISRC linking fails, and reports both without error text', async () => {
    const db = await createTestDb()
    const appleIsrc = vi.fn(async () => { throw new Error('secret linking failure') })
    const spotifyArtwork = vi.fn(async () => { throw new Error('secret fallback failure') })
    const result = await handleScheduled(db, 'enrichment', allDeps, {
      twinCopy: vi.fn(async () => emptyTwins), enrichment: vi.fn(async () => emptyEnrichment), appleIsrc, spotifyArtwork,
    })
    expect(spotifyArtwork).toHaveBeenCalledOnce()
    expect(result).toEqual({
      twinCopy: emptyTwins,
      enrichment: emptyEnrichment,
      appleIsrc: { error: 'failed' },
      spotifyArtwork: { error: 'failed' },
    })
    expect(JSON.stringify(result)).not.toContain('secret')
  })

  it('runs Apple artwork even when playlist catalogue resolution fails', async () => {
    const db = await createTestDb()
    const artwork = vi.fn(async () => { throw new Error('secret artwork failure') })
    const result = await handleScheduled(db, 'maintenance', allDeps, {
      playlistCatalog: vi.fn(async () => { throw new Error('secret catalog failure') }), artwork,
    })
    expect(artwork).toHaveBeenCalledOnce()
    expect(result).toEqual({
      artwork: { error: 'failed' },
      playlistCatalog: { error: 'failed' },
      libraryCleanup: expect.objectContaining({ touchedRuns: 0 }),
      listeningCleanup: expect.objectContaining({ touchedRuns: 0 }),
      playlistCleanup: expect.objectContaining({ touchedRuns: 0 }),
    })
    expect(JSON.stringify(result)).not.toContain('secret')
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

    const result = await handleScheduled(db, 'maintenance', {}, { playlistCleanup })

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

    const result = await handleScheduled(db, 'maintenance', {}, { libraryCleanup })

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

    const result = await handleScheduled(db, 'maintenance', {}, { listeningCleanup })

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

    const result = await handleScheduled(db, 'maintenance', {}, { listeningCleanup, playlistCleanup })

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

    const result = await handleScheduled(db, 'maintenance', {}, { libraryCleanup, playlistCleanup })

    expect(playlistCleanup).toHaveBeenCalledOnce()
    expect(result).toEqual({
      libraryCleanup: { error: 'failed' },
      listeningCleanup: expect.objectContaining({ touchedRuns: 0 }),
      playlistCleanup: expect.objectContaining({ touchedRuns: 0 }),
    })
  })

  it('keeps artwork independent from playlist cleanup failure', async () => {
    const db = await createTestDb()
    const artwork = vi.fn(async () => emptyArtwork)
    const playlistCleanup = vi.fn(async () => { throw new Error('secret cleanup failure') })

    const result = await handleScheduled(db, 'maintenance', { artwork: { storefront: 'ng', catalog } }, {
      playlistCatalog: vi.fn(async () => emptyCatalog),
      artwork,
      playlistCleanup,
    })

    expect(result).toEqual({
      artwork: emptyArtwork,
      playlistCatalog: emptyCatalog,
      libraryCleanup: expect.objectContaining({ touchedRuns: 0 }),
      listeningCleanup: expect.objectContaining({ touchedRuns: 0 }),
      playlistCleanup: { error: 'failed' },
    })
  })
})
