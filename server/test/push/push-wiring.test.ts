import { describe, expect, it } from 'vitest'
import { createApp } from '../../src/app'
import { buildPush } from '../../src/index'

// TURN_PUSH wiring (spec 2026-11-21 durable-mix-turns): with it on, every
// key is required (the buildShares pattern), and /health serves the VAPID
// public key for the web app's subscribe.

const FULL = {
  TURN_PUSH: 'on',
  APPLE_TEAM_ID: 'TEAM123456',
  APPLE_BUNDLE_ID: 'com.example.mixtape',
  APNS_KEY_ID: 'KEY1234567',
  APNS_PRIVATE_KEY: '-----BEGIN PRIVATE KEY-----\\nabc\\n-----END PRIVATE KEY-----',
  VAPID_PUBLIC_KEY: 'BPublic',
  VAPID_PRIVATE_KEY: 'private',
  VAPID_SUBJECT: 'mailto:push@example.com',
}

describe('buildPush', () => {
  it('is off for anything but exact "on", and reads no keys then', () => {
    for (const TURN_PUSH of [undefined, 'off', 'ON', 'true', ' on']) {
      expect(buildPush({ TURN_PUSH })).toEqual({ enabled: false })
    }
  })

  it('on with every key: APNs and VAPID config, topic defaulting to the bundle id', () => {
    expect(buildPush(FULL)).toEqual({
      enabled: true,
      apns: { teamId: 'TEAM123456', keyId: 'KEY1234567', privateKey: FULL.APNS_PRIVATE_KEY, topic: 'com.example.mixtape' },
      vapid: { publicKey: 'BPublic', privateKey: 'private', subject: 'mailto:push@example.com' },
    })
    expect(buildPush({ ...FULL, APNS_TOPIC: 'com.example.other' }).apns?.topic).toBe('com.example.other')
  })

  it.each(['APNS_KEY_ID', 'APNS_PRIVATE_KEY', 'VAPID_PUBLIC_KEY', 'VAPID_PRIVATE_KEY', 'VAPID_SUBJECT', 'APPLE_TEAM_ID'] as const)(
    'throws with TURN_PUSH on and %s missing',
    (name) => {
      expect(() => buildPush({ ...FULL, [name]: undefined })).toThrow(`${name} is required when TURN_PUSH is on`)
      expect(() => buildPush({ ...FULL, [name]: '  ' })).toThrow(name)
    },
  )

  it('throws without a topic, and for a subject that is not mailto: or https:', () => {
    expect(() => buildPush({ ...FULL, APPLE_BUNDLE_ID: undefined })).toThrow(/APNS_TOPIC/)
    expect(() => buildPush({ ...FULL, VAPID_SUBJECT: 'push@example.com' })).toThrow(/VAPID_SUBJECT/)
  })
})

describe('/health vapidPublicKey', () => {
  const auth = { handler: () => new Response('ok'), api: { getSession: async () => null } }

  it('is served when given (TURN_PUSH on), and absent otherwise', async () => {
    const on = (await (await createApp({ auth, vapidPublicKey: 'BPublic' }).request('http://x/health')).json()) as Record<string, unknown>
    expect(on).toMatchObject({ ok: true, vapidPublicKey: 'BPublic' })
    const off = (await (await createApp({ auth }).request('http://x/health')).json()) as Record<string, unknown>
    expect(off).not.toHaveProperty('vapidPublicKey')
  })
})
