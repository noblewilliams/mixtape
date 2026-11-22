import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest'
import { eq } from 'drizzle-orm'
import { createTestDb, type TestDb } from '../helpers/db'
import { djMessages, djSessions, djTurns, pushDevices, user } from '../../src/db/schema'
import { budgetedFetch, MAX_DEVICES_PER_TURN, notifyTurn, NOTIFY_RECHECK_MS, type NotifyDeps, type PushConfig } from '../../src/push/notify'
import { FAILED_LINES } from '../../src/push/copy'
import { computePush } from '../../src/routes/turns'
import type { VapidCache } from '../../src/push/webpush'

// notify (spec 2026-11-21 durable-mix-turns, "Who notifies", "APNs from
// Workers", "Web push"), on a fake fetch and a fake clock.

// RFC 8291 appendix A keys: the server pair as our VAPID keys, the user
// agent's public key and auth secret as a subscription.
const VAPID = {
  publicKey: 'BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8',
  privateKey: 'yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw',
  subject: 'mailto:push@example.com',
}
const SUBSCRIPTION = { p256dh: 'BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4', auth: 'BTBZMqHH6r4Tts7J_aSIgg' }
const PHONE = 'ab'.repeat(32)
const LAPTOP = 'https://fcm.googleapis.com/fcm/send/laptop'
const OLD_LAPTOP = 'https://updates.push.services.mozilla.com/wpush/v2/gone'
const NOW = new Date('2026-11-22T10:00:00.000Z')
const PROMPT = 'songs for my secret breakup with Sam'
const REPLY = 'Here is something tender for the breakup.'

let privateKey: string
beforeAll(async () => {
  const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify'])
  const b64 = Buffer.from(await crypto.subtle.exportKey('pkcs8', pair.privateKey)).toString('base64').replace(/(.{64})/g, '$1\n')
  privateKey = `-----BEGIN PRIVATE KEY-----\n${b64}\n-----END PRIVATE KEY-----\n`
})

let logs: string[]
beforeEach(() => {
  logs = []
  vi.spyOn(console, 'log').mockImplementation((line: unknown) => void logs.push(String(line)))
})
afterEach(() => {
  vi.restoreAllMocks()
})

const config = (): PushConfig => ({
  enabled: true,
  apns: { teamId: 'TEAM123456', keyId: 'KEY1234567', privateKey, topic: 'com.example.mixtape' },
  vapid: VAPID,
})

type Call = { url: string; headers: Record<string, string>; body: unknown }
type Responder = (url: string, call: number) => Response

// APNs answers 200, web push 201, unless the test says otherwise.
function fakeFetch(respond: Responder = (url) => new Response(null, { status: url.includes('push.apple.com') ? 200 : 201 })) {
  const calls: Call[] = []
  const fetch = async (url: string, init: RequestInit) => {
    calls.push({ url, headers: init.headers as Record<string, string>, body: init.body })
    return respond(url, calls.length)
  }
  return { fetch, calls }
}

async function seed(db: TestDb, { title = 'Rainy Drive', status = 'done' as 'done' | 'failed' | 'stopped' | 'running', errorKind = null as string | null, watched = false } = {}) {
  await db.insert(user).values({ id: 'u1', name: 'u1', email: 'u1@example.com', emailVerified: false, createdAt: NOW, updatedAt: NOW }).onConflictDoNothing()
  const [session] = await db.insert(djSessions).values({ userId: 'u1', title }).returning()
  await db.insert(djMessages).values([
    { sessionId: session!.id, role: 'user', content: PROMPT },
    { sessionId: session!.id, role: 'dj', content: REPLY },
  ])
  const [turn] = await db
    .insert(djTurns)
    .values({ sessionId: session!.id, userId: 'u1', kind: 'message', status, errorKind, watchedResult: watched })
    .returning()
  return { sessionId: session!.id, turnId: turn!.id }
}

async function addPhone(db: TestDb, token = PHONE) {
  await db.insert(pushDevices).values({ userId: 'u1', provider: 'apns', platform: 'ios', token, environment: 'production' })
}
async function addLaptop(db: TestDb, endpoint = LAPTOP, keys: { p256dh: string; auth: string } = SUBSCRIPTION) {
  await db.insert(pushDevices).values({ userId: 'u1', provider: 'webpush', platform: 'web', token: endpoint, keys })
}

async function turnOf(db: TestDb, id: string) {
  const [row] = await db.select().from(djTurns).where(eq(djTurns.id, id))
  return row!
}

function deps(db: TestDb, fetch: NotifyDeps['fetch'], extra: Partial<NotifyDeps> = {}): NotifyDeps {
  return { db, config: config(), fetch, now: () => NOW, vapidCache: new Map() as VapidCache, ...extra }
}

const apnsCalls = (calls: Call[]) => calls.filter((c) => c.url.includes('push.apple.com'))
const pushLogs = () => logs.map((line) => JSON.parse(line) as Record<string, unknown>).filter((l) => l.event === 'turn_push')

describe('notifyTurn: when it pushes', () => {
  it('records off with TURN_PUSH off, and sends nothing', async () => {
    const db = await createTestDb()
    const { turnId } = await seed(db)
    await addPhone(db)
    const { fetch, calls } = fakeFetch()
    expect(await notifyTurn(deps(db, fetch, { config: { enabled: false } }), turnId)).toBe('off')
    expect(calls).toHaveLength(0)
    expect(await turnOf(db, turnId)).toMatchObject({ notifyOutcome: 'off', notifiedAt: NOW })
  })

  it('records no_device when every device is disabled', async () => {
    const db = await createTestDb()
    const { turnId } = await seed(db)
    await addPhone(db)
    await db.update(pushDevices).set({ disabledAt: NOW })
    const { fetch, calls } = fakeFetch()
    expect(await notifyTurn(deps(db, fetch), turnId)).toBe('no_device')
    expect(calls).toHaveLength(0)
    expect((await turnOf(db, turnId)).notifyOutcome).toBe('no_device')
  })

  it.each(['stopped', 'running'] as const)('skips a %s turn and records nothing', async (status) => {
    const db = await createTestDb()
    const { turnId } = await seed(db, { status })
    await addPhone(db)
    const { fetch, calls } = fakeFetch()
    expect(await notifyTurn(deps(db, fetch), turnId)).toBe('skipped')
    expect(calls).toHaveLength(0)
    expect(await turnOf(db, turnId)).toMatchObject({ notifyOutcome: null, notifiedAt: null })
  })

  it('skips a turn that is gone with its session', async () => {
    const db = await createTestDb()
    const { turnId, sessionId } = await seed(db)
    await db.delete(djSessions).where(eq(djSessions.id, sessionId))
    const { fetch } = fakeFetch()
    expect(await notifyTurn(deps(db, fetch), turnId)).toBe('skipped')
  })

  it('a watched result waits 8 s; seen by then, no push', async () => {
    const db = await createTestDb()
    const { turnId } = await seed(db, { watched: true })
    await addPhone(db)
    const { fetch, calls } = fakeFetch()
    const scheduleRecheck = vi.fn()

    expect(await notifyTurn(deps(db, fetch, { scheduleRecheck }), turnId)).toBe('deferred')
    expect(scheduleRecheck).toHaveBeenCalledWith(NOTIFY_RECHECK_MS)
    expect(NOTIFY_RECHECK_MS).toBe(8_000)
    expect(await turnOf(db, turnId)).toMatchObject({ notifiedAt: null, notifyOutcome: null })

    // The client's POST /sessions/:id/turn/:turnId/seen.
    await db.update(djTurns).set({ seenAt: NOW }).where(eq(djTurns.id, turnId))
    expect(await notifyTurn(deps(db, fetch, { scheduleRecheck }), turnId, { recheck: true })).toBe('seen')
    expect(calls).toHaveLength(0)
    expect(scheduleRecheck).toHaveBeenCalledTimes(1)
    expect((await turnOf(db, turnId)).notifyOutcome).toBe('seen')
  })

  it('a watched result not seen in 8 s pushes once, on the recheck', async () => {
    const db = await createTestDb()
    const { turnId } = await seed(db, { watched: true })
    await addPhone(db)
    const { fetch, calls } = fakeFetch()
    const scheduleRecheck = vi.fn()

    expect(await notifyTurn(deps(db, fetch, { scheduleRecheck }), turnId)).toBe('deferred')
    expect(calls).toHaveLength(0)
    expect(await notifyTurn(deps(db, fetch, { scheduleRecheck }), turnId, { recheck: true })).toBe('sent')
    expect(calls).toHaveLength(1)
    expect(await notifyTurn(deps(db, fetch, { scheduleRecheck }), turnId, { recheck: true })).toBe('already')
    expect(calls).toHaveLength(1)
    expect(await turnOf(db, turnId)).toMatchObject({ notifyOutcome: 'sent', notifiedAt: NOW })
  })

  it('a watched result with no one to come back (the cron) pushes at once', async () => {
    const db = await createTestDb()
    const { turnId } = await seed(db, { watched: true })
    await addPhone(db)
    const { fetch, calls } = fakeFetch()
    expect(await notifyTurn(deps(db, fetch), turnId)).toBe('sent')
    expect(calls).toHaveLength(1)
  })

  it('a result seen before the first call records seen', async () => {
    const db = await createTestDb()
    const { turnId } = await seed(db, { watched: true })
    await addPhone(db)
    await db.update(djTurns).set({ seenAt: NOW }).where(eq(djTurns.id, turnId))
    const { fetch, calls } = fakeFetch()
    expect(await notifyTurn(deps(db, fetch, { scheduleRecheck: vi.fn() }), turnId)).toBe('seen')
    expect(calls).toHaveLength(0)
  })

  it('a result no watcher took pushes now; a second call sends nothing more', async () => {
    const db = await createTestDb()
    const { turnId } = await seed(db)
    await addPhone(db)
    const { fetch, calls } = fakeFetch()
    const scheduleRecheck = vi.fn()
    expect(await notifyTurn(deps(db, fetch, { scheduleRecheck }), turnId)).toBe('sent')
    expect(scheduleRecheck).not.toHaveBeenCalled()
    expect(await notifyTurn(deps(db, fetch, { scheduleRecheck }), turnId)).toBe('already')
    expect(calls).toHaveLength(1)
  })

  it('two callers at once send once', async () => {
    const db = await createTestDb()
    const { turnId } = await seed(db)
    await addPhone(db)
    const { fetch, calls } = fakeFetch()
    const results = await Promise.all([notifyTurn(deps(db, fetch), turnId), notifyTurn(deps(db, fetch), turnId)])
    expect(results.sort()).toEqual(['already', 'sent'])
    expect(calls).toHaveLength(1)
  })
})

describe('notifyTurn: fan-out', () => {
  it('pushes every live device, disables one the push service says is gone, and logs codes only', async () => {
    const db = await createTestDb()
    const { turnId } = await seed(db)
    await addPhone(db)
    await addLaptop(db)
    await addLaptop(db, OLD_LAPTOP)
    // A device already disabled is not tried.
    await addPhone(db, 'cd'.repeat(32))
    await db.update(pushDevices).set({ disabledAt: NOW }).where(eq(pushDevices.token, 'cd'.repeat(32)))
    const { fetch, calls } = fakeFetch((url) =>
      url === OLD_LAPTOP ? new Response(null, { status: 410 }) : new Response(null, { status: url.includes('apple') ? 200 : 201 }),
    )

    expect(await notifyTurn(deps(db, fetch), turnId)).toBe('sent')
    expect(calls.map((c) => c.url).sort()).toEqual([`https://api.push.apple.com/3/device/${PHONE}`, LAPTOP, OLD_LAPTOP].sort())
    const rows = await db.select().from(pushDevices)
    expect(rows.find((d) => d.token === OLD_LAPTOP)!.disabledAt).toEqual(NOW)
    expect(rows.find((d) => d.token === LAPTOP)!.disabledAt).toBeNull()
    expect(rows.find((d) => d.token === PHONE)!.disabledAt).toBeNull()

    const lines = pushLogs()
    expect(lines).toHaveLength(3)
    for (const line of lines) expect(Object.keys(line).sort()).toEqual(['event', 'outcome', 'reason', 'status'])
    expect(lines.map((l) => l.outcome).sort()).toEqual(['disable', 'sent', 'sent'])
    expect(logs.join('\n')).not.toMatch(/Rainy|breakup|abab|fcm\.googleapis/)
  })

  it('APNs headers: topic, collapse id = turn id, alert push, provider token', async () => {
    const db = await createTestDb()
    const { turnId } = await seed(db)
    await addPhone(db)
    const { fetch, calls } = fakeFetch()
    await notifyTurn(deps(db, fetch), turnId)
    expect(calls[0]!.headers).toMatchObject({
      'apns-topic': 'com.example.mixtape',
      'apns-collapse-id': turnId,
      'apns-push-type': 'alert',
      'apns-priority': '10',
    })
    expect(calls[0]!.headers.authorization).toMatch(/^bearer ey/)
  })

  it('an APNs ExpiredProviderToken re-signs once and retries once', async () => {
    const db = await createTestDb()
    const { turnId } = await seed(db)
    await addPhone(db)
    const { fetch, calls } = fakeFetch((_url, n) =>
      n === 1 ? Response.json({ reason: 'ExpiredProviderToken' }, { status: 403 }) : new Response(null, { status: 200 }),
    )
    expect(await notifyTurn(deps(db, fetch), turnId)).toBe('sent')
    expect(calls).toHaveLength(2)
    expect(calls[1]!.headers.authorization).not.toBe(calls[0]!.headers.authorization)
  })

  it('a second provider-token rejection is not re-signed again: failed', async () => {
    const db = await createTestDb()
    const { turnId } = await seed(db)
    await addPhone(db)
    const { fetch, calls } = fakeFetch(() => Response.json({ reason: 'InvalidProviderToken' }, { status: 403 }))
    expect(await notifyTurn(deps(db, fetch), turnId)).toBe('failed')
    expect(calls).toHaveLength(2)
    expect(await turnOf(db, turnId)).toMatchObject({ notifyOutcome: 'failed', notifiedAt: NOW })
    expect((await db.select().from(pushDevices))[0]!.disabledAt).toBeNull()
  })

  it('one re-sign covers every APNs device that saw the rejection', async () => {
    const db = await createTestDb()
    const { turnId } = await seed(db)
    await addPhone(db)
    await addPhone(db, 'ef'.repeat(32))
    const seenTokens = new Map<string, number>()
    let rejected: string | undefined
    const { fetch, calls } = fakeFetch(() => new Response(null, { status: 200 }))
    const wrapped: NotifyDeps['fetch'] = async (url, init) => {
      const auth = (init.headers as Record<string, string>).authorization!
      seenTokens.set(auth, (seenTokens.get(auth) ?? 0) + 1)
      rejected ??= auth
      if (auth === rejected) {
        calls.push({ url, headers: init.headers as Record<string, string>, body: init.body })
        return Response.json({ reason: 'ExpiredProviderToken' }, { status: 403 })
      }
      return fetch(url, init)
    }
    expect(await notifyTurn(deps(db, wrapped), turnId)).toBe('sent')
    // Two tokens in all: the rejected one and a single fresh one.
    expect(seenTokens.size).toBe(2)
    expect(apnsCalls(calls)).toHaveLength(4)
  })

  it.each([429, 500, 503])('APNs %i gives up for this turn: failed, device kept', async (status) => {
    const db = await createTestDb()
    const { turnId } = await seed(db)
    await addPhone(db)
    const { fetch, calls } = fakeFetch(() => Response.json({ reason: 'TooManyRequests' }, { status }))
    expect(await notifyTurn(deps(db, fetch), turnId)).toBe('failed')
    expect(calls).toHaveLength(1)
    expect((await db.select().from(pushDevices))[0]!.disabledAt).toBeNull()
  })

  it('APNs 410 Unregistered disables the phone', async () => {
    const db = await createTestDb()
    const { turnId } = await seed(db)
    await addPhone(db)
    const { fetch } = fakeFetch(() => Response.json({ reason: 'Unregistered' }, { status: 410 }))
    expect(await notifyTurn(deps(db, fetch), turnId)).toBe('failed')
    expect((await db.select().from(pushDevices))[0]!.disabledAt).toEqual(NOW)
  })

  it('a subscription whose keys cannot encrypt is disabled without a send', async () => {
    const db = await createTestDb()
    const { turnId } = await seed(db)
    await addLaptop(db, LAPTOP, { p256dh: 'AAAA', auth: SUBSCRIPTION.auth })
    const { fetch, calls } = fakeFetch()
    expect(await notifyTurn(deps(db, fetch), turnId)).toBe('failed')
    expect(calls).toHaveLength(0)
    expect((await db.select().from(pushDevices))[0]!.disabledAt).toEqual(NOW)
  })

  it('a bad VAPID key gives up without disabling the subscription', async () => {
    const db = await createTestDb()
    const { turnId } = await seed(db)
    await addLaptop(db)
    const { fetch, calls } = fakeFetch()
    const broken = { ...config(), vapid: { ...VAPID, privateKey: 'short' } }
    expect(await notifyTurn(deps(db, fetch, { config: broken }), turnId)).toBe('failed')
    expect(calls).toHaveLength(0)
    expect((await db.select().from(pushDevices))[0]!.disabledAt).toBeNull()
  })
})

describe('notifyTurn: bounded fan-out', () => {
  // Rotated APNs tokens and old browsers stay live until a push disables
  // them: the fan-out is capped, newest registrations first.
  it(`pushes at most MAX_DEVICES_PER_TURN devices, the most recently seen`, async () => {
    const db = await createTestDb()
    const { turnId } = await seed(db)
    const total = MAX_DEVICES_PER_TURN + 3
    for (let i = 0; i < total; i += 1) {
      await db.insert(pushDevices).values({
        userId: 'u1', provider: 'webpush', platform: 'web', token: `https://fcm.googleapis.com/fcm/send/d${i}`, keys: SUBSCRIPTION,
        lastSeenAt: new Date(NOW.getTime() - (total - i) * 60_000),
      })
    }
    const { fetch, calls } = fakeFetch()
    expect(await notifyTurn(deps(db, fetch), turnId)).toBe('sent')
    expect(calls).toHaveLength(MAX_DEVICES_PER_TURN)
    expect(calls.map((c) => c.url)).not.toContain('https://fcm.googleapis.com/fcm/send/d0')
    expect(calls.map((c) => c.url)).toContain(`https://fcm.googleapis.com/fcm/send/d${total - 1}`)
  })

  it('a spent fetch budget sends nothing more (the cron run\'s subrequests)', async () => {
    const inner = fakeFetch()
    const fetch = budgetedFetch(1, inner.fetch)
    const db = await createTestDb()
    const first = await seed(db)
    const second = await seed(db)
    await addPhone(db)
    expect(await notifyTurn(deps(db, fetch), first.turnId)).toBe('sent')
    expect(await notifyTurn(deps(db, fetch), second.turnId)).toBe('failed')
    expect(inner.calls).toHaveLength(1)
  })
})

describe('notifyTurn: what the push says', () => {
  async function apnsPayload(db: TestDb, turnId: string) {
    const { fetch, calls } = fakeFetch()
    await notifyTurn(deps(db, fetch), turnId)
    return JSON.parse(String(calls[0]!.body)) as Record<string, unknown>
  }

  it('a ready mix: its title, and nothing of the prompt or the reply (snapshot)', async () => {
    const db = await createTestDb()
    const { turnId, sessionId } = await seed(db)
    await addPhone(db)
    const payload = await apnsPayload(db, turnId)
    expect(payload).toEqual({
      aps: { alert: { title: 'Your mix is ready', body: 'Rainy Drive' }, sound: 'default', 'thread-id': sessionId },
      sessionId,
      turnId,
      kind: 'ready',
    })
    expect(JSON.stringify(payload)).not.toMatch(/breakup|Sam|tender/)
  })

  it('an empty title reads "Tap to play it."', async () => {
    const db = await createTestDb()
    const { turnId } = await seed(db, { title: '   ' })
    await addPhone(db)
    expect(((await apnsPayload(db, turnId)).aps as { alert: unknown }).alert).toEqual({ title: 'Your mix is ready', body: 'Tap to play it.' })
  })

  it.each([
    ['failed', 'model'],
    ['lost', 'lost'],
  ])('a %s turn gets one of the Oops lines', async (_name, errorKind) => {
    const db = await createTestDb()
    const { turnId } = await seed(db, { status: 'failed', errorKind })
    await addPhone(db)
    const payload = await apnsPayload(db, turnId)
    expect(payload.kind).toBe('failed')
    expect(FAILED_LINES).toContainEqual((payload.aps as { alert: unknown }).alert)
    expect(JSON.stringify(payload)).not.toMatch(/Rainy|breakup/)
  })

  it('web push gets an encrypted body, never the words in the clear', async () => {
    const db = await createTestDb()
    const { turnId } = await seed(db)
    await addLaptop(db)
    const { fetch, calls } = fakeFetch()
    await notifyTurn(deps(db, fetch), turnId)
    expect(calls[0]!.headers['content-encoding']).toBe('aes128gcm')
    expect(Buffer.from(calls[0]!.body as Uint8Array).toString('latin1')).not.toMatch(/Rainy|ready/)
  })
})

describe('computePush', () => {
  it('is true only with TURN_PUSH on and a live device', async () => {
    const db = await createTestDb()
    await seed(db)
    expect(await computePush(db, 'u1', { TURN_PUSH: 'on' }, 'ios')).toBe(false)
    await addPhone(db)
    expect(await computePush(db, 'u1', { TURN_PUSH: 'off' }, 'ios')).toBe(false)
    expect(await computePush(db, 'u1', { TURN_PUSH: 'ON' }, 'ios')).toBe(false)
    expect(await computePush(db, 'u1', undefined, 'ios')).toBe(false)
    expect(await computePush(db, 'u1', { TURN_PUSH: 'on' }, 'ios')).toBe(true)
    expect(await computePush(db, 'u2', { TURN_PUSH: 'on' }, 'ios')).toBe(false)
    await db.update(pushDevices).set({ disabledAt: NOW })
    expect(await computePush(db, 'u1', { TURN_PUSH: 'on' }, 'ios')).toBe(false)
  })

  // "push is true when this device has a live push registration": a phone
  // whose listener registered only a laptop must keep its own local ping,
  // since the push reaches the laptop, not the phone.
  it('counts only a device on the surface the turn came from', async () => {
    const db = await createTestDb()
    await seed(db)
    await addLaptop(db)
    expect(await computePush(db, 'u1', { TURN_PUSH: 'on' }, 'ios')).toBe(false)
    expect(await computePush(db, 'u1', { TURN_PUSH: 'on' }, 'web')).toBe(true)
    await addPhone(db)
    expect(await computePush(db, 'u1', { TURN_PUSH: 'on' }, 'ios')).toBe(true)
  })
})
