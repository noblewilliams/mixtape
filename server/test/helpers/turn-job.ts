import { asc, eq } from 'drizzle-orm'
import type { TestDb } from './db'
import { createApp, type AuthLike } from '../../src/app'
import { insertUserMessage, type DjDeps } from '../../src/dj/loop'
import type { LlmClient, LlmRequest, LlmToolCall, LlmTurn } from '../../src/dj/llm'
import type { Embedder } from '../../src/enrich/embedder'
import { djMessages, djSessions, djTurns, trackMeanings, tracks, user, userTracks } from '../../src/db/schema'
import { createSessionWithPlaylistSeed } from '../../src/playlists/seed'
import { titleFromPrompt } from '../../src/routes/sessions'
import type { TurnJob } from '../../src/dj/turn-job'

// Shared by the durable turn tests (test/dj/turn-job.test.ts and
// turn-runner.test.ts): a listener with a library, a scripted model, the
// routes over the same database, and what the Worker writes before it
// starts the object.

export const UNIT = Array.from({ length: 1024 }, (_, i) => (i === 0 ? 1 : 0))
export const embed: Embedder = async () => UNIT
export const FAST = { pollMs: 5, timeoutMs: 5_000, guardPollMs: 10 }
let counter = 0

export async function seedUser(db: TestDb, id = 'u1') {
  await db.insert(user).values({ id, name: id, email: `${id}@example.com`, emailVerified: false, createdAt: new Date(), updatedAt: new Date() })
}

export async function seedLibrary(db: TestDb, userId: string, n: number) {
  for (let i = 0; i < n; i++) {
    counter += 1
    const [t] = await db.insert(tracks).values({ appleId: `job-${counter}`, title: `Track ${counter}`, artist: 'Artist', durationMs: 200_000 }).returning()
    await db.insert(trackMeanings).values({ trackId: t.id, embedding: UNIT, lyricsSource: 'lrclib' })
    await db.insert(userTracks).values({ userId, trackId: t.id, playCount: 0, inLibrary: true })
  }
}

export type Scripted = { text?: string; toolCalls?: LlmToolCall[] }

export const toolCall = (id: string, name: string, input: unknown): LlmToolCall => ({ id, name, input })

// curate() shares the LlmClient (told apart by `tools: []`): it picks the
// first `count` pool ids.
export function curateReply(req: LlmRequest): LlmTurn {
  const message = req.messages[0]
  const blocks = typeof message.content === 'string' ? [] : (message.content as Array<{ text?: string }>)
  const ids = Array.from((blocks[0]?.text ?? '').matchAll(/^([0-9a-f-]{36}) \|/gm)).map((m) => m[1])
  const countMatch = (blocks[1]?.text ?? '').match(/Pick up to (\d+) tracks/)
  const picks = ids.slice(0, countMatch ? Number(countMatch[1]) : ids.length).map((id) => ({ id, reason: 'fits the vibe' }))
  const text = JSON.stringify(picks)
  return { text, toolCalls: [], raw: [{ type: 'text', text }], stopReason: 'end_turn', usage: { inputTokens: 50, outputTokens: 20, cacheReadInputTokens: null } }
}

// A conversation script; `before(n)` runs ahead of the nth conversation call.
export function scriptedLlm(script: Scripted[], before?: (call: number) => void | Promise<void>): LlmClient {
  let call = 0
  return async (req) => {
    if (req.tools.length === 0) return curateReply(req)
    const n = call
    call += 1
    await before?.(n)
    const s = script[Math.min(n, script.length - 1)]
    const raw: LlmTurn['raw'] = []
    if (s.text) raw.push({ type: 'text', text: s.text })
    for (const tc of s.toolCalls ?? []) raw.push({ type: 'tool_use', id: tc.id, name: tc.name, input: tc.input })
    return { text: s.text ?? '', toolCalls: s.toolCalls ?? [], raw, stopReason: s.toolCalls?.length ? 'tool_use' : 'end_turn', usage: { inputTokens: 10, outputTokens: 5, cacheReadInputTokens: null } }
  }
}

export const generate = (targetCount: number, themes = 'rainy drive'): Scripted[] => [
  { toolCalls: [toolCall('c1', 'generate_queue', { themes, targetCount })] },
  { text: 'here you go.' },
]

export function authedAs(id: string): AuthLike {
  return { handler: () => new Response('ok'), api: { getSession: async () => ({ user: { id, isAnonymous: false } }) } }
}

export function post(db: TestDb, deps: DjDeps, path: string, body: unknown) {
  return createApp({ auth: authedAs('u1'), db, dj: { deps } }).request(`http://x${path}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  })
}

// Two forks of one database run the same turn, so their bodies differ only
// in what each fork mints: ids, times, and a new session's tape colour.
export function normalized(text: string): string {
  const ids = new Map<string, number>()
  return text
    .replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi, (id) => {
      if (!ids.has(id)) ids.set(id, ids.size)
      return `<id${ids.get(id)}>`
    })
    .replace(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z/g, '<time>')
    .replace(/"caseColor":"#[0-9a-f]{6}"/gi, '"caseColor":"<color>"')
}

// A session that already ran one text-only turn, as the routes leave it.
export async function mixSession(db: TestDb): Promise<string> {
  const res = await post(db, { embed, llm: scriptedLlm([{ text: 'ready.' }]) }, '/sessions', { prompt: 'start' })
  return ((await res.json()) as { session: { id: string } }).session.id
}

// What the Worker does before starting the object (spec, "Start"): the
// listener's message, then the queued dj_turns row and current_turn_id.
export async function queueMessageTurn(db: TestDb, sessionId: string, text: string, kind: 'message' | 'remake' = 'message'): Promise<TurnJob> {
  const userMessageSeq = await insertUserMessage(db, sessionId, text)
  const [turn] = await db.insert(djTurns).values({ sessionId, userId: 'u1', kind }).returning()
  await db.update(djSessions).set({ currentTurnId: turn.id }).where(eq(djSessions.id, sessionId))
  return { turnId: turn.id, sessionId, userId: 'u1', kind, userMessageSeq, text, options: { surface: 'web' } }
}

export async function queueCreateTurn(db: TestDb, prompt: string): Promise<TurnJob> {
  const fallbackTitle = titleFromPrompt(prompt)
  const session = await createSessionWithPlaylistSeed(db, 'u1', fallbackTitle)
  const userMessageSeq = await insertUserMessage(db, session.id, prompt)
  const [turn] = await db.insert(djTurns).values({ sessionId: session.id, userId: 'u1', kind: 'create' }).returning()
  await db.update(djSessions).set({ currentTurnId: turn.id }).where(eq(djSessions.id, session.id))
  return { turnId: turn.id, sessionId: session.id, userId: 'u1', kind: 'create', userMessageSeq, text: prompt, fallbackTitle, options: { surface: 'web' } }
}

export async function turnRow(db: TestDb, id: string) {
  const [row] = await db.select().from(djTurns).where(eq(djTurns.id, id))
  return row
}

export async function messages(db: TestDb, sessionId: string) {
  return db.select().from(djMessages).where(eq(djMessages.sessionId, sessionId)).orderBy(asc(djMessages.seq))
}
