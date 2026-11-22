// Web push on WebCrypto alone (crypto.subtle), so it runs on Workers and in
// Node 20+ with no Node APIs:
// - RFC 8291 message encryption, `aes128gcm` content coding (RFC 8188), one
//   record.
// - RFC 8292 VAPID: an ES256 JWT (aud = push service origin, exp, sub) in
//   `Authorization: vapid t=<jwt>, k=<public key>`.
//
// Key formats (the same as the `web-push` npm CLI prints, so pairs are
// interchangeable): VAPID_PUBLIC_KEY is the base64url (no padding)
// uncompressed P-256 point, 65 bytes starting 0x04, which is also what the
// browser's `applicationServerKey` takes. VAPID_PRIVATE_KEY is the base64url
// raw private scalar `d`, 32 bytes. See scripts/vapid-keys.ts.
import { importJWK, SignJWT } from 'jose'
import type { FetchLike, PushKind } from './apns'

export type WebPushKeys = { p256dh: string; auth: string }
export type VapidKeys = { publicKey: string; privateKey: string; subject: string }

export type WebPushPayload = { kind: PushKind; title: string; body: string; sessionId: string; turnId: string }

// The same JSON as the APNs payload, minus `aps`.
export function buildWebPushPayload(payload: WebPushPayload): WebPushPayload {
  const { kind, title, body, sessionId, turnId } = payload
  return { kind, title, body, sessionId, turnId }
}

const RECORD_SIZE = 4096
const HEADER_BYTES = 16 + 4 + 1 + 65
// Push services accept at most 4096 bytes of body.
const MAX_BODY_BYTES = 4096
const TAG_BYTES = 16

const encoder = new TextEncoder()

export function base64UrlEncode(bytes: Uint8Array): string {
  let binary = ''
  for (const byte of bytes) binary += String.fromCharCode(byte)
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

export function base64UrlDecode(text: string): Uint8Array<ArrayBuffer> {
  const base64 = text.replace(/-/g, '+').replace(/_/g, '/').replace(/\s+/g, '')
  const binary = atob(base64 + '='.repeat((4 - (base64.length % 4)) % 4))
  const bytes = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i)
  return bytes
}

function concat(...parts: Uint8Array[]): Uint8Array<ArrayBuffer> {
  const out = new Uint8Array(parts.reduce((n, part) => n + part.length, 0))
  let offset = 0
  for (const part of parts) {
    out.set(part, offset)
    offset += part.length
  }
  return out
}

function decodePoint(text: string, what: string): Uint8Array<ArrayBuffer> {
  let point: Uint8Array<ArrayBuffer>
  try {
    point = base64UrlDecode(text)
  } catch {
    throw new Error(`${what} is not base64url`)
  }
  if (point.length !== 65 || point[0] !== 4) throw new Error(`${what} must be an uncompressed P-256 point (65 bytes)`)
  return point
}

function privateJwk(publicKey: string, privateKey: string) {
  const point = decodePoint(publicKey, 'VAPID public key')
  const d = base64UrlDecode(privateKey)
  if (d.length !== 32) throw new Error('VAPID private key must be the raw 32-byte scalar, base64url')
  return {
    kty: 'EC',
    crv: 'P-256',
    x: base64UrlEncode(point.slice(1, 33)),
    y: base64UrlEncode(point.slice(33, 65)),
    d: base64UrlEncode(d),
  }
}

async function hkdf(salt: Uint8Array<ArrayBuffer>, ikm: Uint8Array<ArrayBuffer>, info: Uint8Array<ArrayBuffer>, bytes: number) {
  const key = await crypto.subtle.importKey('raw', ikm, 'HKDF', false, ['deriveBits'])
  return new Uint8Array(await crypto.subtle.deriveBits({ name: 'HKDF', hash: 'SHA-256', salt, info }, key, bytes * 8))
}

// `salt` and `serverKeys` exist for the RFC test vector; in use both are
// fresh per message.
export async function encryptPayload(
  plaintext: Uint8Array,
  keys: WebPushKeys,
  { salt, serverKeys }: { salt?: Uint8Array<ArrayBuffer>; serverKeys?: { publicKey: string; privateKey: string } } = {},
): Promise<Uint8Array<ArrayBuffer>> {
  const uaPublic = decodePoint(keys.p256dh, 'Subscription p256dh')
  let authSecret: Uint8Array<ArrayBuffer>
  try {
    authSecret = base64UrlDecode(keys.auth)
  } catch {
    throw new Error('Subscription auth is not base64url')
  }
  if (authSecret.length !== 16) throw new Error('Subscription auth must be 16 bytes')
  if (HEADER_BYTES + plaintext.length + 1 + TAG_BYTES > MAX_BODY_BYTES) {
    throw new Error('Web push payload is too large for one push')
  }

  const messageSalt = salt ?? crypto.getRandomValues(new Uint8Array(16))
  if (messageSalt.length !== 16) throw new Error('Salt must be 16 bytes')

  const ecdh = { name: 'ECDH', namedCurve: 'P-256' } as const
  let asPublic: Uint8Array<ArrayBuffer>
  let asPrivate: CryptoKey
  if (serverKeys) {
    asPublic = decodePoint(serverKeys.publicKey, 'Server public key')
    asPrivate = await crypto.subtle.importKey('jwk', privateJwk(serverKeys.publicKey, serverKeys.privateKey), ecdh, false, [
      'deriveBits',
    ])
  } else {
    const pair = await crypto.subtle.generateKey(ecdh, true, ['deriveBits'])
    asPublic = new Uint8Array(await crypto.subtle.exportKey('raw', pair.publicKey))
    asPrivate = pair.privateKey
  }
  const uaKey = await crypto.subtle.importKey('raw', uaPublic, ecdh, false, [])
  const ecdhSecret = new Uint8Array(await crypto.subtle.deriveBits({ name: 'ECDH', public: uaKey }, asPrivate, 256))

  const keyInfo = concat(encoder.encode('WebPush: info\0'), uaPublic, asPublic)
  const ikm = await hkdf(authSecret, ecdhSecret, keyInfo, 32)
  const cek = await hkdf(messageSalt, ikm, encoder.encode('Content-Encoding: aes128gcm\0'), 16)
  const nonce = await hkdf(messageSalt, ikm, encoder.encode('Content-Encoding: nonce\0'), 12)

  // One record, so it is the last: the 0x02 delimiter, no padding.
  const record = concat(plaintext, new Uint8Array([2]))
  const aesKey = await crypto.subtle.importKey('raw', cek, 'AES-GCM', false, ['encrypt'])
  const ciphertext = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce }, aesKey, record))

  const header = new Uint8Array(HEADER_BYTES)
  header.set(messageSalt, 0)
  new DataView(header.buffer).setUint32(16, RECORD_SIZE)
  header[20] = 65
  header.set(asPublic, 21)
  return concat(header, ciphertext)
}

export type VapidCache = Map<string, { authorization: string; expiresAt: number }>

const VAPID_TTL_MS = 12 * 3600_000
// Re-sign once less than this is left, so a header never expires in flight.
const VAPID_MIN_REMAINING_MS = 3600_000
const defaultVapidCache: VapidCache = new Map()

export async function vapidHeaders(
  endpoint: string,
  vapid: VapidKeys,
  { now = new Date(), cache = defaultVapidCache }: { now?: Date; cache?: VapidCache } = {},
): Promise<{ authorization: string }> {
  if (!/^(mailto:|https:)/.test(vapid.subject)) throw new Error('VAPID subject must be a mailto: or https: URL')
  const audience = new URL(endpoint).origin
  const cacheKey = `${audience} ${vapid.publicKey}`
  const cached = cache.get(cacheKey)
  if (cached && cached.expiresAt - now.getTime() > VAPID_MIN_REMAINING_MS) return { authorization: cached.authorization }

  const exp = Math.floor((now.getTime() + VAPID_TTL_MS) / 1000)
  const signingKey = await importJWK(privateJwk(vapid.publicKey, vapid.privateKey), 'ES256')
  const jwt = await new SignJWT({ sub: vapid.subject })
    .setProtectedHeader({ typ: 'JWT', alg: 'ES256' })
    .setAudience(audience)
    .setExpirationTime(exp)
    .sign(signingKey)
  const authorization = `vapid t=${jwt}, k=${vapid.publicKey}`
  cache.set(cacheKey, { authorization, expiresAt: exp * 1000 })
  return { authorization }
}

// 'disable': 404/410, the subscription is gone; mark the device disabled_at.
// 'give_up': 413, 429, 5xx, any other refusal, or a fetch that threw.
export type WebPushOutcome = { outcome: 'sent' | 'disable' | 'give_up'; status: number | null }

export async function sendWebPush({
  fetch,
  device,
  payload,
  vapid,
  now = new Date(),
  cache,
}: {
  fetch: FetchLike
  device: { endpoint: string; keys: WebPushKeys }
  payload: WebPushPayload
  vapid: VapidKeys
  now?: Date
  cache?: VapidCache
}): Promise<WebPushOutcome> {
  const body = await encryptPayload(encoder.encode(JSON.stringify(payload)), device.keys)
  const { authorization } = await vapidHeaders(device.endpoint, vapid, { now, cache })
  let response: Response
  try {
    response = await fetch(device.endpoint, {
      method: 'POST',
      headers: {
        authorization,
        'content-encoding': 'aes128gcm',
        'content-type': 'application/octet-stream',
        ttl: '86400',
        urgency: 'high',
      },
      body,
    })
  } catch {
    return { outcome: 'give_up', status: null }
  }
  const status = response.status
  // Release the connection without waiting: a teed body's cancel only
  // settles once every branch is cancelled.
  void response.body?.cancel().catch(() => {})
  if (status >= 200 && status < 300) return { outcome: 'sent', status }
  if (status === 404 || status === 410) return { outcome: 'disable', status }
  return { outcome: 'give_up', status }
}
