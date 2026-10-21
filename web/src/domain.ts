export type SessionStatus = 'active' | 'archived'
export type SessionKind = 'mix' | 'album'

export type DjSession = {
  id: string
  title: string
  status: SessionStatus
  queueVersion: number
  notPersonal: boolean
  updatedAt: string
  ageLabel: string
  trackCount: number
  durationLabel: string
  caseColor: string
  stockColor?: string
  kind: SessionKind
  /** Album sessions only: the current pick for the Mixes list, null before the first. */
  pick?: AlbumSummary | null
}

export type DjMessage = {
  id: string
  role: 'user' | 'dj'
  content: string
  queueVersion?: number
  createdAt: string
}

export type QueueTrack = {
  position: number
  trackId: string
  appleId: string | null
  spotifyId: string | null
  title: string
  artist: string
  reason?: string
  durationMs?: number
  artworkUrl?: string
  artworkWidth?: number
  artworkHeight?: number
  artworkBgColor?: string
  newToYou?: boolean
}

export type SessionDetail = {
  session: DjSession
  messages: DjMessage[]
  queue: QueueTrack[]
  /** Album sessions only; their queue is always empty. */
  albums?: AlbumPickState
}

export type AlbumType = 'album' | 'ep' | 'single' | 'live' | 'compilation' | 'soundtrack' | 'mixtape'

type AlbumFields = {
  id: string
  upc: string | null
  appleId: string | null
  title: string
  artist: string
  releaseYear: number | null
  type: AlbumType
  trackCount: number | null
  durationMs: number | null
  artworkUrl?: string
  artworkWidth?: number
  artworkHeight?: number
  artworkBgColor?: string
}

export type AlbumPick = AlbumFields & {
  newToYou: boolean
  reason: string
  savedForLater: boolean
  /** The shortlist version this album belongs to; a passed album's is the one to go back to. */
  version: number
}

export type AlbumPickState = {
  version: number
  pick: AlbumPick | null
  runnersUp: AlbumPick[]
  passed: AlbumPick[]
}

export type AlbumSummary = {
  title: string
  artist: string
  artworkUrl?: string
  artworkBgColor?: string
}

export type ListenLaterEntry = AlbumFields & {
  sessionId: string | null
  savedAt: string
  listenedAt: string | null
  /** The DJ's why from the session it came from; null for a save with no session. */
  reason: string | null
}

export type CollectionView = 'list' | 'grid' | 'closet'
export type AppView = 'session' | 'home' | 'music' | 'memories' | 'mixes' | 'settings'
