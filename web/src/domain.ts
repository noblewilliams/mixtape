export type SessionStatus = 'active' | 'archived'

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
}

export type SessionDetail = {
  session: DjSession
  messages: DjMessage[]
  queue: QueueTrack[]
}

export type CollectionView = 'list' | 'closet'
export type AppView = 'session' | 'home'
