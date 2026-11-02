import { describe, it, expect } from 'vitest'
import { createTestDb, type TestDb } from './helpers/db'
import { createApp, type AuthLike } from '../src/app'
import { user } from '../src/db/auth-schema'
import { aiConsents } from '../src/db/schema'
import { AI_CONSENT_VERSION } from '../src/routes/ai-consent'
import type { DjDeps } from '../src/dj/loop'
import type { LlmClient } from '../src/dj/llm'

const llm: LlmClient = async () => ({ text: 'ok', toolCalls: [], raw: [{ type: 'text', text: 'ok' }], stopReason: 'end_turn', usage: null })
const djDeps: DjDeps = { llm, embed: async () => new Array(1024).fill(0) }

function authedAs(id: string): AuthLike {
  return { handler: () => new Response('ok'), api: { getSession: async () => ({ user: { id } }) } }
}

async function seedUser(db: TestDb, id: string) {
  await db.insert(user).values({ id, name: id, email: `${id}@example.com`, emailVerified: false, createdAt: new Date(), updatedAt: new Date() })
}

function build(db: TestDb, aiConsent: 'off' | 'enforce' = 'off') {
  return createApp({
    auth: authedAs('u1'),
    db,
    dj: { deps: djDeps },
    playlistEditing: { deps: djDeps as never },
    transcribe: { apiKey: 'k', fetchLike: async () => Response.json({ text: 'hi' }) },
    aiConsent,
  })
}

function send(app: ReturnType<typeof createApp>, method: string, path: string, body?: unknown) {
  return app.request(`http://x${path}`, {
    method,
    headers: { 'content-type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  })
}

async function me(app: ReturnType<typeof createApp>) {
  return (await (await send(app, 'GET', '/me')).json()) as { aiConsent: boolean }
}

describe('AI consent', () => {
  it('reports no consent, records it, and reports it', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const app = build(db)
    expect((await me(app)).aiConsent).toBe(false)

    const res = await send(app, 'POST', '/me/ai-consent', { version: AI_CONSENT_VERSION })
    expect(res.status).toBe(200)
    expect(await res.json()).toEqual({ aiConsent: true })
    expect((await me(app)).aiConsent).toBe(true)

    // Idempotent.
    expect((await send(app, 'POST', '/me/ai-consent', { version: AI_CONSENT_VERSION })).status).toBe(200)
    expect(await db.select().from(aiConsents)).toHaveLength(1)
  })

  it('refuses a stale or malformed version', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const app = build(db)
    const stale = await send(app, 'POST', '/me/ai-consent', { version: '2020-01-01' })
    expect(stale.status).toBe(409)
    expect(await stale.json()).toEqual({ error: 'stale_consent_version' })
    expect((await send(app, 'POST', '/me/ai-consent', {})).status).toBe(400)
    expect((await me(app)).aiConsent).toBe(false)
  })

  it('treats an older version on file as no consent', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await db.insert(aiConsents).values({ userId: 'u1', version: '2020-01-01' })
    expect((await me(build(db))).aiConsent).toBe(false)
  })

  it('goes with the account', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const app = build(db)
    await send(app, 'POST', '/me/ai-consent', { version: AI_CONSENT_VERSION })
    await send(app, 'DELETE', '/me')
    expect(await db.select().from(aiConsents)).toEqual([])
  })

  describe('enforcement', () => {
    const gated: [string, string, unknown][] = [
      ['POST', '/sessions', { prompt: 'something chill' }],
      ['POST', '/sessions/00000000-0000-4000-8000-000000000000/messages', { content: 'more' }],
      ['POST', '/transcribe', undefined],
      ['POST', '/playlist-edit-drafts/00000000-0000-4000-8000-000000000000/messages', { content: 'add more' }],
    ]

    it('answers 403 ai_consent_required on AI routes without consent', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const app = build(db, 'enforce')
      for (const [method, path, body] of gated) {
        const res = await send(app, method, path, body)
        expect(res.status, path).toBe(403)
        expect(await res.json()).toEqual({ error: 'ai_consent_required' })
      }
    })

    it('lets the same requests through once consent is recorded', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const app = build(db, 'enforce')
      await send(app, 'POST', '/me/ai-consent', { version: AI_CONSENT_VERSION })
      for (const [method, path, body] of gated) {
        expect((await send(app, method, path, body)).status, path).not.toBe(403)
      }
    })

    it('is off by default', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      const app = build(db, 'off')
      for (const [method, path, body] of gated) {
        expect((await send(app, method, path, body)).status, path).not.toBe(403)
      }
    })

    it('never gates reads', async () => {
      const db = await createTestDb()
      await seedUser(db, 'u1')
      expect((await send(build(db, 'enforce'), 'GET', '/sessions')).status).toBe(200)
    })
  })
})
