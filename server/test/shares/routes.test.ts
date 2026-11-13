import { describe, it, expect } from 'vitest'
import { eq } from 'drizzle-orm'
import { createTestDb, type TestDb } from '../helpers/db'
import { createApp, type AuthLike, type SessionUser, type ShareRateLimiter } from '../../src/app'
import type { DjDeps } from '../../src/dj/loop'
import type { LlmClient } from '../../src/dj/llm'
import { applyOps, replaceQueue } from '../../src/dj/queue-store'
import { djMessages, djSessions, mixShares, mixShareSaves, tracks, user } from '../../src/db/schema'

// Spec 2026-11-13 shared-mixes (API table), plan task S2.

const BASE = 'https://miixtape.netlify.app'
const SHARER = 'user-sharer-1'
const OTHER = 'user-other-2'
const ANON = 'user-anon-3'

const llm: LlmClient = async () => ({ text: 'ok', toolCalls: [], raw: [{ type: 'text', text: 'ok' }], stopReason: 'end_turn', usage: null })
const djDeps: DjDeps = { llm, embed: async () => new Array(1024).fill(0) }

const USERS: Record<string, SessionUser> = {
  [SHARER]: { id: SHARER, name: 'Ada Lovelace' },
  [OTHER]: { id: OTHER, name: 'Grace Hopper' },
  [ANON]: { id: ANON, name: 'Listener', isAnonymous: true },
}

// Who the next request is from; null means no session.
type Caller = { current: string | null }

function authFor(caller: Caller): AuthLike {
  return {
    handler: () => new Response('ok'),
    api: { getSession: async () => (caller.current ? { user: USERS[caller.current] } : null) },
  }
}

function allowAll(): ShareRateLimiter & { keys: string[] } {
  const keys: string[] = []
  return { keys, limit: async ({ key }) => { keys.push(key); return { success: true } } }
}

async function setup(opts: { limiter?: ShareRateLimiter; aiConsent?: 'off' | 'enforce' } = {}) {
  const db = await createTestDb()
  for (const u of Object.values(USERS)) {
    await db.insert(user).values({
      id: u.id,
      name: u.name ?? '',
      email: `${u.id}@secret-mail.example`,
      emailVerified: false,
      createdAt: new Date(),
      updatedAt: new Date(),
    })
  }
  const caller: Caller = { current: SHARER }
  const app = createApp({
    auth: authFor(caller),
    db,
    dj: { deps: djDeps },
    shares: { baseUrl: BASE, limiter: opts.limiter ?? allowAll() },
    aiConsent: opts.aiConsent ?? 'off',
  })
  return { db, app, caller }
}

type App = Awaited<ReturnType<typeof setup>>['app']

function send(app: App, method: string, path: string, body?: unknown, headers: Record<string, string> = {}) {
  return app.request(`http://x${path}`, {
    method,
    headers: { 'content-type': 'application/json', ...headers },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  })
}

let trackN = 0
async function seedTrack(db: TestDb, overrides: Partial<typeof tracks.$inferInsert> = {}) {
  trackN += 1
  const [t] = await db
    .insert(tracks)
    .values({
      appleId: `apple-${trackN}`,
      isrc: `USRC1${String(trackN).padStart(7, '0')}`,
      title: `Song ${trackN}`,
      artist: `Artist ${trackN}`,
      album: `Album ${trackN}`,
      durationMs: 180_000 + trackN,
      artworkUrlTemplate: `https://art.example/${trackN}/{w}x{h}.jpg`,
      artworkWidth: 1000,
      artworkHeight: 1000,
      artworkBgColor: 'aabbcc',
      ...overrides,
    })
    .returning()
  return t
}

async function seedMix(db: TestDb, opts: { userId?: string; songs?: number; kind?: 'mix' | 'album' } = {}) {
  const [session] = await db
    .insert(djSessions)
    .values({ userId: opts.userId ?? SHARER, title: 'Rainy drive', caseColor: '#b84755', kind: opts.kind ?? 'mix' })
    .returning()
  const songs = []
  for (let i = 0; i < (opts.songs ?? 3); i++) songs.push(await seedTrack(db))
  if (songs.length > 0 && (opts.kind ?? 'mix') === 'mix') {
    await replaceQueue(db, session.id, songs.map((s) => ({ trackId: s.id, reason: 'SECRET_REASON because the bridge lifts' })), 'dj')
  }
  await db.insert(djMessages).values({ sessionId: session.id, role: 'user', content: 'SECRET_PROMPT songs for my ex' })
  return { session, songs }
}

async function share(app: App, sessionId: string) {
  return send(app, 'POST', `/sessions/${sessionId}/share`)
}

async function shareToken(app: App, sessionId: string): Promise<string> {
  const res = await share(app, sessionId)
  expect(res.status).toBe(200)
  return ((await res.json()) as { token: string }).token
}

function collectKeys(value: unknown, out = new Set<string>()): Set<string> {
  if (Array.isArray(value)) value.forEach((v) => collectKeys(v, out))
  else if (value && typeof value === 'object') {
    for (const [k, v] of Object.entries(value)) {
      out.add(k)
      collectKeys(v, out)
    }
  }
  return out
}

describe('POST /sessions/:id/share', () => {
  it('returns a 22-char base62 token and the share url', async () => {
    const { app, db } = await setup()
    const { session } = await seedMix(db)
    const res = await share(app, session.id)
    expect(res.status).toBe(200)
    const body = (await res.json()) as { token: string; url: string }
    expect(body.token).toMatch(/^[A-Za-z0-9]{22}$/)
    expect(body.url).toBe(`${BASE}/m/${body.token}`)
    expect(Object.keys(body).sort()).toEqual(['token', 'url'])
  })

  it('gives the same token when shared again at the same version', async () => {
    const { app, db } = await setup()
    const { session } = await seedMix(db)
    const first = await shareToken(app, session.id)
    const second = await shareToken(app, session.id)
    expect(second).toBe(first)
    expect(await db.select().from(mixShares)).toHaveLength(1)
  })

  it('gives a new token after a queue op changes the version', async () => {
    const { app, db } = await setup()
    const { session } = await seedMix(db)
    const first = await shareToken(app, session.id)
    const ops = await send(app, 'POST', `/sessions/${session.id}/queue-ops`, { ops: [{ op: 'remove', position: 0 }] })
    expect(ops.status).toBe(200)
    const second = await shareToken(app, session.id)
    expect(second).not.toBe(first)
    // The first link still works and still shows three songs.
    const old = (await (await send(app, 'GET', `/shared/${first}`)).json()) as { tracks: unknown[] }
    expect(old.tracks).toHaveLength(3)
  })

  it('answers 409 name_required for an anonymous listener with no usable name', async () => {
    const { app, db, caller } = await setup()
    const { session } = await seedMix(db, { userId: ANON })
    caller.current = ANON
    const res = await share(app, session.id)
    expect(res.status).toBe(409)
    expect(await res.json()).toEqual({ error: 'name_required' })
    expect(await db.select().from(mixShares)).toHaveLength(0)
  })

  it('answers 409 name_required for a signed-in listener with a blank name', async () => {
    const { app, db, caller } = await setup()
    USERS['user-blank-4'] = { id: 'user-blank-4', name: '   ' }
    await db.insert(user).values({ id: 'user-blank-4', name: '', email: 'b@example.com', emailVerified: false, createdAt: new Date(), updatedAt: new Date() })
    const { session } = await seedMix(db, { userId: 'user-blank-4' })
    caller.current = 'user-blank-4'
    const res = await share(app, session.id)
    expect(res.status).toBe(409)
    expect(await res.json()).toEqual({ error: 'name_required' })
  })

  it('answers 422 empty_mix when the mix has no active songs', async () => {
    const { app, db } = await setup()
    const { session } = await seedMix(db, { songs: 0 })
    const res = await share(app, session.id)
    expect(res.status).toBe(422)
    expect(await res.json()).toEqual({ error: 'empty_mix' })
  })

  it('answers 404 for an album session', async () => {
    const { app, db } = await setup()
    const { session } = await seedMix(db, { kind: 'album' })
    const res = await share(app, session.id)
    expect(res.status).toBe(404)
  })

  it('answers 404 for someone else\'s mix and for a malformed id', async () => {
    const { app, db, caller } = await setup()
    const { session } = await seedMix(db)
    caller.current = OTHER
    expect((await share(app, session.id)).status).toBe(404)
    expect((await share(app, 'not-a-uuid')).status).toBe(404)
    expect(await db.select().from(mixShares)).toHaveLength(0)
  })

  it('answers 401 without a session', async () => {
    const { app, db, caller } = await setup()
    const { session } = await seedMix(db)
    caller.current = null
    expect((await share(app, session.id)).status).toBe(401)
  })

  it('is not blocked by missing AI consent (share and stop sharing call no model)', async () => {
    const { app, db } = await setup({ aiConsent: 'enforce' })
    const { session } = await seedMix(db)
    expect((await share(app, session.id)).status).toBe(200)
    expect((await send(app, 'DELETE', `/sessions/${session.id}/share`)).status).toBe(204)
    // Sanity: the enforced gate is live for a model route.
    expect((await send(app, 'POST', `/sessions/${session.id}/messages`, { text: 'hi' })).status).toBe(403)
  })
})

describe('DELETE /sessions/:id/share', () => {
  it('revokes every active share of the mix', async () => {
    const { app, db } = await setup()
    const { session } = await seedMix(db)
    const first = await shareToken(app, session.id)
    await send(app, 'POST', `/sessions/${session.id}/queue-ops`, { ops: [{ op: 'remove', position: 0 }] })
    const second = await shareToken(app, session.id)
    const res = await send(app, 'DELETE', `/sessions/${session.id}/share`)
    expect(res.status).toBe(204)
    for (const token of [first, second]) {
      const read = await send(app, 'GET', `/shared/${token}`)
      expect(read.status).toBe(410)
      expect(await read.json()).toEqual({ error: 'revoked' })
    }
    // Sharing again after a revoke makes a fresh link.
    const third = await shareToken(app, session.id)
    expect([first, second]).not.toContain(third)
  })

  it('answers 404 for an album session', async () => {
    const { app, db } = await setup()
    const { session } = await seedMix(db, { kind: 'album' })
    expect((await send(app, 'DELETE', `/sessions/${session.id}/share`)).status).toBe(404)
  })

  it('answers 404 for someone else\'s mix', async () => {
    const { app, db, caller } = await setup()
    const { session } = await seedMix(db)
    const token = await shareToken(app, session.id)
    caller.current = OTHER
    expect((await send(app, 'DELETE', `/sessions/${session.id}/share`)).status).toBe(404)
    caller.current = null
    expect((await send(app, 'GET', `/shared/${token}`)).status).toBe(200)
  })
})

describe('GET /sessions/:id shared flag', () => {
  it('is false before sharing, true while shared, false after stop sharing', async () => {
    const { app, db } = await setup()
    const { session } = await seedMix(db)
    const flag = async () => ((await (await send(app, 'GET', `/sessions/${session.id}`)).json()) as { shared: boolean }).shared
    expect(await flag()).toBe(false)
    await shareToken(app, session.id)
    expect(await flag()).toBe(true)
    await send(app, 'DELETE', `/sessions/${session.id}/share`)
    expect(await flag()).toBe(false)
  })

  it('is false for an album session', async () => {
    const { app, db } = await setup()
    const { session } = await seedMix(db, { kind: 'album' })
    const body = (await (await send(app, 'GET', `/sessions/${session.id}`)).json()) as { shared: boolean }
    expect(body.shared).toBe(false)
  })
})

describe('GET /shared/:token', () => {
  it('returns the snapshot with live track metadata, for anyone', async () => {
    const { app, db, caller } = await setup()
    const { session, songs } = await seedMix(db)
    const token = await shareToken(app, session.id)
    caller.current = null
    const res = await send(app, 'GET', `/shared/${token}`)
    expect(res.status).toBe(200)
    const body = (await res.json()) as Record<string, unknown> & { tracks: Array<Record<string, unknown>> }
    expect(Object.keys(body).sort()).toEqual(['caseColor', 'isOwner', 'sharedAt', 'sharerName', 'title', 'token', 'tracks'])
    expect(body).toMatchObject({ token, title: 'Rainy drive', caseColor: '#b84755', sharerName: 'Ada', isOwner: false })
    expect(new Date(body.sharedAt as string).toString()).not.toBe('Invalid Date')
    expect(body.tracks).toEqual(
      songs.map((s) => ({
        title: s.title,
        artist: s.artist,
        album: s.album,
        durationMs: s.durationMs,
        artwork: { url: s.artworkUrlTemplate, width: 1000, height: 1000, bgColor: 'aabbcc' },
        appleId: s.appleId,
        isrc: s.isrc,
      })),
    )
  })

  it('reads metadata live: artwork found later shows; null ids and artwork stay null', async () => {
    const { app, db } = await setup()
    const [session] = await db.insert(djSessions).values({ userId: SHARER, title: 'Bare', caseColor: '#a32440' }).returning()
    const bare = await seedTrack(db, { appleId: null, isrc: null, album: null, artworkUrlTemplate: null, artworkWidth: null, artworkHeight: null, artworkBgColor: null })
    await replaceQueue(db, session.id, [{ trackId: bare.id, reason: 'r' }], 'dj')
    const token = await shareToken(app, session.id)
    let body = (await (await send(app, 'GET', `/shared/${token}`)).json()) as { tracks: Array<Record<string, unknown>> }
    expect(body.tracks[0]).toMatchObject({ appleId: null, isrc: null, album: null, artwork: null })
    await db.update(tracks).set({ artworkUrlTemplate: 'https://art.example/late/{w}x{h}.jpg', artworkWidth: 600, artworkHeight: 600 }).where(eq(tracks.id, bare.id))
    body = (await (await send(app, 'GET', `/shared/${token}`)).json()) as { tracks: Array<Record<string, unknown>> }
    expect(body.tracks[0].artwork).toEqual({ url: 'https://art.example/late/{w}x{h}.jpg', width: 600, height: 600, bgColor: null })
  })

  it('keeps the snapshot order after the owner reorders the mix', async () => {
    const { app, db } = await setup()
    const { session, songs } = await seedMix(db)
    const token = await shareToken(app, session.id)
    await applyOps(db, session.id, [{ op: 'move', from: 0, to: 2 }], 'user')
    const body = (await (await send(app, 'GET', `/shared/${token}`)).json()) as { tracks: Array<{ title: string }> }
    expect(body.tracks.map((t) => t.title)).toEqual(songs.map((s) => s.title))
  })

  it('keeps the snapshot title after a rename, and the colour', async () => {
    const { app, db } = await setup()
    const { session } = await seedMix(db)
    const token = await shareToken(app, session.id)
    const patch = await send(app, 'PATCH', `/sessions/${session.id}`, { title: 'Renamed', caseColor: '#d88c9a' })
    expect(patch.status).toBe(200)
    const body = (await (await send(app, 'GET', `/shared/${token}`)).json()) as { title: string; caseColor: string }
    expect(body.title).toBe('Rainy drive')
    expect(body.caseColor).toBe('#b84755')
  })

  it('shows only the first name, read live', async () => {
    const { app, db } = await setup()
    const { session } = await seedMix(db)
    const token = await shareToken(app, session.id)
    let body = await (await send(app, 'GET', `/shared/${token}`)).text()
    expect(JSON.parse(body).sharerName).toBe('Ada')
    expect(body).not.toContain('Lovelace')
    await db.update(user).set({ name: '  Augusta   Ada King ' }).where(eq(user.id, SHARER))
    body = await (await send(app, 'GET', `/shared/${token}`)).text()
    expect(JSON.parse(body).sharerName).toBe('Augusta')
  })

  it('never carries reasons, prompts, messages, energy, email or user ids', async () => {
    const { app, db, caller } = await setup()
    const { session } = await seedMix(db)
    const token = await shareToken(app, session.id)
    for (const who of [null, OTHER, SHARER]) {
      caller.current = who
      const text = await (await send(app, 'GET', `/shared/${token}`)).text()
      for (const secret of ['SECRET_REASON', 'SECRET_PROMPT', 'secret-mail', 'Lovelace', SHARER, OTHER]) {
        expect(text).not.toContain(secret)
      }
      const keys = collectKeys(JSON.parse(text))
      for (const banned of ['reason', 'reasons', 'prompt', 'messages', 'energy', 'energyArc', 'email', 'userId', 'sharerId', 'user', 'queue', 'trackId', 'id']) {
        expect(keys.has(banned)).toBe(false)
      }
    }
  })

  it('includes isOwner and sessionId only for the owner', async () => {
    const { app, db, caller } = await setup()
    const { session } = await seedMix(db)
    const token = await shareToken(app, session.id)
    const owner = (await (await send(app, 'GET', `/shared/${token}`)).json()) as Record<string, unknown>
    expect(owner.isOwner).toBe(true)
    expect(owner.sessionId).toBe(session.id)
    caller.current = OTHER
    const other = (await (await send(app, 'GET', `/shared/${token}`)).json()) as Record<string, unknown>
    expect(other.isOwner).toBe(false)
    expect('sessionId' in other).toBe(false)
    caller.current = null
    const anon = (await (await send(app, 'GET', `/shared/${token}`)).json()) as Record<string, unknown>
    expect(anon.isOwner).toBe(false)
    expect('sessionId' in anon).toBe(false)
  })

  it('serves the read as anonymous when the session lookup throws', async () => {
    const { app, db } = await setup()
    const { session } = await seedMix(db)
    const token = await shareToken(app, session.id)
    const db2 = db
    const broken = createApp({
      auth: { handler: () => new Response('ok'), api: { getSession: async () => { throw new Error('auth store down') } } },
      db: db2,
      dj: { deps: djDeps },
      shares: { baseUrl: BASE, limiter: allowAll() },
      aiConsent: 'off',
    })
    const res = await send(broken, 'GET', `/shared/${token}`, undefined, { authorization: 'Bearer junk' })
    expect(res.status).toBe(200)
    expect(((await res.json()) as { isOwner: boolean }).isOwner).toBe(false)
  })

  it('answers 404 not_found for an unknown or malformed token', async () => {
    const { app, caller } = await setup()
    caller.current = null
    for (const token of ['AAAAAAAAAAAAAAAAAAAAAA', 'short', 'AAAAAAAAAAAAAAAAAAAAA-', `${'A'.repeat(23)}`]) {
      const res = await send(app, 'GET', `/shared/${token}`)
      expect(res.status).toBe(404)
      expect(await res.json()).toEqual({ error: 'not_found' })
    }
  })

  it('answers 410 revoked after stop sharing', async () => {
    const { app, db, caller } = await setup()
    const { session } = await seedMix(db)
    const token = await shareToken(app, session.id)
    await send(app, 'DELETE', `/sessions/${session.id}/share`)
    caller.current = null
    const res = await send(app, 'GET', `/shared/${token}`)
    expect(res.status).toBe(410)
    expect(await res.json()).toEqual({ error: 'revoked' })
  })

  it('answers 429 rate_limited when the limiter refuses, keyed by CF-Connecting-IP', async () => {
    const keys: string[] = []
    const limiter: ShareRateLimiter = { limit: async ({ key }) => { keys.push(key); return { success: false } } }
    const { app, db } = await setup({ limiter })
    const { session } = await seedMix(db)
    const token = await shareToken(app, session.id)
    const res = await send(app, 'GET', `/shared/${token}`, undefined, { 'CF-Connecting-IP': '203.0.113.7' })
    expect(res.status).toBe(429)
    expect(await res.json()).toEqual({ error: 'rate_limited' })
    expect(keys).toEqual(['203.0.113.7'])
  })

  it('checks the limiter on every read', async () => {
    const limiter = allowAll()
    const { app, db } = await setup({ limiter })
    const { session } = await seedMix(db)
    const token = await shareToken(app, session.id)
    await send(app, 'GET', `/shared/${token}`, undefined, { 'CF-Connecting-IP': '198.51.100.1' })
    await send(app, 'GET', '/shared/AAAAAAAAAAAAAAAAAAAAAA', undefined, { 'CF-Connecting-IP': '198.51.100.1' })
    expect(limiter.keys).toEqual(['198.51.100.1', '198.51.100.1'])
  })
})

describe('POST/DELETE /shared/:token/save', () => {
  it('saves idempotently', async () => {
    const { app, db, caller } = await setup()
    const { session } = await seedMix(db)
    const token = await shareToken(app, session.id)
    caller.current = OTHER
    expect((await send(app, 'POST', `/shared/${token}/save`)).status).toBe(204)
    expect((await send(app, 'POST', `/shared/${token}/save`)).status).toBe(204)
    const saves = await db.select().from(mixShareSaves)
    expect(saves).toHaveLength(1)
    expect(saves[0].userId).toBe(OTHER)
  })

  it('lets an anonymous listener save', async () => {
    const { app, db, caller } = await setup()
    const { session } = await seedMix(db)
    const token = await shareToken(app, session.id)
    caller.current = ANON
    expect((await send(app, 'POST', `/shared/${token}/save`)).status).toBe(204)
    expect(await db.select().from(mixShareSaves)).toHaveLength(1)
  })

  it('writes no row for the owner\'s own save', async () => {
    const { app, db } = await setup()
    const { session } = await seedMix(db)
    const token = await shareToken(app, session.id)
    expect((await send(app, 'POST', `/shared/${token}/save`)).status).toBe(204)
    expect(await db.select().from(mixShareSaves)).toHaveLength(0)
  })

  it('answers 401 without a session', async () => {
    const { app, db, caller } = await setup()
    const { session } = await seedMix(db)
    const token = await shareToken(app, session.id)
    caller.current = null
    expect((await send(app, 'POST', `/shared/${token}/save`)).status).toBe(401)
    expect((await send(app, 'DELETE', `/shared/${token}/save`)).status).toBe(401)
  })

  it('answers 404 for an unknown token and 410 for a revoked one', async () => {
    const { app, db, caller } = await setup()
    const { session } = await seedMix(db)
    const token = await shareToken(app, session.id)
    await send(app, 'DELETE', `/sessions/${session.id}/share`)
    caller.current = OTHER
    const unknown = await send(app, 'POST', '/shared/AAAAAAAAAAAAAAAAAAAAAA/save')
    expect(unknown.status).toBe(404)
    expect(await unknown.json()).toEqual({ error: 'not_found' })
    expect((await send(app, 'POST', '/shared/bad/save')).status).toBe(404)
    const revoked = await send(app, 'POST', `/shared/${token}/save`)
    expect(revoked.status).toBe(410)
    expect(await revoked.json()).toEqual({ error: 'revoked' })
  })

  it('DELETE removes only the caller\'s save, leaving the share and other saves', async () => {
    const { app, db, caller } = await setup()
    const { session } = await seedMix(db)
    const token = await shareToken(app, session.id)
    caller.current = OTHER
    await send(app, 'POST', `/shared/${token}/save`)
    caller.current = ANON
    await send(app, 'POST', `/shared/${token}/save`)
    caller.current = OTHER
    expect((await send(app, 'DELETE', `/shared/${token}/save`)).status).toBe(204)
    expect((await send(app, 'DELETE', `/shared/${token}/save`)).status).toBe(204)
    const saves = await db.select().from(mixShareSaves)
    expect(saves.map((s) => s.userId)).toEqual([ANON])
    expect(await db.select().from(mixShares)).toHaveLength(1)
    caller.current = null
    expect((await send(app, 'GET', `/shared/${token}`)).status).toBe(200)
  })
})
