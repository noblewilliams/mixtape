import { isSpotifyId } from '../listening/contracts'
import { EnrichSourceError, SOURCE_TIMEOUT_MS, type FetchLike } from './types'
import type { AudioFeatures } from './reccobeats'

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

export type SpotifyAudioFeatureHit = { spotifyId: string; features: AudioFeatures }
export type SpotifyAudioFeaturesResult = { hits: SpotifyAudioFeatureHit[]; missing: string[] }
export type FetchAudioFeaturesBySpotifyIds = (ids: string[]) => Promise<SpotifyAudioFeaturesResult>
export type SpotifyEnrichSource = {
  tracks: FetchTracksBySpotifyIds
  features: FetchAudioFeaturesBySpotifyIds
}

// ReccoBeats keys a track by its own id; the Spotify id only travels in the
// item's href (https://open.spotify.com/track/<id>).
function spotifyIdFromHref(href: unknown): string | null {
  if (typeof href !== 'string') return null
  try {
    const url = new URL(href)
    if (url.origin !== 'https://open.spotify.com' || url.username || url.password) return null
    return /^\/track\/([0-9A-Za-z]{22})\/?$/.exec(url.pathname)?.[1] ?? null
  } catch {
    return null
  }
}

const cleanText = (value: unknown): string =>
  typeof value === 'string' ? value.replace(/\0/g, '').trim() : ''

function normalizedIsrc(value: unknown): string | null {
  const isrc = cleanText(value).toUpperCase()
  return /^[A-Z]{2}[A-Z0-9]{3}\d{7}$/.test(isrc) ? isrc : null
}

function parseItem(raw: unknown): ReccoBeatsTrackHit | null {
  if (!raw || typeof raw !== 'object') return null
  const item = raw as Record<string, unknown>
  const spotifyId = spotifyIdFromHref(item.href)
  if (!spotifyId) return null
  const title = cleanText(item.trackTitle)
  if (!title) return null
  const artists = Array.isArray(item.artists)
    ? item.artists
      .map((artist) => cleanText((artist as { name?: unknown } | null)?.name))
      .filter((name) => name.length > 0)
    : []
  const isrc = normalizedIsrc(item.isrc)
  // duration_ms is a PostgreSQL integer. Invalid upstream values must remain
  // unknown rather than aborting an otherwise usable metadata correction.
  const roundedDuration = finite(item.durationMs)
  const durationMs = roundedDuration === null ? null : inRange(Math.round(roundedDuration), 1, 2147483647)
  return { spotifyId, title, artists, isrc, durationMs }
}

// Resolves Spotify ids to ReccoBeats' track records, in request order; ids the
// API does not answer for (or answers unusably) come back as `missing`. Never
// logs ids or titles: the caller decides what a miss means.
export function fetchTracksBySpotifyIds(
  ids: string[],
  fetchLike: FetchLike = fetch,
): Promise<ReccoBeatsByIdResult> {
  return fetchByIds(ids, 'track', 'track', parseItem, fetchLike)
}

const finite = (value: unknown): number | null =>
  typeof value === 'number' && Number.isFinite(value) ? value : null

function inRange(value: unknown, min: number, max: number, integer = false): number | null {
  const number = finite(value)
  return number !== null && number >= min && number <= max && (!integer || Number.isInteger(number))
    ? number : null
}

function parseFeatures(raw: unknown): SpotifyAudioFeatureHit | null {
  if (!raw || typeof raw !== 'object') return null
  const item = raw as Record<string, unknown>
  const spotifyId = spotifyIdFromHref(item.href)
  if (!spotifyId) return null
  const values = {
    tempo: inRange(item.tempo, Number.MIN_VALUE, Number.MAX_VALUE),
    key: inRange(item.key, 0, 11, true), mode: inRange(item.mode, 0, 1, true),
    energy: inRange(item.energy, 0, 1), danceability: inRange(item.danceability, 0, 1),
    valence: inRange(item.valence, 0, 1), acousticness: inRange(item.acousticness, 0, 1),
    instrumentalness: inRange(item.instrumentalness, 0, 1), liveness: inRange(item.liveness, 0, 1),
    speechiness: inRange(item.speechiness, 0, 1), loudness: inRange(item.loudness, -60, 0),
  }
  if (Object.values(values).every((value) => value === null)) return null
  return { spotifyId, features: {
    ...values, isrc: normalizedIsrc(item.isrc), matchedDurationMs: null,
  } }
}

export function fetchAudioFeaturesBySpotifyIds(
  ids: string[],
  fetchLike: FetchLike = fetch,
): Promise<SpotifyAudioFeaturesResult> {
  return fetchByIds(ids, 'audio-features', 'features', parseFeatures, fetchLike)
}

async function fetchByIds<T extends { spotifyId: string }>(
  ids: string[],
  endpoint: 'track' | 'audio-features',
  label: 'track' | 'features',
  parse: (raw: unknown) => T | null,
  fetchLike: FetchLike,
): Promise<{ hits: T[]; missing: string[] }> {
  const wanted = [...new Set(ids.filter(isSpotifyId))]
  const found = new Map<string, T>()
  const ambiguous = new Set<string>()

  for (let start = 0; start < wanted.length; start += RECCOBEATS_ID_BATCH) {
    const batch = wanted.slice(start, start + RECCOBEATS_ID_BATCH)
    // Ids are base62, so the comma-joined list needs no encoding; a
    // URLSearchParams value would send %2C instead. A rejected fetch (the
    // timeout's TimeoutError, a DNS or connection TypeError) names the
    // request URL, ids and all, in its message, so the detail is fixed.
    const response = await fetchLike(`${BASE}/${endpoint}?ids=${batch.join(',')}`, {
      signal: AbortSignal.timeout(SOURCE_TIMEOUT_MS),
    }).catch(() => {
      throw new EnrichSourceError('reccobeats', `${label} fetch failed`)
    })
    if (!response.ok) {
      await response.body?.cancel().catch(() => undefined)
      if (response.status === 404) continue
      throw new EnrichSourceError('reccobeats', `${label} HTTP ${response.status}`, response.status)
    }
    const body = (await response.json().catch(() => {
      throw new EnrichSourceError('reccobeats', `malformed ${label} JSON`)
    })) as unknown
    const content = Array.isArray(body)
      ? body
      : Array.isArray((body as { content?: unknown } | null)?.content)
        ? (body as { content: unknown[] }).content
        : null
    if (!content) throw new EnrichSourceError('reccobeats', `malformed ${label} response`)
    const requested = new Set(batch)
    for (const raw of content) {
      const hit = parse(raw)
      if (!hit || !requested.has(hit.spotifyId) || ambiguous.has(hit.spotifyId)) continue
      if (found.has(hit.spotifyId)) {
        found.delete(hit.spotifyId)
        ambiguous.add(hit.spotifyId)
      } else {
        found.set(hit.spotifyId, hit)
      }
    }
  }

  return {
    hits: wanted.filter((id) => found.has(id)).map((id) => found.get(id)!),
    missing: [...new Set(ids)].filter((id) => !found.has(id)),
  }
}
