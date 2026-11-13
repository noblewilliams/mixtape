import { describe, it, expect } from 'vitest'
import { eq } from 'drizzle-orm'
import { randomUUID } from 'node:crypto'
import { createTestDb, type TestDb } from '../helpers/db'
import { createApp, type AuthLike, type SessionUser, type ShareRateLimiter } from '../../src/app'
import type { DjDeps } from '../../src/dj/loop'
import type { LlmClient } from '../../src/dj/llm'
import { djSessions, mixShares, mixShareSaves, tracks, user } from '../../src/db/schema'
import { generateShareToken } from '../../src/shares/store'

// Spec 2026-11-13 shared-mixes (API table: GET /me/shared-mixes; Merging and
// deletion; the anonymous cap), plan task S3.

const SHARER = 'user-sharer-1'
const LISTENER = 'user-listener-2'
const OTHER_SHARER = 'user-sharer-3'
const ANON = 'user-anon-4'

const llm: LlmClient = async () => ({ text: 'ok', toolCalls: [], raw: [{ type: 'text', text: 'ok' }], stopReason: 'end_turn', usage: null })
const djDeps: DjDeps = { llm, embed: async () => new Array(1024).fill(0) }

const USERS: Record<string, SessionUser> = {
  [SHARER]: { id: SHARER, name: 'Ada Lovelace' },
  [LISTENER]: { id: LISTENER, name: 'Grace Hopper' },
  [OTHER_SHARER]: { id: OTHER_SHARER, name: '' },
  [ANON]: { id: ANON, name: 'Listener', isAnonymous: true },
}

type Caller = { current: string | null }

function authFor(caller: Caller): AuthLike {
  return {
    handler: () => new Response('ok'),
    api: { getSession: async () => (caller.current ? { user: USERS[caller.current] } : null) },
  }
}

const allowAll: ShareRateLimiter = { limit: async () => ({ success: true }) }

async function setup() {
  const db = await createTestDb()
  for (const u of Object.values(USERS)) {
    await db.insert(user).values({
      id: u.id,
      name: u.name ?? '',
      email: `${u.id}@example.com`,
      emailVerified: false,
      isAnonymous: u.isAnonymous === true,
      createdAt: new Date(),
      updatedAt: new Date(),
    })
  }
  const caller: Caller = { current: LISTENER }
  const app = createApp({
    auth: authFor(caller),
    db,
    dj: { deps: djDeps },
    shares: { baseUrl: 'https://miixtape.netlify.app', limiter: allowAll },
  })
  return { db, app, caller }
}

type App = Awaited<ReturnType<typeof setup>>['app']

function send(app: App, method: string, path: string, body?: unknown) {
  return app.request(`http://x${path}`, {
    method,
    headers: { 'content-type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  })
}

let trackN = 0
async function seedTrack(db: TestDb, overrides: Partial<typeof tracks.$inferInsert> = {}) {
  trackN += 1
  const [t] = await db
    .insert(tracks)
    .values({
      title: `Song ${trackN}`,
      artist: `Artist ${trackN}`,
      durationMs: 200_000,
      artworkUrlTemplate: `https://art.example/${trackN}/{w}x{h}.jpg`,
      artworkWidth: 1000,
      artworkHeight: 800,
      artworkBgColor: 'aabbcc',
      ...overrides,
    })
    .returning()
  return t!
}

// A share row written directly, so entries can point at tracks that no
// longer resolve.
async function seedShare(
  db: TestDb,
  opts: { sharerId?: string; title?: string; trackIds?: string[]; revoked?: boolean } = {},
) {
  const sharerId = opts.sharerId ?? SHARER
  const [session] = await db
    .insert(djSessions)
    .values({ userId: sharerId, title: opts.title ?? 'Rainy drive', caseColor: '#b84755' })
    .returning()
  const trackIds = opts.trackIds ?? [(await seedTrack(db)).id]
  const [share] = await db
    .insert(mixShares)
    .values({
      token: generateShareToken(),
      sessionId: session!.id,
      sharerId,
      queueVersion: session!.queueVersion,
      title: opts.title ?? 'Rainy drive',
      caseColor: '#b84755',
      entries: trackIds.map((trackId, position) => ({ position, trackId })),
      ...(opts.revoked ? { revokedAt: new Date() } : {}),
    })
    .returning()
  return { session: session!, share: share! }
}

async function save(db: TestDb, userId: string, shareId: string, savedAt: Date) {
  await db.insert(mixShareSaves).values({ userId, shareId, savedAt })
}

type Row = {
  token: string
  title: string
  caseColor: string
  sharerName: string | null
  savedAt: string
  trackCount: number
  durationMs: number
  artwork: { url: string; width: number | null; height: number | null; bgColor: string | null } | null
}

async function list(app: App): Promise<Row[]> {
  const res = await send(app, 'GET', '/me/shared-mixes')
  expect(res.status).toBe(200)
  return ((await res.json()) as { mixes: Row[] }).mixes
}

describe('GET /me/shared-mixes', () => {
  it('needs a session', async () => {
    const { app, caller } = await setup()
    caller.current = null
    const res = await send(app, 'GET', '/me/shared-mixes')
    expect(res.status).toBe(401)
  })

  it('is empty for a listener with no saves', async () => {
    const { app } = await setup()
    expect(await list(app)).toEqual([])
  })

  it('lists the caller\'s saves with the row shape, newest save first', async () => {
    const { app, db } = await setup()
    const older = await seedShare(db, { title: 'Older' })
    const newer = await seedShare(db, { title: 'Newer', sharerId: OTHER_SHARER })
    await save(db, LISTENER, older.share.id, new Date('2026-11-01T10:00:00Z'))
    await save(db, LISTENER, newer.share.id, new Date('2026-11-02T10:00:00Z'))
    // Someone else's save never shows.
    const notMine = await seedShare(db, { title: 'Not mine' })
    await save(db, ANON, notMine.share.id, new Date('2026-11-03T10:00:00Z'))

    const rows = await list(app)
    expect(rows.map((r) => r.title)).toEqual(['Newer', 'Older'])
    expect(Object.keys(rows[0]!).sort()).toEqual(
      ['artwork', 'caseColor', 'durationMs', 'savedAt', 'sharerName', 'title', 'token', 'trackCount'],
    )
    expect(rows[0]).toMatchObject({
      token: newer.share.token,
      caseColor: '#b84755',
      // A sharer with no usable name: clients show "a friend".
      sharerName: null,
      savedAt: '2026-11-02T10:00:00.000Z',
    })
    expect(rows[1]!.sharerName).toBe('Ada')
  })

  it('leaves out revoked shares', async () => {
    const { app, db } = await setup()
    const live = await seedShare(db, { title: 'Live' })
    const dead = await seedShare(db, { title: 'Dead', revoked: true })
    await save(db, LISTENER, live.share.id, new Date('2026-11-01T10:00:00Z'))
    await save(db, LISTENER, dead.share.id, new Date('2026-11-02T10:00:00Z'))
    expect((await list(app)).map((r) => r.title)).toEqual(['Live'])
  })

  it('counts and times only songs that still resolve, and takes the first resolvable song\'s artwork', async () => {
    const { app, db } = await setup()
    const noArt = await seedTrack(db, { durationMs: 100_000, artworkUrlTemplate: null })
    const withArt = await seedTrack(db, { durationMs: null, artworkUrlTemplate: 'https://art.example/x/{w}x{h}.jpg' })
    const third = await seedTrack(db, { durationMs: 50_000 })
    const gone = randomUUID()
    const { share } = await seedShare(db, { trackIds: [gone, noArt.id, withArt.id, third.id] })
    await save(db, LISTENER, share.id, new Date())

    const [row] = await list(app)
    expect(row!.trackCount).toBe(3)
    // Null durations count as zero.
    expect(row!.durationMs).toBe(150_000)
    // The first resolvable song has no artwork, so the row's artwork is null.
    expect(row!.artwork).toBeNull()
  })

  it('takes artwork in the readShare shape from the first resolvable song', async () => {
    const { app, db } = await setup()
    const first = await seedTrack(db)
    const second = await seedTrack(db)
    const { share } = await seedShare(db, { trackIds: [randomUUID(), first.id, second.id] })
    await save(db, LISTENER, share.id, new Date())
    const [row] = await list(app)
    expect(row!.artwork).toEqual({ url: first.artworkUrlTemplate, width: 1000, height: 800, bgColor: 'aabbcc' })
  })

  it('reports zero songs and no artwork when nothing in the snapshot resolves', async () => {
    const { app, db } = await setup()
    const { share } = await seedShare(db, { trackIds: [randomUUID()] })
    await save(db, LISTENER, share.id, new Date())
    const [row] = await list(app)
    expect(row).toMatchObject({ trackCount: 0, durationMs: 0, artwork: null })
  })
})

describe('account deletion and shares', () => {
  it('removes the deleted listener\'s saves', async () => {
    const { app, db } = await setup()
    const { share } = await seedShare(db)
    await save(db, LISTENER, share.id, new Date())
    const res = await send(app, 'DELETE', '/me')
    expect(res.status).toBe(200)
    expect(await db.select().from(mixShareSaves)).toEqual([])
    // The sharer's share is untouched.
    expect(await db.select().from(mixShares)).toHaveLength(1)
  })

  it('removes the deleted sharer\'s shares and everyone\'s saves of them', async () => {
    const { app, db, caller } = await setup()
    const mine = await seedShare(db, { sharerId: SHARER })
    const theirs = await seedShare(db, { sharerId: OTHER_SHARER })
    await save(db, LISTENER, mine.share.id, new Date())
    await save(db, ANON, mine.share.id, new Date())
    await save(db, LISTENER, theirs.share.id, new Date())
    caller.current = SHARER
    const res = await send(app, 'DELETE', '/me')
    expect(res.status).toBe(200)
    expect((await db.select().from(mixShares)).map((s) => s.id)).toEqual([theirs.share.id])
    expect(await db.select().from(mixShareSaves)).toEqual([
      expect.objectContaining({ userId: LISTENER, shareId: theirs.share.id }),
    ])
  })
})

describe('anonymous mix cap and saved shares', () => {
  it('does not count saved shares toward the cap', async () => {
    const { app, db, caller } = await setup()
    caller.current = ANON
    // Three saved shares from other people.
    for (let i = 0; i < 3; i++) {
      const { share } = await seedShare(db, { title: `Shared ${i}` })
      await save(db, ANON, share.id, new Date())
    }
    // Two of the anonymous listener's own mixes, below the cap of three.
    await db.insert(djSessions).values([{ userId: ANON, title: 'a' }, { userId: ANON, title: 'b' }])
    const res = await send(app, 'POST', '/sessions', { prompt: 'third mix' })
    expect(res.status).toBe(200)
    expect(await db.select().from(djSessions).where(eq(djSessions.userId, ANON))).toHaveLength(3)

    const capped = await send(app, 'POST', '/sessions', { prompt: 'fourth mix' })
    expect(capped.status).toBe(403)
  })
})
