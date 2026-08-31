import type {
  ApiMessage,
  ApiQueueTrack,
  ApiSessionSummary,
  CreateSessionResponse,
  MixtapeApi,
  SessionDetailResponse,
} from '../api/client'
import { demoQueue, demoSessions, makeConversationFor } from '../data/demo'

const summaries: ApiSessionSummary[] = demoSessions.map((session) => ({
  id: session.id,
  title: session.title,
  status: session.status,
  queueVersion: session.queueVersion,
  updatedAt: session.updatedAt,
  trackCount: session.trackCount,
  durationMs: Math.max(0, Number.parseInt(session.durationLabel, 10)) * 60_000,
}))

function messagesFor(sessionId: string): ApiMessage[] {
  const session = demoSessions.find((item) => item.id === sessionId) ?? demoSessions[0]
  return makeConversationFor(session).map((message) => ({ ...message }))
}

function apiTrack(track: (typeof demoQueue)[number]): ApiQueueTrack {
  return {
    ...track,
    reason: track.reason ?? null,
    durationMs: track.durationMs ?? null,
    artworkUrl: track.artworkUrl ?? null,
    artworkWidth: track.artworkWidth ?? null,
    artworkHeight: track.artworkHeight ?? null,
    artworkBgColor: track.artworkBgColor ?? null,
  }
}

function queueFor(sessionId: string): ApiQueueTrack[] {
  return sessionId === demoSessions[0].id ? demoQueue.map(apiTrack) : []
}

export function createFakeApi(overrides: Partial<MixtapeApi> = {}): MixtapeApi {
  const api: MixtapeApi = {
    listSessions: async () => ({ sessions: summaries.map((session) => ({ ...session })) }),
    getSession: async (sessionId): Promise<SessionDetailResponse> => {
      const session = summaries.find((item) => item.id === sessionId) ?? summaries[0]
      return { session: { ...session }, messages: messagesFor(sessionId), queue: queueFor(sessionId) }
    },
    createSession: async (prompt): Promise<CreateSessionResponse> => {
      const createdAt = new Date().toISOString()
      return {
        session: {
          id: 'created-session',
          title: prompt,
          status: 'active',
          queueVersion: 1,
          updatedAt: createdAt,
        },
        messages: [
          { id: 'created-user', role: 'user', content: prompt, createdAt },
          { id: 'created-dj', role: 'dj', content: 'I made a first pass for this moment.', queueVersion: 1, createdAt },
        ],
        queue: [],
      }
    },
    sendMessage: async (_sessionId, _text) => ({
      djMessage: {
        id: 'reply-message',
        role: 'dj',
        content: 'I kept the opening intact, then reshaped the middle around that feeling.',
        queueVersion: 4,
        createdAt: new Date().toISOString(),
      },
      queue: demoQueue.map(apiTrack),
      queueVersion: 4,
    }),
    getMusicKitToken: async () => ({ developerToken: 'fake-developer-token', expiresAt: 1_788_138_000 }),
    recordSessionEvent: async () => ({ ok: true }),
  }

  return { ...api, ...overrides }
}
