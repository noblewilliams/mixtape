import { EnrichSourceError, norm, SOURCE_TIMEOUT_MS, type FetchLike } from './types'

const UA = { 'User-Agent': 'mixtape/0.1 (personal project; enrichment)' }

export type LyricsKey = { title: string; artist: string; album: string | null; durationMs: number | null }
// Lyric text passes through transiently — callers must never persist or log it.
export type LyricsResult = { lyrics: string | null; instrumental: boolean }

type LrclibRecord = {
  plainLyrics: string | null
  instrumental: boolean
  trackName?: string
  artistName?: string
}

const toResult = (r: LrclibRecord): LyricsResult => ({ lyrics: r.plainLyrics ?? null, instrumental: !!r.instrumental })

type Fetched = { ok: true; body: unknown } | { ok: false }

async function getJson(url: URL, fetchLike: FetchLike): Promise<Fetched> {
  const res = await fetchLike(url, { headers: UA, signal: AbortSignal.timeout(SOURCE_TIMEOUT_MS) })
  if (res.status === 404) return { ok: false }
  if (!res.ok) throw new EnrichSourceError('lrclib', `HTTP ${res.status}`, res.status)
  const body = await res.json().catch(() => {
    throw new EnrichSourceError('lrclib', 'malformed JSON')
  })
  return { ok: true, body }
}

export async function fetchLyrics(key: LyricsKey, fetchLike: FetchLike = fetch): Promise<LyricsResult | null> {
  const artistNorm = norm(key.artist)
  if (!artistNorm) return null

  if (key.durationMs != null) {
    const getUrl = new URL('https://lrclib.net/api/get')
    getUrl.searchParams.set('artist_name', key.artist)
    getUrl.searchParams.set('track_name', key.title)
    if (key.album) getUrl.searchParams.set('album_name', key.album)
    getUrl.searchParams.set('duration', String(Math.round(key.durationMs / 1000)))
    const exact = await getJson(getUrl, fetchLike)
    if (exact.ok) {
      if (typeof exact.body !== 'object' || exact.body === null) {
        throw new EnrichSourceError('lrclib', 'unexpected body')
      }
      const record = exact.body as LrclibRecord
      // Usable signal only — a synced-only record (no plain lyrics, not
      // flagged instrumental) tells us nothing; fall through to search
      // rather than accepting it and stalling the meaning stage forever.
      if (record.plainLyrics != null || record.instrumental === true) {
        return toResult(record)
      }
    }
  }

  const searchUrl = new URL('https://lrclib.net/api/search')
  searchUrl.searchParams.set('track_name', key.title)
  searchUrl.searchParams.set('artist_name', key.artist)
  const searched = await getJson(searchUrl, fetchLike)
  if (!searched.ok || !Array.isArray(searched.body) || !searched.body.length) return null
  // Verify the artist on this path: a wrong-song embedding would be silent,
  // permanent, and unauditable, whereas a miss here is visible and retryable.
  // Also require usable signal — a synced-only record (no plain lyrics, not
  // flagged instrumental) tells us nothing and isn't worth accepting.
  const hit = (searched.body as LrclibRecord[]).find(
    (h) => norm(h.artistName ?? '') === artistNorm && (h.plainLyrics != null || h.instrumental === true),
  )
  return hit ? toResult(hit) : null
}
