import { afterEach, describe, expect, it, vi } from 'vitest'
import { ApiError, createMixtapeApi } from './client'

const fetchMock = vi.fn<typeof fetch>()

describe('Mixtape API client', () => {
  afterEach(() => {
    fetchMock.mockReset()
    vi.unstubAllGlobals()
  })

  it('loads sessions with credentialed requests', async () => {
    fetchMock.mockResolvedValue(
      new Response(
        JSON.stringify({
          sessions: [
            {
              id: 'session-1',
              title: 'Blue hour',
              status: 'active',
              queueVersion: 2,
              updatedAt: '2026-08-30T18:00:00.000Z',
              trackCount: 12,
              durationMs: 2_400_000,
            },
          ],
        }),
        { status: 200, headers: { 'content-type': 'application/json' } },
      ),
    )
    vi.stubGlobal('fetch', fetchMock)

    const api = createMixtapeApi('https://api.mixtape.test')
    const result = await api.listSessions()

    expect(result.sessions[0].trackCount).toBe(12)
    expect(fetchMock).toHaveBeenCalledWith(
      'https://api.mixtape.test/sessions',
      expect.objectContaining({ credentials: 'include' }),
    )
  })

  it('authenticates direct API requests with the current session token', async () => {
    fetchMock.mockResolvedValue(
      new Response(JSON.stringify({ sessions: [] }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const api = createMixtapeApi('https://api.mixtape.test', () => 'session-token')
    await api.listSessions()

    const request = fetchMock.mock.calls[0][1]
    const headers = new Headers(request?.headers)
    expect(headers.get('authorization')).toBe('Bearer session-token')
  })

  it('omits the authorization header before a session is available', async () => {
    fetchMock.mockResolvedValue(
      new Response(JSON.stringify({ sessions: [] }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const api = createMixtapeApi('https://api.mixtape.test', () => null)
    await api.listSessions()

    const request = fetchMock.mock.calls[0][1]
    const headers = new Headers(request?.headers)
    expect(headers.has('authorization')).toBe(false)
  })

  it('posts a DJ message as JSON', async () => {
    fetchMock.mockResolvedValue(
      new Response(
        JSON.stringify({
          djMessage: {
            id: 'message-2',
            role: 'dj',
            content: 'I moved the brighter songs forward.',
            queueVersion: 3,
            createdAt: '2026-08-30T18:00:04.000Z',
          },
          queue: [],
          queueVersion: 3,
        }),
        { status: 200, headers: { 'content-type': 'application/json' } },
      ),
    )
    vi.stubGlobal('fetch', fetchMock)

    const api = createMixtapeApi('https://api.mixtape.test/')
    await api.sendMessage('session-1', 'Move the brighter songs forward.')

    expect(fetchMock).toHaveBeenCalledWith(
      'https://api.mixtape.test/sessions/session-1/messages',
      expect.objectContaining({
        method: 'POST',
        body: JSON.stringify({ text: 'Move the brighter songs forward.' }),
      }),
    )
  })

  it('posts versioned manual queue operations', async () => {
    fetchMock.mockResolvedValue(
      new Response(
        JSON.stringify({ queueVersion: 4, requested: 0, added: 0, removed: 0, queue: [] }),
        { status: 200, headers: { 'content-type': 'application/json' } },
      ),
    )
    vi.stubGlobal('fetch', fetchMock)

    const api = createMixtapeApi('https://api.mixtape.test')
    await api.applyQueueOps('session-1', [{ op: 'move', from: 0, to: 1 }], 3)

    expect(fetchMock).toHaveBeenCalledWith(
      'https://api.mixtape.test/sessions/session-1/queue-ops',
      expect.objectContaining({
        method: 'POST',
        body: JSON.stringify({ ops: [{ op: 'move', from: 0, to: 1 }], expectedVersion: 3 }),
      }),
    )
  })

  it('loads a short-lived MusicKit token with the signed-in browser session', async () => {
    fetchMock.mockResolvedValue(
      new Response(JSON.stringify({ developerToken: 'developer-token', expiresAt: 1_788_138_000 }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const api = createMixtapeApi('https://api.mixtape.test')
    const result = await api.getMusicKitToken()

    expect(result).toEqual({ developerToken: 'developer-token', expiresAt: 1_788_138_000 })
    expect(fetchMock).toHaveBeenCalledWith(
      'https://api.mixtape.test/musickit/token',
      expect.objectContaining({ credentials: 'include' }),
    )
  })

  it('uploads staged library snapshots through the retry-safe contract', async () => {
    fetchMock
      .mockResolvedValueOnce(json({ syncId: 'sync-1', expiresAt: 1_788_138_000_000 }, 201))
      .mockResolvedValueOnce(json({ accepted: 1 }))
      .mockResolvedValueOnce(json({ accepted: 1 }))
      .mockResolvedValueOnce(json({ songs: 1, catalogResolved: 1, playCountsObserved: 0, recentTracks: 1 }))
    vi.stubGlobal('fetch', fetchMock)
    const api = createMixtapeApi('https://api.mixtape.test')
    const songs = [{
      ordinal: 0,
      appleLibraryId: 'i.song-1',
      appleCatalogId: 'catalog-1',
      title: 'Song',
      artist: 'Artist',
      album: null,
      genre: null,
      releaseYear: null,
      explicit: null,
      playCount: null,
      lastPlayedAt: null,
      dateAdded: null,
    }]

    const started = await api.beginLibrarySync({
      source: 'web_musickit', storefront: 'ng', expectedSongs: 1, expectedRecentTracks: 1,
    })
    await api.putLibrarySongs(started.syncId, songs)
    await api.putLibraryRecentTracks(started.syncId, ['catalog-1'])
    await api.completeLibrarySync(started.syncId)

    expect(fetchMock.mock.calls.map(([url, init]) => [url, init?.method])).toEqual([
      ['https://api.mixtape.test/ingest/library/syncs', 'POST'],
      ['https://api.mixtape.test/ingest/library/syncs/sync-1/songs', 'PUT'],
      ['https://api.mixtape.test/ingest/library/syncs/sync-1/recent-tracks', 'PUT'],
      ['https://api.mixtape.test/ingest/library/syncs/sync-1/complete', 'POST'],
    ])
    expect(fetchMock.mock.calls[0][1]?.body).toBe(JSON.stringify({
      source: 'web_musickit', storefront: 'ng', expectedSongs: 1, expectedRecentTracks: 1,
    }))
    expect(fetchMock.mock.calls[1][1]?.body).toBe(JSON.stringify({ songs }))
    expect(fetchMock.mock.calls[2][1]?.body).toBe(JSON.stringify({ catalogIds: ['catalog-1'] }))
  })

  it('uploads playlist metadata and entries through the existing staged contract', async () => {
    fetchMock
      .mockResolvedValueOnce(json({ syncId: 'playlist-sync', expiresAt: 1_788_138_000_000 }, 201))
      .mockResolvedValueOnce(json({ accepted: 1 }))
      .mockResolvedValueOnce(json({ accepted: 0 }))
      .mockResolvedValueOnce(json({ playlists: 1, entries: 0, resolvedEntries: 0, unresolvedEntries: 0 }))
    vi.stubGlobal('fetch', fetchMock)
    const api = createMixtapeApi('https://api.mixtape.test')

    const started = await api.beginPlaylistSync({
      source: 'web_musickit', storefront: 'ng', expectedPlaylists: 1, expectedEntries: 0,
    })
    await api.putPlaylists(started.syncId, [{
      ordinal: 0,
      appleLibraryId: 'p-1',
      appleCatalogId: null,
      name: 'Playlist',
      description: null,
      curatorName: null,
      artworkUrlTemplate: null,
      artworkWidth: null,
      artworkHeight: null,
      artworkBgColor: null,
      kind: 'user',
      canEdit: true,
      appleDateAdded: null,
      appleLastModifiedAt: null,
      sourceFingerprint: 'a'.repeat(64),
      entryCount: 0,
    }])
    await api.putPlaylistEntries(started.syncId, 'p-1', [])
    await api.completePlaylistSync(started.syncId)

    expect(fetchMock.mock.calls.map(([url, init]) => [url, init?.method])).toEqual([
      ['https://api.mixtape.test/ingest/playlists/syncs', 'POST'],
      ['https://api.mixtape.test/ingest/playlists/syncs/playlist-sync/playlists', 'PUT'],
      ['https://api.mixtape.test/ingest/playlists/syncs/playlist-sync/entries', 'PUT'],
      ['https://api.mixtape.test/ingest/playlists/syncs/playlist-sync/complete', 'POST'],
    ])
  })

  it('loads playlist browse pages and details with encoded cursors', async () => {
    fetchMock
      .mockResolvedValueOnce(json({ playlists: [], nextCursor: 'next cursor' }))
      .mockResolvedValueOnce(json({
        playlist: { id: 'p-1', name: 'Evening', entryCount: 1 },
        entries: [{ id: 'e-1', position: 0, title: 'Song', artist: 'Artist', resolved: true }],
        nextEntryCursor: null,
      }))
    vi.stubGlobal('fetch', fetchMock)
    const api = createMixtapeApi('https://api.mixtape.test')

    await api.listPlaylists({ status: 'active', q: 'late night', limit: 24, cursor: 'cursor/one' })
    await api.getPlaylist('playlist/id', { entryLimit: 100, entryCursor: 'entry/one' })

    expect(fetchMock.mock.calls.map(([url]) => url)).toEqual([
      'https://api.mixtape.test/playlists?status=active&limit=24&q=late+night&cursor=cursor%2Fone',
      'https://api.mixtape.test/playlists/playlist%2Fid?entryLimit=100&entryCursor=entry%2Fone',
    ])
  })

  it('updates sessions and manages DJ memories', async () => {
    fetchMock
      .mockResolvedValueOnce(json({
        session: {
          id: 'session-1', title: 'Renamed', status: 'archived', queueVersion: 3,
          updatedAt: '2026-09-01T12:00:00.000Z',
        },
      }))
      .mockResolvedValueOnce(json({ memories: [{
        id: 'memory-1', note: 'No explicit songs', createdAt: '2026-09-01T12:00:00.000Z',
      }] }))
      .mockResolvedValueOnce(json({ ok: true }))
    vi.stubGlobal('fetch', fetchMock)
    const api = createMixtapeApi('https://api.mixtape.test')

    const updated = await api.updateSession('session-1', { title: 'Renamed', status: 'archived' })
    await api.listMemories()
    await api.deleteMemory('memory/1')

    expect(updated.session).toMatchObject({ title: 'Renamed', status: 'archived' })

    expect(fetchMock.mock.calls.map(([url, init]) => [url, init?.method])).toEqual([
      ['https://api.mixtape.test/sessions/session-1', 'PATCH'],
      ['https://api.mixtape.test/me/memories', undefined],
      ['https://api.mixtape.test/me/memories/memory%2F1', 'DELETE'],
    ])
    expect(fetchMock.mock.calls[0][1]?.body).toBe(JSON.stringify({
      title: 'Renamed', status: 'archived',
    }))
  })

  it('marks an expired browser session as unauthorized', async () => {
    fetchMock.mockResolvedValue(
      new Response(JSON.stringify({ error: 'unauthorized' }), {
        status: 401,
        headers: { 'content-type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const api = createMixtapeApi('https://api.mixtape.test')

    const request = api.listSessions()
    await expect(request).rejects.toBeInstanceOf(ApiError)
    await expect(request).rejects.toMatchObject({ status: 401, code: 'unauthorized' })
  })
})

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  })
}
