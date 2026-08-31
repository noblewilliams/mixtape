import { describe, expect, it } from 'vitest'
import type { ApiQueueTrack } from './client'
import { toQueueTrack } from './mappers'

function track(artwork: Pick<
  ApiQueueTrack,
  'artworkUrl' | 'artworkWidth' | 'artworkHeight' | 'artworkBgColor'
>): ApiQueueTrack {
  return {
    position: 0,
    trackId: 'track-1',
    appleId: 'apple-1',
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
