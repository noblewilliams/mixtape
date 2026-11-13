import { and, asc, eq, inArray, isNull, sql } from 'drizzle-orm'
import type { Db } from '../db/types'
import { djSessions, mixShares, mixShareSaves, queueTracks, tracks, user, type MixShareEntry } from '../db/schema'

// Shared mixes (spec docs/superpowers/specs/2026-11-13-shared-mixes-design.md).
// A share is a snapshot: title, tape colour and the ordered active songs at
// the session's queue_version, copied into mix_shares. Song metadata and the
// sharer's first name are read live at read time.

const BASE62 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
export const SHARE_TOKEN_LENGTH = 22
const SHARE_TOKEN_RE = /^[A-Za-z0-9]{22}$/
// The largest multiple of 62 that fits in a byte. Bytes at or above it are
// rejected so `byte % 62` stays uniform (about 131 bits per token).
const ACCEPT_BELOW = 248

type FillRandom = (buf: Uint8Array<ArrayBuffer>) => unknown

export function generateShareToken(fill: FillRandom = (buf) => crypto.getRandomValues(buf)): string {
  let out = ''
  const buf = new Uint8Array(SHARE_TOKEN_LENGTH)
  while (out.length < SHARE_TOKEN_LENGTH) {
    fill(buf)
    for (const byte of buf) {
      if (byte >= ACCEPT_BELOW) continue
      out += BASE62[byte % 62]
      if (out.length === SHARE_TOKEN_LENGTH) break
    }
  }
  return out
}

export function isShareToken(value: string): boolean {
  return SHARE_TOKEN_RE.test(value)
}

// What recipients see of the sharer: the profile's first name, normalised,
// sanitised and capped exactly as the DJ sees it. Null when the sender later
// cleared their name; clients then say "a friend" (plan, Shared contract).
import { firstName } from '../auth/profile-name'
export { firstName }

export type CreateShareResult =
  | { kind: 'ok'; token: string }
  | { kind: 'not_found' }
  | { kind: 'empty_mix' }

// Reuses the active share at the session's current queue_version, else
// snapshots the active queue into a new one. The session row is locked so
// two concurrent shares at one version end with one token.
export async function createOrReuseShare(
  db: Db,
  { sessionId, userId }: { sessionId: string; userId: string },
): Promise<CreateShareResult> {
  return db.transaction(async (tx) => {
    const [session] = await tx
      .select()
      .from(djSessions)
      .where(and(eq(djSessions.id, sessionId), eq(djSessions.userId, userId), eq(djSessions.kind, 'mix')))
      .for('update')
    if (!session) return { kind: 'not_found' } as const

    const [existing] = await tx
      .select({ token: mixShares.token })
      .from(mixShares)
      .where(and(eq(mixShares.sessionId, session.id), eq(mixShares.queueVersion, session.queueVersion), isNull(mixShares.revokedAt)))
      .limit(1)
    if (existing) return { kind: 'ok', token: existing.token } as const

    const entries: MixShareEntry[] = await tx
      .select({ position: queueTracks.position, trackId: queueTracks.trackId })
      .from(queueTracks)
      .where(and(eq(queueTracks.sessionId, session.id), eq(queueTracks.state, 'active')))
      .orderBy(asc(queueTracks.position))
    if (entries.length === 0) return { kind: 'empty_mix' } as const

    const token = generateShareToken()
    await tx.insert(mixShares).values({
      token,
      sessionId: session.id,
      sharerId: userId,
      queueVersion: session.queueVersion,
      title: session.title,
      caseColor: session.caseColor,
      entries,
    })
    return { kind: 'ok', token } as const
  })
}

export async function revokeShares(db: Db, sessionId: string): Promise<void> {
  await db
    .update(mixShares)
    .set({ revokedAt: sql`now()` })
    .where(and(eq(mixShares.sessionId, sessionId), isNull(mixShares.revokedAt)))
}

export async function hasActiveShare(db: Db, sessionId: string): Promise<boolean> {
  const [row] = await db
    .select({ id: mixShares.id })
    .from(mixShares)
    .where(and(eq(mixShares.sessionId, sessionId), isNull(mixShares.revokedAt)))
    .limit(1)
  return row !== undefined
}

// The share row behind a token, without its songs: for saves.
export type ShareRef = { id: string; sessionId: string; sharerId: string; revoked: boolean }

export async function findShare(db: Db, token: string): Promise<ShareRef | null> {
  if (!isShareToken(token)) return null
  const [row] = await db
    .select({ id: mixShares.id, sessionId: mixShares.sessionId, sharerId: mixShares.sharerId, revokedAt: mixShares.revokedAt })
    .from(mixShares)
    .where(eq(mixShares.token, token))
  if (!row) return null
  return { id: row.id, sessionId: row.sessionId, sharerId: row.sharerId, revoked: row.revokedAt !== null }
}

// Same shape as the session list's artwork (routes/sessions.ts GET /).
export type ShareArtwork = { url: string; width: number | null; height: number | null; bgColor: string | null }

export type SharedTrack = {
  title: string
  artist: string
  album: string | null
  durationMs: number | null
  artwork: ShareArtwork | null
  appleId: string | null
  isrc: string | null
}

export type ShareRead =
  | { kind: 'not_found' }
  | { kind: 'revoked' }
  | {
      kind: 'ok'
      share: ShareRef & { token: string; title: string; caseColor: string; createdAt: Date }
      sharerName: string | null
      tracks: SharedTrack[]
    }

export async function readShare(db: Db, token: string): Promise<ShareRead> {
  if (!isShareToken(token)) return { kind: 'not_found' }
  const [row] = await db
    .select({
      id: mixShares.id,
      token: mixShares.token,
      sessionId: mixShares.sessionId,
      sharerId: mixShares.sharerId,
      title: mixShares.title,
      caseColor: mixShares.caseColor,
      entries: mixShares.entries,
      createdAt: mixShares.createdAt,
      revokedAt: mixShares.revokedAt,
      sharerName: user.name,
    })
    .from(mixShares)
    .innerJoin(user, eq(user.id, mixShares.sharerId))
    .where(eq(mixShares.token, token))
  if (!row) return { kind: 'not_found' }
  if (row.revokedAt !== null) return { kind: 'revoked' }

  const ids = [...new Set(row.entries.map((e) => e.trackId))]
  const found = ids.length === 0
    ? []
    : await db
        .select({
          id: tracks.id,
          title: tracks.title,
          artist: tracks.artist,
          album: tracks.album,
          durationMs: tracks.durationMs,
          appleId: tracks.appleId,
          isrc: tracks.isrc,
          artworkUrl: tracks.artworkUrlTemplate,
          artworkWidth: tracks.artworkWidth,
          artworkHeight: tracks.artworkHeight,
          artworkBgColor: tracks.artworkBgColor,
        })
        .from(tracks)
        .where(inArray(tracks.id, ids))
  const byId = new Map(found.map((t) => [t.id, t]))
  const ordered = [...row.entries].sort((a, b) => a.position - b.position)
  const sharedTracks: SharedTrack[] = []
  for (const entry of ordered) {
    const t = byId.get(entry.trackId)
    // A catalogue row gone since the snapshot drops out rather than failing the read.
    if (!t) continue
    sharedTracks.push({
      title: t.title,
      artist: t.artist,
      album: t.album,
      durationMs: t.durationMs,
      artwork: t.artworkUrl === null
        ? null
        : { url: t.artworkUrl, width: t.artworkWidth, height: t.artworkHeight, bgColor: t.artworkBgColor },
      appleId: t.appleId,
      isrc: t.isrc,
    })
  }

  return {
    kind: 'ok',
    share: {
      id: row.id,
      token: row.token,
      sessionId: row.sessionId,
      sharerId: row.sharerId,
      revoked: false,
      title: row.title,
      caseColor: row.caseColor,
      createdAt: row.createdAt,
    },
    sharerName: firstName(row.sharerName),
    tracks: sharedTracks,
  }
}

// Idempotent. The owner's own save writes nothing.
export async function saveShare(db: Db, share: ShareRef, userId: string): Promise<void> {
  if (share.sharerId === userId) return
  await db.insert(mixShareSaves).values({ userId, shareId: share.id }).onConflictDoNothing()
}

export async function unsaveShare(db: Db, token: string, userId: string): Promise<void> {
  if (!isShareToken(token)) return
  await db
    .delete(mixShareSaves)
    .where(and(
      eq(mixShareSaves.userId, userId),
      inArray(mixShareSaves.shareId, db.select({ id: mixShares.id }).from(mixShares).where(eq(mixShares.token, token))),
    ))
}
