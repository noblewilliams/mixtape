import { isSpotifyId } from '../listening/contracts'
import { EnrichSourceError, SOURCE_TIMEOUT_MS, type FetchLike } from './types'

const BASE = 'https://api.reccobeats.com/v1'

// Verified live 2026-09-01: 41 ids in one request answers HTTP 400.
export const RECCOBEATS_ID_BATCH = 40

export type ReccoBeatsTrackHit = {
  spotifyId: string
  title: string
  artists: string[]
  isrc: string | null
  durationMs: number | null
}

export type ReccoBeatsByIdResult = { hits: ReccoBeatsTrackHit[]; missing: string[] }

export type FetchTracksBySpotifyIds = (ids: string[]) => Promise<ReccoBeatsByIdResult>

// ReccoBeats keys a track by its own id; the Spotify id only travels in the
// item's href (https://open.spotify.com/track/<id>).
const TRACK_HREF = /open\.spotify\.com\/track\/([0-9A-Za-z]{22})(?:[?#/]|$)/

const cleanText = (value: unknown): string =>
  typeof value === 'string' ? value.replace(/\0/g, '').trim() : ''

function parseItem(raw: unknown): ReccoBeatsTrackHit | null {
  if (!raw || typeof raw !== 'object') return null
  const item = raw as Record<string, unknown>
  const spotifyId = typeof item.href === 'string' ? TRACK_HREF.exec(item.href)?.[1] : undefined
  if (!spotifyId) return null
  const title = cleanText(item.trackTitle)
  if (!title) return null
  const artists = Array.isArray(item.artists)
    ? item.artists
      .map((artist) => cleanText((artist as { name?: unknown } | null)?.name))
      .filter((name) => name.length > 0)
    : []
  const isrc = cleanText(item.isrc) || null
  const durationMs = typeof item.durationMs === 'number' && Number.isFinite(item.durationMs) && item.durationMs > 0
    ? Math.round(item.durationMs)
    : null
  return { spotifyId, title, artists, isrc, durationMs }
}

// Resolves Spotify ids to ReccoBeats' track records, in request order; ids the
// API does not answer for (or answers unusably) come back as `missing`. Never
// logs ids or titles: the caller decides what a miss means.
export async function fetchTracksBySpotifyIds(
  ids: string[],
  fetchLike: FetchLike = fetch,
): Promise<ReccoBeatsByIdResult> {
  const wanted = [...new Set(ids.filter(isSpotifyId))]
  const found = new Map<string, ReccoBeatsTrackHit>()

  for (let start = 0; start < wanted.length; start += RECCOBEATS_ID_BATCH) {
    const batch = wanted.slice(start, start + RECCOBEATS_ID_BATCH)
    // Ids are base62, so the comma-joined list needs no encoding; a
    // URLSearchParams value would send %2C instead.
    const response = await fetchLike(`${BASE}/track?ids=${batch.join(',')}`, {
      signal: AbortSignal.timeout(SOURCE_TIMEOUT_MS),
    })
    if (!response.ok) {
      throw new EnrichSourceError('reccobeats', `track HTTP ${response.status}`, response.status)
    }
    const body = (await response.json().catch(() => {
      throw new EnrichSourceError('reccobeats', 'malformed track JSON')
    })) as unknown
    const content = Array.isArray(body)
      ? body
      : Array.isArray((body as { content?: unknown } | null)?.content)
        ? (body as { content: unknown[] }).content
        : []
    const requested = new Set(batch)
    for (const raw of content) {
      const hit = parseItem(raw)
      if (hit && requested.has(hit.spotifyId) && !found.has(hit.spotifyId)) found.set(hit.spotifyId, hit)
    }
  }

  return {
    hits: wanted.filter((id) => found.has(id)).map((id) => found.get(id)!),
    missing: [...new Set(ids)].filter((id) => !found.has(id)),
  }
}
