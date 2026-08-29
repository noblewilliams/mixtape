import { EnrichSourceError, type FetchLike } from './types'

const BASE = 'https://api.reccobeats.com/v1'
const DURATION_TOLERANCE_MS = 5000
const TIMEOUT = 5000

export type TrackKey = { title: string; artist: string; durationMs: number | null }

export type AudioFeatures = {
  tempo: number
  key: number
  mode: number
  energy: number
  danceability: number
  valence: number
  acousticness: number
  instrumentalness: number
  liveness: number
  speechiness: number
  loudness: number
  isrc: string | null
}

type Candidate = {
  id: string
  trackTitle: string
  artists: Array<{ name: string }>
  durationMs: number
  isrc: string | null
}

const norm = (s: string) => s.toLowerCase().normalize('NFKD').replace(/[^\p{L}\p{N} ]/gu, '').trim()

export async function resolveAndFetchFeatures(
  track: TrackKey,
  fetchLike: FetchLike = fetch,
): Promise<AudioFeatures | null> {
  // Title only: artist terms in searchText break ReccoBeats matching (probed live).
  const searchUrl = new URL(`${BASE}/track/search`)
  searchUrl.searchParams.set('searchText', track.title)
  const searchRes = await fetchLike(searchUrl, { signal: AbortSignal.timeout(TIMEOUT) })
  if (!searchRes.ok) throw new EnrichSourceError('reccobeats', `search HTTP ${searchRes.status}`, searchRes.status)
  const searchBody = (await searchRes.json().catch(() => {
    throw new EnrichSourceError('reccobeats', 'malformed search JSON')
  })) as { content?: Candidate[] }
  const content = Array.isArray(searchBody?.content) ? searchBody.content : []

  const artistNorm = norm(track.artist)
  const match = content.find((c) => {
    const artistOk = Array.isArray(c.artists) && c.artists.some((a) => norm(a?.name ?? '') === artistNorm)
    if (!artistOk) return false
    if (track.durationMs == null) return true
    return Math.abs(c.durationMs - track.durationMs) <= DURATION_TOLERANCE_MS
  })
  if (!match) return null

  const featRes = await fetchLike(`${BASE}/track/${match.id}/audio-features`, {
    signal: AbortSignal.timeout(TIMEOUT),
  })
  if (!featRes.ok) {
    if (featRes.status === 404) return null
    throw new EnrichSourceError('reccobeats', `features HTTP ${featRes.status}`, featRes.status)
  }
  const f = (await featRes.json().catch(() => {
    throw new EnrichSourceError('reccobeats', 'malformed features JSON')
  })) as Record<string, number> & { isrc?: string }
  return {
    tempo: f.tempo,
    key: f.key,
    mode: f.mode,
    energy: f.energy,
    danceability: f.danceability,
    valence: f.valence,
    acousticness: f.acousticness,
    instrumentalness: f.instrumentalness,
    liveness: f.liveness,
    speechiness: f.speechiness,
    loudness: f.loudness,
    isrc: f.isrc ?? match.isrc ?? null,
  }
}
