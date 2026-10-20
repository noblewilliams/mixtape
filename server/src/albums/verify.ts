import { eq } from 'drizzle-orm'
import type { Db } from '../db/types'
import { userMusicProfiles } from '../db/schema'
import { AppleCatalogError, type AppleCatalogAlbumClient, type ArtworkMetadata, type CatalogAlbum } from '../musickit/catalog'
import type { AlbumType } from './contracts'
import type { ShelfAlbum } from './shelf'

// The catalogue check is the hallucination guard (spec 2026-10-20 →
// Candidates): a candidate Apple cannot confirm in the listener's market is
// dropped, never shown.

// Free plan limits (plan → Standing rules): five album searches and one album
// fetch per turn.
export const MAX_SEARCHES_PER_TURN = 5
export const MAX_FETCHES_PER_TURN = 1
const SEARCH_LIMIT = 5
// catalog.ts refuses a term longer than 120 characters.
const MAX_TERM_LENGTH = 120

export class AlbumVerifyError extends Error {
  constructor(readonly kind: 'catalogue_search' | 'budget') {
    super(`album_verify:${kind}`)
    this.name = 'AlbumVerifyError'
  }
}

export class CatalogBudget {
  searches = 0
  fetches = 0
  take(kind: 'search' | 'fetch'): void {
    if (kind === 'search') {
      if (this.searches >= MAX_SEARCHES_PER_TURN) throw new AlbumVerifyError('budget')
      this.searches += 1
    } else {
      if (this.fetches >= MAX_FETCHES_PER_TURN) throw new AlbumVerifyError('budget')
      this.fetches += 1
    }
  }
}

export type VerifyCandidate = {
  artist: string
  title: string
  type: AlbumType
  why: string
  year?: number
  shelf?: ShelfAlbum
}

export type VerifiedAlbum = {
  appleId: string
  upc: string | null
  title: string
  artist: string
  releaseYear: number | null
  trackCount: number | null
  durationMs: number | null
  type: AlbumType
  artwork: ArtworkMetadata | null
  genre: string | null
  why: string
  fromShelf: boolean
  modelOrder: number
  storefront: string
}

const TOLERATED_WORDS = new Set([
  'deluxe', 'remastered', 'remaster', 'edition', 'expanded', 'anniversary', 'version', 'bonus', 'tracks',
])

/**
 * Folds an artist or album name for matching: NFKC, lowercase, diacritics
 * dropped, bracketed segments and Apple's " - Single"/" - EP" suffix removed,
 * "&" read as "and", punctuation to spaces, the tolerated edition words and a
 * leading "the" dropped, whitespace collapsed.
 */
export function fold(value: string): string {
  const base = value
    .normalize('NFKC')
    .toLowerCase()
    .normalize('NFD')
    .replace(/\p{M}+/gu, '')
    .replace(/\([^)]*\)|\[[^\]]*\]/g, ' ')
    .replace(/\s+-\s+(single|ep)\s*$/u, ' ')
    .replace(/&/g, ' and ')
    .replace(/[^\p{L}\p{N}\s]+/gu, ' ')
  const words = base.split(/\s+/).filter((w) => w.length > 0 && !TOLERATED_WORDS.has(w))
  if (words[0] === 'the' && words.length > 1) words.shift()
  return words.join(' ')
}

const MARKET = /^[a-z]{2}$/

/** The listener's Apple storefront, else the default (as linking does), else null. */
export async function resolveMarket(db: Db, userId: string, defaultStorefront: string | undefined): Promise<string | null> {
  const [profile] = await db
    .select({ storefront: userMusicProfiles.appleStorefront })
    .from(userMusicProfiles)
    .where(eq(userMusicProfiles.userId, userId))
  if (profile?.storefront && MARKET.test(profile.storefront)) return profile.storefront
  const fallback = defaultStorefront?.trim().toLowerCase() ?? ''
  return MARKET.test(fallback) ? fallback : null
}

// Tokens that may follow the wanted artist in a credit ("X & Y" folds to
// "x and y", "X feat. Z" to "x feat z"). Anything else is a different artist
// ("Joni Mitchell Tribute Band" is not Joni Mitchell).
const CREDIT_JOINERS = new Set(['and', '&', 'feat', 'feat.', 'featuring', 'with', 'x'])

/**
 * Whether a credited artist is the wanted (already folded) artist, alone or
 * joined by a credit word. An empty wanted artist matches nothing.
 */
export function artistMatches(creditedArtist: string, wanted: string): boolean {
  if (wanted.length === 0) return false
  const credited = fold(creditedArtist)
  if (credited === wanted) return true
  if (!credited.startsWith(`${wanted} `)) return false
  const next = credited.slice(wanted.length + 1).split(' ')[0]
  return CREDIT_JOINERS.has(next)
}

function resolvedType(candidate: AlbumType, hit: CatalogAlbum): AlbumType {
  if (hit.isSingle) return 'single'
  if (hit.isCompilation) return 'compilation'
  return candidate
}

export async function verifyCandidates(
  catalog: AppleCatalogAlbumClient,
  market: string,
  candidates: VerifyCandidate[],
  budget: CatalogBudget,
): Promise<{ verified: VerifiedAlbum[]; dropped: number }> {
  const verified: VerifiedAlbum[] = []
  const seen = new Set<string>()
  let dropped = 0

  for (const [modelOrder, candidate] of candidates.entries()) {
    const artist = candidate.shelf?.artist ?? candidate.artist
    const title = candidate.shelf?.album ?? candidate.title
    budget.take('search')
    let hits: CatalogAlbum[]
    try {
      hits = await catalog.searchAlbums(market, `${artist} ${title}`.slice(0, MAX_TERM_LENGTH).trim(), SEARCH_LIMIT)
    } catch (error) {
      if (error instanceof AppleCatalogError) throw new AlbumVerifyError('catalogue_search')
      throw error
    }
    const wantedArtist = fold(artist)
    const wantedTitle = fold(title)
    // A name that folds to nothing (all punctuation, say) can match nothing.
    const hit = wantedTitle.length === 0 ? undefined : hits.find((h) =>
      (!h.isSingle || candidate.type === 'single')
      && artistMatches(h.artist, wantedArtist)
      && fold(h.title) === wantedTitle)
    if (!hit) {
      dropped += 1
      continue
    }
    // A second candidate resolving to the same album is not a drop: it is
    // the same record named twice.
    if (seen.has(hit.appleId)) continue
    seen.add(hit.appleId)
    verified.push({
      appleId: hit.appleId,
      upc: hit.upc,
      title: hit.title,
      artist: hit.artist,
      releaseYear: hit.releaseYear,
      trackCount: hit.trackCount,
      durationMs: hit.durationMs,
      type: resolvedType(candidate.type, hit),
      artwork: hit.artwork,
      genre: hit.genre,
      why: candidate.why,
      fromShelf: candidate.shelf !== undefined,
      modelOrder,
      storefront: market,
    })
  }

  if (verified.length === 0) return { verified, dropped }

  budget.take('fetch')
  try {
    const details = await catalog.getAlbums(market, verified.map((v) => v.appleId))
    for (const v of verified) {
      const detail = details.get(v.appleId)
      if (!detail) continue
      v.durationMs = detail.durationMs ?? v.durationMs
      v.trackCount = detail.trackCount ?? v.trackCount
      v.upc = detail.upc ?? v.upc
      v.artwork = detail.artwork ?? v.artwork
    }
  } catch (error) {
    if (!(error instanceof AppleCatalogError)) throw error
    // Best-effort: the card shows no length rather than failing the turn.
    console.log('album verify', JSON.stringify({ detailFetchFailed: 1, albums: verified.length }))
  }
  return { verified, dropped }
}
