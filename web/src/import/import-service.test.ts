import { describe, expect, it, vi } from 'vitest'
import { ApiError, type MixtapeApi } from '../api/client'
import { readExpected, readFixtureArchive } from '../test/listening-export-fixtures'
import { createListeningImportService, playlistFingerprint, type ImportParser } from './import-service'
import type { ListeningExportSnapshot, SnapshotPlaylist } from './snapshot'
import { parseExport } from './spotify-parser'
import { openZipArchive } from './zip-reader'

// The pure parser over the fixture archives; the page passes the Worker
// client, which has the same call.
const directParser: ImportParser = {
  parse: async (file, options) => parseExport(await openZipArchive(file), options),
}

const importSummary = {
  tracks: 0, days: 0, libraryTracks: 0, artists: 0, unresolvedRows: 0, unresolvedPlays: 0,
  ledgerFrom: null, ledgerTo: null, likedRemoved: 0, likedRemovalSkipped: false,
}
const playlistSummary = { playlists: 0, entries: 0, resolvedEntries: 0, unresolvedEntries: 0 }

function setup(parser: ImportParser = directParser) {
  const calls: string[] = []
  const mocks = {
    beginListeningImport: vi.fn<MixtapeApi['beginListeningImport']>(async () => {
      calls.push('begin-import')
      return { importId: 'import-1', expiresAt: 1 }
    }),
    putListeningTracks: vi.fn<MixtapeApi['putListeningTracks']>(async (_importId, tracks) => {
      calls.push('put-tracks')
      return { accepted: tracks.length }
    }),
    putListeningDays: vi.fn<MixtapeApi['putListeningDays']>(async (_importId, days) => {
      calls.push('put-days')
      return { accepted: days.length }
    }),
    putListeningLibrary: vi.fn<MixtapeApi['putListeningLibrary']>(async (_importId, tracks) => {
      calls.push('put-library')
      return { accepted: tracks.length }
    }),
    putListeningArtists: vi.fn<MixtapeApi['putListeningArtists']>(async (_importId, artists) => {
      calls.push('put-artists')
      return { accepted: artists.length }
    }),
    completeListeningImport: vi.fn<MixtapeApi['completeListeningImport']>(async () => {
      calls.push('complete-import')
      return importSummary
    }),
    beginPlaylistSync: vi.fn<MixtapeApi['beginPlaylistSync']>(async () => {
      calls.push('begin-playlists')
      return { syncId: 'playlist-sync', expiresAt: 1 }
    }),
    putPlaylists: vi.fn<MixtapeApi['putPlaylists']>(async (_syncId, playlists) => {
      calls.push('put-playlists')
      return { accepted: playlists.length }
    }),
    putPlaylistEntries: vi.fn<MixtapeApi['putPlaylistEntries']>(async (_syncId, _playlistId, entries) => {
      calls.push('put-entries')
      return { accepted: entries.length }
    }),
    completePlaylistSync: vi.fn<MixtapeApi['completePlaylistSync']>(async () => {
      calls.push('complete-playlists')
      return playlistSummary
    }),
    postFunnelEvent: vi.fn<MixtapeApi['postFunnelEvent']>(async (event) => {
      calls.push(`funnel:${event.type}`)
      return { ok: true }
    }),
  }
  const api = mocks as unknown as MixtapeApi
  return { service: createListeningImportService({ api, parser }), mocks, calls }
}

const uploadOptions = (signal = new AbortController().signal) => ({
  timeZone: 'Africa/Lagos',
  includePrivateSessions: false,
  signal,
  onProgress: vi.fn(),
})

type ExpectedSnapshot = { snapshot: ListeningExportSnapshot }

function fakeParser(snapshot: ListeningExportSnapshot): ImportParser {
  const inventory = { package: snapshot.package, read: [], ignored: [] }
  return {
    parse: async (_file, options) => {
      options.onProgress?.({ stage: 'listing', file: null, completed: 0, total: 0 })
      return { inventory, snapshot }
    },
  }
}

const extendedSnapshot = (tracks: number, days: number): ListeningExportSnapshot => ({
  source: 'spotify_export',
  package: 'spotify_extended',
  timeZone: 'Africa/Lagos',
  country: 'NG',
  tracks: Array.from({ length: tracks }, (_, index) => ({
    platformId: `Track${String(index).padStart(17, '0')}`,
    title: `Track ${index}`,
    artist: 'Artist',
    album: null,
    durationMs: null,
  })),
  days: Array.from({ length: days }, (_, index) => ({
    platformId: `Track${String(index % Math.max(tracks, 1)).padStart(17, '0')}`,
    day: '2026-01-01',
    plays: 1,
    skips: 0,
    completes: 1,
    msPlayed: 60_000,
    hoursMask: 1,
  })),
  library: [],
  artists: [],
  playlists: [],
  unresolved: { rows: 3, plays: 2 },
  ledgerFrom: '2026-01-01',
  ledgerTo: '2026-01-01',
})

const accountSnapshot = (rows: number, playlists: number, entriesInFirst: number): ListeningExportSnapshot => ({
  source: 'spotify_export',
  package: 'spotify_account',
  timeZone: 'Africa/Lagos',
  country: null,
  tracks: [],
  days: [],
  library: Array.from({ length: rows }, (_, index) => ({
    platformId: `Track${String(index).padStart(17, '0')}`,
    playCount: null,
    skipCount: null,
    lastPlayedAt: null,
    dateAdded: null,
    likeRating: null,
  })),
  artists: Array.from({ length: rows }, (_, index) => ({ name: `Artist ${index}`, spotifyId: null })),
  playlists: Array.from({ length: playlists }, (_, ordinal): SnapshotPlaylist => ({
    ordinal,
    key: ordinal.toString(16).padStart(64, '0'),
    name: `Playlist ${ordinal}`,
    description: null,
    lastModifiedAt: null,
    entries: ordinal === 0
      ? Array.from({ length: entriesInFirst }, (_, position) => ({
        position, platformId: null, title: `Song ${position}`, artist: 'Artist', album: null, addedAt: null,
      }))
      : [],
  })),
  unresolved: { rows: 0, plays: 0 },
  ledgerFrom: null,
  ledgerTo: null,
})

describe('ListeningImportService', () => {
  it('inspects an archive with one full default parse and records the funnel step without waiting on it', async () => {
    const parse = vi.fn(directParser.parse)
    const { service, mocks } = setup({ parse })
    const expected = readExpected('extended-basic', 'default')
    let resolveFunnel: (() => void) | undefined
    mocks.postFunnelEvent.mockImplementation(() => new Promise((resolve) => {
      resolveFunnel = () => resolve({ ok: true })
    }))
    const progress = vi.fn()

    const inspected = await service.inspect(readFixtureArchive('extended-basic'), {
      timeZone: 'Africa/Lagos',
      signal: new AbortController().signal,
      onProgress: progress,
    })

    expect(inspected).toEqual({
      inventory: expected.inventory,
      snapshot: expected.snapshot,
      timeZone: 'Africa/Lagos',
      includePrivateSessions: false,
    })
    expect(parse).toHaveBeenCalledTimes(1)
    expect(parse.mock.calls[0][1]).toMatchObject({ timeZone: 'Africa/Lagos', includePrivateSessions: false })
    expect(progress).toHaveBeenCalledWith(expect.objectContaining({ stage: 'complete' }))
    expect(mocks.postFunnelEvent).toHaveBeenCalledTimes(1)
    expect(mocks.postFunnelEvent).toHaveBeenCalledWith({ type: 'file_inspected', surface: 'web' })
    expect(resolveFunnel).toBeDefined()
    resolveFunnel?.()
  })

  it('uploads the inspected snapshot without a second parse when the options match', async () => {
    const parse = vi.fn(directParser.parse)
    const { service, mocks, calls } = setup({ parse })
    const file = readFixtureArchive('extended-basic')
    const inspected = await service.inspect(file, { timeZone: 'Africa/Lagos', signal: new AbortController().signal })

    const result = await service.upload(file, { ...uploadOptions(), inspected })

    expect(parse).toHaveBeenCalledTimes(1)
    expect(result.inventory).toEqual(inspected.inventory)
    expect(mocks.beginListeningImport.mock.calls[0][0]).toMatchObject({ expectedTracks: inspected.snapshot.tracks.length })
    expect(calls.filter((call) => call.startsWith('funnel:'))).toEqual(['funnel:file_inspected', 'funnel:import_completed'])
  })

  it('parses again only when the private-sessions choice differs from the inspected parse', async () => {
    const parse = vi.fn(directParser.parse)
    const { service, mocks } = setup({ parse })
    const file = readFixtureArchive('extended-private-sessions')
    const inspected = await service.inspect(file, { timeZone: 'Africa/Lagos', signal: new AbortController().signal })
    const included = readExpected('extended-private-sessions', 'private-included').snapshot as ListeningExportSnapshot

    await service.upload(file, { ...uploadOptions(), includePrivateSessions: true, inspected })

    expect(parse).toHaveBeenCalledTimes(2)
    expect(parse.mock.calls[1][1]).toMatchObject({ timeZone: 'Africa/Lagos', includePrivateSessions: true })
    expect(mocks.beginListeningImport.mock.calls[0][0]).toMatchObject({
      expectedTracks: included.tracks.length,
      expectedDays: included.days.length,
    })
    expect(mocks.postFunnelEvent.mock.calls.map(([event]) => event.type)).toEqual(['file_inspected', 'import_completed'])
  })

  it('uploads an extended package as tracks and days, then completes, with no playlist sync', async () => {
    const { service, mocks, calls } = setup()
    const expected = readExpected('extended-basic', 'default') as unknown as ExpectedSnapshot & { inventory: unknown }
    const options = uploadOptions()

    const result = await service.upload(readFixtureArchive('extended-basic'), options)

    expect(calls).toEqual(['begin-import', 'put-tracks', 'put-days', 'complete-import', 'funnel:import_completed'])
    expect(mocks.beginListeningImport).toHaveBeenCalledWith({
      source: 'spotify_export',
      package: 'spotify_extended',
      timeZone: 'Africa/Lagos',
      country: 'NG',
      expectedTracks: 6,
      expectedDays: 13,
      expectedLibraryTracks: 0,
      expectedArtists: 0,
      unresolvedRows: 0,
      unresolvedPlays: 0,
    }, options.signal)
    expect(mocks.putListeningTracks).toHaveBeenCalledTimes(1)
    expect(mocks.putListeningTracks.mock.calls[0]).toEqual([
      'import-1',
      expected.snapshot.tracks.map((track, ordinal) => ({ ordinal, ...track })),
      options.signal,
    ])
    expect(mocks.putListeningDays).toHaveBeenCalledTimes(1)
    expect(mocks.putListeningDays.mock.calls[0]).toEqual([
      'import-1',
      expected.snapshot.days.map((day, ordinal) => ({ ordinal, ...day })),
      options.signal,
    ])
    expect(mocks.putListeningLibrary).not.toHaveBeenCalled()
    expect(mocks.putListeningArtists).not.toHaveBeenCalled()
    expect(mocks.completeListeningImport).toHaveBeenCalledWith('import-1', options.signal)
    expect(mocks.beginPlaylistSync).not.toHaveBeenCalled()
    expect(mocks.postFunnelEvent).toHaveBeenCalledWith({ type: 'import_completed', surface: 'web' })
    expect(result).toEqual({
      inventory: expected.inventory,
      summary: importSummary,
      plays: expected.snapshot.days.reduce((sum, day) => sum + day.plays, 0),
      playlists: null,
      playlistError: null,
    })
    expect(result.plays).toBeGreaterThan(0)

    const stages = options.onProgress.mock.calls.map(([progress]) => progress)
    expect(stages.some((progress) => progress.stage === 'reading')).toBe(true)
    expect(stages).toContainEqual({ stage: 'uploading_tracks', completed: 6, total: 6 })
    expect(stages).toContainEqual({ stage: 'uploading_days', completed: 13, total: 13 })
    expect(options.onProgress).toHaveBeenLastCalledWith({ stage: 'complete', completed: 1, total: 1 })
  })

  it('uploads an account package as tracks, library, and artists, then syncs playlists', async () => {
    const { service, mocks, calls } = setup()
    const expected = readExpected('account-basic', 'default') as unknown as ExpectedSnapshot
    const [ferry, uphill] = expected.snapshot.playlists
    const options = uploadOptions()

    const result = await service.upload(readFixtureArchive('account-basic'), options)

    expect(calls).toEqual([
      'begin-import', 'put-tracks', 'put-library', 'put-artists', 'complete-import', 'funnel:import_completed',
      'begin-playlists', 'put-playlists', 'put-entries', 'put-entries', 'complete-playlists',
    ])
    expect(mocks.beginListeningImport).toHaveBeenCalledWith({
      source: 'spotify_export',
      package: 'spotify_account',
      timeZone: 'Africa/Lagos',
      country: null,
      expectedTracks: 7,
      expectedDays: 0,
      expectedLibraryTracks: 5,
      expectedArtists: 2,
      unresolvedRows: 0,
      unresolvedPlays: 0,
    }, options.signal)
    expect(mocks.putListeningTracks.mock.calls[0][1])
      .toEqual(expected.snapshot.tracks.map((track, ordinal) => ({ ordinal, ...track })))
    expect(mocks.putListeningLibrary.mock.calls[0]).toEqual([
      'import-1',
      expected.snapshot.library.map((row, ordinal) => ({ ordinal, ...row })),
      options.signal,
    ])
    expect(mocks.putListeningArtists.mock.calls[0]).toEqual([
      'import-1',
      expected.snapshot.artists.map((artist, ordinal) => ({ ordinal, ...artist })),
      options.signal,
    ])
    expect(mocks.putListeningDays).not.toHaveBeenCalled()

    expect(mocks.beginPlaylistSync).toHaveBeenCalledWith({
      source: 'spotify_export',
      storefront: null,
      expectedPlaylists: 2,
      expectedEntries: 5,
    }, options.signal)
    // Hand-computed: sha256 of "<position>\t<platformId>\t<title>\t<artist>"
    // lines joined by "\n", over each playlist's entries in order.
    const ferryFingerprint = '02c2a788eee9e5237c2edde74f9e407d9251d18e30ba619eb40696a3a304c539'
    const uphillFingerprint = 'fbf9d77ffc96b59b8dc4c78b203276718ecaa895583dc76a82207e48de9b751e'
    expect(mocks.putPlaylists.mock.calls[0]).toEqual(['playlist-sync', [
      {
        ordinal: 0,
        appleLibraryId: ferry.key,
        appleCatalogId: null,
        name: 'Late Nights on the Ferry',
        description: 'Slow ones for the crossing.',
        curatorName: null,
        artworkUrlTemplate: null,
        artworkWidth: null,
        artworkHeight: null,
        artworkBgColor: null,
        kind: 'user',
        canEdit: false,
        appleDateAdded: null,
        appleLastModifiedAt: 1785542400000,
        sourceFingerprint: ferryFingerprint,
        entryCount: 3,
      },
      {
        ordinal: 1,
        appleLibraryId: uphill.key,
        appleCatalogId: null,
        name: 'Running Uphill',
        description: null,
        curatorName: null,
        artworkUrlTemplate: null,
        artworkWidth: null,
        artworkHeight: null,
        artworkBgColor: null,
        kind: 'user',
        canEdit: false,
        appleDateAdded: null,
        appleLastModifiedAt: 1773532800000,
        sourceFingerprint: uphillFingerprint,
        entryCount: 2,
      },
    ], options.signal])
    expect(mocks.putPlaylistEntries.mock.calls[0]).toEqual(['playlist-sync', ferry.key, [
      {
        position: 0,
        appleLibraryEntryId: `${ferry.key}:0`,
        appleLibraryTrackId: null,
        appleCatalogId: null,
        spotifyId: 'LowTideRadio0000000001',
        isrcSnapshot: null,
        titleSnapshot: 'Low Tide Radio',
        artistSnapshot: 'The Copper Hours',
        albumSnapshot: 'Night Ferry',
        durationMsSnapshot: null,
        artworkUrlTemplateSnapshot: null,
        artworkWidthSnapshot: null,
        artworkHeightSnapshot: null,
        artworkBgColorSnapshot: null,
      },
      expect.objectContaining({
        position: 1, appleLibraryEntryId: `${ferry.key}:1`, spotifyId: 'PaperLanterns000000001', titleSnapshot: 'Paper Lanterns',
      }),
      expect.objectContaining({
        position: 2, appleLibraryEntryId: `${ferry.key}:2`, spotifyId: 'WinterHarbour000000001', albumSnapshot: 'Signal Fires',
      }),
    ], options.signal])
    expect(mocks.putPlaylistEntries.mock.calls[1]).toEqual(['playlist-sync', uphill.key, [
      expect.objectContaining({ position: 0, appleLibraryEntryId: `${uphill.key}:0`, spotifyId: 'KiteSeason000000000001' }),
      expect.objectContaining({ position: 1, appleLibraryEntryId: `${uphill.key}:1`, spotifyId: 'MothToNeon000000000001' }),
    ], options.signal])
    expect(mocks.completePlaylistSync).toHaveBeenCalledWith('playlist-sync', options.signal)
    expect(result.playlists).toEqual(playlistSummary)
    expect(result.summary).toEqual(importSummary)
    expect(result.playlistError).toBeNull()
    expect(options.onProgress.mock.calls.map(([progress]) => progress))
      .toContainEqual({ stage: 'uploading_playlists', completed: 7, total: 7 })
  })

  it('fingerprints a playlist from its ordered entries, blank for a missing id', async () => {
    const playlist: SnapshotPlaylist = {
      ordinal: 0,
      key: 'k'.repeat(64),
      name: 'Mixed',
      description: null,
      lastModifiedAt: null,
      entries: [
        { position: 0, platformId: 'LowTideRadio0000000001', title: 'Low Tide Radio', artist: 'The Copper Hours', album: null, addedAt: null },
        { position: 1, platformId: null, title: 'Local File', artist: 'Basement Sessions', album: null, addedAt: null },
      ],
    }
    // sha256("0\tLowTideRadio0000000001\tLow Tide Radio\tThe Copper Hours\n1\t\tLocal File\tBasement Sessions")
    expect(await playlistFingerprint(playlist))
      .toBe('7a62db8aa8cbe930f0b63cd94062be093f17e4b0cc9ece6d4fe3e51f99a30b64')
    expect(await playlistFingerprint({ ...playlist, entries: [] }))
      .toBe('e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855')
  })

  it('chunks tracks by 500 and days by 2000 with ordinals from the canonical order', async () => {
    const { service, mocks } = setup(fakeParser(extendedSnapshot(501, 2001)))
    const options = uploadOptions()

    await service.upload(new Blob([]), options)

    expect(mocks.beginListeningImport).toHaveBeenCalledWith(expect.objectContaining({
      expectedTracks: 501, expectedDays: 2001, unresolvedRows: 3, unresolvedPlays: 2,
    }), options.signal)
    expect(mocks.putListeningTracks.mock.calls.map(([, tracks]) => tracks.length)).toEqual([500, 1])
    expect(mocks.putListeningTracks.mock.calls[0][1][0].ordinal).toBe(0)
    expect(mocks.putListeningTracks.mock.calls[0][1][499].ordinal).toBe(499)
    expect(mocks.putListeningTracks.mock.calls[1][1][0].ordinal).toBe(500)
    expect(mocks.putListeningDays.mock.calls.map(([, days]) => days.length)).toEqual([2000, 1])
    expect(mocks.putListeningDays.mock.calls[0][1][1999].ordinal).toBe(1999)
    expect(mocks.putListeningDays.mock.calls[1][1][0].ordinal).toBe(2000)
    const stages = options.onProgress.mock.calls.map(([progress]) => progress)
    expect(stages).toContainEqual({ stage: 'listing', file: null, completed: 0, total: 0 })
    expect(stages).toContainEqual({ stage: 'uploading_tracks', completed: 500, total: 501 })
    expect(stages).toContainEqual({ stage: 'uploading_tracks', completed: 501, total: 501 })
    expect(stages).toContainEqual({ stage: 'uploading_days', completed: 2000, total: 2001 })
    expect(stages).toContainEqual({ stage: 'uploading_days', completed: 2001, total: 2001 })
  })

  it('chunks library and artists by 500, playlists by 50, and entries by 200', async () => {
    const { service, mocks } = setup(fakeParser(accountSnapshot(501, 51, 201)))
    const options = uploadOptions()

    await service.upload(new Blob([]), options)

    expect(mocks.putListeningLibrary.mock.calls.map(([, rows]) => rows.length)).toEqual([500, 1])
    expect(mocks.putListeningLibrary.mock.calls[1][1][0].ordinal).toBe(500)
    expect(mocks.putListeningArtists.mock.calls.map(([, rows]) => rows.length)).toEqual([500, 1])
    expect(mocks.putListeningArtists.mock.calls[1][1][0].ordinal).toBe(500)
    expect(mocks.beginPlaylistSync).toHaveBeenCalledWith({
      source: 'spotify_export', storefront: null, expectedPlaylists: 51, expectedEntries: 201,
    }, options.signal)
    expect(mocks.putPlaylists.mock.calls.map(([, playlists]) => playlists.length)).toEqual([50, 1])
    expect(mocks.putPlaylistEntries.mock.calls.map(([, key, entries]) => [key, entries.length]))
      .toEqual([['0'.repeat(64), 200], ['0'.repeat(64), 1]])
    expect(mocks.putPlaylistEntries.mock.calls[1][2][0].position).toBe(200)
    expect(options.onProgress).toHaveBeenLastCalledWith({ stage: 'complete', completed: 1, total: 1 })
  })

  it('stops between chunks when cancelled and posts no completion', async () => {
    const { service, mocks } = setup(fakeParser(extendedSnapshot(501, 5)))
    const controller = new AbortController()
    mocks.putListeningTracks.mockImplementationOnce(async (_importId, tracks) => {
      controller.abort()
      return { accepted: tracks.length }
    })

    await expect(service.upload(new Blob([]), uploadOptions(controller.signal)))
      .rejects.toMatchObject({ name: 'AbortError' })

    expect(mocks.putListeningTracks).toHaveBeenCalledOnce()
    expect(mocks.putListeningDays).not.toHaveBeenCalled()
    expect(mocks.completeListeningImport).not.toHaveBeenCalled()
    expect(mocks.postFunnelEvent).not.toHaveBeenCalled()
  })

  it('resolves with the listening summary when the playlist phase fails after the history landed', async () => {
    const { service, mocks, calls } = setup(fakeParser(accountSnapshot(1, 1, 1)))
    const options = uploadOptions()
    mocks.putPlaylists.mockRejectedValueOnce(new ApiError(409, { error: 'sync_conflict' }))

    const result = await service.upload(new Blob([]), options)

    expect(result.summary).toEqual(importSummary)
    expect(result.playlists).toBeNull()
    expect(result.playlistError).toBeInstanceOf(ApiError)
    expect(result.playlistError).toMatchObject({ status: 409, code: 'sync_conflict' })
    // The rejected putPlaylists call bypasses the recording mock body, so it is checked on its own.
    expect(calls).toEqual([
      'begin-import', 'put-library', 'put-artists', 'complete-import', 'funnel:import_completed', 'begin-playlists',
    ])
    expect(mocks.putPlaylists).toHaveBeenCalledOnce()
    expect(mocks.postFunnelEvent).toHaveBeenCalledTimes(1)
    expect(mocks.postFunnelEvent).toHaveBeenCalledWith({ type: 'import_completed', surface: 'web' })
    expect(mocks.completePlaylistSync).not.toHaveBeenCalled()
    expect(options.onProgress).toHaveBeenLastCalledWith({ stage: 'complete', completed: 1, total: 1 })
  })

  it('keeps a non-API playlist failure on the result too', async () => {
    const { service, mocks } = setup(fakeParser(accountSnapshot(1, 1, 1)))
    mocks.completePlaylistSync.mockRejectedValueOnce(new TypeError('Failed to fetch'))

    const result = await service.upload(new Blob([]), uploadOptions())

    expect(result.summary).toEqual(importSummary)
    expect(result.playlists).toBeNull()
    expect(result.playlistError).toBeInstanceOf(TypeError)
    expect(mocks.postFunnelEvent).toHaveBeenCalledTimes(1)
  })

  it('rejects on a cancel between playlist steps, with the completion already recorded', async () => {
    const { service, mocks } = setup(fakeParser(accountSnapshot(1, 1, 1)))
    const controller = new AbortController()
    mocks.putPlaylists.mockImplementationOnce(async (_syncId, playlists) => {
      controller.abort()
      return { accepted: playlists.length }
    })

    await expect(service.upload(new Blob([]), uploadOptions(controller.signal)))
      .rejects.toMatchObject({ name: 'AbortError' })

    expect(mocks.putPlaylistEntries).not.toHaveBeenCalled()
    expect(mocks.completePlaylistSync).not.toHaveBeenCalled()
    expect(mocks.postFunnelEvent).toHaveBeenCalledTimes(1)
    expect(mocks.postFunnelEvent).toHaveBeenCalledWith({ type: 'import_completed', surface: 'web' })
  })

  it('rejects when a playlist request is aborted mid-flight', async () => {
    const { service, mocks } = setup(fakeParser(accountSnapshot(1, 1, 1)))
    const controller = new AbortController()
    mocks.beginPlaylistSync.mockImplementationOnce(async () => {
      controller.abort()
      throw controller.signal.reason // what fetch rejects with once its signal aborts
    })

    await expect(service.upload(new Blob([]), uploadOptions(controller.signal)))
      .rejects.toMatchObject({ name: 'AbortError' })

    expect(mocks.putPlaylists).not.toHaveBeenCalled()
    expect(mocks.postFunnelEvent).toHaveBeenCalledTimes(1)
  })

  it('rethrows a custom abort reason from the playlist phase untouched', async () => {
    const { service, mocks } = setup(fakeParser(accountSnapshot(1, 1, 1)))
    const controller = new AbortController()
    const reason = new Error('left the page')
    mocks.beginPlaylistSync.mockImplementationOnce(async () => {
      controller.abort(reason)
      throw reason
    })

    await expect(service.upload(new Blob([]), uploadOptions(controller.signal))).rejects.toBe(reason)
    expect(mocks.postFunnelEvent).toHaveBeenCalledTimes(1)
  })

  it('stops between playlist entry chunks when cancelled', async () => {
    const { service, mocks } = setup(fakeParser(accountSnapshot(1, 1, 201)))
    const controller = new AbortController()
    mocks.putPlaylistEntries.mockImplementationOnce(async (_syncId, _key, entries) => {
      controller.abort()
      return { accepted: entries.length }
    })

    await expect(service.upload(new Blob([]), uploadOptions(controller.signal)))
      .rejects.toMatchObject({ name: 'AbortError' })

    expect(mocks.putPlaylistEntries).toHaveBeenCalledOnce()
    expect(mocks.completePlaylistSync).not.toHaveBeenCalled()
    expect(mocks.postFunnelEvent).toHaveBeenCalledTimes(1)
  })

  it('does not begin the server run when parsing fails', async () => {
    const { service, mocks } = setup({
      parse: async () => { throw new Error('unreadable') },
    })

    await expect(service.upload(new Blob([]), uploadOptions())).rejects.toThrow('unreadable')
    expect(mocks.beginListeningImport).not.toHaveBeenCalled()
  })

  it('propagates an API error with its code and stops the run', async () => {
    const { service, mocks } = setup(fakeParser(extendedSnapshot(2, 2)))
    mocks.putListeningDays.mockRejectedValueOnce(new ApiError(409, { error: 'count_mismatch' }))

    await expect(service.upload(new Blob([]), uploadOptions()))
      .rejects.toMatchObject({ name: 'ApiError', status: 409, code: 'count_mismatch' })

    expect(mocks.completeListeningImport).not.toHaveBeenCalled()
    expect(mocks.postFunnelEvent).not.toHaveBeenCalled()
  })

  it('never surfaces a funnel failure, rejected or thrown', async () => {
    const { service, mocks } = setup(fakeParser(extendedSnapshot(1, 1)))
    mocks.postFunnelEvent.mockRejectedValueOnce(new Error('offline'))
    mocks.postFunnelEvent.mockImplementationOnce(() => { throw new Error('offline') })

    await expect(service.inspect(new Blob([]), { timeZone: 'Africa/Lagos', signal: new AbortController().signal }))
      .resolves.toMatchObject({ inventory: { package: 'spotify_extended', read: [], ignored: [] } })
    await expect(service.upload(new Blob([]), uploadOptions())).resolves.toMatchObject({ playlists: null })
    expect(mocks.postFunnelEvent).toHaveBeenCalledTimes(2)
  })
})
