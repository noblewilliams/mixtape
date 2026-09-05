import { eq, inArray } from 'drizzle-orm'
import type { Db } from '../db/types'
import { trackFeatures, tracks } from '../db/schema'
import type { PlaylistEditToolOperation } from './contracts'
import type { DraftOperationInput, PlaylistEditDraftView } from './store'

export type PlacementEntry = {
  entryKey: string
  trackId: string | null
  artist: string
  album: string | null
  genre: string | null
  releaseYear: number | null
  tempo: number | null
  energy: number | null
}

export type PlacementAnchors = {
  afterEntryKey?: string
  beforeEntryKey?: string
}

type WeightedDistance = { total: number; weight: number }

function normalized(value: string | null): string | null {
  const result = value?.normalize('NFKC').trim().toLocaleLowerCase('en') ?? ''
  return result || null
}

function addNumeric(
  distance: WeightedDistance,
  left: number | null,
  right: number | null,
  range: number,
  weight: number,
): void {
  if (left == null || right == null || !Number.isFinite(left) || !Number.isFinite(right)) return
  distance.total += Math.min(Math.abs(left - right) / range, 1) * weight
  distance.weight += weight
}

function addText(
  distance: WeightedDistance,
  left: string | null,
  right: string | null,
  weight: number,
): void {
  const a = normalized(left)
  const b = normalized(right)
  if (!a || !b) return
  distance.total += (a === b ? 0 : 1) * weight
  distance.weight += weight
}

function pairDistance(left: PlacementEntry, right: PlacementEntry): number | null {
  const distance: WeightedDistance = { total: 0, weight: 0 }
  addNumeric(distance, left.tempo, right.tempo, 90, 0.35)
  addNumeric(distance, left.energy, right.energy, 1, 0.3)
  addNumeric(distance, left.releaseYear, right.releaseYear, 30, 0.15)
  addText(distance, left.genre, right.genre, 0.1)
  addText(distance, left.artist, right.artist, 0.06)
  addText(distance, left.album, right.album, 0.04)
  return distance.weight > 0 ? distance.total / distance.weight : null
}

function gapScore(
  before: PlacementEntry | undefined,
  after: PlacementEntry | undefined,
  candidate: PlacementEntry,
): number | null {
  const values = [
    before ? pairDistance(before, candidate) : null,
    after ? pairDistance(candidate, after) : null,
  ].filter((value): value is number => value != null)
  return values.length ? values.reduce((sum, value) => sum + value, 0) / values.length : null
}

/**
 * Returns occurrence anchors for the lowest-discontinuity insertion gap.
 * Equal scores prefer an interior gap, then the earliest one. With no usable
 * comparison at all, append is the conservative deterministic fallback.
 */
export function chooseBestFitAnchors(
  current: readonly PlacementEntry[],
  candidate: PlacementEntry,
): PlacementAnchors {
  if (!current.length) return {}

  let bestIndex = current.length
  let bestScore = gapScore(current.at(-1), undefined, candidate)
  for (let index = 0; index <= current.length; index++) {
    const score = gapScore(current[index - 1], current[index], candidate)
    if (score == null) continue
    const isInterior = index > 0 && index < current.length
    const bestIsInterior = bestIndex > 0 && bestIndex < current.length
    if (
      bestScore == null
      || score < bestScore - Number.EPSILON
      || (Math.abs(score - bestScore) <= Number.EPSILON && isInterior && !bestIsInterior)
      || (Math.abs(score - bestScore) <= Number.EPSILON && isInterior === bestIsInterior && index < bestIndex)
    ) {
      bestIndex = index
      bestScore = score
    }
  }

  return {
    ...(bestIndex > 0 ? { afterEntryKey: current[bestIndex - 1].entryKey } : {}),
    ...(bestIndex < current.length ? { beforeEntryKey: current[bestIndex].entryKey } : {}),
  }
}

export class PlaylistPlacementError extends Error {
  constructor(readonly category: 'missing_track' | 'duplicate_track' | 'invalid_operation') {
    super(`playlist_placement:${category}`)
    this.name = 'PlaylistPlacementError'
  }
}

function insertionIndex(current: PlacementEntry[], anchors: PlacementAnchors): number {
  const after = anchors.afterEntryKey == null
    ? null : current.findIndex((entry) => entry.entryKey === anchors.afterEntryKey)
  const before = anchors.beforeEntryKey == null
    ? null : current.findIndex((entry) => entry.entryKey === anchors.beforeEntryKey)
  if (after === -1 || before === -1 || (after != null && before != null && after + 1 !== before)) {
    throw new PlaylistPlacementError('invalid_operation')
  }
  if (after != null) return after + 1
  if (before != null) return before
  return current.length
}

export async function resolvePlacementOperations(
  db: Db,
  draft: PlaylistEditDraftView,
  operations: readonly PlaylistEditToolOperation[],
): Promise<DraftOperationInput[]> {
  const trackIds = [...new Set([
    ...draft.entries.flatMap((entry) => entry.trackId ? [entry.trackId] : []),
    ...operations.flatMap((operation) =>
      operation.type === 'add' || operation.type === 'replace' ? [operation.trackId] : []),
  ])]
  const rows = trackIds.length ? await db.select({
    id: tracks.id,
    appleId: tracks.appleId,
    artist: tracks.artist,
    album: tracks.album,
    genre: tracks.genre,
    releaseYear: tracks.releaseYear,
    tempo: trackFeatures.tempo,
    energy: trackFeatures.energy,
  }).from(tracks).leftJoin(trackFeatures, eq(trackFeatures.trackId, tracks.id))
    .where(inArray(tracks.id, trackIds)) : []
  const metadata = new Map(rows.map((row) => [row.id, row]))
  const current: PlacementEntry[] = draft.entries.map((entry) => {
    const row = entry.trackId ? metadata.get(entry.trackId) : undefined
    return {
      entryKey: entry.entryKey,
      trackId: entry.trackId,
      artist: row?.artist ?? entry.artist,
      album: row?.album ?? entry.album,
      genre: row?.genre ?? null,
      releaseYear: row?.releaseYear ?? null,
      tempo: row?.tempo ?? null,
      energy: row?.energy ?? null,
    }
  })
  const resolved: DraftOperationInput[] = []

  for (const operation of operations) {
    if (operation.type === 'add') {
      const row = metadata.get(operation.trackId)
      if (!row?.appleId) throw new PlaylistPlacementError('missing_track')
      if (current.some((entry) => entry.trackId === operation.trackId)) {
        throw new PlaylistPlacementError('duplicate_track')
      }
      const candidate: PlacementEntry = {
        entryKey: crypto.randomUUID(),
        trackId: row.id,
        artist: row.artist,
        album: row.album,
        genre: row.genre,
        releaseYear: row.releaseYear,
        tempo: row.tempo,
        energy: row.energy,
      }
      const explicit = {
        ...(operation.afterEntryKey ? { afterEntryKey: operation.afterEntryKey } : {}),
        ...(operation.beforeEntryKey ? { beforeEntryKey: operation.beforeEntryKey } : {}),
      }
      const anchors = operation.placementIntent === 'best_fit'
        ? chooseBestFitAnchors(current, candidate)
        : explicit
      const index = insertionIndex(current, anchors)
      current.splice(index, 0, candidate)
      resolved.push({ type: 'add', trackId: row.id, entryKey: candidate.entryKey, ...anchors })
      continue
    }

    const index = current.findIndex((entry) => entry.entryKey === operation.entryKey)
    if (index < 0) throw new PlaylistPlacementError('invalid_operation')
    if (operation.type === 'remove') {
      current.splice(index, 1)
      resolved.push(operation)
      continue
    }
    if (operation.type === 'move') {
      if (operation.afterEntryKey === operation.entryKey || operation.beforeEntryKey === operation.entryKey) {
        throw new PlaylistPlacementError('invalid_operation')
      }
      const [entry] = current.splice(index, 1)
      const anchors = {
        ...(operation.afterEntryKey ? { afterEntryKey: operation.afterEntryKey } : {}),
        ...(operation.beforeEntryKey ? { beforeEntryKey: operation.beforeEntryKey } : {}),
      }
      current.splice(insertionIndex(current, anchors), 0, entry)
      resolved.push(operation)
      continue
    }

    const row = metadata.get(operation.trackId)
    if (!row?.appleId) throw new PlaylistPlacementError('missing_track')
    if (current.some((entry, position) => position !== index && entry.trackId === operation.trackId)) {
      throw new PlaylistPlacementError('duplicate_track')
    }
    current[index] = {
      entryKey: operation.entryKey,
      trackId: row.id,
      artist: row.artist,
      album: row.album,
      genre: row.genre,
      releaseYear: row.releaseYear,
      tempo: row.tempo,
      energy: row.energy,
    }
    resolved.push({ type: 'replace', entryKey: operation.entryKey, trackId: row.id })
  }

  return resolved
}
