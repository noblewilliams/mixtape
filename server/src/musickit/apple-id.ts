// MusicKit exposes catalog identifiers as opaque strings. Keep only bounded
// RFC 3986 unreserved characters so IDs remain safe inside Apple's comma-
// separated query parameter without assuming today's values stay numeric.
export const APPLE_SONG_ID_PATTERN = /^[A-Za-z0-9._~-]{1,128}$/

export function isAppleSongId(value: string): boolean {
  return APPLE_SONG_ID_PATTERN.test(value)
}
