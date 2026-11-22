import { describe, expect, it } from 'vitest'
import { APNS_MAX_PAYLOAD_BYTES, buildApnsPayload, sendApns, type ApnsPayload } from '../../src/push/apns'

const NOW = new Date('2026-11-22T10:00:00.000Z')
const DEVICE_TOKEN = 'a'.repeat(64)
const SESSION_ID = '2f7c8b1e-4b0d-4c55-9d1a-7a5e1c3f9b10'
const TURN_ID = '9a1d2c3b-5e6f-4a7b-8c9d-0e1f2a3b4c5d'

type Call = { url: string; init: RequestInit }

function fakeFetch(response: Response | (() => Promise<Response>)) {
  const calls: Call[] = []
  const fetch = async (url: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(url), init: init ?? {} })
    return typeof response === 'function' ? response() : response.clone()
  }
  return { fetch, calls }
}

const reason = (status: number, reason: string) =>
  new Response(JSON.stringify({ reason }), { status, headers: { 'content-type': 'application/json' } })

const payload = () =>
  buildApnsPayload({ kind: 'ready', title: 'Your mix is ready', body: 'Late night drive', sessionId: SESSION_ID, turnId: TURN_ID })

function send(fetch: ReturnType<typeof fakeFetch>['fetch'], environment: 'production' | 'sandbox' = 'production') {
  return sendApns({
    fetch,
    token: 'provider.jwt.token',
    device: { token: DEVICE_TOKEN, environment },
    topic: 'com.example.mixtape',
    payload: payload(),
    collapseId: TURN_ID,
    now: NOW,
  })
}

describe('buildApnsPayload', () => {
  it('shapes the alert, thread and routing ids only', () => {
    expect(payload()).toEqual({
      aps: { alert: { title: 'Your mix is ready', body: 'Late night drive' }, sound: 'default', 'thread-id': SESSION_ID },
      sessionId: SESSION_ID,
      turnId: TURN_ID,
      kind: 'ready',
    })
  })

  it('refuses a payload at or over 4096 bytes', () => {
    expect(() =>
      buildApnsPayload({ kind: 'failed', title: 'Oops', body: 'é'.repeat(2100), sessionId: SESSION_ID, turnId: TURN_ID }),
    ).toThrow(/4096/)
    expect(APNS_MAX_PAYLOAD_BYTES).toBe(4096)
  })
})

describe('sendApns request', () => {
  it('posts to the production host with the spec headers and JSON body', async () => {
    const { fetch, calls } = fakeFetch(new Response(null, { status: 200, headers: { 'apns-id': 'x' } }))
    await send(fetch)
    expect(calls).toHaveLength(1)
    const [{ url, init }] = calls
    expect(url).toBe(`https://api.push.apple.com/3/device/${DEVICE_TOKEN}`)
    expect(init.method).toBe('POST')
    expect(init.headers).toEqual({
      authorization: 'bearer provider.jwt.token',
      'apns-topic': 'com.example.mixtape',
      'apns-push-type': 'alert',
      'apns-priority': '10',
      'apns-expiration': String(NOW.getTime() / 1000 + 86_400),
      'apns-collapse-id': TURN_ID,
      'content-type': 'application/json',
    })
    expect(JSON.parse(String(init.body)) as ApnsPayload).toEqual(payload())
  })

  it('posts to the sandbox host for a sandbox device', async () => {
    const { fetch, calls } = fakeFetch(new Response(null, { status: 200 }))
    await send(fetch, 'sandbox')
    expect(calls[0]!.url).toBe(`https://api.sandbox.push.apple.com/3/device/${DEVICE_TOKEN}`)
  })
})

describe('sendApns outcomes', () => {
  it('200 is sent', async () => {
    expect(await send(fakeFetch(new Response(null, { status: 200 })).fetch)).toEqual({ outcome: 'sent', status: 200, reason: null })
  })

  it.each([
    [410, 'Unregistered'],
    [410, 'ExpiredToken'],
    [400, 'BadDeviceToken'],
    [400, 'DeviceTokenNotForTopic'],
  ])('%i %s disables the device', async (status, why) => {
    expect(await send(fakeFetch(reason(status, why)).fetch)).toEqual({ outcome: 'disable', status, reason: why })
  })

  it.each([
    [403, 'ExpiredProviderToken'],
    [403, 'InvalidProviderToken'],
  ])('%i %s asks for a fresh provider token', async (status, why) => {
    expect(await send(fakeFetch(reason(status, why)).fetch)).toEqual({ outcome: 'refresh_token', status, reason: why })
  })

  it.each([
    [429, 'TooManyRequests'],
    [429, 'TooManyProviderTokenUpdates'],
    [500, 'InternalServerError'],
    [503, 'ServiceUnavailable'],
    [400, 'PayloadTooLarge'],
    [403, 'BadCertificate'],
  ])('%i %s gives up', async (status, why) => {
    expect(await send(fakeFetch(reason(status, why)).fetch)).toEqual({ outcome: 'give_up', status, reason: why })
  })

  it('a 5xx with no JSON body gives up with a null reason', async () => {
    expect(await send(fakeFetch(new Response('<html>', { status: 502 })).fetch)).toEqual({
      outcome: 'give_up',
      status: 502,
      reason: null,
    })
  })

  it('a network error gives up with a null status', async () => {
    const { fetch } = fakeFetch(() => Promise.reject(new TypeError('network down')))
    expect(await send(fetch)).toEqual({ outcome: 'give_up', status: null, reason: 'network' })
  })
})
