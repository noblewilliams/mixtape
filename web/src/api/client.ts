export type ApiSessionStatus = 'active' | 'archived'

export type ApiSession = {
  id: string
  title: string
  status: ApiSessionStatus
  queueVersion: number
  updatedAt: string
}

export type ApiSessionSummary = ApiSession & {
  trackCount: number
  durationMs: number
}

export type ApiMessage = {
  id: string
  role: 'user' | 'dj'
  content: string
  queueVersion?: number | null
  createdAt: string
}

export type ApiQueueTrack = {
  position: number
  trackId: string
  appleId: string | null
  title: string
  artist: string
  reason?: string | null
  durationMs?: number | null
}

export type SessionDetailResponse = {
  session: ApiSession
  messages: ApiMessage[]
  queue: ApiQueueTrack[]
}

export type CreateSessionResponse = SessionDetailResponse & {
  sessionTitle?: string
}

export type SendMessageResponse = {
  djMessage: ApiMessage
  queue: ApiQueueTrack[]
  queueVersion: number
  sessionTitle?: string
}

export type MixtapeApi = {
  listSessions: () => Promise<{ sessions: ApiSessionSummary[] }>
  getSession: (sessionId: string) => Promise<SessionDetailResponse>
  createSession: (prompt: string) => Promise<CreateSessionResponse>
  sendMessage: (sessionId: string, text: string) => Promise<SendMessageResponse>
  recordSessionEvent: (sessionId: string, type: 'played' | 'saved_playlist') => Promise<{ ok: true }>
}

export class ApiError extends Error {
  readonly status: number
  readonly code?: string
  readonly payload: unknown

  constructor(status: number, payload: unknown) {
    const record = isRecord(payload) ? payload : null
    const message = typeof record?.message === 'string' ? record.message : `Request failed with status ${status}`
    super(message)
    this.name = 'ApiError'
    this.status = status
    this.code = typeof record?.error === 'string' ? record.error : undefined
    this.payload = payload
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null
}

function normalizeBaseUrl(baseUrl: string): string {
  return baseUrl.replace(/\/+$/, '')
}

async function readPayload(response: Response): Promise<unknown> {
  if (response.status === 204) return null
  const contentType = response.headers.get('content-type') ?? ''
  if (!contentType.includes('application/json')) return response.text()
  return response.json()
}

export function createMixtapeApi(baseUrl: string): MixtapeApi {
  const root = normalizeBaseUrl(baseUrl)

  async function request<T>(path: string, init: RequestInit = {}): Promise<T> {
    const headers = new Headers(init.headers)
    headers.set('accept', 'application/json')
    if (init.body !== undefined) headers.set('content-type', 'application/json')

    const response = await fetch(`${root}${path}`, {
      ...init,
      credentials: 'include',
      headers,
    })
    const payload = await readPayload(response)
    if (!response.ok) throw new ApiError(response.status, payload)
    return payload as T
  }

  return {
    listSessions: () => request('/sessions'),
    getSession: (sessionId) => request(`/sessions/${encodeURIComponent(sessionId)}`),
    createSession: (prompt) =>
      request('/sessions', {
        method: 'POST',
        body: JSON.stringify({ prompt }),
      }),
    sendMessage: (sessionId, text) =>
      request(`/sessions/${encodeURIComponent(sessionId)}/messages`, {
        method: 'POST',
        body: JSON.stringify({ text }),
      }),
    recordSessionEvent: (sessionId, type) =>
      request(`/sessions/${encodeURIComponent(sessionId)}/events`, {
        method: 'POST',
        body: JSON.stringify({ type }),
      }),
  }
}
