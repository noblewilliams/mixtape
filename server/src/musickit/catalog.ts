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
  durationMs?: number | null
  genre?: string | null
  releaseYear?: number | null
  explicit?: boolean | null
}

export type AppleCatalogClient = {
  getSongs(storefront: string, appleIds: readonly string[]): Promise<Map<string, CatalogSong>>
}

export type AppleIsrcCatalogClient = {
  getSongsByIsrc(storefront: string, isrcs: readonly string[]): Promise<Map<string, CatalogSong[]>>
}

export type AppleCatalogSearchClient = {
  searchSongs(storefront: string, term: string, limit: number): Promise<CatalogSong[]>
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
const MAX_ISRCS_PER_REQUEST = 25
const DEFAULT_TIMEOUT_MS = 5000
const DEFAULT_MAX_RESPONSE_BYTES = 5 * 1024 * 1024
const TOKEN_REFRESH_MARGIN_SECONDS = 60

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function parseSong(value: unknown): CatalogSong | null {
  if (!isRecord(value) || value.type !== 'songs' || typeof value.id !== 'string' || !isRecord(value.attributes)) return null
  const attributes = value.attributes
  if (typeof attributes.name !== 'string' || typeof attributes.artistName !== 'string') return null

  return {
    appleId: value.id,
    isrc: typeof attributes.isrc === 'string' ? attributes.isrc : null,
    title: attributes.name,
    artist: attributes.artistName,
    album: typeof attributes.albumName === 'string' ? attributes.albumName : null,
    artwork: parseArtworkMetadata(attributes.artwork),
    durationMs: typeof attributes.durationInMillis === 'number'
      && Number.isInteger(attributes.durationInMillis)
      && attributes.durationInMillis > 0 && attributes.durationInMillis <= 2147483647
      ? attributes.durationInMillis : null,
    genre: Array.isArray(attributes.genreNames) && typeof attributes.genreNames[0] === 'string'
      ? attributes.genreNames[0] : null,
    releaseYear: typeof attributes.releaseDate === 'string' && /^\d{4}(?:-\d{2}-\d{2})?$/.test(attributes.releaseDate)
      ? Number(attributes.releaseDate.slice(0, 4)) : null,
    explicit: attributes.contentRating === 'explicit' ? true : attributes.contentRating === 'clean' ? false : null,
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
}): AppleCatalogClient & AppleIsrcCatalogClient & AppleCatalogSearchClient {
  async function token(): Promise<string> {
    let cachedToken = tokenCache.get(tokenCacheKey)
    if (!cachedToken || cachedToken.expiresAt - TOKEN_REFRESH_MARGIN_SECONDS <= nowSeconds()) {
      cachedToken = await issueServerToken()
      tokenCache.set(tokenCacheKey, cachedToken)
    }
    return cachedToken.developerToken
  }

  async function request(url: URL): Promise<unknown> {
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

  async function requestBatch(storefront: string, ids: readonly string[], filter = 'ids'): Promise<unknown> {
    const url = new URL(API_ROOT)
    url.pathname = `/v1/catalog/${encodeURIComponent(storefront)}/songs`
    url.searchParams.set(filter, ids.join(','))
    return request(url)
  }

  return {
    async searchSongs(storefront, term, limit) {
      const normalizedTerm = term.trim()
      if (
        !/^[a-z]{2}$/.test(storefront)
        || normalizedTerm.length < 1
        || normalizedTerm.length > 120
        || !Number.isInteger(limit)
        || limit < 1
        || limit > 25
      ) throw new AppleCatalogError('response')

      const url = new URL(API_ROOT)
      url.pathname = `/v1/catalog/${encodeURIComponent(storefront)}/search`
      url.searchParams.set('term', normalizedTerm)
      url.searchParams.set('types', 'songs')
      url.searchParams.set('limit', String(limit))
      const payload = await request(url)
      if (
        !isRecord(payload)
        || !isRecord(payload.results)
        || !isRecord(payload.results.songs)
        || !Array.isArray(payload.results.songs.data)
        || payload.errors != null
      ) throw new AppleCatalogError('response', 200)

      const parsed = new Map<string, CatalogSong | null>()
      for (const value of payload.results.songs.data) {
        const song = parseSong(value)
        if (!song || !isAppleSongId(song.appleId)) continue
        parsed.set(song.appleId, parsed.has(song.appleId) ? null : song)
      }
      return [...parsed.values()].filter((song): song is CatalogSong => song != null)
    },
    async getSongsByIsrc(storefront, isrcs) {
      const requested = [...new Set(isrcs.map(value => value.toUpperCase())
        .filter(value => /^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$/.test(value)))]
      const songs = new Map<string, CatalogSong[]>()
      for (let offset = 0; offset < requested.length; offset += MAX_ISRCS_PER_REQUEST) {
        const batch = requested.slice(offset, offset + MAX_ISRCS_PER_REQUEST)
        const payload = await requestBatch(storefront, batch, 'filter[isrc]')
        if (!isRecord(payload) || !Array.isArray(payload.data)
          || payload.next != null || payload.errors != null) throw new AppleCatalogError('response', 200)
        const seen = new Set<string>()
        for (const value of payload.data) {
          const parsed = parseSong(value)
          const isrc = parsed?.isrc?.toUpperCase()
          // A malformed or partial result could hide a second match. Fail the
          // lookup rather than turn incomplete evidence into an exact identity.
          if (!parsed || !isrc || !/^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$/.test(isrc)
            || !isAppleSongId(parsed.appleId) || seen.has(parsed.appleId)) {
            throw new AppleCatalogError('response', 200)
          }
          seen.add(parsed.appleId)
          if (batch.includes(isrc)) {
            songs.set(isrc, [...(songs.get(isrc) ?? []), { ...parsed, isrc }])
          }
        }
      }
      return songs
    },
    async getSongs(storefront, appleIds) {
      const requestedIds = [...new Set(appleIds.filter(isAppleSongId))]
      const songs = new Map<string, CatalogSong>()

      for (let offset = 0; offset < requestedIds.length; offset += MAX_IDS_PER_REQUEST) {
        const batch = requestedIds.slice(offset, offset + MAX_IDS_PER_REQUEST)
        const requested = new Set(batch)
        const seen = new Set<string>()
        const payload = await requestBatch(storefront, batch)
        if (!isRecord(payload) || !Array.isArray(payload.data)) {
          throw new AppleCatalogError('response', 200)
        }
        for (const value of payload.data) {
          if (!isRecord(value) || typeof value.id !== 'string' || !requested.has(value.id)) continue
          if (seen.has(value.id)) { songs.delete(value.id); continue }
          seen.add(value.id)
          const parsed = parseSong(value)
          if (parsed && requested.has(parsed.appleId)) songs.set(parsed.appleId, parsed)
        }
      }

      return songs
    },
  }
}
