import { and, asc, eq, inArray } from 'drizzle-orm'
import type { Db } from '../db/types'
import { userArtistSeeds } from '../db/schema'
import { ARTIST_SEED_NAME_MAX } from './contracts'

export type ArtistSeedSource = (typeof userArtistSeeds.$inferInsert)['source']

export type ArtistSeedView = {
  name: string
  spotifyId: string | null
  source: ArtistSeedSource
  createdAt: Date
}

// The pool matches seeds to artists on lower(btrim(name)) (dj/pool.ts), so
// that is also what makes two spellings the same seed here.
const seedKey = (name: string) => name.trim().toLowerCase()

// Trims, drops blanks and over-long names, and keeps the first spelling of
// each name; order is the caller's.
export function dedupeSeedNames(names: string[]): string[] {
  const seen = new Set<string>()
  const out: string[] = []
  for (const raw of names) {
    const name = raw.replace(/\0/g, '').trim()
    if (name.length === 0 || name.length > ARTIST_SEED_NAME_MAX) continue
    const key = seedKey(name)
    if (seen.has(key)) continue
    seen.add(key)
    out.push(name)
  }
  return out
}

export async function listArtistSeeds(db: Db, userId: string): Promise<ArtistSeedView[]> {
  return db
    .select({
      name: userArtistSeeds.name,
      spotifyId: userArtistSeeds.spotifyId,
      source: userArtistSeeds.source,
      createdAt: userArtistSeeds.createdAt,
    })
    .from(userArtistSeeds)
    .where(eq(userArtistSeeds.userId, userId))
    .orderBy(asc(userArtistSeeds.createdAt), asc(userArtistSeeds.name))
}

// Inserts the names the user does not already have (any source, matched
// case-insensitively); existing rows are never touched. Returns how many
// rows were added.
export async function insertMissingArtistSeeds(
  db: Db,
  userId: string,
  names: string[],
  source: ArtistSeedSource,
): Promise<number> {
  const wanted = dedupeSeedNames(names)
  if (wanted.length === 0) return 0
  const existing = await db
    .select({ name: userArtistSeeds.name })
    .from(userArtistSeeds)
    .where(eq(userArtistSeeds.userId, userId))
  const present = new Set(existing.map((row) => seedKey(row.name)))
  const missing = wanted.filter((name) => !present.has(seedKey(name)))
  if (missing.length === 0) return 0
  const inserted = await db
    .insert(userArtistSeeds)
    .values(missing.map((name) => ({ userId, name, source })))
    .onConflictDoNothing({ target: [userArtistSeeds.userId, userArtistSeeds.name] })
    .returning({ name: userArtistSeeds.name })
  return inserted.length
}

// Makes the user's interview seeds exactly `names`: interview rows not in the
// list go, names not yet present (under any source) come in as interview
// seeds, and a name already held by another source is left as it is. Runs
// inside whatever transaction the caller holds. Returns the deduped list.
export async function replaceInterviewSeeds(db: Db, userId: string, names: string[]): Promise<string[]> {
  const wanted = dedupeSeedNames(names)
  const wantedKeys = new Set(wanted.map(seedKey))
  const interviewRows = await db
    .select({ name: userArtistSeeds.name })
    .from(userArtistSeeds)
    .where(and(eq(userArtistSeeds.userId, userId), eq(userArtistSeeds.source, 'interview')))
  const stale = interviewRows.map((row) => row.name).filter((name) => !wantedKeys.has(seedKey(name)))
  if (stale.length > 0) {
    await db
      .delete(userArtistSeeds)
      .where(and(
        eq(userArtistSeeds.userId, userId),
        eq(userArtistSeeds.source, 'interview'),
        inArray(userArtistSeeds.name, stale),
      ))
  }
  await insertMissingArtistSeeds(db, userId, wanted, 'interview')
  return wanted
}
