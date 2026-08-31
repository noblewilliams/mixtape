import {
  parseArtworkMetadata,
  type ArtworkMetadata,
} from '../artwork/normalize'
import { isAppleSongId } from './apple-id'

export { parseArtworkMetadata } from '../artwork/normalize'
export type { ArtworkMetadata } from '../artwork/normalize'

export type FetchLike = (url: string | URL, init?: RequestInit) => Promise<Response>

export type CatalogSong = {
  appleId: string
  isrc: string | null
  title: string
  artist: string
  album: string | null
  artwork: ArtworkMetadata | null
}

export type AppleCatalogClient = {
  getSongs(storefront: string, appleIds: readonly string[]): Promise<Map<string, CatalogSong>>
}

export type AppleCatalogErrorCategory =
  | 'authorization'
  | 'rate_limit'
  | 'upstream'
  | 'timeout'
  | 'network'
  | 'response'

export class AppleCatalogError extends Error {
  constructor(
    readonly category: AppleCatalogErrorCategory,
    readonly status?: number,
  ) {
    super(status === undefined ? `apple_catalog:${category}` : `apple_catalog:${category}:${status}`)
    this.name = 'AppleCatalogError'
  }
}

export type AppleCatalogToken = { developerToken: string; expiresAt: number }
export type AppleCatalogTokenCache = {
  get(key: string): AppleCatalogToken | undefined
  set(key: string, token: AppleCatalogToken): void
}

export function createAppleCatalogTokenCache(): AppleCatalogTokenCache {
  const tokens = new Map<string, AppleCatalogToken>()
  return {
    get: (key) => tokens.get(key),
    set: (key, token) => tokens.set(key, token),
  }
}

const API_ROOT = 'https://api.music.apple.com'
const MAX_IDS_PER_REQUEST = 300
const DEFAULT_TIMEOUT_MS = 5000
const DEFAULT_MAX_RESPONSE_BYTES = 5 * 1024 * 1024
const TOKEN_REFRESH_MARGIN_SECONDS = 60

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function parseSong(value: unknown): CatalogSong | null {
  if (!isRecord(value) || typeof value.id !== 'string' || !isRecord(value.attributes)) return null
  const attributes = value.attributes
  if (typeof attributes.name !== 'string' || typeof attributes.artistName !== 'string') return null

  return {
    appleId: value.id,
    isrc: typeof attributes.isrc === 'string' ? attributes.isrc : null,
    title: attributes.name,
    artist: attributes.artistName,
    album: typeof attributes.albumName === 'string' ? attributes.albumName : null,
    artwork: parseArtworkMetadata(attributes.artwork),
  }
}

function categoryForStatus(status: number): AppleCatalogErrorCategory {
  if (status === 401 || status === 403) return 'authorization'
  if (status === 429) return 'rate_limit'
  return 'upstream'
}

async function parseBoundedJson(response: Response, maxBytes: number): Promise<unknown> {
  if (!response.body) throw new AppleCatalogError('response', response.status)

  const reader = response.body.getReader()
  const chunks: Uint8Array[] = []
  let totalBytes = 0
  try {
    while (true) {
      const { done, value } = await reader.read()
      if (done) break
      totalBytes += value.byteLength
      if (totalBytes > maxBytes) {
        await reader.cancel()
        throw new AppleCatalogError('response', response.status)
      }
      chunks.push(value)
    }
  } catch (error) {
    if (error instanceof AppleCatalogError) throw error
    try {
      await reader.cancel()
    } catch {
      // Cancellation is best-effort after an upstream stream error.
    }
    throw error
  } finally {
    reader.releaseLock()
  }

  const bytes = new Uint8Array(totalBytes)
  let offset = 0
  for (const chunk of chunks) {
    bytes.set(chunk, offset)
    offset += chunk.byteLength
  }
  return JSON.parse(new TextDecoder().decode(bytes))
}

export function createAppleCatalogClient({
  fetchLike,
  issueServerToken,
  nowSeconds = () => Math.floor(Date.now() / 1000),
  timeoutMs = DEFAULT_TIMEOUT_MS,
  maxResponseBytes = DEFAULT_MAX_RESPONSE_BYTES,
  tokenCache = createAppleCatalogTokenCache(),
  tokenCacheKey = 'client',
}: {
  fetchLike: FetchLike
  issueServerToken: () => Promise<AppleCatalogToken>
  nowSeconds?: () => number
  timeoutMs?: number
  maxResponseBytes?: number
  tokenCache?: AppleCatalogTokenCache
  tokenCacheKey?: string
}): AppleCatalogClient {
  async function token(): Promise<string> {
    let cachedToken = tokenCache.get(tokenCacheKey)
    if (!cachedToken || cachedToken.expiresAt - TOKEN_REFRESH_MARGIN_SECONDS <= nowSeconds()) {
      cachedToken = await issueServerToken()
      tokenCache.set(tokenCacheKey, cachedToken)
    }
    return cachedToken.developerToken
  }

  async function requestBatch(storefront: string, ids: readonly string[]): Promise<unknown> {
    const url = new URL(API_ROOT)
    url.pathname = `/v1/catalog/${encodeURIComponent(storefront)}/songs`
    url.searchParams.set('ids', ids.join(','))

    let developerToken: string
    try {
      developerToken = await token()
    } catch {
      throw new AppleCatalogError('authorization')
    }

    const controller = new AbortController()
    const timeout = setTimeout(() => controller.abort(), timeoutMs)
    let phase: 'fetch' | 'response' = 'fetch'
    try {
      const response = await fetchLike(url, {
        headers: { Authorization: `Bearer ${developerToken}` },
        signal: controller.signal,
      })
      phase = 'response'

      if (!response.ok) {
        try {
          await response.body?.cancel()
        } catch {
          // The typed HTTP category is authoritative even if cancellation fails.
        }
        throw new AppleCatalogError(categoryForStatus(response.status), response.status)
      }
      return await parseBoundedJson(response, maxResponseBytes)
    } catch (error) {
      if (error instanceof AppleCatalogError) throw error
      if (controller.signal.aborted) throw new AppleCatalogError('timeout')
      throw new AppleCatalogError(phase === 'fetch' ? 'network' : 'response', phase === 'response' ? 200 : undefined)
    } finally {
      clearTimeout(timeout)
    }
  }

  return {
    async getSongs(storefront, appleIds) {
      const requestedIds = [...new Set(appleIds.filter(isAppleSongId))]
      const requested = new Set(requestedIds)
      const songs = new Map<string, CatalogSong>()

      for (let offset = 0; offset < requestedIds.length; offset += MAX_IDS_PER_REQUEST) {
        const payload = await requestBatch(storefront, requestedIds.slice(offset, offset + MAX_IDS_PER_REQUEST))
        if (!isRecord(payload) || !Array.isArray(payload.data)) {
          throw new AppleCatalogError('response', 200)
        }
        for (const value of payload.data) {
          const parsed = parseSong(value)
          if (parsed && requested.has(parsed.appleId)) songs.set(parsed.appleId, parsed)
        }
      }

      return songs
    },
  }
}
