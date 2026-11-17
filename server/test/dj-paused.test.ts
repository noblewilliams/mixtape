import { describe, it, expect, beforeEach } from 'vitest'
import { createTestDb } from './helpers/db'
import { djPauses } from '../src/db/schema'
import { resetAutoPauseCache } from '../src/dj/auto-pause'
import { createApp, type AuthLike } from '../src/app'
import { djPausedMode } from '../src/index'
import type { DjDeps } from '../src/dj/loop'
import type { LlmClient } from '../src/dj/llm'
import type { Db } from '../src/db/types'

let llmCalls = 0
const llm: LlmClient = async () => {
  llmCalls += 1
  return { text: 'ok', toolCalls: [], raw: [{ type: 'text', text: 'ok' }], stopReason: 'end_turn', usage: null }
}
const djDeps: DjDeps = { llm, embed: async () => new Array(1024).fill(0) }
const auth: AuthLike = { handler: () => new Response('ok'), api: { getSession: async () => ({ user: { id: 'u1' } }) } }

// The guard answers before any route reads the database, so a stub that
// throws on use proves no handler ran.
const db = new Proxy({}, { get: () => { throw new Error('db touched') } }) as unknown as Db

function build(djPaused: boolean) {
  return createApp({ auth, db, dj: { deps: djDeps }, playlistEditing: { deps: djDeps as never }, djPaused })
}

function send(app: ReturnType<typeof createApp>, method: string, path: string, body?: unknown) {
  return app.request(`http://x${path}`, {
    method,
    headers: { 'content-type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  })
}

const sid = '00000000-0000-4000-8000-000000000001'

beforeEach(() => resetAutoPauseCache())

describe('DJ_PAUSED', () => {
  it('reads only "on" as paused', () => {
    expect(djPausedMode({ DJ_PAUSED: 'on' })).toBe(true)
    expect(djPausedMode({ DJ_PAUSED: 'off' })).toBe(false)
    expect(djPausedMode({ DJ_PAUSED: 'ON ' })).toBe(false)
    expect(djPausedMode({})).toBe(false)
  })

  it('reports the pause on the public /health', async () => {
    expect(await (await send(build(true), 'GET', '/health')).json()).toMatchObject({ ok: true, djPaused: true })
    expect(await (await send(build(false), 'GET', '/health')).json()).toMatchObject({ ok: true, djPaused: false })
  })

  it('refuses every request that would reach the model, before any work', async () => {
    const app = build(true)
    llmCalls = 0
    for (const path of ['/sessions', `/sessions/${sid}/messages`, `/playlist-edit-drafts/${sid}/messages`]) {
      const res = await send(app, 'POST', path, { prompt: 'late night drive', text: 'more bass' })
      expect(res.status, path).toBe(503)
      expect(await res.json(), path).toEqual({ error: 'dj_paused' })
    }
    expect(llmCalls).toBe(0)
  })

  it('leaves routes that call no model alone', async () => {
    const app = build(true)
    // Reads, shares, deletes and queue edits reach their handlers (here the
    // throwing db stub turns that into a 500), never the pause refusal.
    for (const [method, path] of [
      ['GET', '/sessions'],
      ['GET', `/sessions/${sid}`],
      ['POST', `/sessions/${sid}/share`],
      ['POST', `/sessions/${sid}/queue-ops`],
      ['POST', '/sessions/delete'],
    ] as const) {
      const res = await send(app, method, path, method === 'GET' ? undefined : {})
      expect(res.status, `${method} ${path}`).not.toBe(503)
    }
  })
})

describe('automatic pause (credits spent)', () => {
  it('closes /health and every model route while a pause row exists, and reopens when it goes', async () => {
    const realDb = await createTestDb()
    const app = createApp({ auth, db: realDb as unknown as Db, dj: { deps: djDeps }, playlistEditing: { deps: djDeps as never } })
    expect(await (await send(app, 'GET', '/health')).json()).toMatchObject({ djPaused: false })

    await realDb.insert(djPauses).values({ id: 'anthropic_billing' })
    resetAutoPauseCache()
    expect(await (await send(app, 'GET', '/health')).json()).toMatchObject({ djPaused: true })
    llmCalls = 0
    for (const path of ['/sessions', `/sessions/${sid}/messages`, `/playlist-edit-drafts/${sid}/messages`]) {
      const res = await send(app, 'POST', path, { prompt: 'late night drive', text: 'more bass' })
      expect(res.status, path).toBe(503)
      expect(await res.json(), path).toEqual({ error: 'dj_paused' })
    }
    expect(llmCalls).toBe(0)

    await realDb.delete(djPauses)
    resetAutoPauseCache()
    expect(await (await send(app, 'GET', '/health')).json()).toMatchObject({ djPaused: false })
  })

  it('reads open when the pause table cannot be read', async () => {
    // build(false) uses a db stub that throws on any use.
    expect(await (await send(build(false), 'GET', '/health')).json()).toMatchObject({ ok: true, djPaused: false })
  })
})
