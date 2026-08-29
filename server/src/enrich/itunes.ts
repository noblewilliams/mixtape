export type FetchLike = (url: string | URL, init?: RequestInit) => Promise<Response>

export class EnrichSourceError extends Error {
  constructor(source: string, detail: string) {
    super(`${source}: ${detail}`)
  }
}

export type ItunesHit = {
  trackName: string
  artistName: string
  previewUrl: string | null
  durationMs: number | null
  genre: string | null
}

export async function lookupItunes(
  appleId: string,
  storefront: string,
  fetchLike: FetchLike = fetch,
): Promise<ItunesHit | null> {
  const url = `https://itunes.apple.com/lookup?id=${encodeURIComponent(appleId)}&country=${storefront}`
  const res = await fetchLike(url)
  if (!res.ok) throw new EnrichSourceError('itunes', `HTTP ${res.status}`)
  const body = (await res.json()) as {
    resultCount: number
    results: Array<{
      trackName?: string
      artistName?: string
      previewUrl?: string
      trackTimeMillis?: number
      primaryGenreName?: string
    }>
  }
  if (!body.resultCount || !body.results.length) return null
  const r = body.results[0]
  return {
    trackName: r.trackName ?? '',
    artistName: r.artistName ?? '',
    previewUrl: r.previewUrl ?? null,
    durationMs: r.trackTimeMillis ?? null,
    genre: r.primaryGenreName ?? null,
  }
}
