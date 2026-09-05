import type { ArtworkMetadata } from './normalize'
import {
  ArtworkProviderError,
  fetchArtworkJson,
  fixedArtworkUrl,
  isRecord,
  type ArtworkFetchLike,
} from './provider'

export { ArtworkProviderError } from './provider'

const DEFAULT_TIMEOUT_MS = 5000
const DEFAULT_MAX_RESPONSE_BYTES = 256 * 1024
const ISRC_PATTERN = /^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$/
const DEEZER_COVER_PATH = /^\/images\/cover\/[0-9A-Za-z]+\/(\d+)x(\d+)-[0-9A-Za-z-]+\.(?:jpg|jpeg|png)$/

export type DeezerArtworkClient = {
  getArtwork(isrc: string): Promise<ArtworkMetadata | null>
}

export function createDeezerArtworkClient({
  fetchLike = fetch,
  timeoutMs = DEFAULT_TIMEOUT_MS,
  maxResponseBytes = DEFAULT_MAX_RESPONSE_BYTES,
}: {
  fetchLike?: ArtworkFetchLike
  timeoutMs?: number
  maxResponseBytes?: number
} = {}): DeezerArtworkClient {
  return {
    async getArtwork(value) {
      const isrc = value.toUpperCase()
      if (!ISRC_PATTERN.test(isrc)) throw new ArtworkProviderError('response', 'deezer')
      const url = new URL(`https://api.deezer.com/track/isrc:${isrc}`)
      const payload = await fetchArtworkJson({
        provider: 'deezer', url, fetchLike, timeoutMs, maxResponseBytes,
      })
      if (payload === null) return null
      if (isRecord(payload) && isRecord(payload.error) && payload.error.code === 800) return null
      if (
        !isRecord(payload)
        || !Number.isInteger(payload.id)
        || typeof payload.title !== 'string'
        || payload.title.trim() === ''
        || typeof payload.isrc !== 'string'
        || payload.isrc.toUpperCase() !== isrc
        || !isRecord(payload.artist)
        || typeof payload.artist.name !== 'string'
        || payload.artist.name.trim() === ''
        || !isRecord(payload.album)
      ) throw new ArtworkProviderError('response', 'deezer', 200)

      const image = fixedArtworkUrl(
        payload.album.cover_xl,
        'e-cdns-images.dzcdn.net',
        DEEZER_COVER_PATH,
      )
      const dimensions = image && DEEZER_COVER_PATH.exec(image.pathname)
      const width = dimensions ? Number(dimensions[1]) : 0
      const height = dimensions ? Number(dimensions[2]) : 0
      if (!image || !Number.isInteger(width) || width <= 0 || width > 4096
        || !Number.isInteger(height) || height <= 0 || height > 4096) {
        throw new ArtworkProviderError('response', 'deezer', 200)
      }
      return { url: image.toString(), width, height, bgColor: null }
    },
  }
}
