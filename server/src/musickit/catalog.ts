import {
  parseArtworkMetadata,
  type ArtworkMetadata,
} from '../artwork/normalize'
import { isAppleCatalogId, isAppleSongId } from './apple-id'

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

export type CatalogArtist = {
  id: string
  name: string
  genres: string[]
}

export type AppleCatalogArtistClient = {
  searchArtists(storefront: string, term: string, limit: number): Promise<CatalogArtist[]>
  // One page of an artist's top songs; an unknown artist (404) is an empty list.
  artistTopSongs(storefront: string, artistId: string, limit: number): Promise<CatalogSong[]>
}

export type CatalogAlbum = {
  appleId: string
  upc: string | null
  title: string
  artist: string
  releaseYear: number | null
  trackCount: number | null
  durationMs: number | null
  isSingle: boolean
  isCompilation: boolean
  genre: string | null
  artwork: ArtworkMetadata | null
}

export type AppleCatalogAlbumClient = {
  searchAlbums(storefront: string, term: string, limit: number): Promise<CatalogAlbum[]>
  getAlbums(storefront: string, ids: readonly string[]): Promise<Map<string, CatalogAlbum>>
}

// One page of a chart or a playlist's songs. next is the offset of the
// following page when Apple reports one, else null.
export type CatalogSongPage = { songs: CatalogSong[]; next: number | null }

export type CatalogPlaylist = { id: string; name: string; curator: string | null }

// The catalogue seed's lists (spec 2026-10-21 everyone-gets-a-mix, step 3).
export type AppleCatalogSeedClient = {
  chartSongs(storefront: string, genreId: string | null, limit: number, offset?: number): Promise<CatalogSongPage>
  searchPlaylists(storefront: string, term: string, limit: number): Promise<CatalogPlaylist[]>
  // An unknown playlist (404) is an empty page.
  playlistTracks(storefront: string, playlistId: string, limit: number, offset?: number): Promise<CatalogSongPage>
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
// The album fetch returns the full tracks relationship, so a 100-id batch can
// be large; callers in this codebase pass a handful of ids per turn, so the
// bounded 5 MB read is not a practical concern. Lower this if a caller ever
// needs many albums at once.
const MAX_ALBUM_IDS_PER_REQUEST = 100
const MAX_ALBUM_SEARCH_LIMIT = 10
const MAX_ARTIST_SEARCH_LIMIT = 25
const MAX_TOP_SONGS_LIMIT = 30
const MAX_CHART_LIMIT = 200
const MAX_PLAYLIST_SEARCH_LIMIT = 25
const MAX_PLAYLIST_TRACKS_LIMIT = 100
const MAX_PAGE_OFFSET = 100_000
const MAX_INT32 = 2147483647
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
      && attributes.durationInMillis > 0 && attributes.durationInMillis <= MAX_INT32
      ? attributes.durationInMillis : null,
    genre: Array.isArray(attributes.genreNames) && typeof attributes.genreNames[0] === 'string'
      ? attributes.genreNames[0] : null,
    releaseYear: typeof attributes.releaseDate === 'string' && /^\d{4}(?:-\d{2}-\d{2})?$/.test(attributes.releaseDate)
      ? Number(attributes.releaseDate.slice(0, 4)) : null,
    explicit: attributes.contentRating === 'explicit' ? true : attributes.contentRating === 'clean' ? false : null,
  }
}

function parseArtist(value: unknown): CatalogArtist | null {
  if (!isRecord(value) || value.type !== 'artists' || typeof value.id !== 'string' || !isRecord(value.attributes)) return null
  const attributes = value.attributes
  if (typeof attributes.name !== 'string' || attributes.name.trim().length === 0) return null
  return {
    id: value.id,
    name: attributes.name,
    genres: Array.isArray(attributes.genreNames)
      ? attributes.genreNames.filter((genre): genre is string => typeof genre === 'string')
      : [],
  }
}

// Duplicate ids are ambiguous: drop every copy rather than choose a winner.
function uniqueById<T>(items: Iterable<T | null>, id: (item: T) => string): T[] {
  const parsed = new Map<string, T | null>()
  for (const item of items) {
    if (!item) continue
    const key = id(item)
    parsed.set(key, parsed.has(key) ? null : item)
  }
  return [...parsed.values()].filter((item): item is T => item != null)
}

// Total running time from the album's tracks relationship. Null unless every
// track on a complete (unpaginated) relationship carries a valid duration:
// a partial sum would understate the record.
function albumDurationMs(value: Record<string, unknown>): number | null {
  if (!isRecord(value.relationships) || !isRecord(value.relationships.tracks)) return null
  const relationship = value.relationships.tracks
  if (relationship.next != null || !Array.isArray(relationship.data) || relationship.data.length === 0) return null
  let total = 0
  for (const track of relationship.data) {
    if (!isRecord(track) || !isRecord(track.attributes)) return null
    const duration = track.attributes.durationInMillis
    if (typeof duration !== 'number' || !Number.isInteger(duration) || duration <= 0) return null
    total += duration
    if (total > MAX_INT32) return null
  }
  return total
}

function parseAlbum(value: unknown): CatalogAlbum | null {
  if (!isRecord(value) || value.type !== 'albums' || typeof value.id !== 'string' || !isRecord(value.attributes)) return null
  const attributes = value.attributes
  if (typeof attributes.name !== 'string' || typeof attributes.artistName !== 'string') return null

  return {
    appleId: value.id,
    upc: typeof attributes.upc === 'string' && /^\d{8,14}$/.test(attributes.upc) ? attributes.upc : null,
    title: attributes.name,
    artist: attributes.artistName,
    releaseYear: typeof attributes.releaseDate === 'string' && /^\d{4}(?:-\d{2}-\d{2})?$/.test(attributes.releaseDate)
      ? Number(attributes.releaseDate.slice(0, 4)) : null,
    trackCount: typeof attributes.trackCount === 'number' && Number.isInteger(attributes.trackCount)
      && attributes.trackCount > 0 && attributes.trackCount <= MAX_INT32
      ? attributes.trackCount : null,
    durationMs: albumDurationMs(value),
    isSingle: attributes.isSingle === true,
    isCompilation: attributes.isCompilation === true,
    genre: Array.isArray(attributes.genreNames) && typeof attributes.genreNames[0] === 'string'
      ? attributes.genreNames[0] : null,
    artwork: parseArtworkMetadata(attributes.artwork),
  }
}

function parsePlaylist(value: unknown): CatalogPlaylist | null {
  if (!isRecord(value) || value.type !== 'playlists' || typeof value.id !== 'string' || !isRecord(value.attributes)) return null
  const attributes = value.attributes
  if (typeof attributes.name !== 'string' || attributes.name.trim().length === 0) return null
  return {
    id: value.id,
    name: attributes.name,
    curator: typeof attributes.curatorName === 'string' ? attributes.curatorName : null,
  }
}

// The offset Apple's next link names, when it moves forward from this page.
function nextOffset(next: unknown, offset: number): number | null {
  if (typeof next !== 'string') return null
  let raw: string | null
  try {
    raw = new URL(next, API_ROOT).searchParams.get('offset')
  } catch {
    return null
  }
  if (raw === null || !/^\d+$/.test(raw)) return null
  const value = Number(raw)
  return value > offset ? value : null
}

const validOffset = (offset: number) => Number.isInteger(offset) && offset >= 0 && offset <= MAX_PAGE_OFFSET

function songPage(data: unknown[], next: unknown, offset: number): CatalogSongPage {
  const songs = uniqueById(
    data.map(parseSong).filter((song) => song != null && isAppleSongId(song.appleId)),
    (song) => song.appleId,
  )
  // A page with no entries at all ends the list whatever next says.
  return { songs, next: data.length > 0 ? nextOffset(next, offset) : null }
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
}): AppleCatalogClient & AppleIsrcCatalogClient & AppleCatalogSearchClient & AppleCatalogAlbumClient
  & AppleCatalogArtistClient & AppleCatalogSeedClient {
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

  async function requestBatch(
    storefront: string,
    ids: readonly string[],
    filter = 'ids',
    resource: 'songs' | 'albums' = 'songs',
  ): Promise<unknown> {
    const url = new URL(API_ROOT)
    url.pathname = `/v1/catalog/${encodeURIComponent(storefront)}/${resource}`
    url.searchParams.set(filter, ids.join(','))
    return request(url)
  }

  return {
    async chartSongs(storefront, genreId, limit, offset = 0) {
      if (
        !/^[a-z]{2}$/.test(storefront)
        || (genreId !== null && !/^\d{1,12}$/.test(genreId))
        || !Number.isInteger(limit)
        || limit < 1
        || !validOffset(offset)
      ) throw new AppleCatalogError('response')

      const url = new URL(API_ROOT)
      url.pathname = `/v1/catalog/${encodeURIComponent(storefront)}/charts`
      url.searchParams.set('types', 'songs')
      if (genreId !== null) url.searchParams.set('genre', genreId)
      // Caps on purpose: the seed route pages with its own limit.
      url.searchParams.set('limit', String(Math.min(limit, MAX_CHART_LIMIT)))
      if (offset > 0) url.searchParams.set('offset', String(offset))
      let payload: unknown
      try {
        payload = await request(url)
      } catch (error) {
        // Apple does not chart every subgenre in every storefront: it answers
        // 404, or 400 for a genre it does not chart there. Either is an empty list.
        if (error instanceof AppleCatalogError
          && (error.status === 404 || (error.status === 400 && genreId !== null))) return { songs: [], next: null }
        throw error
      }
      if (!isRecord(payload) || !isRecord(payload.results) || payload.errors != null) {
        throw new AppleCatalogError('response', 200)
      }
      // Apple omits the songs key, or sends no chart, for a genre it does not chart.
      const charts = payload.results.songs
      if (charts === undefined || (Array.isArray(charts) && charts.length === 0)) return { songs: [], next: null }
      if (!Array.isArray(charts) || !isRecord(charts[0]) || !Array.isArray(charts[0].data)) {
        throw new AppleCatalogError('response', 200)
      }
      return songPage(charts[0].data, charts[0].next, offset)
    },
    async searchPlaylists(storefront, term, limit) {
      const normalizedTerm = term.trim()
      if (
        !/^[a-z]{2}$/.test(storefront)
        || normalizedTerm.length < 1
        || normalizedTerm.length > 120
        || !Number.isInteger(limit)
        || limit < 1
      ) throw new AppleCatalogError('response')

      const url = new URL(API_ROOT)
      url.pathname = `/v1/catalog/${encodeURIComponent(storefront)}/search`
      url.searchParams.set('term', normalizedTerm)
      url.searchParams.set('types', 'playlists')
      url.searchParams.set('limit', String(Math.min(limit, MAX_PLAYLIST_SEARCH_LIMIT)))
      const payload = await request(url)
      if (!isRecord(payload) || !isRecord(payload.results) || payload.errors != null) {
        throw new AppleCatalogError('response', 200)
      }
      // Apple omits the playlists key entirely when nothing matches.
      if (payload.results.playlists === undefined) return []
      if (!isRecord(payload.results.playlists) || !Array.isArray(payload.results.playlists.data)) {
        throw new AppleCatalogError('response', 200)
      }
      return uniqueById(
        payload.results.playlists.data.map(parsePlaylist)
          .filter((playlist) => playlist != null && isAppleCatalogId(playlist.id)),
        (playlist) => playlist.id,
      )
    },
    async playlistTracks(storefront, playlistId, limit, offset = 0) {
      if (
        !/^[a-z]{2}$/.test(storefront)
        || !isAppleCatalogId(playlistId)
        // '.' and '..' pass the id pattern but the pathname setter collapses them.
        || /^\.+$/.test(playlistId)
        || !Number.isInteger(limit)
        || limit < 1
        || !validOffset(offset)
      ) throw new AppleCatalogError('response')

      const url = new URL(API_ROOT)
      url.pathname = `/v1/catalog/${encodeURIComponent(storefront)}/playlists/${encodeURIComponent(playlistId)}/tracks`
      url.searchParams.set('limit', String(Math.min(limit, MAX_PLAYLIST_TRACKS_LIMIT)))
      if (offset > 0) url.searchParams.set('offset', String(offset))
      let payload: unknown
      try {
        payload = await request(url)
      } catch (error) {
        if (error instanceof AppleCatalogError && error.status === 404) return { songs: [], next: null }
        throw error
      }
      if (!isRecord(payload) || !Array.isArray(payload.data) || payload.errors != null) {
        throw new AppleCatalogError('response', 200)
      }
      return songPage(payload.data, payload.next, offset)
    },
    async searchArtists(storefront, term, limit) {
      const normalizedTerm = term.trim()
      if (
        !/^[a-z]{2}$/.test(storefront)
        || normalizedTerm.length < 1
        || normalizedTerm.length > 120
        || !Number.isInteger(limit)
        || limit < 1
      ) throw new AppleCatalogError('response')

      const url = new URL(API_ROOT)
      url.pathname = `/v1/catalog/${encodeURIComponent(storefront)}/search`
      url.searchParams.set('term', normalizedTerm)
      url.searchParams.set('types', 'artists')
      // Caps on purpose (searchSongs rejects): the fill calls this with small fixed limits.
      url.searchParams.set('limit', String(Math.min(limit, MAX_ARTIST_SEARCH_LIMIT)))
      const payload = await request(url)
      if (!isRecord(payload) || !isRecord(payload.results) || payload.errors != null) {
        throw new AppleCatalogError('response', 200)
      }
      // Apple omits the artists key entirely when nothing matches.
      if (payload.results.artists === undefined) return []
      if (!isRecord(payload.results.artists) || !Array.isArray(payload.results.artists.data)) {
        throw new AppleCatalogError('response', 200)
      }
      return uniqueById(
        payload.results.artists.data.map(parseArtist).filter((artist) => artist != null && isAppleCatalogId(artist.id)),
        (artist) => artist.id,
      )
    },
    async artistTopSongs(storefront, artistId, limit) {
      if (
        !/^[a-z]{2}$/.test(storefront)
        || !isAppleCatalogId(artistId)
        // '.' and '..' pass the id pattern but the pathname setter collapses them.
        || /^\.+$/.test(artistId)
        || !Number.isInteger(limit)
        || limit < 1
      ) throw new AppleCatalogError('response')

      const url = new URL(API_ROOT)
      url.pathname = `/v1/catalog/${encodeURIComponent(storefront)}/artists/${encodeURIComponent(artistId)}/view/top-songs`
      // Caps on purpose (searchSongs rejects): the fill calls this with small fixed limits.
      url.searchParams.set('limit', String(Math.min(limit, MAX_TOP_SONGS_LIMIT)))
      let payload: unknown
      try {
        payload = await request(url)
      } catch (error) {
        if (error instanceof AppleCatalogError && error.status === 404) return []
        throw error
      }
      // One page only; `next` is ignored because callers take the top N.
      if (!isRecord(payload) || !Array.isArray(payload.data) || payload.errors != null) {
        throw new AppleCatalogError('response', 200)
      }
      return uniqueById(
        payload.data.map(parseSong).filter((song) => song != null && isAppleSongId(song.appleId)),
        (song) => song.appleId,
      )
    },
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
    async searchAlbums(storefront, term, limit) {
      const normalizedTerm = term.trim()
      if (
        !/^[a-z]{2}$/.test(storefront)
        || normalizedTerm.length < 1
        || normalizedTerm.length > 120
        || !Number.isInteger(limit)
        || limit < 1
        || limit > MAX_ALBUM_SEARCH_LIMIT
      ) throw new AppleCatalogError('response')

      const url = new URL(API_ROOT)
      url.pathname = `/v1/catalog/${encodeURIComponent(storefront)}/search`
      url.searchParams.set('term', normalizedTerm)
      url.searchParams.set('types', 'albums')
      url.searchParams.set('limit', String(limit))
      const payload = await request(url)
      if (!isRecord(payload) || !isRecord(payload.results) || payload.errors != null) {
        throw new AppleCatalogError('response', 200)
      }
      // Apple omits the albums key entirely when nothing matches.
      if (payload.results.albums === undefined) return []
      if (!isRecord(payload.results.albums) || !Array.isArray(payload.results.albums.data)) {
        throw new AppleCatalogError('response', 200)
      }

      const parsed = new Map<string, CatalogAlbum | null>()
      for (const value of payload.results.albums.data) {
        const album = parseAlbum(value)
        if (!album || !isAppleCatalogId(album.appleId)) continue
        parsed.set(album.appleId, parsed.has(album.appleId) ? null : album)
      }
      return [...parsed.values()].filter((album): album is CatalogAlbum => album != null)
    },
    async getAlbums(storefront, ids) {
      const requestedIds = [...new Set(ids.filter(isAppleCatalogId))]
      const albums = new Map<string, CatalogAlbum>()

      for (let offset = 0; offset < requestedIds.length; offset += MAX_ALBUM_IDS_PER_REQUEST) {
        const batch = requestedIds.slice(offset, offset + MAX_ALBUM_IDS_PER_REQUEST)
        const requested = new Set(batch)
        const seen = new Set<string>()
        const payload = await requestBatch(storefront, batch, 'ids', 'albums')
        if (!isRecord(payload) || !Array.isArray(payload.data)) {
          throw new AppleCatalogError('response', 200)
        }
        for (const value of payload.data) {
          if (!isRecord(value) || typeof value.id !== 'string' || !requested.has(value.id)) continue
          if (seen.has(value.id)) { albums.delete(value.id); continue }
          seen.add(value.id)
          const parsed = parseAlbum(value)
          if (parsed && requested.has(parsed.appleId)) albums.set(parsed.appleId, parsed)
        }
      }

      return albums
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
