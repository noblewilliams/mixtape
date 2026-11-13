import { describe, expect, it } from 'vitest'
import type { ApiAlbum, ApiListenLaterEntry, ApiQueueTrack, ApiSession, ApiSessionSummary } from './client'
import { MalformedResponseError, toAlbumPick, toAlbumPickState, toDjSession, toListenLaterEntry, toQueueTrack, toSharedMix, toSharedMixRow } from './mappers'

function track(artwork: Pick<
  ApiQueueTrack,
  'artworkUrl' | 'artworkWidth' | 'artworkHeight' | 'artworkBgColor'
>): ApiQueueTrack {
  return {
    position: 0,
    trackId: 'track-1',
    appleId: 'apple-1',
    spotifyId: null,
    title: 'Song',
    artist: 'Artist',
    reason: null,
    durationMs: null,
    ...artwork,
  }
}

describe('toQueueTrack artwork contract', () => {
  it('preserves complete artwork metadata', () => {
    expect(
      toQueueTrack(
        track({
          artworkUrl: 'https://is1-ssl.mzstatic.com/image/thumb/cover/{w}x{h}.{f}',
          artworkWidth: 3000,
          artworkHeight: 3000,
          artworkBgColor: '1a2b3c',
        }),
      ),
    ).toMatchObject({
      artworkUrl: 'https://is1-ssl.mzstatic.com/image/thumb/cover/{w}x{h}.{f}',
      artworkWidth: 3000,
      artworkHeight: 3000,
      artworkBgColor: '1a2b3c',
    })
  })

  it('normalizes explicit API nulls to absent optional domain values', () => {
    expect(
      toQueueTrack(
        track({
          artworkUrl: null,
          artworkWidth: null,
          artworkHeight: null,
          artworkBgColor: null,
        }),
      ),
    ).toMatchObject({
      artworkUrl: undefined,
      artworkWidth: undefined,
      artworkHeight: undefined,
      artworkBgColor: undefined,
    })
  })
})

const nullArtwork = { artworkUrl: null, artworkWidth: null, artworkHeight: null, artworkBgColor: null }

describe('toQueueTrack Spotify id', () => {
  it('carries a Spotify id and a null one as-is', () => {
    expect(toQueueTrack({ ...track(nullArtwork), spotifyId: 'LowTideRadio0000000001' }).spotifyId)
      .toBe('LowTideRadio0000000001')
    expect(toQueueTrack(track(nullArtwork)).spotifyId).toBeNull()
  })
})

describe('toQueueTrack new to you', () => {
  it('carries newToYou and treats an older server without the field as false', () => {
    expect(toQueueTrack({ ...track(nullArtwork), newToYou: true }).newToYou).toBe(true)
    expect(toQueueTrack({ ...track(nullArtwork), newToYou: false }).newToYou).toBe(false)
    expect(toQueueTrack(track(nullArtwork)).newToYou).toBe(false)
  })
})

describe('toDjSession corpus flag', () => {
  const session: ApiSession = {
    id: 'session-1',
    title: 'Blue hour',
    status: 'active',
    queueVersion: 2,
    notPersonal: true,
    updatedAt: new Date().toISOString(),
  }

  it('carries notPersonal from the API session', () => {
    expect(toDjSession(session, []).notPersonal).toBe(true)
    expect(toDjSession({ ...session, notPersonal: false, trackCount: 1, durationMs: 1 }).notPersonal).toBe(false)
  })
})

it('uses the saved tape colour and retains deterministic legacy fallback', () => {
  const session: ApiSession = { id: 'tape', title: 'Dinner', status: 'active', queueVersion: 0, notPersonal: false, updatedAt: '2026-09-25T00:00:00Z' }
  expect(toDjSession({ ...session, caseColor: '#3257ae' }).caseColor).toBe('#3257ae')
  expect(toDjSession(session).caseColor).toBe(toDjSession({ ...session }).caseColor)
})

const album: ApiAlbum = {
  id: '9b1f0c1e-0000-4000-8000-000000000001',
  upc: '00000000001',
  appleId: '1500000001',
  title: 'Low Tide Hours',
  artist: 'Mara Ilesanmi',
  releaseYear: 2019,
  type: 'album',
  trackCount: 11,
  durationMs: 2_640_000,
  artwork: null,
  newToThem: false,
  reason: 'Slow and warm.',
  savedForLater: false,
  version: 1,
}

describe('toAlbumPick', () => {
  it('flattens artwork like a queue track and renames newToThem', () => {
    const pick = toAlbumPick({
      ...album,
      newToThem: true,
      artwork: { url: 'https://is1-ssl.mzstatic.com/{w}x{h}.{f}', width: 3000, height: 3000, bgColor: '1a2b3c' },
    })
    expect(pick).toMatchObject({
      id: album.id, title: 'Low Tide Hours', type: 'album', newToYou: true, savedForLater: false, version: 1,
      artworkUrl: 'https://is1-ssl.mzstatic.com/{w}x{h}.{f}', artworkWidth: 3000, artworkHeight: 3000, artworkBgColor: '1a2b3c',
    })
    expect(pick).not.toHaveProperty('newToThem')
    expect(pick).not.toHaveProperty('artwork')
  })

  it('leaves artwork fields absent when the album has none', () => {
    const pick = toAlbumPick(album)
    expect(pick.newToYou).toBe(false)
    expect(pick.artworkUrl).toBeUndefined()
    expect(pick.artworkBgColor).toBeUndefined()
  })

  it('maps a whole pick state', () => {
    const state = toAlbumPickState({ pick: album, runnersUp: [{ ...album, id: 'b' }], passed: [], version: 2 })
    expect(state.version).toBe(2)
    expect(state.pick?.id).toBe(album.id)
    expect(state.runnersUp.map((item) => item.id)).toEqual(['b'])
    expect(toAlbumPickState({ pick: null, runnersUp: [], passed: [], version: 0 }).pick).toBeNull()
  })
})

describe('toListenLaterEntry', () => {
  it('flattens artwork and keeps the session link, dates and reason', () => {
    const entry: ApiListenLaterEntry = {
      id: album.id, upc: null, appleId: '1500000001', title: 'Low Tide Hours', artist: 'Mara Ilesanmi',
      releaseYear: 2019, type: 'live', trackCount: 11, durationMs: 2_640_000,
      artwork: { url: 'https://example.test/{w}x{h}.{f}', width: null, height: null, bgColor: null },
      sessionId: null, savedAt: '2026-10-20T10:00:00.000Z', listenedAt: null, reason: null,
    }
    expect(toListenLaterEntry(entry)).toEqual({
      id: album.id, upc: null, appleId: '1500000001', title: 'Low Tide Hours', artist: 'Mara Ilesanmi',
      releaseYear: 2019, type: 'live', trackCount: 11, durationMs: 2_640_000,
      artworkUrl: 'https://example.test/{w}x{h}.{f}', artworkWidth: undefined, artworkHeight: undefined, artworkBgColor: undefined,
      sessionId: null, savedAt: '2026-10-20T10:00:00.000Z', listenedAt: null, reason: null,
    })
  })
})

describe('toDjSession kinds', () => {
  const base: ApiSession = { id: 'session-1', title: 'Train home', status: 'active', queueVersion: 1, notPersonal: false, updatedAt: new Date().toISOString() }

  it('defaults to a mix on an older server', () => {
    const session = toDjSession(base, [])
    expect(session.kind).toBe('mix')
    expect(session.pick).toBeUndefined()
  })

  it('carries an album summary pick and a null one', () => {
    const summary: ApiSessionSummary = {
      ...base, kind: 'album', trackCount: 0, durationMs: 0,
      pick: { title: 'Low Tide Hours', artist: 'Mara Ilesanmi', artwork: { url: 'https://example.test/{w}x{h}.{f}', width: 600, height: 600, bgColor: '223344' } },
    }
    expect(toDjSession(summary)).toMatchObject({
      kind: 'album', trackCount: 0, durationLabel: '0 min',
      pick: { title: 'Low Tide Hours', artist: 'Mara Ilesanmi', artworkUrl: 'https://example.test/{w}x{h}.{f}', artworkBgColor: '223344' },
    })
    expect(toDjSession({ ...summary, pick: null }).pick).toBeNull()
  })

  it('strips a stray pick from a mix summary', () => {
    const summary: ApiSessionSummary = {
      ...base, kind: 'mix', trackCount: 3, durationMs: 600_000,
      pick: { title: 'Low Tide Hours', artist: 'Mara Ilesanmi', artwork: null },
    }
    const session = toDjSession(summary)
    expect(session.kind).toBe('mix')
    expect(session).not.toHaveProperty('pick')
  })

  it('tolerates an album detail with no queue', () => {
    const session = toDjSession({ ...base, kind: 'album' }, undefined)
    expect(session).toMatchObject({ kind: 'album', trackCount: 0, durationLabel: '0 min' })
  })
})

describe('shared mix mapper (strict)', () => {
  const body = () => ({
    token: '4fQ9xK2mZr7TbW1nLpY8sA',
    title: 'Late drive, windows down',
    caseColor: '#bc5734',
    sharerName: 'Ada',
    sharedAt: '2026-11-13T09:00:00.000Z',
    isOwner: false,
    tracks: [
      {
        title: 'Midnight City', artist: 'M83', album: 'Hurry Up, We’re Dreaming', durationMs: 243_000,
        artwork: { url: 'https://is1-ssl.mzstatic.com/a/{w}x{h}.{f}', width: 3000, height: 3000, bgColor: '1a2b3c' },
        appleId: '1440818588', isrc: 'FR6V81100060',
      },
      { title: 'Nightcall', artist: 'Kavinsky', album: null, durationMs: null, artwork: null, appleId: null, isrc: null },
    ],
  })

  it('maps a complete body, flattening artwork and dropping nulls', () => {
    const mix = toSharedMix(body())
    expect(mix).toEqual({
      token: '4fQ9xK2mZr7TbW1nLpY8sA',
      title: 'Late drive, windows down',
      caseColor: '#bc5734',
      sharerName: 'Ada',
      sharedAt: '2026-11-13T09:00:00.000Z',
      isOwner: false,
      tracks: [
        {
          title: 'Midnight City', artist: 'M83', album: 'Hurry Up, We’re Dreaming', durationMs: 243_000,
          artworkUrl: 'https://is1-ssl.mzstatic.com/a/{w}x{h}.{f}', artworkBgColor: '1a2b3c',
          appleId: '1440818588', isrc: 'FR6V81100060',
        },
        { title: 'Nightcall', artist: 'Kavinsky' },
      ],
    })
  })

  it('keeps sessionId only for the owner', () => {
    expect(toSharedMix({ ...body(), isOwner: true, sessionId: 'session-1' }).sessionId).toBe('session-1')
    expect(toSharedMix({ ...body(), isOwner: false, sessionId: 'session-1' })).not.toHaveProperty('sessionId')
  })

  it('rejects an owner body without a session id', () => {
    expect(() => toSharedMix({ ...body(), isOwner: true })).toThrow(MalformedResponseError)
  })

  it('accepts a null sharer name (the client shows "a friend")', () => {
    expect(toSharedMix({ ...body(), sharerName: null }).sharerName).toBeNull()
  })

  it.each([
    ['not an object', null],
    ['a missing sharerName key', (({ sharerName: _omit, ...rest }) => rest)(body())],
    ['a numeric sharerName', { ...body(), sharerName: 7 }],
    ['a missing title', { ...body(), title: undefined }],
    ['a numeric token', { ...body(), token: 7 }],
    ['a missing isOwner', { ...body(), isOwner: undefined }],
    ['tracks that are not a list', { ...body(), tracks: {} }],
    ['a track without an artist', { ...body(), tracks: [{ ...body().tracks[0], artist: undefined }] }],
    ['a string duration', { ...body(), tracks: [{ ...body().tracks[0], durationMs: '243000' }] }],
    ['artwork without a url', { ...body(), tracks: [{ ...body().tracks[0], artwork: { width: 1, height: 1, bgColor: null } }] }],
    ['a missing appleId field', { ...body(), tracks: [{ title: 'A', artist: 'B', album: null, durationMs: null, artwork: null, isrc: null }] }],
  ])('rejects %s', (_label, value) => {
    expect(() => toSharedMix(value)).toThrow(MalformedResponseError)
  })

  it('maps a saved shared-mix row and rejects a malformed one', () => {
    const row = {
      token: '4fQ9xK2mZr7TbW1nLpY8sA', title: 'Late drive', caseColor: '#bc5734', sharerName: 'Ada',
      savedAt: '2026-11-13T09:00:00.000Z', trackCount: 10, durationMs: 2_460_000,
      artwork: { url: 'https://example.test/{w}x{h}.{f}', width: null, height: null, bgColor: null },
    }
    expect(toSharedMixRow(row)).toEqual({
      token: row.token, title: row.title, caseColor: row.caseColor, sharerName: 'Ada', savedAt: row.savedAt,
      trackCount: 10, durationMs: 2_460_000, artworkUrl: 'https://example.test/{w}x{h}.{f}',
    })
    expect(() => toSharedMixRow({ ...row, trackCount: '10' })).toThrow(MalformedResponseError)
    expect(() => toSharedMixRow({ ...row, artwork: undefined })).toThrow(MalformedResponseError)
    expect(toSharedMixRow({ ...row, sharerName: null }).sharerName).toBeNull()
    const { sharerName: _omit, ...withoutSharer } = row
    expect(() => toSharedMixRow(withoutSharer)).toThrow(MalformedResponseError)
    expect(() => toSharedMixRow({ ...row, sharerName: 7 })).toThrow(MalformedResponseError)
  })
})
