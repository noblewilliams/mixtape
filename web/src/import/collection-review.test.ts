import { expect, it } from 'vitest'
import { applySelection, initialSelection } from './collection-review'
import type { ListeningExportSnapshot } from './snapshot'
const id = '4uLU6hMCjMI75M1A2tKUQC'
const snapshot: ListeningExportSnapshot = {
  source: 'spotify_export',
  package: 'spotify_exportify',
  timeZone: 'UTC',
  country: null,
  tracks: [
    {
      platformId: id,
      title: 'Song',
      artist: 'Artist',
      album: null,
      durationMs: null,
    },
  ],
  days: [],
  library: [],
  artists: [],
  playlists: [
    {
      ordinal: 0,
      key: 'a'.repeat(64),
      name: 'liked',
      description: null,
      lastModifiedAt: null,
      entries: [
        {
          position: 0,
          platformId: id,
          title: 'Song',
          artist: 'Artist',
          album: null,
          addedAt: null,
        },
      ],
    },
  ],
  unresolved: { rows: 0, plays: 0 },
  ledgerFrom: null,
  ledgerTo: null,
}
it('requires review, keeps likes explicit, and removes skipped music from the upload', () => {
  const selected = initialSelection(snapshot, {
    library: { ids: [], fingerprint: 'b'.repeat(64) },
    playlists: [],
  })
  expect(() => applySelection(snapshot, selected)).toThrow()
  selected.confirmed = true
  selected.files[0].role = 'liked'
  expect(
    applySelection(snapshot, selected).snapshot.library.map(
      (r) => r.platformId,
    ),
  ).toEqual([id])
  expect(applySelection(snapshot, selected).snapshot.playlists).toEqual([])
  selected.files[0].role = 'skip'
  expect(() => applySelection(snapshot, selected)).toThrow()
})

it('does not publish an empty quick export or remove likes with an empty file', () => {
  const empty = {
    ...snapshot,
    tracks: [],
    playlists: snapshot.playlists.map((p) => ({ ...p, entries: [] })),
  }
  const selection = initialSelection(empty, {
    library: { ids: [id], fingerprint: 'b'.repeat(64) },
    playlists: [],
  })
  selection.confirmed = true
  selection.confirmRemovals = true
  selection.libraryMode = 'replace'
  selection.files[0].role = 'liked'
  expect(() => applySelection(empty, selection)).toThrow()
})
