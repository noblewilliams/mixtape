import { describe, expect, it, vi } from 'vitest'
import { createTestDb, type TestDb } from '../helpers/db'
import { eq } from 'drizzle-orm'
import { playlistCatalogLookups, playlistEntries, trackFeatures, tracks, user, userMusicProfiles, userPlaylists, userTracks } from '../../src/db/schema'
import { PLAYLIST_CATALOG_LEASE_MS, runPlaylistCatalogBatch } from '../../src/playlists/catalog-resolution'
import { AppleCatalogError, type CatalogSong } from '../../src/musickit/catalog'
import { handleScheduled } from '../../src/enrich/scheduled'
import { okDeps } from '../helpers/enrich-fixtures'

const NOW = new Date('2026-09-04T12:00:00Z')
const song = (appleId: string): CatalogSong => ({
  appleId, title: 'Catalog title', artist: 'Catalog artist', album: 'Catalog album',
  isrc: 'USABC2400001',
  artwork: { url: 'https://is1.mzstatic.com/cover/{w}x{h}.jpg', width: 1000, height: 1000, bgColor: 'abcdef' },
})

async function seed(db: TestDb, ids: (string | null)[], owner = 'listener', storefront: string | null = 'ng') {
  await db.insert(user).values({ id: owner, name: owner, email: `${owner}@example.com` })
  await db.insert(userMusicProfiles).values({ userId: owner, appleStorefront: storefront })
  const [playlist] = await db.insert(userPlaylists).values({
    userId: owner, appleLibraryId: 'private-library-id', name: 'Private playlist',
    kind: 'user', sourceFingerprint: 'a'.repeat(64),
  }).returning()
  if (ids.length) await db.insert(playlistEntries).values(ids.map((appleCatalogId, position) => ({
    playlistId: playlist.id, appleCatalogId, position, appleLibraryEntryId: `entry-${position}`,
    titleSnapshot: 'Private snapshot title', artistSnapshot: 'Private snapshot artist',
  })))
  return playlist
}

describe('playlist catalog resolution', () => {
  it('feeds materialized songs through the existing scheduled enrichment job', async () => {
    const db = await createTestDb()
    await seed(db, ['123'])
    const catalog = { getSongs: async () => new Map([['123', song('123')]]) }
    const result = await handleScheduled(db, { enrichment: okDeps, artwork: { catalog, storefront: 'ng', now: () => NOW } })
    expect(result.playlistCatalog).toMatchObject({ matched: 1, linkedEntries: 1 })
    expect(result.enrichment).toMatchObject({ processed: 1, features: 1, meaning: 1 })
    expect(await db.select().from(trackFeatures)).toHaveLength(1)
    expect(await db.select().from(userTracks)).toEqual([])
  })

  it('backs off catalog misses and retries later without blocking new IDs', async () => {
    const db = await createTestDb()
    const playlist = await seed(db, ['123'])
    let now = NOW
    const getSongs = vi.fn(async (_market: string, ids: readonly string[]) =>
      new Map(ids.filter(id => id !== '123').map(id => [id, song(id)])))
    const deps = { catalog: { getSongs }, now: () => now }
    expect(await runPlaylistCatalogBatch(db, deps)).toMatchObject({ missing: 1 })
    await db.insert(playlistEntries).values({ playlistId: playlist.id, position: 1,
      appleLibraryEntryId: 'entry-1', appleCatalogId: '456', titleSnapshot: 'T', artistSnapshot: 'A' })
    now = new Date(NOW.getTime() + 60_000)
    expect(await runPlaylistCatalogBatch(db, deps)).toMatchObject({ processed: 1, matched: 1 })
    expect(getSongs.mock.calls[1][1]).toEqual(['456'])
    expect(await runPlaylistCatalogBatch(db, deps)).toMatchObject({ processed: 0 })
    now = new Date(NOW.getTime() + 31 * 86400_000)
    getSongs.mockImplementation(async (_market, ids) => new Map(ids.map(id => [id, song(id)])))
    expect(await runPlaylistCatalogBatch(db, deps)).toMatchObject({ matched: 1, linkedEntries: 1 })
  })

  it('materializes exact catalog songs and links duplicate occurrences without inventing library membership', async () => {
    const db = await createTestDb()
    await seed(db, ['123', '123', null])
    const before = await db.select().from(playlistEntries).orderBy(playlistEntries.position)
    const getSongs = vi.fn(async () => new Map([['123', song('123')]]))

    const result = await runPlaylistCatalogBatch(db, { catalog: { getSongs }, now: () => NOW })

    expect(result).toEqual({ processed: 1, matched: 1, missing: 0, failed: 0, linkedEntries: 2 })
    expect(getSongs).toHaveBeenCalledExactlyOnceWith('ng', ['123'])
    const [track] = await db.select().from(tracks)
    expect(track).toMatchObject({ appleId: '123', title: 'Catalog title', artistSource: 'apple_catalog',
      isrc: 'USABC2400001', artworkBgColor: 'abcdef', artworkFetchedAt: NOW })
    const after = await db.select().from(playlistEntries).orderBy(playlistEntries.position)
    expect(after.map(row => row.trackId)).toEqual([track.id, track.id, null])
    expect(after.map(({ trackId, updatedAt, ...row }) => row))
      .toEqual(before.map(({ trackId, updatedAt, ...row }) => row))
    expect(await db.select().from(userTracks)).toEqual([])
  })

  it('isolates malformed metadata and keeps valid songs usable when optional metadata is missing', async () => {
    const db = await createTestDb()
    await seed(db, ['123', '456', '789'])
    const getSongs = vi.fn(async () => new Map([
      ['123', { ...song('123'), title: 'secret\0invalid' }],
      ['456', { ...song('456'), artwork: null, isrc: 'bad-isrc' }],
      ['789', song('wrong-id')],
      ['extra', song('extra')],
    ]))
    expect(await runPlaylistCatalogBatch(db, { catalog: { getSongs }, now: () => NOW }))
      .toEqual({ processed: 3, matched: 1, missing: 1, failed: 1, linkedEntries: 1 })
    expect(await db.select().from(tracks)).toMatchObject([
      { appleId: '456', isrc: null, artworkUrlTemplate: null, artworkFetchedAt: null },
    ])
  })

  it('relinks existing records without a catalog request or overwriting their metadata', async () => {
    const db = await createTestDb()
    await seed(db, ['123'])
    const [track] = await db.insert(tracks).values({ appleId: '123', title: 'Existing', artist: 'A' }).returning()
    const getSongs = vi.fn(async () => new Map<string, CatalogSong>())
    expect(await runPlaylistCatalogBatch(db, { catalog: { getSongs } }))
      .toMatchObject({ processed: 0, linkedEntries: 1 })
    expect(getSongs).not.toHaveBeenCalled()
    expect(await db.select().from(tracks)).toEqual([track])
  })

  it('only fetches active Apple entries with a valid catalog ID and known storefront', async () => {
    const db = await createTestDb()
    const removed = await seed(db, ['removed'], 'removed-owner')
    await db.update(userPlaylists).set({ inLibrary: false }).where(eq(userPlaylists.id, removed.id))
    const spotify = await seed(db, ['spotify-placeholder'], 'spotify-owner')
    await db.update(userPlaylists).set({ source: 'spotify_export' }).where(eq(userPlaylists.id, spotify.id))
    await seed(db, ['no-market'], 'no-market-owner', null)
    await seed(db, ['bad,id', null, 'valid'], 'active-owner', 'gb')
    const getSongs = vi.fn(async () => new Map([['valid', song('valid')]]))
    expect(await runPlaylistCatalogBatch(db, { catalog: { getSongs }, now: () => NOW }))
      .toMatchObject({ processed: 1, linkedEntries: 1 })
    expect(getSongs).toHaveBeenCalledExactlyOnceWith('gb', ['valid'])
  })

  it('does not materialize a playlist entry removed while Apple is responding', async () => {
    const db = await createTestDb()
    const playlist = await seed(db, ['123'])
    const getSongs = vi.fn(async () => {
      await db.update(userPlaylists).set({ inLibrary: false }).where(eq(userPlaylists.id, playlist.id))
      return new Map([['123', song('123')]])
    })
    expect(await runPlaylistCatalogBatch(db, { catalog: { getSongs }, now: () => NOW }))
      .toMatchObject({ matched: 0, linkedEntries: 0 })
    expect(await db.select().from(tracks)).toEqual([])
    expect(await db.select().from(playlistCatalogLookups)).toEqual([])
  })

  it('preserves a track inserted by another importer during the catalog request', async () => {
    const db = await createTestDb()
    await seed(db, ['123'])
    const getSongs = vi.fn(async () => {
      await db.insert(tracks).values({ appleId: '123', title: 'Concurrent title', artist: 'Concurrent artist' })
      return new Map([['123', song('123')]])
    })
    expect(await runPlaylistCatalogBatch(db, { catalog: { getSongs } })).toMatchObject({ linkedEntries: 1 })
    expect(await db.select().from(tracks)).toMatchObject([{ title: 'Concurrent title', artist: 'Concurrent artist' }])
  })

  it('makes one bounded catalog request per invocation and shares identities across listeners', async () => {
    const db = await createTestDb()
    const ids = Array.from({ length: 27 }, (_, i) => `id-${i.toString().padStart(2, '0')}`)
    await seed(db, ids)
    await seed(db, ['id-00'], 'second-listener')
    const getSongs = vi.fn(async (_market: string, requested: readonly string[]) => new Map(requested.map(id => [id, song(id)])))
    expect(await runPlaylistCatalogBatch(db, { catalog: { getSongs } })).toMatchObject({ processed: 25, linkedEntries: 26 })
    expect(getSongs).toHaveBeenCalledOnce()
    expect(getSongs.mock.calls[0][1]).toHaveLength(25)
    expect(await runPlaylistCatalogBatch(db, { catalog: { getSongs } })).toMatchObject({ processed: 2, linkedEntries: 2 })
    expect(await db.select().from(tracks)).toHaveLength(27)
    expect(await db.select().from(userTracks)).toEqual([])
  })

  it('does not let a miss in one storefront suppress a lookup in another', async () => {
    const db = await createTestDb()
    await seed(db, ['123'], 'gb-listener', 'gb')
    await seed(db, ['123'], 'ng-listener', 'ng')
    const getSongs = vi.fn(async (market: string) => market === 'ng' ? new Map([['123', song('123')]]) : new Map<string, CatalogSong>())
    const deps = { catalog: { getSongs }, now: () => NOW }
    expect(await runPlaylistCatalogBatch(db, deps)).toMatchObject({ missing: 1 })
    expect(await runPlaylistCatalogBatch(db, deps)).toMatchObject({ matched: 1, linkedEntries: 2 })
    expect(getSongs.mock.calls.map(([market]) => market)).toEqual(['gb', 'ng'])
  })

  it.each([
    ['authorization', 6 * 3600_000], ['rate_limit', 3600_000],
    ['upstream', 15 * 60_000], ['timeout', 15 * 60_000], ['network', 15 * 60_000],
    ['response', 7 * 86400_000], ['internal', 3600_000],
  ] as const)('backs off %s with fixed categories only', async (category, retryMs) => {
    const db = await createTestDb()
    await seed(db, ['123'])
    const getSongs = vi.fn(async (): Promise<Map<string, CatalogSong>> => {
      throw category === 'internal' ? new Error('SECRET RESPONSE') : new AppleCatalogError(category)
    })
    const deps = { catalog: { getSongs }, now: () => NOW }
    const result = await runPlaylistCatalogBatch(db, deps)
    expect(result).toEqual({ processed: 1, matched: 0, missing: 0, failed: 1, linkedEntries: 0 })
    expect(await runPlaylistCatalogBatch(db, deps)).toMatchObject({ processed: 0 })
    expect(getSongs).toHaveBeenCalledOnce()
    const [lookup] = await db.select().from(playlistCatalogLookups)
    expect(lookup.lastCategory).toBe(category === 'response' ? 'malformed' : category)
    expect(lookup.nextAttemptAt).toEqual(new Date(NOW.getTime() + retryMs))
    expect(JSON.stringify([result, lookup])).not.toContain('SECRET RESPONSE')
  })

  it('fences an expired worker response after another worker claims the same ID', async () => {
    const db = await createTestDb()
    await seed(db, ['123'])
    let release!: (songs: Map<string, CatalogSong>) => void
    let started!: () => void
    const fetching = new Promise<void>(resolve => { started = resolve })
    const getSongs = vi.fn(async () => {
      started()
      return new Promise<Map<string, CatalogSong>>(resolve => { release = resolve })
    })
    const first = runPlaylistCatalogBatch(db, { catalog: { getSongs }, now: () => NOW })
    await fetching
    const other = vi.fn(async (): Promise<Map<string, CatalogSong>> => { throw new AppleCatalogError('rate_limit') })
    expect(await runPlaylistCatalogBatch(db, { catalog: { getSongs: other }, now: () => NOW }))
      .toMatchObject({ processed: 0 })
    expect(other).not.toHaveBeenCalled()
    const later = new Date(NOW.getTime() + PLAYLIST_CATALOG_LEASE_MS + 1)
    expect(await runPlaylistCatalogBatch(db, { catalog: { getSongs: other }, now: () => later }))
      .toMatchObject({ failed: 1 })
    release(new Map([['123', song('123')]]))
    expect(await first).toMatchObject({ processed: 0, matched: 0, linkedEntries: 0 })
    expect(await db.select().from(tracks)).toEqual([])
    expect(await db.select().from(playlistCatalogLookups))
      .toMatchObject([{ attempts: 2, lastCategory: 'rate_limit' }])
  })
})
