export type DraftEntry = {
  entryKey: string
  origin: 'source' | 'catalog_addition'
  sourceEntryId: string | null
  trackId: string | null
  appleLibraryTrackId: string | null
  appleCatalogId: string | null
  spotifyId: string | null
  title: string
  artist: string
  album: string | null
  durationMs: number | null
  artworkUrlTemplate: string | null
  artworkWidth: number | null
  artworkHeight: number | null
  artworkBgColor: string | null
}

type Anchors = { afterEntryKey?: string; beforeEntryKey?: string }

export type ResolvedDraftOperation =
  | ({ type: 'add'; entry: DraftEntry } & Anchors)
  | { type: 'remove'; entryKey: string }
  | ({ type: 'move'; entryKey: string } & Anchors)
  | { type: 'replace'; entryKey: string; entry: DraftEntry }

export type DraftDiff = {
  added: Array<{ entryKey: string; toPosition: number }>
  removed: Array<{ entryKey: string; fromPosition: number }>
  moved: Array<{ entryKey: string; fromPosition: number; toPosition: number }>
  replaced: Array<{ entryKey: string; position: number }>
}

export class DraftOperationError extends Error {
  constructor(readonly category: 'duplicate_entry' | 'missing_entry' | 'invalid_anchors') {
    super(`playlist-edit:${category}`)
  }
}

function positionOf(entries: DraftEntry[], entryKey: string): number {
  const index = entries.findIndex((entry) => entry.entryKey === entryKey)
  if (index < 0) throw new DraftOperationError('missing_entry')
  return index
}

function insertionPosition(entries: DraftEntry[], anchors: Anchors): number {
  const after = anchors.afterEntryKey == null
    ? null
    : positionOf(entries, anchors.afterEntryKey)
  const before = anchors.beforeEntryKey == null
    ? null
    : positionOf(entries, anchors.beforeEntryKey)
  if (after != null && before != null && after + 1 !== before) {
    throw new DraftOperationError('invalid_anchors')
  }
  if (after != null) return after + 1
  if (before != null) return before
  return entries.length
}

export function applyDraftOperations(
  current: readonly DraftEntry[],
  operations: readonly ResolvedDraftOperation[],
): DraftEntry[] {
  const entries = current.map((entry) => ({ ...entry }))
  if (new Set(entries.map((entry) => entry.entryKey)).size !== entries.length) {
    throw new DraftOperationError('duplicate_entry')
  }

  for (const operation of operations) {
    if (operation.type === 'add') {
      if (entries.some((entry) => entry.entryKey === operation.entry.entryKey)) {
        throw new DraftOperationError('duplicate_entry')
      }
      const position = insertionPosition(entries, operation)
      entries.splice(position, 0, { ...operation.entry })
      continue
    }

    const position = positionOf(entries, operation.entryKey)
    if (operation.type === 'remove') {
      entries.splice(position, 1)
      continue
    }
    if (operation.type === 'replace') {
      const existing = entries[position]
      entries[position] = {
        ...operation.entry,
        entryKey: existing.entryKey,
        sourceEntryId: existing.sourceEntryId,
      }
      continue
    }

    if (
      operation.afterEntryKey === operation.entryKey
      || operation.beforeEntryKey === operation.entryKey
    ) throw new DraftOperationError('invalid_anchors')
    const [entry] = entries.splice(position, 1)
    const destination = insertionPosition(entries, operation)
    entries.splice(destination, 0, entry)
  }
  return entries
}

function stableOccurrenceKeys(base: string[], draft: string[]): Set<string> {
  // Entry keys are unique. Therefore the LCS is the longest increasing
  // subsequence of base positions in draft order: O(n log n) rather than a
  // 10k×10k dynamic-programming matrix.
  const basePosition = new Map(base.map((key, position) => [key, position]))
  const keys = draft.filter((key) => basePosition.has(key))
  const values = keys.map((key) => basePosition.get(key)!)
  const tailValues: number[] = []
  const tailIndexes: number[] = []
  const previous = Array<number>(values.length).fill(-1)

  for (let index = 0; index < values.length; index++) {
    let low = 0
    let high = tailValues.length
    while (low < high) {
      const middle = (low + high) >> 1
      if (tailValues[middle] < values[index]) low = middle + 1
      else high = middle
    }
    if (low > 0) previous[index] = tailIndexes[low - 1]
    tailValues[low] = values[index]
    tailIndexes[low] = index
  }

  const stable = new Set<string>()
  let cursor = tailIndexes.at(-1) ?? -1
  while (cursor >= 0) {
    stable.add(keys[cursor])
    cursor = previous[cursor]
  }
  return stable
}

function replaced(base: DraftEntry, draft: DraftEntry): boolean {
  return base.origin !== draft.origin
    || base.trackId !== draft.trackId
    || base.appleLibraryTrackId !== draft.appleLibraryTrackId
    || base.appleCatalogId !== draft.appleCatalogId
    || base.spotifyId !== draft.spotifyId
    || base.title !== draft.title
    || base.artist !== draft.artist
    || base.album !== draft.album
    || base.durationMs !== draft.durationMs
}

export function diffDraft(base: readonly DraftEntry[], draft: readonly DraftEntry[]): DraftDiff {
  const basePositions = new Map(base.map((entry, position) => [entry.entryKey, position]))
  const draftPositions = new Map(draft.map((entry, position) => [entry.entryKey, position]))
  if (basePositions.size !== base.length || draftPositions.size !== draft.length) {
    throw new DraftOperationError('duplicate_entry')
  }
  const baseByKey = new Map(base.map((entry) => [entry.entryKey, entry]))
  const draftByKey = new Map(draft.map((entry) => [entry.entryKey, entry]))
  const commonBase = base.filter((entry) => draftPositions.has(entry.entryKey))
    .map((entry) => entry.entryKey)
  const commonDraft = draft.filter((entry) => basePositions.has(entry.entryKey))
    .map((entry) => entry.entryKey)
  const stable = stableOccurrenceKeys(commonBase, commonDraft)

  return {
    added: draft.flatMap((entry, toPosition) => basePositions.has(entry.entryKey)
      ? [] : [{ entryKey: entry.entryKey, toPosition }]),
    removed: base.flatMap((entry, fromPosition) => draftPositions.has(entry.entryKey)
      ? [] : [{ entryKey: entry.entryKey, fromPosition }]),
    moved: commonDraft.flatMap((entryKey) => stable.has(entryKey) ? [] : [{
      entryKey,
      fromPosition: basePositions.get(entryKey)!,
      toPosition: draftPositions.get(entryKey)!,
    }]),
    replaced: commonDraft.flatMap((entryKey) =>
      replaced(baseByKey.get(entryKey)!, draftByKey.get(entryKey)!)
        ? [{ entryKey, position: draftPositions.get(entryKey)! }]
        : []),
  }
}
