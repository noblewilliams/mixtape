import { and, asc, desc, eq, isNull, or, sql } from 'drizzle-orm'
import type { Db } from '../db/types'
import { albumPicks, albums, djSessions, listenLater, sessionEvents } from '../db/schema'
import type { AlbumType } from './contracts'
import type { VerifiedAlbum } from './verify'

// Album pick versions (spec 2026-10-20 → Data). The pick version IS
// dj_sessions.queue_version, so mix history's fencing vocabulary applies:
// a stale expectedVersion is a conflict, exactly as for a queue.

export const MAX_PICK_ROWS = 3

export class AlbumStoreError extends Error {
  constructor(readonly kind: 'not_found' | 'wrong_kind' | 'conflict') {
    super(`album_store:${kind}`)
    this.name = 'AlbumStoreError'
  }
}

export type AlbumRow = typeof albums.$inferSelect

export type AlbumView = {
  id: string
  upc: string | null
  appleId: string | null
  title: string
  artist: string
  releaseYear: number | null
  type: AlbumType
  trackCount: number | null
  durationMs: number | null
  artwork: { url: string; width: number | null; height: number | null; bgColor: string | null } | null
  newToThem: boolean
  reason: string
  savedForLater: boolean
  version: number
}

export type AlbumPickState = {
  version: number
  pick: AlbumView | null
  runnersUp: AlbumView[]
  passed: AlbumView[]
}

export type PickInput = { albumId: string; reason: string; newToThem: boolean }

/** Upserts verified albums on apple_id, refreshing fields Apple now reports. */
export async function upsertAlbums(db: Db, verified: VerifiedAlbum[]): Promise<Map<string, AlbumRow>> {
  if (verified.length === 0) return new Map()
  const now = new Date()
  const rows = await db
    .insert(albums)
    .values(verified.map((v) => ({
      appleId: v.appleId,
      upc: v.upc,
      appleCatalogStorefront: v.storefront,
      title: v.title,
      artist: v.artist,
      releaseYear: v.releaseYear,
      trackCount: v.trackCount,
      durationMs: v.durationMs,
      type: v.type,
      artworkUrlTemplate: v.artwork?.url ?? null,
      artworkWidth: v.artwork?.width ?? null,
      artworkHeight: v.artwork?.height ?? null,
      artworkBgColor: v.artwork?.bgColor ?? null,
      artworkFetchedAt: v.artwork ? now : null,
    })))
    .onConflictDoUpdate({
      target: albums.appleId,
      targetWhere: sql`${albums.appleId} IS NOT NULL`,
      set: {
        appleCatalogStorefront: sql`excluded.apple_catalog_storefront`,
        upc: sql`coalesce(excluded.upc, ${albums.upc})`,
        title: sql`excluded.title`,
        artist: sql`excluded.artist`,
        type: sql`excluded.type`,
        releaseYear: sql`coalesce(excluded.release_year, ${albums.releaseYear})`,
        trackCount: sql`coalesce(excluded.track_count, ${albums.trackCount})`,
        durationMs: sql`coalesce(excluded.duration_ms, ${albums.durationMs})`,
        artworkUrlTemplate: sql`coalesce(excluded.artwork_url_template, ${albums.artworkUrlTemplate})`,
        artworkWidth: sql`coalesce(excluded.artwork_width, ${albums.artworkWidth})`,
        artworkHeight: sql`coalesce(excluded.artwork_height, ${albums.artworkHeight})`,
        artworkBgColor: sql`coalesce(excluded.artwork_bg_color, ${albums.artworkBgColor})`,
        artworkFetchedAt: sql`coalesce(excluded.artwork_fetched_at, ${albums.artworkFetchedAt})`,
      },
    })
    .returning()
  return new Map(rows.map((r) => [r.appleId!, r]))
}

// Locks the owned album session row for the rest of the transaction.
async function lockAlbumSession(tx: Db, sessionId: string, userId: string, expectedVersion?: number): Promise<number> {
  const [session] = await tx
    .select({ kind: djSessions.kind, queueVersion: djSessions.queueVersion })
    .from(djSessions)
    .where(and(eq(djSessions.id, sessionId), eq(djSessions.userId, userId)))
    .for('update')
  if (!session) throw new AlbumStoreError('not_found')
  if (session.kind !== 'album') throw new AlbumStoreError('wrong_kind')
  if (expectedVersion !== undefined && expectedVersion !== session.queueVersion) throw new AlbumStoreError('conflict')
  return session.queueVersion
}

// Writes version current + 1. Replacing the previous version's pick, by a
// model turn, choosePick or goBack, is a pass: exactly one album_passed event
// per new version whose rank-0 album differs from the previous one's.
async function insertVersion(tx: Db, sessionId: string, current: number, picks: PickInput[]): Promise<number> {
  const version = current + 1
  if (current > 0) {
    const [previous] = await tx
      .select({ albumId: albumPicks.albumId })
      .from(albumPicks)
      .where(and(eq(albumPicks.sessionId, sessionId), eq(albumPicks.version, current), eq(albumPicks.rank, 0)))
    if (previous && previous.albumId !== picks[0].albumId) {
      await tx.insert(sessionEvents).values({ sessionId, type: 'album_passed' })
    }
  }
  await tx.insert(albumPicks).values(picks.slice(0, MAX_PICK_ROWS).map((p, rank) => ({
    sessionId, version, rank, albumId: p.albumId, reason: p.reason, newToThem: p.newToThem,
  })))
  await tx.update(djSessions).set({ queueVersion: version, updatedAt: new Date() }).where(eq(djSessions.id, sessionId))
  return version
}

async function versionRows(tx: Db, sessionId: string, version: number): Promise<PickInput[]> {
  return tx
    .select({ albumId: albumPicks.albumId, reason: albumPicks.reason, newToThem: albumPicks.newToThem })
    .from(albumPicks)
    .where(and(eq(albumPicks.sessionId, sessionId), eq(albumPicks.version, version)))
    .orderBy(asc(albumPicks.rank))
}

/**
 * Writes one pick version (rank 0 is the pick) and bumps the session's version, in one transaction,
 * recording album_passed when the previous version's pick is replaced.
 */
export async function writePickVersion(
  db: Db,
  input: { sessionId: string; userId: string; picks: PickInput[]; expectedVersion?: number },
): Promise<{ version: number }> {
  if (input.picks.length === 0) throw new Error('album store: a pick version needs at least one album')
  return db.transaction(async (tx) => {
    const current = await lockAlbumSession(tx as unknown as Db, input.sessionId, input.userId, input.expectedVersion)
    return { version: await insertVersion(tx as unknown as Db, input.sessionId, current, input.picks) }
  })
}

/** The latest version's pick and runners-up, and the earlier picks passed over, newest first. */
export async function readPickState(db: Db, sessionId: string, userId: string): Promise<AlbumPickState> {
  const [session] = await db
    .select({ queueVersion: djSessions.queueVersion })
    .from(djSessions)
    .where(and(eq(djSessions.id, sessionId), eq(djSessions.userId, userId)))
  if (!session) throw new AlbumStoreError('not_found')
  const version = session.queueVersion

  const rows = await db
    .select({ pick: albumPicks, album: albums, savedAt: listenLater.savedAt })
    .from(albumPicks)
    .innerJoin(albums, eq(albums.id, albumPicks.albumId))
    .leftJoin(listenLater, and(
      eq(listenLater.albumId, albumPicks.albumId),
      eq(listenLater.userId, userId),
      isNull(listenLater.removedAt),
    ))
    .where(and(
      eq(albumPicks.sessionId, sessionId),
      or(eq(albumPicks.version, version), eq(albumPicks.rank, 0)),
    ))
    .orderBy(desc(albumPicks.version), asc(albumPicks.rank))

  const view = (r: (typeof rows)[number]): AlbumView => ({
    id: r.album.id,
    upc: r.album.upc,
    appleId: r.album.appleId,
    title: r.album.title,
    artist: r.album.artist,
    releaseYear: r.album.releaseYear,
    type: r.album.type,
    trackCount: r.album.trackCount,
    durationMs: r.album.durationMs,
    artwork: r.album.artworkUrlTemplate
      ? { url: r.album.artworkUrlTemplate, width: r.album.artworkWidth, height: r.album.artworkHeight, bgColor: r.album.artworkBgColor }
      : null,
    newToThem: r.pick.newToThem,
    reason: r.pick.reason,
    savedForLater: r.savedAt !== null,
    version: r.pick.version,
  })

  const latest = rows.filter((r) => r.pick.version === version)
  const pick = latest.find((r) => r.pick.rank === 0)
  const passed: AlbumView[] = []
  // An album still in the latest version (pick or runner-up) is not passed over.
  const seen = new Set<string>(latest.map((r) => r.album.id))
  for (const r of rows) {
    if (r.pick.version >= version || r.pick.rank !== 0 || seen.has(r.album.id)) continue
    seen.add(r.album.id)
    passed.push(view(r))
  }
  return {
    version,
    pick: pick ? view(pick) : null,
    runnersUp: latest.filter((r) => r.pick.rank > 0).map(view),
    passed,
  }
}

/** Makes a runner-up (or any album of the latest version) the pick. No model call. */
export async function choosePick(
  db: Db,
  input: { sessionId: string; userId: string; albumId: string; expectedVersion?: number },
): Promise<AlbumPickState> {
  await db.transaction(async (rawTx) => {
    const tx = rawTx as unknown as Db
    const current = await lockAlbumSession(tx, input.sessionId, input.userId, input.expectedVersion)
    const rows = await versionRows(tx, input.sessionId, current)
    const chosen = rows.find((r) => r.albumId === input.albumId)
    if (!chosen) throw new AlbumStoreError('not_found')
    // Already the pick: nothing passed over, nothing to write.
    if (rows[0].albumId === input.albumId) return
    // insertVersion records the pass.
    await insertVersion(tx, input.sessionId, current, [chosen, ...rows.filter((r) => r !== chosen)])
  })
  return readPickState(db, input.sessionId, input.userId)
}

/** Restores an earlier version's shortlist as a new version. No model call. */
export async function goBack(
  db: Db,
  input: { sessionId: string; userId: string; version: number; expectedVersion?: number },
): Promise<AlbumPickState> {
  await db.transaction(async (rawTx) => {
    const tx = rawTx as unknown as Db
    const current = await lockAlbumSession(tx, input.sessionId, input.userId, input.expectedVersion)
    if (!Number.isSafeInteger(input.version) || input.version < 1 || input.version > current) {
      throw new AlbumStoreError('not_found')
    }
    if (input.version === current) return
    const rows = await versionRows(tx, input.sessionId, input.version)
    if (rows.length === 0) throw new AlbumStoreError('not_found')
    // insertVersion records the pass (none when the restored pick is the current one).
    await insertVersion(tx, input.sessionId, current, rows)
  })
  return readPickState(db, input.sessionId, input.userId)
}
