import type { AlbumPick, AlbumPickState, AlbumSummary, DjMessage, DjSession, ListenLaterEntry, QueueTrack, SharedMix, SharedMixRow, SharedMixTrack } from '../domain'
import type {
  AlbumPickResponse,
  ApiAlbum,
  ApiAlbumArtwork,
  ApiListenLaterEntry,
  ApiMessage,
  ApiQueueTrack,
  ApiSession,
  ApiSessionSummary,
} from './client'

const TAPE_PALETTES = [
  ['#3f4851', '#f2ede2'],
  ['#76584f', '#eee6d7'],
  ['#596454', '#f2ede2'],
  ['#51434f', '#eee6d7'],
  ['#b8aa63', '#f2ede2'],
] as const

function paletteFor(id: string) {
  const hash = [...id].reduce((value, character) => (value * 31 + character.charCodeAt(0)) >>> 0, 0)
  return TAPE_PALETTES[hash % TAPE_PALETTES.length]
}

export function ageLabel(isoDate: string): string {
  const elapsedMs = Math.max(0, Date.now() - new Date(isoDate).getTime())
  const minutes = Math.floor(elapsedMs / 60_000)
  if (minutes < 1) return 'just now'
  if (minutes < 60) return `${minutes} min ago`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours} hr${hours === 1 ? '' : 's'} ago`
  const days = Math.floor(hours / 24)
  if (days === 1) return 'yesterday'
  if (days < 14) return `${days} days ago`
  const weeks = Math.floor(days / 7)
  if (weeks < 8) return `${weeks} week${weeks === 1 ? '' : 's'} ago`
  const months = Math.floor(days / 30)
  return `${months} month${months === 1 ? '' : 's'} ago`
}

export function durationLabel(durationMs: number): string {
  if (durationMs <= 0) return '0 min'
  const minutes = Math.max(1, Math.round(durationMs / 60_000))
  if (minutes < 60) return `${minutes} min`
  const hours = Math.floor(minutes / 60)
  const remainder = minutes % 60
  return remainder === 0 ? `${hours} hr` : `${hours} hr ${remainder} min`
}

export function toDjSession(
  session: ApiSession | ApiSessionSummary,
  queue: ApiQueueTrack[] = [],
): DjSession {
  const [caseColor, stockColor] = paletteFor(session.id)
  const trackCount = 'trackCount' in session ? session.trackCount : queue.length
  const totalDuration =
    'durationMs' in session
      ? session.durationMs
      : queue.reduce((total, track) => total + (track.durationMs ?? 0), 0)

  const { pick, ...rest } = session as ApiSessionSummary
  const kind = session.kind ?? 'mix'

  return {
    ...rest,
    kind,
    ...(kind === 'album' && pick !== undefined ? { pick: pick && toAlbumSummary(pick) } : {}),
    ageLabel: ageLabel(session.updatedAt),
    trackCount,
    durationLabel: durationLabel(totalDuration),
    caseColor: session.caseColor ?? caseColor,
    stockColor,
  }
}

function flatArtwork(artwork: ApiAlbumArtwork | null) {
  return {
    artworkUrl: artwork?.url ?? undefined,
    artworkWidth: artwork?.width ?? undefined,
    artworkHeight: artwork?.height ?? undefined,
    artworkBgColor: artwork?.bgColor ?? undefined,
  }
}

function toAlbumSummary(pick: NonNullable<ApiSessionSummary['pick']>): AlbumSummary {
  const { artworkUrl, artworkBgColor } = flatArtwork(pick.artwork)
  return { title: pick.title, artist: pick.artist, artworkUrl, artworkBgColor }
}

export function toAlbumPick({ artwork, newToThem, ...album }: ApiAlbum): AlbumPick {
  return { ...album, ...flatArtwork(artwork), newToYou: newToThem }
}

export function toAlbumPickState(response: AlbumPickResponse): AlbumPickState {
  return {
    version: response.version,
    pick: response.pick ? toAlbumPick(response.pick) : null,
    runnersUp: response.runnersUp.map(toAlbumPick),
    passed: response.passed.map(toAlbumPick),
  }
}

export function toListenLaterEntry({ artwork, ...entry }: ApiListenLaterEntry): ListenLaterEntry {
  return { ...entry, ...flatArtwork(artwork) }
}

export function toDjMessage(message: ApiMessage): DjMessage {
  return {
    ...message,
    queueVersion: message.queueVersion ?? undefined,
  }
}

export function toQueueTrack(track: ApiQueueTrack): QueueTrack {
  return {
    ...track,
    reason: track.reason ?? undefined,
    durationMs: track.durationMs ?? undefined,
    artworkUrl: track.artworkUrl ?? undefined,
    artworkWidth: track.artworkWidth ?? undefined,
    artworkHeight: track.artworkHeight ?? undefined,
    artworkBgColor: track.artworkBgColor ?? undefined,
    newToYou: track.newToYou ?? false,
  }
}

/** A response body that does not match the contract; the shared-mix reads refuse to guess. */
export class MalformedResponseError extends Error {
  constructor(what: string) {
    super(`Malformed response: ${what}`)
    this.name = 'MalformedResponseError'
  }
}

type Fields = Record<string, unknown>

function record(value: unknown, what: string): Fields {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) throw new MalformedResponseError(what)
  return value as Fields
}
function text(body: Fields, key: string, what: string): string {
  const value = body[key]
  if (typeof value !== 'string') throw new MalformedResponseError(`${what}.${key}`)
  return value
}
function count(body: Fields, key: string, what: string): number {
  const value = body[key]
  if (typeof value !== 'number' || !Number.isFinite(value)) throw new MalformedResponseError(`${what}.${key}`)
  return value
}
/** Present and either null or the type; a missing key is a contract miss, not a null. */
function nullable<T extends 'string' | 'number'>(body: Fields, key: string, type: T, what: string): (T extends 'string' ? string : number) | undefined {
  if (!(key in body)) throw new MalformedResponseError(`${what}.${key}`)
  const value = body[key]
  if (value === null) return undefined
  if (typeof value !== type || (type === 'number' && !Number.isFinite(value))) throw new MalformedResponseError(`${what}.${key}`)
  return value as T extends 'string' ? string : number
}
function artworkOf(body: Fields, what: string): { artworkUrl?: string; artworkBgColor?: string } {
  if (!('artwork' in body)) throw new MalformedResponseError(`${what}.artwork`)
  if (body.artwork === null) return {}
  const artwork = record(body.artwork, `${what}.artwork`)
  const url = text(artwork, 'url', `${what}.artwork`)
  nullable(artwork, 'width', 'number', `${what}.artwork`)
  nullable(artwork, 'height', 'number', `${what}.artwork`)
  const bgColor = nullable(artwork, 'bgColor', 'string', `${what}.artwork`)
  return { artworkUrl: url, ...(bgColor === undefined ? {} : { artworkBgColor: bgColor }) }
}
const defined = <T extends object>(value: T): T =>
  Object.fromEntries(Object.entries(value).filter(([, item]) => item !== undefined)) as T

function toSharedMixTrack(value: unknown, index: number): SharedMixTrack {
  const what = `tracks[${index}]`
  const body = record(value, what)
  return defined({
    title: text(body, 'title', what),
    artist: text(body, 'artist', what),
    album: nullable(body, 'album', 'string', what),
    durationMs: nullable(body, 'durationMs', 'number', what),
    ...artworkOf(body, what),
    appleId: nullable(body, 'appleId', 'string', what),
    isrc: nullable(body, 'isrc', 'string', what),
  })
}

/** GET /shared/:token, checked field by field (shared contract: parsed strictly). */
export function toSharedMix(value: unknown): SharedMix {
  const body = record(value, 'shared mix')
  const isOwner = body.isOwner
  if (typeof isOwner !== 'boolean') throw new MalformedResponseError('shared mix.isOwner')
  if (!Array.isArray(body.tracks)) throw new MalformedResponseError('shared mix.tracks')
  const mix: SharedMix = {
    token: text(body, 'token', 'shared mix'),
    title: text(body, 'title', 'shared mix'),
    caseColor: text(body, 'caseColor', 'shared mix'),
    sharerName: nullable(body, 'sharerName', 'string', 'shared mix') ?? null,
    sharedAt: text(body, 'sharedAt', 'shared mix'),
    isOwner,
    tracks: body.tracks.map(toSharedMixTrack),
  }
  // The server sends sessionId only to the owner; the client keeps it only there too.
  if (isOwner) mix.sessionId = text(body, 'sessionId', 'shared mix')
  return mix
}

/** A row of GET /me/shared-mixes, checked field by field. */
export function toSharedMixRow(value: unknown): SharedMixRow {
  const what = 'shared mix row'
  const body = record(value, what)
  return defined({
    token: text(body, 'token', what),
    title: text(body, 'title', what),
    caseColor: text(body, 'caseColor', what),
    sharerName: nullable(body, 'sharerName', 'string', what) ?? null,
    savedAt: text(body, 'savedAt', what),
    trackCount: count(body, 'trackCount', what),
    durationMs: count(body, 'durationMs', what),
    ...artworkOf(body, what),
  })
}
