export { EnrichSourceError } from './types'
export type { FetchLike } from './types'

import { EnrichSourceError, type FetchLike } from './types'

export type ItunesHit = {
  trackName: string | null
  artistName: string | null
  previewUrl: string | null
  durationMs: number | null
  genre: string | null
}

export async function lookupItunes(
  appleId: string,
  storefront: string,
  fetchLike: FetchLike = fetch,
): Promise<ItunesHit | null> {
  const u = new URL('https://itunes.apple.com/lookup')
  u.searchParams.set('id', appleId)
  u.searchParams.set('country', storefront)
  const res = await fetchLike(u, { signal: AbortSignal.timeout(5000) })
  if (!res.ok) throw new EnrichSourceError('itunes', `HTTP ${res.status}`, res.status)
  const body = (await res.json().catch(() => {
    throw new EnrichSourceError('itunes', 'malformed JSON')
  })) as {
    resultCount: number
    results: Array<{
      trackName?: string
      artistName?: string
      previewUrl?: string
      trackTimeMillis?: number
      primaryGenreName?: string
    }>
  }
  if (!body?.resultCount || !Array.isArray(body.results) || !body.results.length) return null
  const r = body.results[0]
  return {
    trackName: r.trackName ?? null,
    artistName: r.artistName ?? null,
    previewUrl: r.previewUrl ?? null,
    durationMs: r.trackTimeMillis ?? null,
    genre: r.primaryGenreName ?? null,
  }
}
