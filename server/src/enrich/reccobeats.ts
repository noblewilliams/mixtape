import { EnrichSourceError, SOURCE_TIMEOUT_MS, type FetchLike } from './types'

const BASE = 'https://api.reccobeats.com/v1'
const DURATION_TOLERANCE_MS = 5000

export type TrackKey = { title: string; artist: string; durationMs: number | null }

export type AudioFeatures = {
  tempo: number | null
  key: number | null
  mode: number | null
  energy: number | null
  danceability: number | null
  valence: number | null
  acousticness: number | null
  instrumentalness: number | null
  liveness: number | null
  speechiness: number | null
  loudness: number | null
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

const num = (v: unknown) => (typeof v === 'number' && Number.isFinite(v) ? v : null)

export async function resolveAndFetchFeatures(
  track: TrackKey,
  fetchLike: FetchLike = fetch,
): Promise<AudioFeatures | null> {
  const titleNorm = norm(track.title)
  const artistNorm = norm(track.artist)
  if (!artistNorm || !titleNorm) return null

  // Title only: artist terms in searchText break ReccoBeats matching (probed live).
  const searchUrl = new URL(`${BASE}/track/search`)
  searchUrl.searchParams.set('searchText', track.title)
  const searchRes = await fetchLike(searchUrl, { signal: AbortSignal.timeout(SOURCE_TIMEOUT_MS) })
  if (!searchRes.ok) throw new EnrichSourceError('reccobeats', `search HTTP ${searchRes.status}`, searchRes.status)
  const searchBody = (await searchRes.json().catch(() => {
    throw new EnrichSourceError('reccobeats', 'malformed search JSON')
  })) as { content?: Candidate[] }
  const content = Array.isArray(searchBody?.content) ? searchBody.content : []

  const artistOk = (c: Candidate) =>
    Array.isArray(c.artists) &&
    c.artists.some((a) => {
      const n = norm(a?.name ?? '')
      return n !== '' && n === artistNorm
    })
  const durationOk = (c: Candidate) => {
    if (track.durationMs == null) return true
    if (c.durationMs == null) return false // missing candidate duration: fail closed
    return Math.abs(c.durationMs - track.durationMs) <= DURATION_TOLERANCE_MS
  }
  const exactTitle = content.filter((c) => norm(c.trackTitle ?? '') === titleNorm)
  // Exact-title candidates preferred, but not exclusive: a cover carrying the plain
  // title shouldn't monopolize the pool and hide a real non-exact match (e.g. an
  // "(Album Version)" track) that the artist+duration gate can still vouch for.
  // Without a known duration, exact title is REQUIRED (title-only search happily
  // returns live/remix cuts otherwise).
  const match =
    exactTitle.find((c) => artistOk(c) && durationOk(c)) ??
    (track.durationMs != null ? content.find((c) => artistOk(c) && durationOk(c)) : undefined)
  if (!match) return null

  const featRes = await fetchLike(`${BASE}/track/${match.id}/audio-features`, {
    signal: AbortSignal.timeout(SOURCE_TIMEOUT_MS),
  })
  if (!featRes.ok) {
    if (featRes.status === 404) return null
    throw new EnrichSourceError('reccobeats', `features HTTP ${featRes.status}`, featRes.status)
  }
  const f = (await featRes.json().catch(() => {
    throw new EnrichSourceError('reccobeats', 'malformed features JSON')
  })) as Record<string, unknown> & { isrc?: unknown }
  return {
    tempo: num(f.tempo),
    key: num(f.key),
    mode: num(f.mode),
    energy: num(f.energy),
    danceability: num(f.danceability),
    valence: num(f.valence),
    acousticness: num(f.acousticness),
    instrumentalness: num(f.instrumentalness),
    liveness: num(f.liveness),
    speechiness: num(f.speechiness),
    loudness: num(f.loudness),
    isrc: typeof f.isrc === 'string' ? f.isrc : (match.isrc ?? null),
  }
}
