// A shared mix link, `/m/<token>` (spec 2026-11-13 shared-mixes). The site
// serves /m/* with the app's index.html, so the pathname is read as is. The
// token is opaque: 22 base62 characters, as the shared contract says.
const sharedMixPath = /^\/m\/([A-Za-z0-9]{22})\/?$/

/** The share token when this location is a shared mix link, else null. */
export function sharedMixToken(location: Pick<Location, 'pathname'>): string | null {
  return sharedMixPath.exec(location.pathname)?.[1] ?? null
}
