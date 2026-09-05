import { and, eq, inArray, or, sql } from 'drizzle-orm'
import type { Db } from '../db/types'
import { updateLibraryMembership } from '../library/membership'
import {
  listeningDays,
  listeningImportArtists,
  listeningImportDays,
  listeningImportLibrary,
  listeningImportRuns,
  listeningImportTracks,
  userArtistSeeds,
  userMusicProfiles,
  userMusicSources,
  userPlaylists,
  playlistOrigins,
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

export type ListeningImportSummary = {
  tracks: number
  days: number
  libraryTracks: number
  artists: number
  unresolvedRows: number
  unresolvedPlays: number
  // Bounds of this source's ledger after the run; null for a package with no days.
  ledgerFrom: string | null
  ledgerTo: string | null
  // Tracks leaving the combined library on Spotify account re-import.
  // The compatibility skip field is false for newly completed runs.
  likedRemoved: number
  likedRemovalSkipped: boolean
}

export type DeleteSourceResult = {
  deletedDays: number
  deletedTracks: number
  unlibraried: number
}

export type ListeningImportStore = {
  begin(
    userId: string,
    input: BeginListeningImport,
  ): Promise<{ importId: string; expiresAt: number }>
  putTracks(userId: string, importId: string, tracks: ListeningTrackSnapshot[]): Promise<void>
  putDays(userId: string, importId: string, days: ListeningDaySnapshot[]): Promise<void>
  putLibrary(userId: string, importId: string, tracks: ListeningLibrarySnapshot[]): Promise<void>
  putArtists(userId: string, importId: string, artists: ListeningArtistSnapshot[]): Promise<void>
  complete(userId: string, importId: string): Promise<ListeningImportSummary>
  deleteSource(userId: string, source: ListeningImportSource): Promise<DeleteSourceResult>
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

// The tracks column a source's platform ids resolve through. Constants, never
// input, so they are safe to splice into SQL.
const PLATFORM_COLUMNS: Record<ListeningImportSource, ReturnType<typeof sql.raw>> = {
  spotify_export: sql.raw('spotify_id'),
  apple_export: sql.raw('apple_id'),
}

const CHUNK_KINDS = ['tracks', 'days', 'library', 'artists'] as const satisfies readonly ChunkKind[]

const CHUNK_TABLES: Record<ChunkKind, ReturnType<typeof sql.raw>> = {
  tracks: sql.raw('listening_import_tracks'),
  days: sql.raw('listening_import_days'),
  library: sql.raw('listening_import_library'),
  artists: sql.raw('listening_import_artists'),
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

function normalizeRows(value: unknown): Record<string, unknown>[] {
  if (Array.isArray(value)) return value as Record<string, unknown>[]
  if (value && typeof value === 'object' && 'rows' in value) {
    const rows = (value as { rows?: unknown }).rows
    return Array.isArray(rows) ? rows as Record<string, unknown>[] : []
  }
  return []
}

function completedSummary(run: Run): ListeningImportSummary {
  if (
    run.resultTracks == null
    || run.resultDays == null
    || run.resultLibraryTracks == null
    || run.resultArtists == null
    || run.resultLikedRemoved == null
    || run.resultLikedRemovalSkipped == null
  ) throw new ListeningImportError('internal')
  return {
    tracks: run.resultTracks,
    days: run.resultDays,
    libraryTracks: run.resultLibraryTracks,
    artists: run.resultArtists,
    unresolvedRows: run.unresolvedRows,
    unresolvedPlays: run.unresolvedPlays,
    ledgerFrom: run.ledgerFrom,
    ledgerTo: run.ledgerTo,
    likedRemoved: run.resultLikedRemoved,
    likedRemovalSkipped: run.resultLikedRemovalSkipped,
  }
}

// Per-user ledger aggregate, optionally restricted to a set of tracks. Recent
// plays anchor on the database clock so the window drifts without a recompute.
const ledgerAggregate = (userId: string, trackFilter: ReturnType<typeof sql> | null) => sql`
  SELECT
    ld.track_id,
    sum(ld.plays)::int AS plays,
    coalesce(sum(ld.plays) FILTER (WHERE ld.day >= CURRENT_DATE - 730), 0)::int AS recent,
    sum(ld.skips)::int AS skips,
    max(ld.day) AS last_day
  FROM listening_days ld
  WHERE ld.user_id = ${userId}${trackFilter ?? sql``}
  GROUP BY ld.track_id
`

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

    async complete(userId, importId) {
      return db.transaction(async (rawTx) => {
        const tx = rawTx as unknown as Db
        const now = currentTime()
        // Lock order matches begin() and the library sibling: profile, then run.
        const [profile] = await tx.select().from(userMusicProfiles)
          .where(eq(userMusicProfiles.userId, userId))
          .for('update')
        if (!profile) throw new ListeningImportError('not_found')
        const [run] = await tx.select().from(listeningImportRuns)
          .where(and(eq(listeningImportRuns.id, importId), eq(listeningImportRuns.userId, userId)))
          .for('update')
        if (!run) throw new ListeningImportError('not_found')
        if (run.status === 'completed') return completedSummary(run)
        if (run.status !== 'open' || run.expiresAt.getTime() <= now.getTime()) {
          throw new ListeningImportError('invalid_state')
        }
        for (const kind of CHUNK_KINDS) {
          if (run[COUNTERS[kind].received] !== run[COUNTERS[kind].expected]) {
            throw new ListeningImportError('count_mismatch')
          }
        }

        // Staged rows must match the expected counts with ordinals exactly
        // 0..n-1, and every day or library row must name a staged track.
        const validation = normalizeRows(await tx.execute(sql`
          SELECT
            ${sql.join(CHUNK_KINDS.map((kind) => sql`
              (SELECT count(*)::int FROM ${CHUNK_TABLES[kind]} WHERE import_id = ${importId})
                AS ${sql.raw(`${kind}_count`)},
              (SELECT count(*) = 0 OR (min(ordinal) = 0 AND max(ordinal) = count(*) - 1)
                FROM ${CHUNK_TABLES[kind]} WHERE import_id = ${importId})
                AS ${sql.raw(`${kind}_valid`)}`), sql`,`)},
            EXISTS (
              SELECT 1 FROM listening_import_days d
              WHERE d.import_id = ${importId} AND NOT EXISTS (
                SELECT 1 FROM listening_import_tracks t
                WHERE t.import_id = d.import_id AND t.platform_id = d.platform_id
              )
            ) AS orphan_days,
            EXISTS (
              SELECT 1 FROM listening_import_library l
              WHERE l.import_id = ${importId} AND NOT EXISTS (
                SELECT 1 FROM listening_import_tracks t
                WHERE t.import_id = l.import_id AND t.platform_id = l.platform_id
              )
            ) AS orphan_library
        `))[0]
        for (const kind of CHUNK_KINDS) {
          if (
            Number(validation?.[`${kind}_count`]) !== run[COUNTERS[kind].expected]
            || validation?.[`${kind}_valid`] !== true
          ) throw new ListeningImportError('count_mismatch')
        }
        if (validation?.orphan_days === true || validation?.orphan_library === true) {
          throw new ListeningImportError('conflict')
        }

        const idColumn = PLATFORM_COLUMNS[run.source]
        const carriesDays = CHUNKS_BY_PACKAGE[run.package].includes('days')
        const accountPackage = run.package === 'spotify_account'
        const runTracks = sql`
          SELECT t.id AS track_id, it.platform_id
          FROM listening_import_tracks it
          JOIN tracks t ON t.${idColumn} = it.platform_id
          WHERE it.import_id = ${importId}
        `

        // 1. Canonical tracks. Spotify's export names the album artist, so its
        // title and artist win unless enrichment already corrected the artist;
        // an Apple export only fills gaps the live sync left.
        if (run.source === 'spotify_export') {
          await tx.execute(sql`
            INSERT INTO tracks (spotify_id, title, artist, album, duration_ms, artist_source, created_at)
            SELECT platform_id, title, artist, album, duration_ms, 'export', ${now}
            FROM listening_import_tracks
            WHERE import_id = ${importId}
            ORDER BY platform_id
            ON CONFLICT (spotify_id) WHERE spotify_id IS NOT NULL DO UPDATE SET
              title = excluded.title,
              artist = CASE
                WHEN tracks.artist_source IN ('reccobeats', 'apple_catalog') THEN tracks.artist
                ELSE excluded.artist
              END,
              artist_source = CASE
                WHEN tracks.artist_source IN ('reccobeats', 'apple_catalog') THEN tracks.artist_source
                ELSE 'export'
              END,
              album = coalesce(tracks.album, excluded.album),
              duration_ms = coalesce(tracks.duration_ms, excluded.duration_ms)
          `)
        } else {
          await tx.execute(sql`
            INSERT INTO tracks (apple_id, title, artist, album, duration_ms, artist_source, created_at)
            SELECT platform_id, title, artist, album, duration_ms, 'export', ${now}
            FROM listening_import_tracks
            WHERE import_id = ${importId}
            ORDER BY platform_id
            ON CONFLICT (apple_id) WHERE apple_id IS NOT NULL DO UPDATE SET
              album = coalesce(tracks.album, excluded.album),
              duration_ms = coalesce(tracks.duration_ms, excluded.duration_ms)
          `)
        }

        // 2. Ledger: replace day values, then drop this source's days for the
        // run's tracks that the run no longer covers.
        if (carriesDays) {
          await tx.execute(sql`
            INSERT INTO listening_days (
              user_id, source, track_id, day, plays, skips, completes, ms_played, hours_mask
            )
            SELECT
              ${userId}, ${run.source}, t.id, d.day, d.plays, d.skips, d.completes, d.ms_played, d.hours_mask
            FROM listening_import_days d
            JOIN tracks t ON t.${idColumn} = d.platform_id
            WHERE d.import_id = ${importId}
            ORDER BY d.platform_id, d.day
            ON CONFLICT (user_id, source, track_id, day) DO UPDATE SET
              plays = excluded.plays,
              skips = excluded.skips,
              completes = excluded.completes,
              ms_played = excluded.ms_played,
              hours_mask = excluded.hours_mask
          `)
          await tx.execute(sql`
            DELETE FROM listening_days ld
            USING (${runTracks}) rt
            WHERE ld.user_id = ${userId}
              AND ld.source = ${run.source}
              AND ld.track_id = rt.track_id
              AND NOT EXISTS (
                SELECT 1 FROM listening_import_days d
                WHERE d.import_id = ${importId}
                  AND d.platform_id = rt.platform_id
                  AND d.day = ld.day
              )
          `)
        }

        // 3. Derived user rows for every track in the run, pooling all of the
        // user's ledger sources; a native observed count is never lowered.
        await tx.execute(sql`
          WITH run_tracks AS (${runTracks}),
          ledger AS (${ledgerAggregate(userId, sql` AND ld.track_id IN (SELECT track_id FROM run_tracks)`)}),
          library AS (
            SELECT
              rt.track_id, l.play_count, l.skip_count, l.last_played_at, l.date_added, l.like_rating
            FROM listening_import_library l
            JOIN run_tracks rt ON rt.platform_id = l.platform_id
            WHERE l.import_id = ${importId}
          )
          INSERT INTO user_tracks (
            user_id, track_id, play_count, play_count_observed, play_count_recent, last_played_at,
            skip_count, like_rating, date_added, in_library, seeded, updated_at
          )
          SELECT
            ${userId},
            rt.track_id,
            greatest(coalesce(lg.plays, 0), coalesce(lb.play_count, 0)),
            lg.track_id IS NOT NULL OR lb.play_count IS NOT NULL,
            coalesce(lg.recent, 0),
            greatest(lg.last_day::timestamp AT TIME ZONE 'UTC', lb.last_played_at),
            coalesce(lb.skip_count, lg.skips),
            lb.like_rating,
            lb.date_added,
            false,
            false,
            ${now}
          FROM run_tracks rt
          LEFT JOIN ledger lg ON lg.track_id = rt.track_id
          LEFT JOIN library lb ON lb.track_id = rt.track_id
          ORDER BY rt.platform_id
          ON CONFLICT (user_id, track_id) DO UPDATE SET
            play_count = greatest(
              CASE WHEN user_tracks.play_count_observed THEN user_tracks.play_count ELSE 0 END,
              excluded.play_count
            ),
            play_count_observed = user_tracks.play_count_observed OR excluded.play_count_observed,
            play_count_recent = excluded.play_count_recent,
            last_played_at = greatest(user_tracks.last_played_at, excluded.last_played_at),
            skip_count = coalesce(excluded.skip_count, user_tracks.skip_count),
            like_rating = coalesce(excluded.like_rating, user_tracks.like_rating),
            date_added = coalesce(user_tracks.date_added, excluded.date_added),
            updated_at = excluded.updated_at
        `)

        // 4. Account snapshots replace Spotify membership only; Apple media
        // library rows remain additive. History is never membership evidence.
        let likedRemoved = 0
        const likedRemovalSkipped = false
        if (CHUNKS_BY_PACKAGE[run.package].includes('library')) {
          const removed = await updateLibraryMembership(tx, userId, run.source, {
            kind: accountPackage ? 'replace' : 'add',
            trackIds: sql`
              SELECT rt.track_id
              FROM listening_import_library l
              JOIN (${runTracks}) rt ON rt.platform_id = l.platform_id
              WHERE l.import_id = ${importId}
            `,
          }, now)
          if (accountPackage) likedRemoved = removed
        }
        if (accountPackage) {
          // 5. Followed artists seed the pool; a seed keeps the id it has.
          await tx.execute(sql`
            INSERT INTO user_artist_seeds (user_id, name, spotify_id, source, created_at)
            SELECT ${userId}, name, spotify_id, 'spotify_export', ${now}
            FROM listening_import_artists
            WHERE import_id = ${importId}
            ORDER BY name
            ON CONFLICT (user_id, name) DO UPDATE SET
              spotify_id = coalesce(user_artist_seeds.spotify_id, excluded.spotify_id)
          `)
        }

        // 6. Enrichment order: pool candidates first, by recent plays.
        await tx.execute(sql`
          UPDATE tracks tr
          SET enrich_priority = greatest(
            tr.enrich_priority,
            CASE
              WHEN ut.in_library OR ut.seeded OR ut.play_count_recent >= 3
                THEN 1 + ut.play_count_recent
              ELSE 0
            END
          )
          FROM (${runTracks}) rt
          JOIN user_tracks ut ON ut.user_id = ${userId} AND ut.track_id = rt.track_id
          WHERE tr.id = rt.track_id
        `)

        // 7. Source bookkeeping; ledger bounds only move for packages with days.
        let ledgerFrom: string | null = null
        let ledgerTo: string | null = null
        if (carriesDays) {
          const bounds = normalizeRows(await tx.execute(sql`
            SELECT min(day)::text AS ledger_from, max(day)::text AS ledger_to
            FROM listening_days
            WHERE user_id = ${userId} AND source = ${run.source}
          `))[0]
          ledgerFrom = bounds?.ledger_from == null ? null : String(bounds.ledger_from)
          ledgerTo = bounds?.ledger_to == null ? null : String(bounds.ledger_to)
        }
        await tx.insert(userMusicSources)
          .values({
            userId,
            source: run.source,
            connectedAt: now,
            lastImportedAt: now,
            ledgerFrom,
            ledgerTo,
            updatedAt: now,
          })
          .onConflictDoUpdate({
            target: [userMusicSources.userId, userMusicSources.source],
            set: {
              lastImportedAt: now,
              updatedAt: now,
              ...(carriesDays ? { ledgerFrom, ledgerTo } : {}),
            },
          })

        // 8. Profile: the device's zone always, its country when it sent one.
        await tx.update(userMusicProfiles)
          .set({ timeZone: run.timeZone, country: run.country ?? profile.country, updatedAt: now })
          .where(eq(userMusicProfiles.userId, userId))

        const summary: ListeningImportSummary = {
          tracks: run.expectedTracks,
          days: run.expectedDays,
          libraryTracks: run.expectedLibraryTracks,
          artists: run.expectedArtists,
          unresolvedRows: run.unresolvedRows,
          unresolvedPlays: run.unresolvedPlays,
          ledgerFrom,
          ledgerTo,
          likedRemoved,
          likedRemovalSkipped,
        }
        await deps.beforeCommit?.()
        await tx.update(listeningImportRuns).set({
          status: 'completed',
          resultTracks: summary.tracks,
          resultDays: summary.days,
          resultLibraryTracks: summary.libraryTracks,
          resultArtists: summary.artists,
          ledgerFrom,
          ledgerTo,
          resultLikedRemoved: likedRemoved,
          resultLikedRemovalSkipped: likedRemovalSkipped,
          completedAt: now,
        }).where(eq(listeningImportRuns.id, importId))
        return summary
      })
    },

    // Delete-import is the reset for everything an import derived: the
    // source's ledger and seeds go, its tracks leave the library unless a live
    // Apple library owns membership, rows nothing else justifies go, and
    // survivors are recomputed from what remains. play_count stays as is.
    async deleteSource(userId, source) {
      return db.transaction(async (rawTx) => {
        const tx = rawTx as unknown as Db
        const now = currentTime()
        // Same profile lock as complete(), so the two never interleave.
        await tx.insert(userMusicProfiles).values({ userId }).onConflictDoNothing()
        await tx.select({ userId: userMusicProfiles.userId }).from(userMusicProfiles)
          .where(eq(userMusicProfiles.userId, userId))
          .for('update')
        await tx.update(listeningImportRuns)
          .set({ status: 'expired' })
          .where(and(
            eq(listeningImportRuns.userId, userId),
            eq(listeningImportRuns.source, source),
            eq(listeningImportRuns.status, 'open'),
          ))
        const deletedDays = (await tx.delete(listeningDays)
          .where(and(eq(listeningDays.userId, userId), eq(listeningDays.source, source)))
          .returning({ trackId: listeningDays.trackId })).length
        await tx.delete(userArtistSeeds)
          .where(and(eq(userArtistSeeds.userId, userId), sql`${userArtistSeeds.source} = ${source}`))
        await tx.delete(userMusicSources)
          .where(and(eq(userMusicSources.userId, userId), eq(userMusicSources.source, source)))

        if (source === 'spotify_export') {
          await tx.delete(playlistOrigins).where(and(
            eq(playlistOrigins.userId, userId), eq(playlistOrigins.source, 'spotify_export'),
          ))
          await tx.update(userPlaylists)
            .set({ inLibrary: false, updatedAt: now })
            .where(and(
              eq(userPlaylists.userId, userId),
              eq(userPlaylists.source, 'spotify_export'),
              eq(userPlaylists.inLibrary, true),
            ))
        }
        const unlibraried = await updateLibraryMembership(tx, userId, source, { kind: 'remove' }, now)

        const deletedTracks = normalizeRows(await tx.execute(sql`
          DELETE FROM user_tracks ut
          WHERE ut.user_id = ${userId}
            AND NOT ut.in_library
            AND NOT ut.seeded
            AND NOT EXISTS (
              SELECT 1 FROM listening_days ld
              WHERE ld.user_id = ut.user_id AND ld.track_id = ut.track_id
            )
          RETURNING ut.track_id
        `)).length
        // Survivors: recent plays from the remaining ledger; skips only where
        // ledger rows remain to say so.
        await tx.execute(sql`
          WITH ledger AS (${ledgerAggregate(userId, null)})
          UPDATE user_tracks ut
          SET
            play_count_recent = coalesce(lg.recent, 0),
            skip_count = CASE WHEN lg.track_id IS NULL THEN ut.skip_count ELSE lg.skips END,
            updated_at = ${now}
          FROM user_tracks cur
          LEFT JOIN ledger lg ON lg.track_id = cur.track_id
          WHERE cur.user_id = ${userId}
            AND ut.user_id = cur.user_id
            AND ut.track_id = cur.track_id
            AND (
              ut.play_count_recent <> coalesce(lg.recent, 0)
              OR (lg.track_id IS NOT NULL AND ut.skip_count IS DISTINCT FROM lg.skips)
            )
        `)
        return { deletedDays, deletedTracks, unlibraried }
      })
    },

    putTracks: (userId, importId, tracks) => stage(userId, importId, tracks, trackSpec),
    putDays: (userId, importId, days) => stage(userId, importId, days, daySpec),
    putLibrary: (userId, importId, tracks) => stage(userId, importId, tracks, librarySpec),
    putArtists: (userId, importId, artists) => stage(userId, importId, artists, artistSpec),
  }
}
