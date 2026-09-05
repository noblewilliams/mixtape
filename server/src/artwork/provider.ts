import { MAX_ARTWORK_URL_LENGTH } from './normalize'

export type ArtworkFetchLike = (url: string | URL, init?: RequestInit) => Promise<Response>
export type ArtworkProvider = 'spotify_oembed' | 'deezer'
export type ArtworkProviderErrorCategory =
  | 'authorization'
  | 'rate_limit'
  | 'upstream'
  | 'timeout'
  | 'network'
  | 'response'

export class ArtworkProviderError extends Error {
  constructor(
    readonly category: ArtworkProviderErrorCategory,
    readonly provider: ArtworkProvider,
    readonly status?: number,
  ) {
    super(status === undefined ? `${provider}:${category}` : `${provider}:${category}:${status}`)
    this.name = 'ArtworkProviderError'
  }
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

export function optionalPositiveInteger(value: unknown): number | null | undefined {
  if (value === null || value === undefined) return null
  if (!Number.isInteger(value) || (value as number) <= 0 || (value as number) > 2147483647) {
    return undefined
  }
  return value as number
}

export function fixedArtworkUrl(
  value: unknown,
  host: string,
  pathPattern: RegExp,
): URL | null {
  if (typeof value !== 'string' || value.length === 0 || value.length > MAX_ARTWORK_URL_LENGTH) {
    return null
  }
  try {
    const url = new URL(value)
    if (
      url.protocol !== 'https:'
      || url.hostname !== host
      || url.username !== ''
      || url.password !== ''
      || url.port !== ''
      || url.search !== ''
      || url.hash !== ''
      || !pathPattern.test(url.pathname)
    ) return null
    return url
  } catch {
    return null
  }
}

function categoryForStatus(status: number): ArtworkProviderErrorCategory {
  if (status === 401 || status === 403) return 'authorization'
  if (status === 429) return 'rate_limit'
  return 'upstream'
}

async function boundedJson(
  response: Response,
  provider: ArtworkProvider,
  maxResponseBytes: number,
): Promise<unknown> {
  if (!response.body) throw new ArtworkProviderError('response', provider, response.status)
  const reader = response.body.getReader()
  const chunks: Uint8Array[] = []
  let total = 0
  try {
    while (true) {
      const { done, value } = await reader.read()
      if (done) break
      total += value.byteLength
      if (total > maxResponseBytes) {
        await reader.cancel().catch(() => undefined)
        throw new ArtworkProviderError('response', provider, response.status)
      }
      chunks.push(value)
    }
  } catch (error) {
    if (error instanceof ArtworkProviderError) throw error
    try { await reader.cancel() } catch { /* best-effort stream cleanup */ }
    // The outer request scope distinguishes a body timeout from another
    // malformed/failed response without retaining the stream's error detail.
    throw error
  } finally {
    reader.releaseLock()
  }

  const bytes = new Uint8Array(total)
  let offset = 0
  for (const chunk of chunks) {
    bytes.set(chunk, offset)
    offset += chunk.byteLength
  }
  try {
    return JSON.parse(new TextDecoder().decode(bytes)) as unknown
  } catch {
    throw new ArtworkProviderError('response', provider, response.status)
  }
}

export async function fetchArtworkJson({
  provider,
  url,
  fetchLike,
  timeoutMs,
  maxResponseBytes,
  missingStatuses = [404],
}: {
  provider: ArtworkProvider
  url: URL
  fetchLike: ArtworkFetchLike
  timeoutMs: number
  maxResponseBytes: number
  missingStatuses?: readonly number[]
}): Promise<unknown | null> {
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), timeoutMs)
  let phase: 'fetch' | 'response' = 'fetch'
  try {
    const response = await fetchLike(url, { signal: controller.signal })
    phase = 'response'

    if (missingStatuses.includes(response.status)) {
      await response.body?.cancel().catch(() => undefined)
      return null
    }
    if (!response.ok) {
      await response.body?.cancel().catch(() => undefined)
      throw new ArtworkProviderError(categoryForStatus(response.status), provider, response.status)
    }
    return await boundedJson(response, provider, maxResponseBytes)
  } catch (error) {
    if (error instanceof ArtworkProviderError) throw error
    if (controller.signal.aborted) throw new ArtworkProviderError('timeout', provider)
    throw new ArtworkProviderError(phase === 'fetch' ? 'network' : 'response', provider)
  } finally {
    clearTimeout(timeout)
  }
}
