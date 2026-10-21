import type { AlbumPick, AlbumPickState, AlbumSummary, DjMessage, DjSession, ListenLaterEntry, QueueTrack } from '../domain'
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

function ageLabel(isoDate: string): string {
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

function durationLabel(durationMs: number): string {
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
