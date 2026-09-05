import { describe, expect, it } from 'vitest'
import {
  DraftOperationError,
  applyDraftOperations,
  diffDraft,
  type DraftEntry,
} from '../../src/playlist-editing/domain'

const source = (entryKey: string, title = entryKey): DraftEntry => ({
  entryKey,
  origin: 'source',
  sourceEntryId: entryKey,
  trackId: null,
  appleLibraryTrackId: `library-${entryKey}`,
  appleCatalogId: null,
  spotifyId: null,
  title,
  artist: 'Artist',
  album: null,
  durationMs: null,
  artworkUrlTemplate: null,
  artworkWidth: null,
  artworkHeight: null,
  artworkBgColor: null,
})

const addition = (entryKey: string, title = entryKey): DraftEntry => ({
  ...source(entryKey, title),
  origin: 'catalog_addition',
  sourceEntryId: null,
  trackId: entryKey,
  appleLibraryTrackId: null,
  appleCatalogId: `catalog-${entryKey}`,
})

describe('playlist edit draft domain', () => {
  it('inserts with occurrence anchors and preserves duplicate recordings', () => {
    const base = [source('a', 'Same'), source('b', 'Same'), source('c')]
    const result = applyDraftOperations(base, [
      { type: 'add', entry: addition('x'), afterEntryKey: 'a', beforeEntryKey: 'b' },
      { type: 'add', entry: addition('y'), afterEntryKey: 'c' },
    ])

    expect(result.map((entry) => entry.entryKey)).toEqual(['a', 'x', 'b', 'c', 'y'])
    expect(result.filter((entry) => entry.title === 'Same')).toHaveLength(2)
  })

  it('removes, moves and replaces one exact occurrence', () => {
    const base = [source('a'), source('b'), source('c'), source('d')]
    const result = applyDraftOperations(base, [
      { type: 'remove', entryKey: 'b' },
      { type: 'move', entryKey: 'd', beforeEntryKey: 'a' },
      { type: 'replace', entryKey: 'c', entry: addition('ignored', 'Replacement') },
    ])

    expect(result.map((entry) => entry.entryKey)).toEqual(['d', 'a', 'c'])
    expect(result[2]).toMatchObject({
      entryKey: 'c',
      sourceEntryId: 'c',
      origin: 'catalog_addition',
      title: 'Replacement',
    })
  })

  it.each([
    { operations: [{ type: 'remove', entryKey: 'missing' }] },
    { operations: [{ type: 'add', entry: addition('a') }] },
    { operations: [{ type: 'add', entry: addition('x'), afterEntryKey: 'a', beforeEntryKey: 'c' }] },
    { operations: [{ type: 'move', entryKey: 'a', afterEntryKey: 'a' }] },
    { operations: [{ type: 'move', entryKey: 'a', beforeEntryKey: 'missing' }] },
  ] as const)('rejects invalid or contradictory operations: $operations', ({ operations }) => {
    expect(() => applyDraftOperations([source('a'), source('b'), source('c')], operations))
      .toThrow(DraftOperationError)
  })

  it('returns a deterministic occurrence-aware diff without counting insertion shifts as moves', () => {
    const base = [source('a'), source('b'), source('c'), source('d')]
    const draft = applyDraftOperations(base, [
      { type: 'add', entry: addition('x'), afterEntryKey: 'a' },
      { type: 'remove', entryKey: 'c' },
      { type: 'move', entryKey: 'd', beforeEntryKey: 'a' },
      { type: 'replace', entryKey: 'b', entry: addition('ignored', 'New B') },
    ])

    expect(diffDraft(base, draft)).toEqual({
      added: [{ entryKey: 'x', toPosition: 2 }],
      removed: [{ entryKey: 'c', fromPosition: 2 }],
      moved: [{ entryKey: 'd', fromPosition: 3, toPosition: 0 }],
      replaced: [{ entryKey: 'b', position: 3 }],
    })
    expect(diffDraft(base, draft)).toEqual(diffDraft(base, draft))
  })

  it('leaves input arrays unchanged and supports an empty result', () => {
    const base = [source('a')]
    expect(applyDraftOperations(base, [{ type: 'remove', entryKey: 'a' }])).toEqual([])
    expect(base.map((entry) => entry.entryKey)).toEqual(['a'])
  })

  it('diffs a 10,000-entry playlist without quadratic storage', () => {
    const base = Array.from({ length: 10_000 }, (_, index) => source(`entry-${index}`))
    const draft = [base[9_999], ...base.slice(0, 9_999)]
    expect(diffDraft(base, draft).moved).toEqual([
      { entryKey: 'entry-9999', fromPosition: 9_999, toPosition: 0 },
    ])
  })
})
