import { describe, expect, it } from 'vitest'
import type { ApiQueueTrack, ApiSession } from './client'
import { toDjSession, toQueueTrack } from './mappers'

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
