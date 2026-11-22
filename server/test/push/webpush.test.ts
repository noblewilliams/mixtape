import { decodeJwt, decodeProtectedHeader, importJWK, jwtVerify } from 'jose'
import { describe, expect, it } from 'vitest'
import {
  base64UrlDecode,
  base64UrlEncode,
  buildWebPushPayload,
  encryptPayload,
  sendWebPush,
  vapidHeaders,
  type VapidCache,
} from '../../src/push/webpush'

// RFC 8291 section 5 and appendix A.
const RFC = {
  plaintext: 'When I grow up, I want to be a watermelon',
  asPublic: 'BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8',
  asPrivate: 'yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw',
  uaPublic: 'BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4',
  auth: 'BTBZMqHH6r4Tts7J_aSIgg',
  salt: 'DGv6ra1nlYgDCS1FRnbzlw',
  header:
    'DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8',
  body:
    'DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27ml' +
    'mlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPT' +
    'pK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN',
}

const NOW = new Date('2026-11-22T10:00:00.000Z')
const ENDPOINT = 'https://fcm.googleapis.com/fcm/send/abc123:def'
const VAPID = { publicKey: RFC.asPublic, privateKey: RFC.asPrivate, subject: 'mailto:push@example.com' }
const SESSION_ID = '2f7c8b1e-4b0d-4c55-9d1a-7a5e1c3f9b10'
const TURN_ID = '9a1d2c3b-5e6f-4a7b-8c9d-0e1f2a3b4c5d'

async function vapidPublicKey() {
  const point = base64UrlDecode(RFC.asPublic)
  return importJWK(
    { kty: 'EC', crv: 'P-256', x: base64UrlEncode(point.slice(1, 33)), y: base64UrlEncode(point.slice(33, 65)) },
    'ES256',
  )
}

function parseAuthorization(value: string) {
  const match = /^vapid t=([^,\s]+), k=([A-Za-z0-9_-]+)$/.exec(value)
  expect(match).not.toBeNull()
  return { jwt: match![1]!, k: match![2]! }
}

describe('base64url', () => {
  it('round-trips without padding', () => {
    const bytes = new Uint8Array([0, 251, 255, 1, 2])
    expect(base64UrlEncode(bytes)).toBe('APv_AQI')
    expect(base64UrlDecode('APv_AQI')).toEqual(bytes)
  })
})

describe('encryptPayload (RFC 8291)', () => {
  it('reproduces the appendix A ciphertext exactly', async () => {
    const out = await encryptPayload(
      new TextEncoder().encode(RFC.plaintext),
      { p256dh: RFC.uaPublic, auth: RFC.auth },
      { salt: base64UrlDecode(RFC.salt), serverKeys: { publicKey: RFC.asPublic, privateKey: RFC.asPrivate } },
    )
    // 86-byte header + 41 + delimiter + 16-byte tag. (Section 5's example
    // says Content-Length: 145, but its own body decodes to 144 bytes.)
    expect(out.length).toBe(144)
    expect(base64UrlEncode(out.slice(0, 86))).toBe(RFC.header)
    expect(base64UrlEncode(out)).toBe(RFC.body)
  })

  it('uses a fresh salt and server key per message by default', async () => {
    const keys = { p256dh: RFC.uaPublic, auth: RFC.auth }
    const a = await encryptPayload(new TextEncoder().encode('hi'), keys)
    const b = await encryptPayload(new TextEncoder().encode('hi'), keys)
    expect(a.length).toBe(86 + 2 + 1 + 16)
    expect(base64UrlEncode(a.slice(0, 16))).not.toBe(base64UrlEncode(b.slice(0, 16)))
    expect(base64UrlEncode(a.slice(21, 86))).not.toBe(base64UrlEncode(b.slice(21, 86)))
  })

  it('rejects a malformed subscription key', async () => {
    await expect(
      encryptPayload(new TextEncoder().encode('hi'), { p256dh: 'AAAA', auth: RFC.auth }),
    ).rejects.toThrow(/p256dh/)
    await expect(
      encryptPayload(new TextEncoder().encode('hi'), { p256dh: RFC.uaPublic, auth: 'AAAA' }),
    ).rejects.toThrow(/auth/)
  })

  it('refuses a payload too large for one 4096-byte push', async () => {
    await expect(
      encryptPayload(new Uint8Array(4000), { p256dh: RFC.uaPublic, auth: RFC.auth }),
    ).rejects.toThrow(/too large/)
  })
})

describe('vapidHeaders (RFC 8292)', () => {
  it('signs aud = endpoint origin, exp = now + 12 h, sub = subject, and carries k', async () => {
    const { authorization } = await vapidHeaders(ENDPOINT, VAPID, { now: NOW, cache: new Map() })
    const { jwt, k } = parseAuthorization(authorization)
    expect(k).toBe(RFC.asPublic)
    expect(decodeProtectedHeader(jwt)).toEqual({ typ: 'JWT', alg: 'ES256' })
    expect(decodeJwt(jwt)).toEqual({
      aud: 'https://fcm.googleapis.com',
      exp: NOW.getTime() / 1000 + 12 * 3600,
      sub: 'mailto:push@example.com',
    })
    await expect(jwtVerify(jwt, await vapidPublicKey(), { currentDate: NOW })).resolves.toBeTruthy()
  })

  it('reuses the header per origin and re-signs for another origin', async () => {
    const cache: VapidCache = new Map()
    const a = await vapidHeaders(ENDPOINT, VAPID, { now: NOW, cache })
    const b = await vapidHeaders('https://fcm.googleapis.com/fcm/send/other', VAPID, {
      now: new Date(NOW.getTime() + 60 * 60_000),
      cache,
    })
    const c = await vapidHeaders('https://updates.push.services.mozilla.com/wpush/v2/x', VAPID, { now: NOW, cache })
    expect(b.authorization).toBe(a.authorization)
    expect(c.authorization).not.toBe(a.authorization)
    expect(decodeJwt(parseAuthorization(c.authorization).jwt).aud).toBe('https://updates.push.services.mozilla.com')
  })

  it('re-signs once the cached header has under an hour left', async () => {
    const cache: VapidCache = new Map()
    const a = await vapidHeaders(ENDPOINT, VAPID, { now: NOW, cache })
    const later = new Date(NOW.getTime() + 11 * 3600_000)
    const b = await vapidHeaders(ENDPOINT, VAPID, { now: later, cache })
    expect(b.authorization).not.toBe(a.authorization)
    expect(decodeJwt(parseAuthorization(b.authorization).jwt).exp).toBe(later.getTime() / 1000 + 12 * 3600)
  })

  it('rejects a subject that is not mailto: or https:', async () => {
    await expect(vapidHeaders(ENDPOINT, { ...VAPID, subject: 'push@example.com' }, { now: NOW, cache: new Map() })).rejects.toThrow(
      /subject/,
    )
  })
})

describe('buildWebPushPayload', () => {
  it('is the APNs payload minus aps', () => {
    expect(
      buildWebPushPayload({ kind: 'ready', title: 'Your mix is ready', body: 'Late night drive', sessionId: SESSION_ID, turnId: TURN_ID }),
    ).toEqual({ kind: 'ready', title: 'Your mix is ready', body: 'Late night drive', sessionId: SESSION_ID, turnId: TURN_ID })
  })
})

type Call = { url: string; init: RequestInit }

function fakeFetch(response: Response | (() => Promise<Response>)) {
  const calls: Call[] = []
  const fetch = async (url: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(url), init: init ?? {} })
    return typeof response === 'function' ? response() : response.clone()
  }
  return { fetch, calls }
}

function send(fetch: ReturnType<typeof fakeFetch>['fetch']) {
  return sendWebPush({
    fetch,
    device: { endpoint: ENDPOINT, keys: { p256dh: RFC.uaPublic, auth: RFC.auth } },
    payload: buildWebPushPayload({ kind: 'ready', title: 'Your mix is ready', body: 'Late night drive', sessionId: SESSION_ID, turnId: TURN_ID }),
    vapid: VAPID,
    now: NOW,
    cache: new Map(),
  })
}

describe('sendWebPush', () => {
  it('posts the encrypted body with the spec headers', async () => {
    const { fetch, calls } = fakeFetch(new Response(null, { status: 201 }))
    await send(fetch)
    expect(calls).toHaveLength(1)
    const [{ url, init }] = calls
    expect(url).toBe(ENDPOINT)
    expect(init.method).toBe('POST')
    const headers = init.headers as Record<string, string>
    expect(headers['content-encoding']).toBe('aes128gcm')
    expect(headers['content-type']).toBe('application/octet-stream')
    expect(headers.ttl).toBe('86400')
    expect(headers.urgency).toBe('high')
    const { jwt, k } = parseAuthorization(headers.authorization!)
    expect(k).toBe(RFC.asPublic)
    expect(decodeJwt(jwt).aud).toBe('https://fcm.googleapis.com')
    const body = init.body as Uint8Array
    const plaintextLength = new TextEncoder().encode(
      JSON.stringify({ kind: 'ready', title: 'Your mix is ready', body: 'Late night drive', sessionId: SESSION_ID, turnId: TURN_ID }),
    ).length
    expect(body.length).toBe(86 + plaintextLength + 1 + 16)
    // The header's record size is 4096 and the key id is a 65-byte point.
    expect([...body.slice(16, 21)]).toEqual([0, 0, 16, 0, 65])
  })

  it.each([200, 201, 202])('%i is sent', async (status) => {
    expect(await send(fakeFetch(new Response(null, { status })).fetch)).toEqual({ outcome: 'sent', status })
  })

  it.each([404, 410])('%i disables the device', async (status) => {
    expect(await send(fakeFetch(new Response('gone', { status })).fetch)).toEqual({ outcome: 'disable', status })
  })

  it.each([413, 429, 500, 503, 400, 403])('%i gives up', async (status) => {
    expect(await send(fakeFetch(new Response('no', { status })).fetch)).toEqual({ outcome: 'give_up', status })
  })

  it('a network error gives up with a null status', async () => {
    const { fetch } = fakeFetch(() => Promise.reject(new TypeError('network down')))
    expect(await send(fetch)).toEqual({ outcome: 'give_up', status: null })
  })
})
