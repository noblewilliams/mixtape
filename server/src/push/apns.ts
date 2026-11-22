export type FetchLike = (input: string, init: RequestInit) => Promise<Response>

export type PushKind = 'ready' | 'failed'

export type ApnsPayload = {
  aps: { alert: { title: string; body: string }; sound: 'default'; 'thread-id': string }
  sessionId: string
  turnId: string
  kind: PushKind
}

export const APNS_MAX_PAYLOAD_BYTES = 4096

const HOSTS = {
  production: 'https://api.push.apple.com',
  sandbox: 'https://api.sandbox.push.apple.com',
} as const

export function buildApnsPayload({
  kind,
  title,
  body,
  sessionId,
  turnId,
}: {
  kind: PushKind
  title: string
  body: string
  sessionId: string
  turnId: string
}): ApnsPayload {
  const payload: ApnsPayload = {
    aps: { alert: { title, body }, sound: 'default', 'thread-id': sessionId },
    sessionId,
    turnId,
    kind,
  }
  const bytes = new TextEncoder().encode(JSON.stringify(payload)).length
  if (bytes >= APNS_MAX_PAYLOAD_BYTES) throw new Error(`APNs payload is ${bytes} bytes; it must stay under 4096`)
  return payload
}

// 'disable': mark the device disabled_at, do not retry.
// 'refresh_token': re-sign the provider token (forceRefresh) and retry once.
// 'give_up': nothing more for this turn (notify_outcome = 'failed').
// `reason` is Apple's reason code ('network' for a fetch that threw); it and
// `status` are all a log line may carry.
export type ApnsOutcome = {
  outcome: 'sent' | 'disable' | 'refresh_token' | 'give_up'
  status: number | null
  reason: string | null
}

const DISABLE: Record<number, readonly string[]> = {
  410: ['Unregistered', 'ExpiredToken'],
  400: ['BadDeviceToken', 'DeviceTokenNotForTopic'],
}
const REFRESH = ['ExpiredProviderToken', 'InvalidProviderToken']

export async function sendApns({
  fetch,
  token,
  device,
  topic,
  payload,
  collapseId,
  now = new Date(),
}: {
  fetch: FetchLike
  token: string
  device: { token: string; environment: 'production' | 'sandbox' }
  topic: string
  payload: ApnsPayload
  collapseId: string
  now?: Date
}): Promise<ApnsOutcome> {
  let response: Response
  try {
    response = await fetch(`${HOSTS[device.environment]}/3/device/${device.token}`, {
      method: 'POST',
      headers: {
        authorization: `bearer ${token}`,
        'apns-topic': topic,
        'apns-push-type': 'alert',
        'apns-priority': '10',
        'apns-expiration': String(Math.floor(now.getTime() / 1000) + 86_400),
        'apns-collapse-id': collapseId,
        'content-type': 'application/json',
      },
      body: JSON.stringify(payload),
    })
  } catch {
    return { outcome: 'give_up', status: null, reason: 'network' }
  }

  const status = response.status
  if (status === 200) {
    // Release the connection without waiting: a teed body's cancel only
    // settles once every branch is cancelled.
    void response.body?.cancel().catch(() => {})
    return { outcome: 'sent', status, reason: null }
  }
  const reason = await readReason(response)
  if (reason && DISABLE[status]?.includes(reason)) return { outcome: 'disable', status, reason }
  if (status === 403 && reason && REFRESH.includes(reason)) return { outcome: 'refresh_token', status, reason }
  return { outcome: 'give_up', status, reason }
}

async function readReason(response: Response): Promise<string | null> {
  try {
    const body = (await response.json()) as { reason?: unknown }
    return typeof body.reason === 'string' ? body.reason : null
  } catch {
    return null
  }
}
