// MusicKit exposes catalog identifiers as opaque strings. Keep only bounded
// RFC 3986 unreserved characters so IDs remain safe inside Apple's comma-
// separated query parameter without assuming today's values stay numeric.
// The rule is the same for every catalog resource type (songs, albums, ...).
export const APPLE_CATALOG_ID_PATTERN = /^[A-Za-z0-9._~-]{1,128}$/
export const APPLE_SONG_ID_PATTERN = APPLE_CATALOG_ID_PATTERN

export function isAppleCatalogId(value: string): boolean {
  return APPLE_CATALOG_ID_PATTERN.test(value)
}

export const isAppleSongId = isAppleCatalogId
