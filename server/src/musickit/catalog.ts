import {
  parseArtworkMetadata,
  type ArtworkMetadata,
} from '../artwork/normalize'

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

type TokenResult = { developerToken: string; expiresAt: number }

const API_ROOT = 'https://api.music.apple.com'
const MAX_IDS_PER_REQUEST = 300
const DEFAULT_TIMEOUT_MS = 5000
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

export function createAppleCatalogClient({
  fetchLike,
  issueServerToken,
  nowSeconds = () => Math.floor(Date.now() / 1000),
  timeoutMs = DEFAULT_TIMEOUT_MS,
}: {
  fetchLike: FetchLike
  issueServerToken: () => Promise<TokenResult>
  nowSeconds?: () => number
  timeoutMs?: number
}): AppleCatalogClient {
  let cachedToken: TokenResult | undefined

  async function token(): Promise<string> {
    if (!cachedToken || cachedToken.expiresAt - TOKEN_REFRESH_MARGIN_SECONDS <= nowSeconds()) {
      cachedToken = await issueServerToken()
    }
    return cachedToken.developerToken
  }

  async function requestBatch(storefront: string, ids: readonly string[]): Promise<unknown> {
    const url = new URL(API_ROOT)
    url.pathname = `/v1/catalog/${encodeURIComponent(storefront)}/songs`
    url.searchParams.set('ids', ids.join(','))

    const controller = new AbortController()
    const timeout = setTimeout(() => controller.abort(), timeoutMs)
    let response: Response
    try {
      response = await fetchLike(url, {
        headers: { Authorization: `Bearer ${await token()}` },
        signal: controller.signal,
      })
    } catch {
      throw new AppleCatalogError(controller.signal.aborted ? 'timeout' : 'network')
    } finally {
      clearTimeout(timeout)
    }

    if (!response.ok) throw new AppleCatalogError(categoryForStatus(response.status), response.status)
    try {
      return await response.json()
    } catch {
      throw new AppleCatalogError('response', response.status)
    }
  }

  return {
    async getSongs(storefront, appleIds) {
      const requestedIds = [...new Set(appleIds.filter((id) => id.length > 0))]
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
