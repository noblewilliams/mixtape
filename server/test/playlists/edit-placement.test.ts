import { describe, expect, it } from 'vitest'
import {
  chooseBestFitAnchors,
  type PlacementEntry,
} from '../../src/playlist-editing/placement'

function entry(entryKey: string, over: Partial<PlacementEntry> = {}): PlacementEntry {
  return {
    entryKey,
    trackId: entryKey,
    artist: 'Artist',
    album: null,
    genre: null,
    releaseYear: null,
    tempo: null,
    energy: null,
    ...over,
  }
}

describe('playlist edit placement', () => {
  it('places a candidate in the smoothest neighbouring gap', () => {
    const current = [
      entry('slow', { tempo: 70, energy: 0.2, genre: 'R&B/Soul' }),
      entry('warm', { tempo: 92, energy: 0.45, genre: 'R&B/Soul' }),
      entry('fast', { tempo: 145, energy: 0.9, genre: 'Dance' }),
    ]
    const candidate = entry('candidate', {
      artist: 'Daniel Caesar', tempo: 120, energy: 0.68, genre: 'R&B/Soul',
    })

    expect(chooseBestFitAnchors(current, candidate)).toEqual({
      afterEntryKey: 'warm',
      beforeEntryKey: 'fast',
    })
  })

  it('uses album and artist continuity when numeric features are unavailable', () => {
    const current = [
      entry('other', { artist: 'Other', album: 'Other album' }),
      entry('daniel-a', { artist: 'Daniel Caesar', album: 'Never Enough' }),
      entry('daniel-b', { artist: 'Daniel Caesar', album: 'Never Enough' }),
    ]
    const candidate = entry('candidate', { artist: 'Daniel Caesar', album: 'Never Enough' })

    expect(chooseBestFitAnchors(current, candidate)).toEqual({
      afterEntryKey: 'daniel-a',
      beforeEntryKey: 'daniel-b',
    })
  })

  it('falls back to append when no comparable metadata exists', () => {
    const current = [entry('a'), entry('b')]
    const candidate = entry('candidate', { artist: '', album: null })
    const blankCurrent = current.map((item) => ({ ...item, artist: '' }))

    expect(chooseBestFitAnchors(blankCurrent, candidate)).toEqual({ afterEntryKey: 'b' })
    expect(chooseBestFitAnchors([], candidate)).toEqual({})
  })

  it('is deterministic on equal scores', () => {
    const current = [
      entry('a', { tempo: 100 }),
      entry('b', { tempo: 100 }),
    ]
    const candidate = entry('candidate', { tempo: 100 })
    expect(chooseBestFitAnchors(current, candidate)).toEqual({
      afterEntryKey: 'a', beforeEntryKey: 'b',
    })
  })
})
