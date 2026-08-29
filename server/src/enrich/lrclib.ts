import { EnrichSourceError, SOURCE_TIMEOUT_MS, type FetchLike } from './types'

const UA = { 'User-Agent': 'mixtape/0.1 (personal project; enrichment)' }

export type LyricsKey = { title: string; artist: string; album: string | null; durationMs: number | null }
// Lyric text passes through transiently — callers must never persist or log it.
export type LyricsResult = { lyrics: string | null; instrumental: boolean }

type LrclibRecord = { plainLyrics: string | null; instrumental: boolean }

const toResult = (r: LrclibRecord): LyricsResult => ({ lyrics: r.plainLyrics ?? null, instrumental: !!r.instrumental })

async function getJson(url: URL, fetchLike: FetchLike): Promise<unknown | '404'> {
  const res = await fetchLike(url, { headers: UA, signal: AbortSignal.timeout(SOURCE_TIMEOUT_MS) })
  if (res.status === 404) return '404'
  if (!res.ok) throw new EnrichSourceError('lrclib', `HTTP ${res.status}`, res.status)
  return res.json().catch(() => {
    throw new EnrichSourceError('lrclib', 'malformed JSON')
  })
}

export async function fetchLyrics(key: LyricsKey, fetchLike: FetchLike = fetch): Promise<LyricsResult | null> {
  if (key.durationMs != null) {
    const getUrl = new URL('https://lrclib.net/api/get')
    getUrl.searchParams.set('artist_name', key.artist)
    getUrl.searchParams.set('track_name', key.title)
    if (key.album) getUrl.searchParams.set('album_name', key.album)
    getUrl.searchParams.set('duration', String(Math.round(key.durationMs / 1000)))
    const exact = await getJson(getUrl, fetchLike)
    if (exact !== '404') return toResult(exact as LrclibRecord)
  }

  const searchUrl = new URL('https://lrclib.net/api/search')
  searchUrl.searchParams.set('track_name', key.title)
  searchUrl.searchParams.set('artist_name', key.artist)
  const hits = await getJson(searchUrl, fetchLike)
  if (hits === '404' || !Array.isArray(hits) || !hits.length) return null
  return toResult(hits[0] as LrclibRecord)
}
