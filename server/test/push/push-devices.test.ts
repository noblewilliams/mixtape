import { describe, expect, it } from 'vitest'
import { eq } from 'drizzle-orm'
import { randomUUID } from 'node:crypto'
import { createTestDb, type TestDb } from '../helpers/db'
import { createApp, type AuthLike } from '../../src/app'
import { linkAnonymousRows } from '../../src/auth/link-anonymous'
import { djSessions, djTurns, pushDevices, user } from '../../src/db/schema'

// Push registration (spec 2026-11-21 durable-mix-turns, "Device
// registration"): PUT /push/devices and DELETE /push/devices/:token.

const APNS = 'AB'.repeat(32)
const ENDPOINT = 'https://fcm.googleapis.com/fcm/send/abc123:def/ghi'
const KEYS = { p256dh: 'BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4', auth: 'BTBZMqHH6r4Tts7J_aSIgg' }

async function seedUser(db: TestDb, id: string, isAnonymous = false) {
  await db.insert(user).values({ id, name: id, email: `${id}@example.com`, emailVerified: false, isAnonymous, createdAt: new Date(), updatedAt: new Date() })
}

function authedAs(id: string, isAnonymous = false): AuthLike {
  return { handler: () => new Response('ok'), api: { getSession: async () => ({ user: { id, isAnonymous } }) } }
}

function app(db: TestDb, userId = 'u1', isAnonymous = false) {
  return createApp({ auth: authedAs(userId, isAnonymous), db })
}

function send(a: ReturnType<typeof createApp>, method: string, path: string, body?: unknown) {
  return a.request(`http://x${path}`, {
    method,
    headers: { 'content-type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  })
}

const apnsBody = (extra: Record<string, unknown> = {}) => ({ provider: 'apns', platform: 'ios', token: APNS, environment: 'production', appVersion: '1.2.0 (9)', ...extra })
const webBody = (extra: Record<string, unknown> = {}) => ({ provider: 'webpush', platform: 'web', token: ENDPOINT, keys: KEYS, ...extra })

const devices = (db: TestDb) => db.select().from(pushDevices)

describe('PUT /push/devices', () => {
  it('needs a session', async () => {
    const db = await createTestDb()
    const a = createApp({ auth: { handler: () => new Response('ok'), api: { getSession: async () => null } }, db })
    expect((await send(a, 'PUT', '/push/devices', apnsBody())).status).toBe(401)
    expect((await send(a, 'DELETE', `/push/devices/${APNS}`)).status).toBe(401)
  })

  it('registers an APNs device, lower-casing its token', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const res = await send(app(db), 'PUT', '/push/devices', apnsBody())
    expect(res.status).toBe(204)
    const [row] = await devices(db)
    expect(row).toMatchObject({ userId: 'u1', provider: 'apns', platform: 'ios', token: APNS.toLowerCase(), environment: 'production', appVersion: '1.2.0 (9)', keys: null, disabledAt: null })
  })

  it('registers a web push subscription with its keys', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    expect((await send(app(db), 'PUT', '/push/devices', webBody())).status).toBe(204)
    const [row] = await devices(db)
    expect(row).toMatchObject({ userId: 'u1', provider: 'webpush', platform: 'web', token: ENDPOINT, keys: KEYS, environment: null })
  })

  it.each([
    ['a short APNs token', apnsBody({ token: 'ab'.repeat(31) })],
    ['a long APNs token', apnsBody({ token: 'a'.repeat(202) })],
    ['a non-hex APNs token', apnsBody({ token: 'zz'.repeat(32) })],
    ['an APNs device without its environment', apnsBody({ environment: undefined })],
    ['an unknown environment', apnsBody({ environment: 'staging' })],
    ['an APNs device on the web platform', apnsBody({ platform: 'web' })],
    ['an app version over 40 characters', apnsBody({ appVersion: 'x'.repeat(41) })],
    ['an http endpoint', webBody({ token: 'http://push.example.com/x' })],
    ['an endpoint that is not a URL', webBody({ token: 'not a url' })],
    ['an endpoint over 1024 characters', webBody({ token: `https://push.example.com/${'a'.repeat(1010)}` })],
    ['a web device without keys', webBody({ keys: undefined })],
    ['keys that are not base64url', webBody({ keys: { p256dh: 'a b+c', auth: KEYS.auth } })],
    ['a missing auth key', webBody({ keys: { p256dh: KEYS.p256dh } })],
    ['an unknown provider', { provider: 'fcm', platform: 'android', token: 'x' }],
  ])('refuses %s', async (_name, body) => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const res = await send(app(db), 'PUT', '/push/devices', body)
    expect(res.status).toBe(400)
    expect(await res.json()).toEqual({ error: 'invalid_request' })
    expect(await devices(db)).toHaveLength(0)
  })

  it('refuses a body that is not JSON', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const res = await app(db).request('http://x/push/devices', { method: 'PUT', headers: { 'content-type': 'application/json' }, body: '{' })
    expect(res.status).toBe(400)
  })

  it('upserts on (provider, token): the row moves to the caller, is live again and seen now', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedUser(db, 'u2')
    await send(app(db, 'u1'), 'PUT', '/push/devices', apnsBody({ environment: 'sandbox' }))
    const long = new Date('2026-01-01T00:00:00Z')
    await db.update(pushDevices).set({ disabledAt: long, lastSeenAt: long })

    // The same phone, now signed in to another account, in upper case.
    expect((await send(app(db, 'u2'), 'PUT', '/push/devices', apnsBody({ appVersion: '1.3.0' }))).status).toBe(204)
    const rows = await devices(db)
    expect(rows).toHaveLength(1)
    expect(rows[0]).toMatchObject({ userId: 'u2', environment: 'production', appVersion: '1.3.0', disabledAt: null })
    expect(rows[0]!.lastSeenAt.getTime()).toBeGreaterThan(long.getTime())
  })

  it('updates a web subscription\'s keys in place', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await send(app(db), 'PUT', '/push/devices', webBody())
    const keys = { p256dh: KEYS.p256dh, auth: 'AAAAAAAAAAAAAAAAAAAAAA' }
    await send(app(db), 'PUT', '/push/devices', webBody({ keys }))
    const rows = await devices(db)
    expect(rows).toHaveLength(1)
    expect(rows[0]!.keys).toEqual(keys)
  })

  it('lets an anonymous listener register', async () => {
    const db = await createTestDb()
    await seedUser(db, 'anon', true)
    expect((await send(app(db, 'anon', true), 'PUT', '/push/devices', apnsBody())).status).toBe(204)
    expect((await devices(db))[0]!.userId).toBe('anon')
  })
})

describe('DELETE /push/devices/:token', () => {
  it('deletes the caller\'s row for that token, any provider, and only theirs', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedUser(db, 'u2')
    await send(app(db, 'u1'), 'PUT', '/push/devices', apnsBody())
    await send(app(db, 'u1'), 'PUT', '/push/devices', webBody())
    // u2 holds another device; u1 deleting it is a no-op.
    const other = 'cd'.repeat(32)
    await send(app(db, 'u2'), 'PUT', '/push/devices', apnsBody({ token: other }))

    expect((await send(app(db, 'u1'), 'DELETE', `/push/devices/${other}`)).status).toBe(204)
    expect(await devices(db)).toHaveLength(3)

    // Upper case, as the client may hold it.
    expect((await send(app(db, 'u1'), 'DELETE', `/push/devices/${APNS}`)).status).toBe(204)
    // The endpoint, URL-encoded (it carries slashes and a colon).
    expect((await send(app(db, 'u1'), 'DELETE', `/push/devices/${encodeURIComponent(ENDPOINT)}`)).status).toBe(204)
    const left = await devices(db)
    expect(left.map((d) => [d.userId, d.token])).toEqual([['u2', other]])
  })

  it('is a 204 for a token it does not know', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    expect((await send(app(db), 'DELETE', '/push/devices/nothing-here')).status).toBe(204)
  })
})

describe('push devices follow the listener', () => {
  it('an anonymous link moves the devices (and the mix\'s turns) to the new account', async () => {
    const db = await createTestDb()
    const anon = randomUUID()
    const next = randomUUID()
    await seedUser(db, anon, true)
    await seedUser(db, next)
    await send(app(db, anon, true), 'PUT', '/push/devices', apnsBody())
    await send(app(db, anon, true), 'PUT', '/push/devices', webBody())
    const [mix] = await db.insert(djSessions).values({ userId: anon, title: 'Late night' }).returning()
    const [turn] = await db.insert(djTurns).values({ sessionId: mix!.id, userId: anon, kind: 'create', status: 'done' }).returning()

    await linkAnonymousRows(db, { anonymousUserId: anon, newUserId: next })
    // The plugin deletes the anonymous user next.
    await db.delete(user).where(eq(user.id, anon))

    const rows = await devices(db)
    expect(rows.map((d) => d.userId)).toEqual([next, next])
    const [moved] = await db.select().from(djTurns).where(eq(djTurns.id, turn!.id))
    expect(moved?.userId).toBe(next)
  })

  it('moves devices even when there is no mix to merge', async () => {
    const db = await createTestDb()
    const anon = randomUUID()
    const next = randomUUID()
    await seedUser(db, anon, true)
    await seedUser(db, next)
    await db.insert(djSessions).values({ userId: next, title: 'Mine already' })
    await send(app(db, anon, true), 'PUT', '/push/devices', apnsBody())

    expect(await linkAnonymousRows(db, { anonymousUserId: anon, newUserId: next })).toEqual({ mode: 'none' })
    expect((await devices(db))[0]!.userId).toBe(next)
  })

  it('account deletion removes the user\'s devices and leaves others\'', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedUser(db, 'u2')
    await send(app(db, 'u1'), 'PUT', '/push/devices', apnsBody())
    await send(app(db, 'u2'), 'PUT', '/push/devices', webBody())

    const res = await createApp({ auth: authedAs('u1'), db, accountDeletion: {} }).request('http://x/me', { method: 'DELETE', headers: { 'content-type': 'application/json' } })
    expect(res.status).toBe(200)
    expect((await devices(db)).map((d) => d.userId)).toEqual(['u2'])
  })
})
