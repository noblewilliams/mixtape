export type MusicSnapshotProgress = {
  stage: 'library_songs' | 'playlists' | 'playlist_tracks' | 'recent_tracks' | 'complete'
  completed: number
  total?: number
}

export type LibrarySongSnapshot = {
  ordinal: number
  appleLibraryId: string | null
  appleCatalogId: string
  title: string
  artist: string
  album: string | null
  genre: string | null
  releaseYear: number | null
  explicit: boolean | null
  playCount: null
  lastPlayedAt: null
  dateAdded: number | null
}

export type PlaylistSnapshot = {
  ordinal: number
  appleLibraryId: string
  appleCatalogId: string | null
  name: string
  description: string | null
  curatorName: string | null
  artworkUrlTemplate: string | null
  artworkWidth: number | null
  artworkHeight: number | null
  artworkBgColor: string | null
  kind: 'user' | 'editorial' | 'external' | 'personal_mix' | 'replay' | 'user_shared' | 'unknown'
  canEdit: boolean
  appleDateAdded: number | null
  appleLastModifiedAt: number | null
  sourceFingerprint: string
  entryCount: number
}

export type PlaylistEntrySnapshot = {
  playlistAppleId: string
  position: number
  appleLibraryEntryId: string
  appleLibraryTrackId: string | null
  appleCatalogId: string | null
  /** Set by the Spotify export sync; MusicKit entries leave it out (server default null). */
  spotifyId?: string | null
  isrcSnapshot: string | null
  titleSnapshot: string
  artistSnapshot: string
  albumSnapshot: string | null
  durationMsSnapshot: number | null
  artworkUrlTemplateSnapshot: string | null
  artworkWidthSnapshot: number | null
  artworkHeightSnapshot: number | null
  artworkBgColorSnapshot: string | null
}

export type MusicSnapshot = {
  storefront: string
  songs: LibrarySongSnapshot[]
  playlists: PlaylistSnapshot[]
  playlistEntries: PlaylistEntrySnapshot[]
  recentCatalogIds: string[]
  excludedLibrarySongs: number
}

type ApplePage = {
  data: unknown[]
  next?: string
  meta?: { total?: number }
}

type FetchMusicSnapshotOptions = {
  request: (path: string, signal: AbortSignal) => Promise<ApplePage>
  signal: AbortSignal
  onProgress: (progress: MusicSnapshotProgress) => void
}

type AppleResource = {
  id: string
  type: string
  attributes: Record<string, unknown>
  relationships: Record<string, unknown>
}

const MAX_LIBRARY_SONGS = 100_000
const MAX_PLAYLISTS = 2_000
const MAX_PLAYLIST_ENTRIES = 100_000
const MAX_RECENT_TRACKS = 30
const CATALOG_ID_RE = /^[A-Za-z0-9._~-]{1,128}$/
const ISRC_RE = /^[A-Z]{2}[A-Z0-9]{3}\d{7}$/

function record(value: unknown): Record<string, unknown> {
  return typeof value === 'object' && value !== null ? value as Record<string, unknown> : {}
}

function resource(value: unknown): AppleResource | null {
  const valueRecord = record(value)
  if (typeof valueRecord.id !== 'string' || typeof valueRecord.type !== 'string') return null
  return {
    id: valueRecord.id,
    type: valueRecord.type,
    attributes: record(valueRecord.attributes),
    relationships: record(valueRecord.relationships),
  }
}

function nonempty(value: unknown): string | null {
  return typeof value === 'string' && value.trim() ? value.trim() : null
}

function nullableInteger(value: unknown): number | null {
  return typeof value === 'number' && Number.isInteger(value) && value >= 0
    ? value
    : null
}

function timestamp(value: unknown): number | null {
  if (typeof value !== 'string') return null
  const parsed = Date.parse(value)
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : null
}

function releaseYear(value: unknown): number | null {
  if (typeof value !== 'string') return null
  const match = /^(\d{4})/.exec(value)
  if (!match) return null
  const parsed = Number(match[1])
  return parsed >= 1900 && parsed <= 3000 ? parsed : null
}

function contentRating(value: unknown): boolean | null {
  if (value === 'explicit') return true
  if (value === 'clean') return false
  return null
}

function catalogId(value: AppleResource): string | null {
  if (value.type === 'songs' && CATALOG_ID_RE.test(value.id)) return value.id
  const playParams = record(value.attributes.playParams)
  if (typeof playParams.catalogId === 'string' && CATALOG_ID_RE.test(playParams.catalogId)) {
    return playParams.catalogId
  }
  const catalog = record(value.relationships.catalog)
  const data = Array.isArray(catalog.data) ? catalog.data : []
  const related = resource(data[0])
  return related && CATALOG_ID_RE.test(related.id) ? related.id : null
}

function description(attributes: Record<string, unknown>): string | null {
  const value = attributes.description
  if (typeof value === 'string') return nonempty(value)
  const standard = nonempty(record(value).standard)
  return standard ?? nonempty(record(value).short)
}

function artwork(attributes: Record<string, unknown>) {
  const value = record(attributes.artwork)
  const bgColor = typeof value.bgColor === 'string' && /^[0-9a-f]{6}$/i.test(value.bgColor)
    ? value.bgColor.toLowerCase()
    : null
  return {
    url: nonempty(value.url),
    width: nullableInteger(value.width),
    height: nullableInteger(value.height),
    bgColor,
  }
}

function playlistKind(attributes: Record<string, unknown>, canEdit: boolean): PlaylistSnapshot['kind'] {
  if (canEdit) return 'user'
  const value = nonempty(attributes.kind)?.replaceAll('-', '_')
  if (value === 'editorial' || value === 'external' || value === 'personal_mix'
    || value === 'replay' || value === 'user_shared') return value
  return 'unknown'
}

function normalizeLibrarySong(value: AppleResource, ordinal: number): LibrarySongSnapshot | null {
  const appleCatalogId = catalogId(value)
  const title = nonempty(value.attributes.name)
  const artist = nonempty(value.attributes.artistName)
  if (!appleCatalogId || !title || !artist) return null
  const genres = Array.isArray(value.attributes.genreNames) ? value.attributes.genreNames : []
  return {
    ordinal,
    appleLibraryId: value.type === 'library-songs' ? value.id : null,
    appleCatalogId,
    title,
    artist,
    album: nonempty(value.attributes.albumName),
    genre: nonempty(genres[0]),
    releaseYear: releaseYear(value.attributes.releaseDate),
    explicit: contentRating(value.attributes.contentRating),
    playCount: null,
    lastPlayedAt: null,
    dateAdded: timestamp(value.attributes.dateAdded),
  }
}

function normalizePlaylistEntry(
  playlistAppleId: string,
  value: AppleResource,
  position: number,
  occurrence: number,
): Omit<PlaylistEntrySnapshot, 'appleLibraryEntryId'> & { identitySeed: string } {
  const image = artwork(value.attributes)
  const isrc = nonempty(value.attributes.isrc)?.toUpperCase() ?? null
  return {
    playlistAppleId,
    position,
    identitySeed: `${playlistAppleId}:${value.type}:${value.id}:${occurrence}`,
    appleLibraryTrackId: value.type.startsWith('library-') ? value.id : null,
    appleCatalogId: catalogId(value),
    isrcSnapshot: isrc && ISRC_RE.test(isrc) ? isrc : null,
    titleSnapshot: nonempty(value.attributes.name) ?? 'Unknown title',
    artistSnapshot: nonempty(value.attributes.artistName) ?? 'Unknown artist',
    albumSnapshot: nonempty(value.attributes.albumName),
    durationMsSnapshot: nullableInteger(value.attributes.durationInMillis),
    artworkUrlTemplateSnapshot: image.url,
    artworkWidthSnapshot: image.width,
    artworkHeightSnapshot: image.height,
    artworkBgColorSnapshot: image.bgColor,
  }
}

async function sha256(value: string) {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value))
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, '0')).join('')
}

async function stableEntryId(seed: string) {
  return seed.length <= 500 ? `web:${seed}` : `web:${await sha256(seed)}`
}

async function pages(
  initialPath: string,
  max: number,
  request: FetchMusicSnapshotOptions['request'],
  signal: AbortSignal,
  onPage?: (count: number, total?: number) => void,
) {
  const values: AppleResource[] = []
  const visited = new Set<string>()
  let next: string | undefined = initialPath
  while (next) {
    signal.throwIfAborted()
    if (visited.has(next)) throw new Error('Apple Music pagination did not advance.')
    visited.add(next)
    const page = await request(next, signal)
    for (const item of page.data) {
      const parsed = resource(item)
      if (parsed) values.push(parsed)
      if (values.length > max) throw new Error('Apple Music response exceeded the safety limit.')
    }
    onPage?.(values.length, page.meta?.total)
    next = page.next
  }
  return values
}

export async function fetchMusicSnapshot({ request, signal, onProgress }: FetchMusicSnapshotOptions): Promise<MusicSnapshot> {
  signal.throwIfAborted()
  const storefrontPage = await request('/v1/me/storefront', signal)
  const storefrontResource = resource(storefrontPage.data[0])
  if (!storefrontResource || !/^[a-z]{2}$/.test(storefrontResource.id)) {
    throw new Error('Apple Music did not return a valid storefront.')
  }

  const rawSongs = await pages(
    '/v1/me/library/songs?limit=100&include=catalog',
    MAX_LIBRARY_SONGS,
    request,
    signal,
    (completed, total) => onProgress({ stage: 'library_songs', completed, total }),
  )
  const songs: LibrarySongSnapshot[] = []
  for (const value of rawSongs) {
    const normalized = normalizeLibrarySong(value, songs.length)
    if (normalized) songs.push(normalized)
  }

  const rawPlaylists = await pages(
    '/v1/me/library/playlists?limit=100',
    MAX_PLAYLISTS,
    request,
    signal,
    (completed, total) => onProgress({ stage: 'playlists', completed, total }),
  )
  const playlists: PlaylistSnapshot[] = []
  const playlistEntries: PlaylistEntrySnapshot[] = []
  for (const value of rawPlaylists) {
    signal.throwIfAborted()
    const name = nonempty(value.attributes.name)
    if (!name || value.type !== 'library-playlists') continue
    const rawEntries = await pages(
      `/v1/me/library/playlists/${encodeURIComponent(value.id)}/tracks?limit=100`,
      MAX_PLAYLIST_ENTRIES - playlistEntries.length,
      request,
      signal,
    )
    const occurrences = new Map<string, number>()
    const entries: PlaylistEntrySnapshot[] = []
    for (const rawEntry of rawEntries) {
      const occurrenceKey = `${rawEntry.type}:${rawEntry.id}`
      const occurrence = occurrences.get(occurrenceKey) ?? 0
      occurrences.set(occurrenceKey, occurrence + 1)
      const normalized = normalizePlaylistEntry(value.id, rawEntry, entries.length, occurrence)
      const { identitySeed, ...entry } = normalized
      entries.push({ ...entry, appleLibraryEntryId: await stableEntryId(identitySeed) })
    }
    playlistEntries.push(...entries)
    if (playlistEntries.length > MAX_PLAYLIST_ENTRIES) {
      throw new Error('Apple Music response exceeded the playlist-entry safety limit.')
    }
    const image = artwork(value.attributes)
    const canEdit = value.attributes.canEdit === true
    const fingerprint = await sha256(JSON.stringify(entries))
    playlists.push({
      ordinal: playlists.length,
      appleLibraryId: value.id,
      appleCatalogId: catalogId(value),
      name,
      description: description(value.attributes),
      curatorName: nonempty(value.attributes.curatorName),
      artworkUrlTemplate: image.url,
      artworkWidth: image.width,
      artworkHeight: image.height,
      artworkBgColor: image.bgColor,
      kind: playlistKind(value.attributes, canEdit),
      canEdit,
      appleDateAdded: timestamp(value.attributes.dateAdded),
      appleLastModifiedAt: timestamp(value.attributes.lastModifiedDate),
      sourceFingerprint: fingerprint,
      entryCount: entries.length,
    })
    onProgress({
      stage: 'playlist_tracks',
      completed: playlistEntries.length,
      total: playlistEntries.length,
    })
  }

  const rawRecent = await pages(
    '/v1/me/recent/played/tracks?limit=30',
    MAX_RECENT_TRACKS,
    request,
    signal,
    (completed, total) => onProgress({ stage: 'recent_tracks', completed, total }),
  )
  const recentCatalogIds = [...new Set(rawRecent.flatMap((value) => {
    const id = catalogId(value)
    return id ? [id] : []
  }))]
  onProgress({ stage: 'complete', completed: songs.length, total: songs.length })
  return {
    storefront: storefrontResource.id,
    songs,
    playlists,
    playlistEntries,
    recentCatalogIds,
    excludedLibrarySongs: rawSongs.length - songs.length,
  }
}
