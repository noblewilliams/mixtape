export type ArtworkMetadata = {
  url: string
  width: number | null
  height: number | null
  bgColor: string | null
}

export type NullableArtworkMetadata = Omit<ArtworkMetadata, 'url'> & {
  url: string | null
}

export const MAX_ARTWORK_URL_LENGTH = 2048

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function optionalPositiveInteger(value: unknown): number | null | undefined {
  if (value === undefined || value === null) return null
  if (!Number.isInteger(value) || (value as number) <= 0) return undefined
  return value as number
}

function optionalBackgroundColor(value: unknown): string | null | undefined {
  if (value === undefined || value === null) return null
  if (typeof value !== 'string' || !/^[0-9a-fA-F]{6}$/.test(value)) return undefined
  return value.toLowerCase()
}

export function parseNullableArtworkMetadata(value: unknown): NullableArtworkMetadata | null {
  if (!isRecord(value) || (value.url !== null && typeof value.url !== 'string')) return null

  const width = optionalPositiveInteger(value.width)
  const height = optionalPositiveInteger(value.height)
  const bgColor = optionalBackgroundColor(value.bgColor)
  if (width === undefined || height === undefined || bgColor === undefined) return null

  if (value.url === null) return { url: null, width, height, bgColor }
  if (value.url.length === 0 || value.url.length > MAX_ARTWORK_URL_LENGTH) return null

  let parsedUrl: URL
  try {
    parsedUrl = new URL(value.url)
  } catch {
    return null
  }

  const isAppleCdn =
    parsedUrl.hostname === 'mzstatic.com' || parsedUrl.hostname.endsWith('.mzstatic.com')
  if (
    parsedUrl.protocol !== 'https:' ||
    !isAppleCdn ||
    parsedUrl.username !== '' ||
    parsedUrl.password !== '' ||
    parsedUrl.port !== ''
  ) {
    return null
  }

  const hasWidthToken = value.url.includes('{w}')
  const hasHeightToken = value.url.includes('{h}')
  if (hasWidthToken !== hasHeightToken) return null

  return { url: value.url, width, height, bgColor }
}

export function parseArtworkMetadata(value: unknown): ArtworkMetadata | null {
  const parsed = parseNullableArtworkMetadata(value)
  return parsed?.url == null ? null : { ...parsed, url: parsed.url }
}
