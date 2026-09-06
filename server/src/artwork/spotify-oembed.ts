import { isSpotifyId } from '../listening/contracts'
import type { ArtworkMetadata } from './normalize'
import {
  ArtworkProviderError,
  fetchArtworkJson,
  fixedArtworkUrl,
  isRecord,
  optionalPositiveInteger,
  type ArtworkFetchLike,
} from './provider'

const DEFAULT_TIMEOUT_MS = 5000
const DEFAULT_MAX_RESPONSE_BYTES = 256 * 1024
const SPOTIFY_IMAGE_CDN_HOST = /^image-cdn-[a-z]+\.spotifycdn\.com$/
const SPOTIFY_IMAGE_PATH = /^\/image\/[0-9A-Za-z]+$/

function isSpotifyImageHost(hostname: string): boolean {
  return hostname === 'i.scdn.co' || SPOTIFY_IMAGE_CDN_HOST.test(hostname)
}

export type SpotifyOEmbedArtworkClient = {
  getArtwork(spotifyId: string): Promise<ArtworkMetadata | null>
}

export function createSpotifyOEmbedArtworkClient({
  fetchLike = fetch,
  timeoutMs = DEFAULT_TIMEOUT_MS,
  maxResponseBytes = DEFAULT_MAX_RESPONSE_BYTES,
}: {
  fetchLike?: ArtworkFetchLike
  timeoutMs?: number
  maxResponseBytes?: number
} = {}): SpotifyOEmbedArtworkClient {
  return {
    async getArtwork(spotifyId) {
      if (!isSpotifyId(spotifyId)) throw new ArtworkProviderError('response', 'spotify_oembed')
      const url = new URL('https://open.spotify.com/oembed')
      url.searchParams.set('url', `https://open.spotify.com/track/${spotifyId}`)
      const payload = await fetchArtworkJson({
        provider: 'spotify_oembed', url, fetchLike, timeoutMs, maxResponseBytes,
      })
      if (payload === null) return null
      if (
        !isRecord(payload)
        || payload.version !== '1.0'
        || payload.provider_name !== 'Spotify'
        || payload.provider_url !== 'https://spotify.com'
        || payload.type !== 'rich'
        || typeof payload.title !== 'string'
        || payload.title.trim() === ''
      ) throw new ArtworkProviderError('response', 'spotify_oembed', 200)

      if (payload.thumbnail_url === null) return null
      const image = fixedArtworkUrl(payload.thumbnail_url, isSpotifyImageHost, SPOTIFY_IMAGE_PATH)
      const width = optionalPositiveInteger(payload.thumbnail_width)
      const height = optionalPositiveInteger(payload.thumbnail_height)
      if (!image || width === undefined || height === undefined) {
        throw new ArtworkProviderError('response', 'spotify_oembed', 200)
      }
      return { url: image.toString(), width, height, bgColor: null }
    },
  }
}
