import { afterEach, describe, expect, it, vi } from 'vitest'
import { AnonymousCapError, ApiError, createMixtapeApi, REMAKE_TEXT } from './client'

const fetchMock = vi.fn<typeof fetch>()

describe('Mixtape API client', () => {
  afterEach(() => {
    fetchMock.mockReset()
    vi.unstubAllGlobals()
  })

  it('uploads voice audio with auth and cancellation without overriding the multipart boundary', async () => {
    fetchMock.mockResolvedValue(new Response(JSON.stringify({ text: 'A quiet evening', language: 'en' }), {
      status: 200, headers: { 'content-type': 'application/json' },
    }))
    vi.stubGlobal('fetch', fetchMock)
    const api = createMixtapeApi('https://api.mixtape.test/', () => 'voice-session-token')
    const audio = new File(['recording'], 'voice-prompt.webm', { type: 'audio/webm' })
    const controller = new AbortController()

    const result = await api.transcribe(audio, controller.signal)

    expect(result).toEqual({ text: 'A quiet evening', language: 'en' })
    expect(fetchMock).toHaveBeenCalledWith('https://api.mixtape.test/transcribe', expect.objectContaining({
      method: 'POST', credentials: 'include', signal: controller.signal,
    }))
    const request = fetchMock.mock.calls[0][1]!
    const headers = new Headers(request.headers)
    expect(headers.get('authorization')).toBe('Bearer voice-session-token')
    expect(headers.get('accept')).toBe('application/json')
    expect(headers.has('content-type')).toBe(false)
    expect(request.body).toBeInstanceOf(FormData)
    const uploaded = (request.body as FormData).get('audio') as File
    expect(uploaded.name).toBe(audio.name)
    expect(uploaded.type).toBe(audio.type)
    expect(uploaded.size).toBe(audio.size)
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

  it('sends a chosen shape beside the message text, not inside it', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ djMessage: { id: 'm', role: 'dj', content: 'ok', queueVersion: null, createdAt: '2026-08-30T18:00:04.000Z' }, queue: [], queueVersion: 3 }), { status: 200, headers: { 'content-type': 'application/json' } }),
    )
    vi.stubGlobal('fetch', fetchMock)

    await createMixtapeApi('https://api.mixtape.test/').sendMessage('session-1', 'Slower in the middle', 'fall')

    expect(fetchMock).toHaveBeenCalledWith(
      'https://api.mixtape.test/sessions/session-1/messages',
      expect.objectContaining({ body: JSON.stringify({ text: 'Slower in the middle', energyArc: 'fall' }) }),
    )
  })

  it('sends remake: true only when asked', async () => {
    const reply = () => new Response(JSON.stringify({ djMessage: { id: 'm', role: 'dj', content: 'ok', queueVersion: 4, createdAt: '2026-11-09T18:00:04.000Z' }, queue: [], queueVersion: 4 }), { status: 200, headers: { 'content-type': 'application/json' } })
    fetchMock.mockImplementation(async () => reply())
    vi.stubGlobal('fetch', fetchMock)
    const api = createMixtapeApi('https://api.mixtape.test')

    await api.sendMessage('session-1', REMAKE_TEXT, undefined, { remake: true })
    await api.sendMessage('session-1', 'Slower in the middle', 'fall', { remake: true })
    await api.sendMessage('session-1', 'Keep going', undefined, { remake: false })
    await api.sendMessage('session-1', 'Keep going', undefined, {})
    await api.sendMessage('session-1', 'Keep going')

    expect(REMAKE_TEXT).toBe('Remake this with my music')
    expect(fetchMock.mock.calls.map(([url, init]) => [url, init?.body])).toEqual([
      ['https://api.mixtape.test/sessions/session-1/messages', JSON.stringify({ text: 'Remake this with my music', remake: true })],
      ['https://api.mixtape.test/sessions/session-1/messages', JSON.stringify({ text: 'Slower in the middle', energyArc: 'fall', remake: true })],
      ['https://api.mixtape.test/sessions/session-1/messages', JSON.stringify({ text: 'Keep going' })],
      ['https://api.mixtape.test/sessions/session-1/messages', JSON.stringify({ text: 'Keep going' })],
      ['https://api.mixtape.test/sessions/session-1/messages', JSON.stringify({ text: 'Keep going' })],
    ])
  })

  it('reads the history pill on a follow-up turn, and leaves the key out when it is missing or unknown', async () => {
    const turn = (extra: Record<string, unknown>) => new Response(JSON.stringify({ djMessage: { id: 'm', role: 'dj', content: 'ok', queueVersion: 4, createdAt: '2026-11-09T18:00:04.000Z' }, queue: [], queueVersion: 4, ...extra }), { status: 200, headers: { 'content-type': 'application/json' } })
    fetchMock
      .mockResolvedValueOnce(turn({ addMusic: 'history' }))
      .mockResolvedValueOnce(turn({}))
      .mockResolvedValueOnce(turn({ addMusic: null }))
      .mockResolvedValueOnce(turn({ addMusic: 'apple_export' }))
    vi.stubGlobal('fetch', fetchMock)
    const api = createMixtapeApi('https://api.mixtape.test')

    expect((await api.sendMessage('session-1', 'Only my likes')).addMusic).toBe('history')
    for (let call = 0; call < 3; call += 1) {
      const response = await api.sendMessage('session-1', 'Only my likes')
      expect(response).not.toHaveProperty('addMusic')
      expect(response.queueVersion).toBe(4)
    }
  })

  it('reads the history pill on a new mix, and leaves the key out when it is missing', async () => {
    const created = (extra: Record<string, unknown>) => new Response(JSON.stringify({
      session: { id: 'session-9', title: 'Likes', status: 'active', queueVersion: 1, notPersonal: false, updatedAt: '2026-11-09T18:00:00.000Z' },
      messages: [],
      queue: [],
      suggestions: [],
      ...extra,
    }), { status: 200, headers: { 'content-type': 'application/json' } })
    fetchMock.mockResolvedValueOnce(created({ addMusic: 'history' })).mockResolvedValueOnce(created({}))
    vi.stubGlobal('fetch', fetchMock)
    const api = createMixtapeApi('https://api.mixtape.test')

    expect((await api.createSession('From my likes')).addMusic).toBe('history')
    const plain = await api.createSession('From my likes')
    expect(plain).not.toHaveProperty('addMusic')
    expect(plain.session.id).toBe('session-9')
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

    const signal = new AbortController().signal
    await api.listPlaylists({ status: 'active', source: 'spotify_export', q: 'late night', limit: 24, cursor: 'cursor/one' }, signal)
    await api.getPlaylist('playlist/id', { entryLimit: 100, entryCursor: 'entry/one' }, signal)

    expect(fetchMock.mock.calls.map(([url]) => url)).toEqual([
      'https://api.mixtape.test/playlists?status=active&limit=24&q=late+night&source=spotify_export&cursor=cursor%2Fone',
      'https://api.mixtape.test/playlists/playlist%2Fid?entryLimit=100&entryCursor=entry%2Fone',
    ])
    expect(fetchMock.mock.calls.every(([, init]) => init?.signal === signal)).toBe(true)
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

  it('reads AI consent from /me and treats an older server (no field) as granted', async () => {
    vi.stubGlobal('fetch', fetchMock)
    fetchMock.mockResolvedValueOnce(json({ user: { id: 'user-1', isAnonymous: false }, merged: null, aiConsent: false }))
    fetchMock.mockResolvedValueOnce(json({ user: { id: 'user-1', isAnonymous: false }, merged: null, aiConsent: true }))
    fetchMock.mockResolvedValueOnce(json({ user: { id: 'user-1', isAnonymous: false }, merged: null }))
    const api = createMixtapeApi('https://api.mixtape.test')

    expect((await api.getMe()).aiConsent).toBe(false)
    expect((await api.getMe()).aiConsent).toBe(true)
    expect((await api.getMe()).aiConsent).toBe(true)
  })

  it('records AI consent with POST /me/ai-consent and the current version', async () => {
    fetchMock.mockResolvedValueOnce(json({ aiConsent: true }))
    vi.stubGlobal('fetch', fetchMock)
    const api = createMixtapeApi('https://api.mixtape.test', () => 'consent-token')

    await expect(api.grantAiConsent()).resolves.toEqual({ aiConsent: true })

    const [url, init] = fetchMock.mock.calls[0]
    expect(url).toBe('https://api.mixtape.test/me/ai-consent')
    expect(init?.method).toBe('POST')
    expect(init?.body).toBe(JSON.stringify({ version: '2026-11-02' }))
    expect(new Headers(init?.headers).get('authorization')).toBe('Bearer consent-token')
  })

  it('rejects a consent answer the server did not record', async () => {
    vi.stubGlobal('fetch', fetchMock)
    fetchMock.mockResolvedValueOnce(json({ error: 'stale_consent_version' }, 409))
    fetchMock.mockResolvedValueOnce(json({ aiConsent: false }))
    const api = createMixtapeApi('https://api.mixtape.test')

    await expect(api.grantAiConsent()).rejects.toMatchObject({ name: 'ApiError', status: 409, code: 'stale_consent_version' })
    await expect(api.grantAiConsent()).rejects.toThrow()
  })

  it('deletes the account with DELETE /me and no body', async () => {
    fetchMock.mockResolvedValueOnce(json({ deleted: true, apple: 'not_linked' }))
    vi.stubGlobal('fetch', fetchMock)
    const api = createMixtapeApi('https://api.mixtape.test')

    await expect(api.deleteAccount()).resolves.toEqual({ deleted: true, apple: 'not_linked' })

    const [url, init] = fetchMock.mock.calls[0]
    expect(url).toBe('https://api.mixtape.test/me')
    expect(init?.method).toBe('DELETE')
    expect(init?.body).toBeUndefined()
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

describe('Mixtape API client: listening import and onboarding', () => {
  afterEach(() => {
    fetchMock.mockReset()
    vi.unstubAllGlobals()
  })

  const track = {
    ordinal: 0,
    platformId: 'LowTideRadio0000000001',
    title: 'Low Tide Radio',
    artist: 'The Copper Hours',
    album: 'Night Ferry',
    durationMs: 187_000,
  }
  const day = {
    ordinal: 0,
    platformId: 'LowTideRadio0000000001',
    day: '2025-01-15',
    plays: 1,
    skips: 0,
    completes: 1,
    msPlayed: 187_000,
    hoursMask: 524_288,
  }
  const libraryRow = {
    ordinal: 0,
    platformId: 'LowTideRadio0000000001',
    playCount: null,
    skipCount: null,
    lastPlayedAt: null,
    dateAdded: null,
    likeRating: null,
  }
  const artist = { ordinal: 0, name: 'Meridian Vale', spotifyId: 'MeridianVale0000000001' }

  it('stages a listening import through begin, chunk puts, complete, and source delete', async () => {
    const summary = {
      tracks: 1, days: 1, libraryTracks: 1, artists: 1, unresolvedRows: 2, unresolvedPlays: 1,
      ledgerFrom: '2025-01-15', ledgerTo: '2025-01-15', likedRemoved: 0, likedRemovalSkipped: false,
    }
    fetchMock
      .mockResolvedValueOnce(json({ importId: 'import-1', expiresAt: 1_788_138_000_000 }, 201))
      .mockResolvedValueOnce(json({ accepted: 1 }))
      .mockResolvedValueOnce(json({ accepted: 1 }))
      .mockResolvedValueOnce(json({ accepted: 1 }))
      .mockResolvedValueOnce(json({ accepted: 1 }))
      .mockResolvedValueOnce(json(summary))
      .mockResolvedValueOnce(json({ deletedDays: 1, deletedTracks: 1, unlibraried: 1 }))
    vi.stubGlobal('fetch', fetchMock)
    const api = createMixtapeApi('https://api.mixtape.test')
    const signal = new AbortController().signal
    const begin = {
      source: 'spotify_export' as const,
      package: 'spotify_extended' as const,
      timeZone: 'Africa/Lagos',
      country: 'NG',
      expectedTracks: 1,
      expectedDays: 1,
      expectedLibraryTracks: 0,
      expectedArtists: 0,
      unresolvedRows: 2,
      unresolvedPlays: 1,
    }

    const started = await api.beginListeningImport(begin, signal)
    expect(started).toEqual({ importId: 'import-1', expiresAt: 1_788_138_000_000 })
    expect(await api.putListeningTracks('import-1', [track], signal)).toEqual({ accepted: 1 })
    expect(await api.putListeningDays('import-1', [day], signal)).toEqual({ accepted: 1 })
    expect(await api.putListeningLibrary('import-1', [libraryRow], signal)).toEqual({ accepted: 1 })
    expect(await api.putListeningArtists('import-1', [artist], signal)).toEqual({ accepted: 1 })
    expect(await api.completeListeningImport('import-1', signal)).toEqual(summary)
    expect(await api.deleteListeningSource('spotify_export', signal))
      .toEqual({ deletedDays: 1, deletedTracks: 1, unlibraried: 1 })

    expect(fetchMock.mock.calls.map(([url, init]) => [url, init?.method])).toEqual([
      ['https://api.mixtape.test/ingest/listening/imports', 'POST'],
      ['https://api.mixtape.test/ingest/listening/imports/import-1/tracks', 'PUT'],
      ['https://api.mixtape.test/ingest/listening/imports/import-1/days', 'PUT'],
      ['https://api.mixtape.test/ingest/listening/imports/import-1/library', 'PUT'],
      ['https://api.mixtape.test/ingest/listening/imports/import-1/artists', 'PUT'],
      ['https://api.mixtape.test/ingest/listening/imports/import-1/complete', 'POST'],
      ['https://api.mixtape.test/ingest/listening/sources/spotify_export', 'DELETE'],
    ])
    expect(fetchMock.mock.calls[0][1]?.body).toBe(JSON.stringify(begin))
    expect(fetchMock.mock.calls[1][1]?.body).toBe(JSON.stringify({ tracks: [track] }))
    expect(fetchMock.mock.calls[2][1]?.body).toBe(JSON.stringify({ days: [day] }))
    expect(fetchMock.mock.calls[3][1]?.body).toBe(JSON.stringify({ tracks: [libraryRow] }))
    expect(fetchMock.mock.calls[4][1]?.body).toBe(JSON.stringify({ artists: [artist] }))
    expect(fetchMock.mock.calls[5][1]?.body).toBeUndefined()
    expect(fetchMock.mock.calls.every(([, init]) => init?.signal === signal)).toBe(true)
  })

  it('surfaces the listening protocol error codes through ApiError', async () => {
    fetchMock
      .mockResolvedValueOnce(json({ error: 'count_mismatch' }, 409))
      .mockResolvedValueOnce(json({ error: 'invalid_id' }, 400))
      .mockResolvedValueOnce(json({ error: 'not_found' }, 404))
    vi.stubGlobal('fetch', fetchMock)
    const api = createMixtapeApi('https://api.mixtape.test')

    await expect(api.putListeningDays('import-1', [day]))
      .rejects.toMatchObject({ name: 'ApiError', status: 409, code: 'count_mismatch' })
    await expect(api.putListeningTracks('import-1', [track]))
      .rejects.toMatchObject({ status: 400, code: 'invalid_id' })
    await expect(api.completeListeningImport('import-1'))
      .rejects.toMatchObject({ status: 404, code: 'not_found' })
  })

  it('folds a schema rejection into the invalid_request code', async () => {
    const zodPayload = {
      success: false,
      error: { name: 'ZodError', issues: [{ code: 'too_big', path: ['tracks'], message: 'Too many' }] },
    }
    fetchMock
      .mockResolvedValueOnce(json(zodPayload, 400))
      .mockResolvedValueOnce(json({ error: 'invalid_request' }, 400))
    vi.stubGlobal('fetch', fetchMock)
    const api = createMixtapeApi('https://api.mixtape.test')

    await expect(api.putListeningTracks('import-1', [track]))
      .rejects.toMatchObject({ name: 'ApiError', status: 400, code: 'invalid_request', payload: zodPayload })
    await expect(api.putListeningTracks('import-1', [track]))
      .rejects.toMatchObject({ name: 'ApiError', status: 400, code: 'invalid_request' })

    // The mapping is narrow: a code string wins, and only an explicit refusal folds.
    expect(new ApiError(400, { success: false }).code).toBe('invalid_request')
    expect(new ApiError(409, { success: false, error: 'count_mismatch' }).code).toBe('count_mismatch')
    expect(new ApiError(500, { success: true }).code).toBeUndefined()
    expect(new ApiError(500, {}).code).toBeUndefined()
    expect(new ApiError(502, 'Bad Gateway').code).toBeUndefined()
  })

  it('begins a Spotify playlist sync with a null storefront', async () => {
    fetchMock.mockResolvedValueOnce(json({ syncId: 'playlist-sync', expiresAt: 1_788_138_000_000 }, 201))
    vi.stubGlobal('fetch', fetchMock)
    const api = createMixtapeApi('https://api.mixtape.test')

    const started = await api.beginPlaylistSync({
      source: 'spotify_export', storefront: null, expectedPlaylists: 2, expectedEntries: 5,
    })

    expect(started.syncId).toBe('playlist-sync')
    expect(fetchMock.mock.calls[0][0]).toBe('https://api.mixtape.test/ingest/playlists/syncs')
    expect(fetchMock.mock.calls[0][1]?.body).toBe(JSON.stringify({
      source: 'spotify_export', storefront: null, expectedPlaylists: 2, expectedEntries: 5,
    }))
  })

  it('reads onboarding state and connected music sources', async () => {
    const source = {
      source: 'spotify_export',
      connectedAt: '2026-09-01T12:00:00.000Z',
      lastImportedAt: '2026-09-02T12:00:00.000Z',
      ledgerFrom: '2024-03-02',
      ledgerTo: '2026-04-05',
    }
    const onboarding = {
      sources: [source],
      hasLibrary: true,
      chosenService: 'spotify',
      markedRequestedAt: '2026-09-01T12:00:00.000Z',
      interviewCompletedAt: null,
      importCompletedAt: '2026-09-02T12:00:00.000Z',
      musicReady: true,
    }
    fetchMock
      .mockResolvedValueOnce(json(onboarding))
      .mockResolvedValueOnce(json({ sources: [source] }))
    vi.stubGlobal('fetch', fetchMock)
    const api = createMixtapeApi('https://api.mixtape.test')

    expect(await api.getOnboarding()).toEqual(onboarding)
    expect(await api.getMusicSources()).toEqual({ sources: [source] })
    expect(fetchMock.mock.calls.map(([url, init]) => [url, init?.method])).toEqual([
      ['https://api.mixtape.test/me/onboarding', undefined],
      ['https://api.mixtape.test/me/music-sources', undefined],
    ])
  })

  it('reads musicReady as false when an older server leaves it out, or sends anything but true', async () => {
    const onboarding = {
      userId: 'user-1',
      sources: [],
      hasLibrary: false,
      chosenService: null,
      markedRequestedAt: null,
      interviewCompletedAt: null,
      importCompletedAt: null,
      interview: null,
    }
    fetchMock
      .mockResolvedValueOnce(json(onboarding))
      .mockResolvedValueOnce(json({ ...onboarding, musicReady: null }))
      .mockResolvedValueOnce(json({ ...onboarding, musicReady: false }))
    vi.stubGlobal('fetch', fetchMock)
    const api = createMixtapeApi('https://api.mixtape.test')

    expect(await api.getOnboarding()).toEqual({ ...onboarding, musicReady: false })
    expect((await api.getOnboarding()).musicReady).toBe(false)
    expect((await api.getOnboarding()).musicReady).toBe(false)
  })

  it('passes an empty or null onboarding body through as before, without throwing', async () => {
    fetchMock
      .mockResolvedValueOnce(new Response(null, { status: 204 }))
      .mockResolvedValueOnce(new Response('', { status: 200 }))
      .mockResolvedValueOnce(json(null))
    vi.stubGlobal('fetch', fetchMock)
    const api = createMixtapeApi('https://api.mixtape.test')

    await expect(api.getOnboarding()).resolves.toBeNull()
    await expect(api.getOnboarding()).resolves.toBe('')
    await expect(api.getOnboarding()).resolves.toBeNull()
  })

  it('posts funnel events and the interview as JSON', async () => {
    fetchMock
      .mockResolvedValueOnce(json({ ok: true }, 201))
      .mockResolvedValueOnce(json({ seeds: 2, notes: { saved: 4, duplicate: 0, capped: 0 } }))
    vi.stubGlobal('fetch', fetchMock)
    const api = createMixtapeApi('https://api.mixtape.test')
    const interview = {
      surface: 'web' as const,
      neverSkip: ['Sade', 'Tems'],
      playsMost: 'Slow soul',
      listensWhen: 'Late, after work',
      neverWants: 'Nothing sleepy',
      era: '90s',
    }

    expect(await api.postFunnelEvent({ type: 'file_inspected', surface: 'web' })).toEqual({ ok: true })
    expect(await api.postInterview(interview)).toEqual({ seeds: 2, notes: { saved: 4, duplicate: 0, capped: 0 } })
    expect(fetchMock.mock.calls[0][1]?.keepalive).toBe(true)
    expect(fetchMock.mock.calls.map(([url, init]) => [url, init?.method, init?.body])).toEqual([
      ['https://api.mixtape.test/me/funnel-events', 'POST', JSON.stringify({ type: 'file_inspected', surface: 'web' })],
      ['https://api.mixtape.test/me/interview', 'POST', JSON.stringify(interview)],
    ])
  })

  it('lists and replaces artist seeds and manages pasted seed tracks', async () => {
    const seed = { name: 'Sade', spotifyId: null, source: 'interview', createdAt: '2026-09-01T12:00:00.000Z' }
    const seedTrack = {
      trackId: 'track-1', spotifyId: 'LowTideRadio0000000001', title: 'Low Tide Radio', artist: 'The Copper Hours', album: null,
    }
    fetchMock
      .mockResolvedValueOnce(json({ seeds: [seed] }))
      .mockResolvedValueOnce(json({ seeds: [seed] }))
      .mockResolvedValueOnce(json({ tracks: [seedTrack] }))
      .mockResolvedValueOnce(json({
        resolved: [{ spotifyId: 'LowTideRadio0000000001', trackId: 'track-1', title: 'Low Tide Radio', artist: 'The Copper Hours' }],
        unresolved: ['Missing000000000000001'],
      }))
      .mockResolvedValueOnce(json({ removed: true, deleted: false }))
    vi.stubGlobal('fetch', fetchMock)
    const api = createMixtapeApi('https://api.mixtape.test')

    expect(await api.getArtistSeeds()).toEqual({ seeds: [seed] })
    expect(await api.putArtistSeeds(['Sade'])).toEqual({ seeds: [seed] })
    expect(await api.getSeedTracks()).toEqual({ tracks: [seedTrack] })
    const pasted = await api.postSeedTracks(['LowTideRadio0000000001', 'Missing000000000000001'])
    expect(pasted.resolved[0].trackId).toBe('track-1')
    expect(pasted.unresolved).toEqual(['Missing000000000000001'])
    expect(await api.deleteSeedTrack('track/1')).toEqual({ removed: true, deleted: false })

    expect(fetchMock.mock.calls.map(([url, init]) => [url, init?.method ?? 'GET', init?.body])).toEqual([
      ['https://api.mixtape.test/me/artist-seeds', 'GET', undefined],
      ['https://api.mixtape.test/me/artist-seeds', 'PUT', JSON.stringify({ names: ['Sade'] })],
      ['https://api.mixtape.test/me/seed-tracks', 'GET', undefined],
      ['https://api.mixtape.test/me/seed-tracks', 'POST', JSON.stringify({ spotifyIds: ['LowTideRadio0000000001', 'Missing000000000000001'] })],
      ['https://api.mixtape.test/me/seed-tracks/track%2F1', 'DELETE', undefined],
    ])
  })

  it('reads the signed-in user and the one-time merge result from /me', async () => {
    fetchMock.mockResolvedValue(new Response(JSON.stringify({
      user: { id: 'user-1', name: 'Noble', email: 'noble@example.com', isAnonymous: false },
      merged: 'mixes_only',
    }), { status: 200, headers: { 'content-type': 'application/json' } }))
    vi.stubGlobal('fetch', fetchMock)
    const api = createMixtapeApi('https://api.mixtape.test', () => 'me-token')

    const result = await api.getMe()

    expect(fetchMock).toHaveBeenCalledWith('https://api.mixtape.test/me', expect.objectContaining({ credentials: 'include' }))
    expect(new Headers(fetchMock.mock.calls[0][1]!.headers).get('authorization')).toBe('Bearer me-token')
    expect(result).toEqual({ user: { id: 'user-1', isAnonymous: false }, merged: 'mixes_only', albumPicks: false, neverRefuse: false, aiConsent: true, askName: false })
  })

  it('reports an anonymous user with no merge as merged null', async () => {
    fetchMock.mockResolvedValue(new Response(JSON.stringify({
      user: { id: 'anon-1', name: 'Listener', email: 'x@anonymous.mixtape.invalid', isAnonymous: true },
      merged: null,
    }), { status: 200, headers: { 'content-type': 'application/json' } }))
    vi.stubGlobal('fetch', fetchMock)

    const result = await createMixtapeApi('https://api.mixtape.test').getMe()

    expect(result).toEqual({ user: { id: 'anon-1', isAnonymous: true }, merged: null, albumPicks: false, neverRefuse: false, aiConsent: true, askName: false })
  })

  it('maps the anonymous mix cap on a new mix to AnonymousCapError', async () => {
    fetchMock.mockResolvedValue(new Response(JSON.stringify({ error: 'anonymous_cap', limit: 3 }), {
      status: 403, headers: { 'content-type': 'application/json' },
    }))
    vi.stubGlobal('fetch', fetchMock)

    const error = await createMixtapeApi('https://api.mixtape.test').createSession('late night drive').catch((e: unknown) => e)

    expect(error).toBeInstanceOf(AnonymousCapError)
    expect(error).toBeInstanceOf(ApiError)
    expect(error).toMatchObject({ name: 'AnonymousCapError', status: 403, code: 'anonymous_cap', limit: 3 })
  })

  it('keeps other 403s from POST /sessions as a plain ApiError', async () => {
    fetchMock.mockResolvedValue(new Response(JSON.stringify({ error: 'forbidden' }), {
      status: 403, headers: { 'content-type': 'application/json' },
    }))
    vi.stubGlobal('fetch', fetchMock)

    const error = await createMixtapeApi('https://api.mixtape.test').createSession('late night drive').catch((e: unknown) => e)

    expect(error).toBeInstanceOf(ApiError)
    expect(error).not.toBeInstanceOf(AnonymousCapError)
  })

  describe('album picks', () => {
    const ok = (body: unknown) => new Response(JSON.stringify(body), { status: 200, headers: { 'content-type': 'application/json' } })
    const sent = () => fetchMock.mock.calls.map(([url, init]) => [url, init?.method ?? 'GET', init?.body])

    it('sends kind album on a new session and never an energy arc', async () => {
      fetchMock.mockImplementation(async () => ok({ session: {}, messages: [], pick: null, runnersUp: [], passed: [], version: 1 }))
      vi.stubGlobal('fetch', fetchMock)
      const api = createMixtapeApi('https://api.mixtape.test')

      await api.createSession('An album for the train home', undefined, 'rise', 'album')
      await api.createSession('A mix', undefined, 'rise', 'mix')
      await api.createSession('A plain mix')

      expect(sent()).toEqual([
        ['https://api.mixtape.test/sessions', 'POST', JSON.stringify({ prompt: 'An album for the train home', kind: 'album' })],
        ['https://api.mixtape.test/sessions', 'POST', JSON.stringify({ prompt: 'A mix', energyArc: 'rise' })],
        ['https://api.mixtape.test/sessions', 'POST', JSON.stringify({ prompt: 'A plain mix' })],
      ])
    })

    it('chooses a runner-up or goes back to a version, fenced on expectedVersion', async () => {
      fetchMock.mockImplementation(async () => ok({ pick: null, runnersUp: [], passed: [], version: 3 }))
      vi.stubGlobal('fetch', fetchMock)
      const api = createMixtapeApi('https://api.mixtape.test')

      await api.choosePick('session/1', { albumId: 'album-2' }, 2)
      await api.choosePick('session/1', { version: 1 })

      expect(sent()).toEqual([
        ['https://api.mixtape.test/sessions/session%2F1/pick', 'POST', JSON.stringify({ albumId: 'album-2', expectedVersion: 2 })],
        ['https://api.mixtape.test/sessions/session%2F1/pick', 'POST', JSON.stringify({ version: 1 })],
      ])
    })

    it('reads and writes the Listen later shelf', async () => {
      fetchMock.mockImplementation(async () => ok({ entries: [] }))
      vi.stubGlobal('fetch', fetchMock)
      const api = createMixtapeApi('https://api.mixtape.test')

      await api.listListenLater()
      await api.saveForLater('album/1', 'session-1')
      await api.saveForLater('album/1')
      await api.unsaveForLater('album/1')
      await api.markListened('album/1')

      expect(sent()).toEqual([
        ['https://api.mixtape.test/me/listen-later', 'GET', undefined],
        ['https://api.mixtape.test/me/listen-later/album%2F1', 'PUT', JSON.stringify({ sessionId: 'session-1' })],
        ['https://api.mixtape.test/me/listen-later/album%2F1', 'PUT', JSON.stringify({})],
        ['https://api.mixtape.test/me/listen-later/album%2F1', 'DELETE', undefined],
        ['https://api.mixtape.test/me/listen-later/album%2F1/listened', 'POST', undefined],
      ])
      expect(new Headers(fetchMock.mock.calls[1][1]!.headers).get('content-type')).toBe('application/json')
    })

    it('reads the album picks capability from /me and treats an older server as off', async () => {
      vi.stubGlobal('fetch', fetchMock)
      fetchMock.mockResolvedValueOnce(ok({ user: { id: 'user-1', isAnonymous: false }, merged: null, albumPicks: true }))
      fetchMock.mockResolvedValueOnce(ok({ user: { id: 'user-1', isAnonymous: false }, merged: null }))
      const api = createMixtapeApi('https://api.mixtape.test')

      expect((await api.getMe()).albumPicks).toBe(true)
      expect((await api.getMe()).albumPicks).toBe(false)
    })

    it('reads the never-refuse flag from /me and treats an older server as off', async () => {
      vi.stubGlobal('fetch', fetchMock)
      fetchMock.mockResolvedValueOnce(ok({ user: { id: 'user-1', isAnonymous: true }, merged: null, albumPicks: false, neverRefuse: true, askName: false }))
      fetchMock.mockResolvedValueOnce(ok({ user: { id: 'user-1', isAnonymous: true }, merged: null }))
      const api = createMixtapeApi('https://api.mixtape.test')

      expect((await api.getMe()).neverRefuse).toBe(true)
      expect((await api.getMe()).neverRefuse).toBe(false)
    })

    it('reads askName from /me and treats an older server as not asking', async () => {
      vi.stubGlobal('fetch', fetchMock)
      fetchMock.mockResolvedValueOnce(ok({ user: { id: 'user-1', isAnonymous: false }, merged: null, askName: true }))
      fetchMock.mockResolvedValueOnce(ok({ user: { id: 'user-1', isAnonymous: false }, merged: null }))
      const api = createMixtapeApi('https://api.mixtape.test')

      expect((await api.getMe()).askName).toBe(true)
      expect((await api.getMe()).askName).toBe(false)
    })

    it('reads the public never-refuse flag from /health and treats an older server as off', async () => {
      vi.stubGlobal('fetch', fetchMock)
      fetchMock.mockResolvedValueOnce(ok({ ok: true, service: 'mixtape-api', neverRefuse: true }))
      fetchMock.mockResolvedValueOnce(ok({ ok: true, service: 'mixtape-api' }))
      const api = createMixtapeApi('https://api.mixtape.test')

      expect(await api.getConfig()).toEqual({ neverRefuse: true })
      expect(await api.getConfig()).toEqual({ neverRefuse: false })
      expect(fetchMock.mock.calls.map(([url, init]) => [url, init?.method ?? 'GET'])).toEqual([
        ['https://api.mixtape.test/health', 'GET'],
        ['https://api.mixtape.test/health', 'GET'],
      ])
    })
  })
})
