import { and, eq, inArray, or, sql } from 'drizzle-orm'
import type { Db } from '../db/types'
import {
  listeningImportArtists,
  listeningImportDays,
  listeningImportLibrary,
  listeningImportRuns,
  listeningImportTracks,
  userMusicProfiles,
  userMusicSources,
} from '../db/schema'
import { isAppleSongId } from '../musickit/apple-id'
import {
  isSpotifyId,
  type BeginListeningImport,
  type ListeningArtistSnapshot,
  type ListeningDaySnapshot,
  type ListeningImportPackage,
  type ListeningImportSource,
  type ListeningLibrarySnapshot,
  type ListeningTrackSnapshot,
} from './contracts'

export type ListeningImportErrorCategory =
  | 'not_found'
  | 'conflict'
  | 'invalid_state'
  | 'count_mismatch'
  | 'invalid_id'
  | 'internal'

export class ListeningImportError extends Error {
  constructor(readonly category: ListeningImportErrorCategory) {
    super(`listening-import:${category}`)
    this.name = 'ListeningImportError'
  }
}

// Staging only; complete and deleteSource land with the publish step.
export type ListeningImportStore = {
  begin(
    userId: string,
    input: BeginListeningImport,
  ): Promise<{ importId: string; expiresAt: number }>
  putTracks(userId: string, importId: string, tracks: ListeningTrackSnapshot[]): Promise<void>
  putDays(userId: string, importId: string, days: ListeningDaySnapshot[]): Promise<void>
  putLibrary(userId: string, importId: string, tracks: ListeningLibrarySnapshot[]): Promise<void>
  putArtists(userId: string, importId: string, artists: ListeningArtistSnapshot[]): Promise<void>
}

type StoreDeps = {
  now?: () => Date
  ttlMs?: number
  beforeCommit?: () => void | Promise<void>
}

export const LISTENING_IMPORT_DEFAULT_TTL_MS = 2 * 60 * 60 * 1_000

type Run = typeof listeningImportRuns.$inferSelect
type ChunkKind = 'tracks' | 'days' | 'library' | 'artists'

// Which chunk types each package carries (spec → Packages). Tracks always.
const CHUNKS_BY_PACKAGE: Record<ListeningImportPackage, readonly ChunkKind[]> = {
  spotify_extended: ['tracks', 'days'],
  spotify_account: ['tracks', 'library', 'artists'],
  apple_media: ['tracks', 'days', 'library'],
}

const PLATFORM_ID_VALIDATORS: Record<ListeningImportSource, (value: string) => boolean> = {
  spotify_export: isSpotifyId,
  apple_export: isAppleSongId,
}

const COUNTERS = {
  tracks: { received: 'receivedTracks', expected: 'expectedTracks' },
  days: { received: 'receivedDays', expected: 'expectedDays' },
  library: { received: 'receivedLibraryTracks', expected: 'expectedLibraryTracks' },
  artists: { received: 'receivedArtists', expected: 'expectedArtists' },
} as const satisfies Record<ChunkKind, { received: keyof Run; expected: keyof Run }>

function receivedPatch(kind: ChunkKind, value: number) {
  switch (kind) {
    case 'tracks': return { receivedTracks: value }
    case 'days': return { receivedDays: value }
    case 'library': return { receivedLibraryTracks: value }
    case 'artists': return { receivedArtists: value }
  }
}

const toDate = (value: number | null) => value == null ? null : new Date(value)
const sameInstant = (value: Date | null, millis: number | null) =>
  (value?.getTime() ?? null) === millis
const compareKeys = (a: string, b: string) => a < b ? -1 : a > b ? 1 : 0
// Platform ids are validated against the source (base62 or Apple's unreserved
// alphabet) before any key is built, so '|' can never occur inside one.
const dayKey = (platformId: string, day: string) => `${platformId}|${day}`

type Ordered = { ordinal: number }

// One chunk type: how to key a row, tell an exact re-send from a changed one,
// find what is already staged, and insert what is missing.
type ChunkSpec<TValue extends Ordered, TRow extends Ordered> = {
  kind: ChunkKind
  key(value: TValue): string
  rowKey(row: TRow): string
  same(row: TRow, value: TValue): boolean
  platformId?(value: TValue): string
  existing(tx: Db, importId: string, values: TValue[]): Promise<TRow[]>
  insert(tx: Db, importId: string, values: TValue[]): Promise<void>
}

const trackSpec: ChunkSpec<ListeningTrackSnapshot, typeof listeningImportTracks.$inferSelect> = {
  kind: 'tracks',
  key: (value) => value.platformId,
  rowKey: (row) => row.platformId,
  platformId: (value) => value.platformId,
  same: (row, value) => row.ordinal === value.ordinal
    && row.platformId === value.platformId
    && row.title === value.title
    && row.artist === value.artist
    && row.album === value.album
    && row.durationMs === value.durationMs,
  existing: (tx, importId, values) => tx.select().from(listeningImportTracks).where(and(
    eq(listeningImportTracks.importId, importId),
    or(
      inArray(listeningImportTracks.ordinal, values.map((value) => value.ordinal)),
      inArray(listeningImportTracks.platformId, values.map((value) => value.platformId)),
    ),
  )),
  insert: async (tx, importId, values) => {
    await tx.insert(listeningImportTracks).values(values.map((value) => ({ importId, ...value })))
  },
}

const daySpec: ChunkSpec<ListeningDaySnapshot, typeof listeningImportDays.$inferSelect> = {
  kind: 'days',
  key: (value) => dayKey(value.platformId, value.day),
  rowKey: (row) => dayKey(row.platformId, row.day),
  platformId: (value) => value.platformId,
  same: (row, value) => row.ordinal === value.ordinal
    && row.platformId === value.platformId
    && row.day === value.day
    && row.plays === value.plays
    && row.skips === value.skips
    && row.completes === value.completes
    && row.msPlayed === value.msPlayed
    && row.hoursMask === value.hoursMask,
  // Match on the (platform id, day) pair, not the platform id alone: a track
  // can have hundreds of staged days and a chunk carries up to 2 000 rows.
  existing: (tx, importId, values) => tx.select().from(listeningImportDays).where(and(
    eq(listeningImportDays.importId, importId),
    or(
      inArray(listeningImportDays.ordinal, values.map((value) => value.ordinal)),
      sql`(${listeningImportDays.platformId}, ${listeningImportDays.day}) IN (${
        sql.join(values.map((value) => sql`(${value.platformId}, ${value.day}::date)`), sql`, `)
      })`,
    ),
  )),
  insert: async (tx, importId, values) => {
    await tx.insert(listeningImportDays).values(values.map((value) => ({ importId, ...value })))
  },
}

const librarySpec: ChunkSpec<ListeningLibrarySnapshot, typeof listeningImportLibrary.$inferSelect> = {
  kind: 'library',
  key: (value) => value.platformId,
  rowKey: (row) => row.platformId,
  platformId: (value) => value.platformId,
  same: (row, value) => row.ordinal === value.ordinal
    && row.platformId === value.platformId
    && row.playCount === value.playCount
    && row.skipCount === value.skipCount
    && sameInstant(row.lastPlayedAt, value.lastPlayedAt)
    && sameInstant(row.dateAdded, value.dateAdded)
    && row.likeRating === value.likeRating,
  existing: (tx, importId, values) => tx.select().from(listeningImportLibrary).where(and(
    eq(listeningImportLibrary.importId, importId),
    or(
      inArray(listeningImportLibrary.ordinal, values.map((value) => value.ordinal)),
      inArray(listeningImportLibrary.platformId, values.map((value) => value.platformId)),
    ),
  )),
  insert: async (tx, importId, values) => {
    await tx.insert(listeningImportLibrary).values(values.map((value) => ({
      importId,
      ...value,
      lastPlayedAt: toDate(value.lastPlayedAt),
      dateAdded: toDate(value.dateAdded),
    })))
  },
}

const artistSpec: ChunkSpec<ListeningArtistSnapshot, typeof listeningImportArtists.$inferSelect> = {
  kind: 'artists',
  key: (value) => value.name,
  rowKey: (row) => row.name,
  same: (row, value) => row.ordinal === value.ordinal
    && row.name === value.name
    && row.spotifyId === value.spotifyId,
  existing: (tx, importId, values) => tx.select().from(listeningImportArtists).where(and(
    eq(listeningImportArtists.importId, importId),
    or(
      inArray(listeningImportArtists.ordinal, values.map((value) => value.ordinal)),
      inArray(listeningImportArtists.name, values.map((value) => value.name)),
    ),
  )),
  insert: async (tx, importId, values) => {
    await tx.insert(listeningImportArtists).values(values.map((value) => ({ importId, ...value })))
  },
}

function assertUnique<TValue extends Ordered>(values: TValue[], key: (value: TValue) => string) {
  const ordinals = new Set<number>()
  const keys = new Set<string>()
  for (const value of values) {
    const valueKey = key(value)
    if (ordinals.has(value.ordinal) || keys.has(valueKey)) {
      throw new ListeningImportError('conflict')
    }
    ordinals.add(value.ordinal)
    keys.add(valueKey)
  }
}

export function createListeningImportStore(db: Db, deps: StoreDeps = {}): ListeningImportStore {
  const currentTime = () => deps.now?.() ?? new Date()
  const ttlMs = deps.ttlMs ?? LISTENING_IMPORT_DEFAULT_TTL_MS

  async function lockedOpenRun(tx: Db, userId: string, importId: string, now: Date): Promise<Run> {
    const [run] = await tx.select().from(listeningImportRuns)
      .where(and(eq(listeningImportRuns.id, importId), eq(listeningImportRuns.userId, userId)))
      .for('update')
    if (!run) throw new ListeningImportError('not_found')
    if (run.status !== 'open' || run.expiresAt.getTime() <= now.getTime()) {
      throw new ListeningImportError('invalid_state')
    }
    return run
  }

  // Idempotent chunk staging, same rule as library sync: a row already staged
  // must match exactly by ordinal and natural key, missing rows are inserted,
  // and the chunk may never push the received count past the expected one.
  async function stage<TValue extends Ordered, TRow extends Ordered>(
    userId: string,
    importId: string,
    values: TValue[],
    spec: ChunkSpec<TValue, TRow>,
  ) {
    await db.transaction(async (rawTx) => {
      const tx = rawTx as unknown as Db
      const run = await lockedOpenRun(tx, userId, importId, currentTime())
      if (!CHUNKS_BY_PACKAGE[run.package].includes(spec.kind)) {
        throw new ListeningImportError('invalid_state')
      }
      if (spec.platformId) {
        const isValidId = PLATFORM_ID_VALIDATORS[run.source]
        for (const value of values) {
          if (!isValidId(spec.platformId(value))) throw new ListeningImportError('invalid_id')
        }
      }
      assertUnique(values, spec.key)
      if (values.length === 0) return

      const existing = await spec.existing(tx, importId, values)
      const byOrdinal = new Map(existing.map((row) => [row.ordinal, row]))
      const byKey = new Map(existing.map((row) => [spec.rowKey(row), row]))
      const missing: TValue[] = []
      for (const value of values) {
        const ordinalRow = byOrdinal.get(value.ordinal)
        const keyRow = byKey.get(spec.key(value))
        if (ordinalRow || keyRow) {
          if (!ordinalRow || ordinalRow !== keyRow || !spec.same(ordinalRow, value)) {
            throw new ListeningImportError('conflict')
          }
        } else {
          missing.push(value)
        }
      }

      const counter = COUNTERS[spec.kind]
      const received = run[counter.received]
      if (received + missing.length > run[counter.expected]) {
        throw new ListeningImportError('count_mismatch')
      }
      if (missing.length > 0) {
        missing.sort((a, b) => compareKeys(spec.key(a), spec.key(b)))
        await spec.insert(tx, importId, missing)
        await tx.update(listeningImportRuns)
          .set(receivedPatch(spec.kind, received + missing.length))
          .where(eq(listeningImportRuns.id, importId))
      }
    })
  }

  return {
    async begin(userId, input) {
      return db.transaction(async (rawTx) => {
        const tx = rawTx as unknown as Db
        const now = currentTime()
        const expiresAt = new Date(now.getTime() + ttlMs)
        // An export-only listener has no storefront; an existing profile keeps
        // whatever storefront the library sync set.
        await tx.insert(userMusicProfiles)
          .values({ userId, createdAt: now, updatedAt: now })
          .onConflictDoNothing()
        const [profile] = await tx.select().from(userMusicProfiles)
          .where(eq(userMusicProfiles.userId, userId))
          .for('update')
        if (!profile) throw new ListeningImportError('not_found')
        await tx.update(userMusicProfiles)
          .set({
            timeZone: input.timeZone,
            ...(input.country == null ? {} : { country: input.country }),
            updatedAt: now,
          })
          .where(eq(userMusicProfiles.userId, userId))
        await tx.update(listeningImportRuns)
          .set({ status: 'expired' })
          .where(and(
            eq(listeningImportRuns.userId, userId),
            eq(listeningImportRuns.source, input.source),
            eq(listeningImportRuns.status, 'open'),
          ))
        const [run] = await tx.insert(listeningImportRuns).values({
          userId,
          source: input.source,
          package: input.package,
          status: 'open',
          timeZone: input.timeZone,
          country: input.country,
          expectedTracks: input.expectedTracks,
          expectedDays: input.expectedDays,
          expectedLibraryTracks: input.expectedLibraryTracks,
          expectedArtists: input.expectedArtists,
          unresolvedRows: input.unresolvedRows,
          unresolvedPlays: input.unresolvedPlays,
          startedAt: now,
          expiresAt,
        }).returning({ id: listeningImportRuns.id })
        if (!run) throw new ListeningImportError('internal')
        await tx.insert(userMusicSources)
          .values({ userId, source: input.source, connectedAt: now, updatedAt: now })
          .onConflictDoUpdate({
            target: [userMusicSources.userId, userMusicSources.source],
            set: { updatedAt: now },
          })
        return { importId: run.id, expiresAt: expiresAt.getTime() }
      })
    },

    putTracks: (userId, importId, tracks) => stage(userId, importId, tracks, trackSpec),
    putDays: (userId, importId, days) => stage(userId, importId, days, daySpec),
    putLibrary: (userId, importId, tracks) => stage(userId, importId, tracks, librarySpec),
    putArtists: (userId, importId, artists) => stage(userId, importId, artists, artistSpec),
  }
}
