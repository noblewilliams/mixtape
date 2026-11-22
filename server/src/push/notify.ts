import { and, eq, isNull } from 'drizzle-orm'
import type { Db } from '../db/types'
import { djSessions, djTurns, pushDevices } from '../db/schema'
import { buildApnsPayload, sendApns, type ApnsOutcome, type FetchLike, type PushKind } from './apns'
import { failedCopy, readyCopy } from './copy'
import { getApnsProviderToken, type ApnsKey } from './provider-token'
import { buildWebPushPayload, sendWebPush, vapidHeaders, type VapidCache, type VapidKeys, type WebPushKeys } from './webpush'

// Telling the listener a turn ended (spec 2026-11-21 durable-mix-turns, "Who
// notifies", "APNs from Workers", "Web push"). Called by the TurnRunner object
// once a turn finishes (and again for the 8 s recheck), and by the
// maintenance sweep for lost turns. The push says only that the mix is ready
// (its title) or that the turn failed: never the prompt, the reply, songs or
// lyrics. Logs carry { event: 'turn_push', outcome, status, reason } only.

// How long a watched result waits for the client's `seen` before pushing.
export const NOTIFY_RECHECK_MS = 8_000

export type PushConfig = {
  // TURN_PUSH exact "on".
  enabled: boolean
  apns?: ApnsKey & { topic: string }
  vapid?: VapidKeys
}

export type NotifyDeps = {
  db: Db
  config: PushConfig
  fetch?: FetchLike
  now?: () => Date
  // Asks the caller to call again with `recheck: true` this many ms from now
  // (the object's second alarm). Absent (the cron sweep), nothing can come
  // back later, so a watched result is treated as already rechecked.
  scheduleRecheck?: (ms: number) => void
  // Per-origin VAPID header cache; one per isolate by default.
  vapidCache?: VapidCache
}

// sent / failed / seen / no_device / off are what notify_outcome records.
// deferred: waiting for `seen` (a recheck is scheduled). skipped: nothing to
// tell (stopped, still live, or gone). already: an earlier call notified.
export type NotifyResult = 'sent' | 'failed' | 'seen' | 'no_device' | 'off' | 'deferred' | 'skipped' | 'already'

type Recorded = 'seen' | 'no_device' | 'off'

export function turnPushEnabled(env: { TURN_PUSH?: string } | undefined): boolean {
  return env?.TURN_PUSH === 'on'
}

/** True when the user has a device that is not disabled. */
export async function hasLiveDevice(db: Db, userId: string): Promise<boolean> {
  const [row] = await db
    .select({ id: pushDevices.id })
    .from(pushDevices)
    .where(and(eq(pushDevices.userId, userId), isNull(pushDevices.disabledAt)))
    .limit(1)
  return row !== undefined
}

export async function notifyTurn(deps: NotifyDeps, turnId: string, { recheck = false }: { recheck?: boolean } = {}): Promise<NotifyResult> {
  const { db } = deps
  const now = deps.now ?? (() => new Date())

  const [turn] = await db
    .select({
      status: djTurns.status,
      sessionId: djTurns.sessionId,
      userId: djTurns.userId,
      watchedResult: djTurns.watchedResult,
      seenAt: djTurns.seenAt,
      notifiedAt: djTurns.notifiedAt,
      title: djSessions.title,
    })
    .from(djTurns)
    .innerJoin(djSessions, eq(djSessions.id, djTurns.sessionId))
    .where(eq(djTurns.id, turnId))
  // Gone with its session: nobody to tell.
  if (!turn) return 'skipped'
  if (turn.notifiedAt) return 'already'
  // Stopped: the listener asked for it. Live: not ended yet.
  if (turn.status !== 'done' && turn.status !== 'failed') return 'skipped'

  // Each terminal record is conditional on no earlier one, so two callers
  // (a recheck racing a retried alarm) record and send at most once.
  const record = async (outcome: Recorded): Promise<NotifyResult> => {
    const rows = await db
      .update(djTurns)
      .set({ notifiedAt: now(), notifyOutcome: outcome })
      .where(and(eq(djTurns.id, turnId), isNull(djTurns.notifiedAt)))
      .returning({ id: djTurns.id })
    return rows.length > 0 ? outcome : 'already'
  }

  if (!deps.config.enabled) return record('off')

  const devices = await db
    .select({
      id: pushDevices.id,
      provider: pushDevices.provider,
      token: pushDevices.token,
      keys: pushDevices.keys,
      environment: pushDevices.environment,
    })
    .from(pushDevices)
    .where(and(eq(pushDevices.userId, turn.userId), isNull(pushDevices.disabledAt)))
  if (devices.length === 0) return record('no_device')

  // `seen` from any device suppresses the push to all of them.
  if (turn.seenAt) return record('seen')
  if (turn.watchedResult && !recheck && deps.scheduleRecheck) {
    deps.scheduleRecheck(NOTIFY_RECHECK_MS)
    return 'deferred'
  }

  // Claimed before anything is sent, fenced on no `seen` either: a seen that
  // lands after this is too late, and one before it wins.
  const claimed = await db
    .update(djTurns)
    .set({ notifiedAt: now() })
    .where(and(eq(djTurns.id, turnId), isNull(djTurns.notifiedAt), isNull(djTurns.seenAt)))
    .returning({ id: djTurns.id })
  if (claimed.length === 0) {
    const [again] = await db.select({ seenAt: djTurns.seenAt, notifiedAt: djTurns.notifiedAt }).from(djTurns).where(eq(djTurns.id, turnId))
    return again?.seenAt && !again.notifiedAt ? record('seen') : 'already'
  }

  const kind: PushKind = turn.status === 'done' ? 'ready' : 'failed'
  const copy = kind === 'ready' ? readyCopy(turn.title) : failedCopy(turnId)
  const message = { kind, title: copy.title, body: copy.body, sessionId: turn.sessionId, turnId }
  const sender = new Sender(deps, now)

  let sent = false
  await Promise.all(
    devices.map(async (device) => {
      let outcome: DeviceOutcome
      try {
        outcome =
          device.provider === 'apns'
            ? await sender.apns(device, message)
            : device.provider === 'webpush'
              ? await sender.webPush(device, message)
              : { outcome: 'give_up', status: null, reason: 'unsupported' }
      } catch {
        outcome = { outcome: 'give_up', status: null, reason: 'internal' }
      }
      console.log(JSON.stringify({ event: 'turn_push', outcome: outcome.outcome, status: outcome.status, reason: outcome.reason }))
      if (outcome.outcome === 'sent') sent = true
      if (outcome.outcome === 'disable') {
        await db
          .update(pushDevices)
          .set({ disabledAt: now() })
          .where(and(eq(pushDevices.id, device.id), isNull(pushDevices.disabledAt)))
          .catch(() => console.error('push device disable failed'))
      }
    }),
  )

  const outcome = sent ? 'sent' : 'failed'
  await db.update(djTurns).set({ notifyOutcome: outcome }).where(eq(djTurns.id, turnId))
  return outcome
}

type DeviceOutcome = { outcome: 'sent' | 'disable' | 'give_up'; status: number | null; reason: string | null }
type Message = { kind: PushKind; title: string; body: string; sessionId: string; turnId: string }
type Device = { token: string; keys: WebPushKeys | null; environment: 'production' | 'sandbox' | null }

// One turn's sends. The provider token is read once for all of the user's
// APNs devices, and re-signed at most once (a 403 ExpiredProviderToken /
// InvalidProviderToken), however many devices see the rejection.
class Sender {
  private token: Promise<string> | undefined
  private refreshed: Promise<string> | undefined
  private readonly fetch: FetchLike

  constructor(
    private readonly deps: NotifyDeps,
    private readonly now: () => Date,
  ) {
    this.fetch = deps.fetch ?? ((input, init) => fetch(input, init))
  }

  async apns(device: Device, message: Message): Promise<DeviceOutcome> {
    const apns = this.deps.config.apns
    if (!apns) return { outcome: 'give_up', status: null, reason: 'unconfigured' }
    if (!device.environment) return { outcome: 'give_up', status: null, reason: 'no_environment' }
    const payload = buildApnsPayload(message)
    const send = (token: string) =>
      sendApns({
        fetch: this.fetch,
        token,
        device: { token: device.token, environment: device.environment! },
        topic: apns.topic,
        payload,
        collapseId: message.turnId,
        now: this.now(),
      })

    let token: string
    try {
      this.token ??= getApnsProviderToken(this.deps.db, apns, { now: this.now() })
      token = await this.token
    } catch {
      return { outcome: 'give_up', status: null, reason: 'provider_token' }
    }
    const first: ApnsOutcome = await send(token)
    if (first.outcome !== 'refresh_token') return first as DeviceOutcome

    let fresh: string
    try {
      this.refreshed ??= getApnsProviderToken(this.deps.db, apns, { now: this.now(), forceRefresh: true, rejectedToken: token })
      fresh = await this.refreshed
    } catch {
      return { outcome: 'give_up', status: first.status, reason: 'provider_token' }
    }
    const second = await send(fresh)
    // A second rejection is not re-signed again.
    return second.outcome === 'refresh_token' ? { outcome: 'give_up', status: second.status, reason: second.reason } : (second as DeviceOutcome)
  }

  async webPush(device: Device, message: Message): Promise<DeviceOutcome> {
    const vapid = this.deps.config.vapid
    if (!vapid) return { outcome: 'give_up', status: null, reason: 'unconfigured' }
    if (!device.keys) return { outcome: 'disable', status: null, reason: 'bad_subscription' }
    let endpoint: URL
    try {
      endpoint = new URL(device.token)
    } catch {
      return { outcome: 'disable', status: null, reason: 'bad_subscription' }
    }
    const cache = this.deps.vapidCache
    // Signed first, on its own: with the endpoint known good, a throw here is
    // our VAPID configuration, not the device's, and must not disable it.
    try {
      await vapidHeaders(endpoint.href, vapid, { now: this.now(), ...(cache ? { cache } : {}) })
    } catch {
      return { outcome: 'give_up', status: null, reason: 'vapid' }
    }
    try {
      const result = await sendWebPush({
        fetch: this.fetch,
        device: { endpoint: device.token, keys: device.keys },
        payload: buildWebPushPayload(message),
        vapid,
        now: this.now(),
        ...(cache ? { cache } : {}),
      })
      return { ...result, reason: null }
    } catch {
      // The subscription's keys do not encrypt (not a P-256 point, a short
      // auth secret): it can never receive a push.
      return { outcome: 'disable', status: null, reason: 'bad_subscription' }
    }
  }
}
