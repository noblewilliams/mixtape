import { Hono } from 'hono'
import { and, eq, inArray, sql } from 'drizzle-orm'
import { z } from 'zod'
import type { AppVars } from '../app'
import type { Db } from '../db/types'
import { pushDevices } from '../db/schema'

// Push registration (spec 2026-11-21 durable-mix-turns, "Device
// registration"), mounted at /push/devices behind requireSession. Anonymous
// listeners may register (the first-run flow makes a mix before sign-in);
// their rows follow them on sign-up (auth/link-anonymous.ts). No AI consent
// gate: nothing here reaches a model. The row holds the token and what the
// sender needs, never a device name or model.

const BASE64URL = /^[A-Za-z0-9_-]+={0,2}$/

const apnsBody = z.object({
  provider: z.literal('apns'),
  platform: z.literal('ios'),
  token: z.string().regex(/^[0-9a-fA-F]{64,200}$/),
  environment: z.enum(['production', 'sandbox']),
  appVersion: z.string().max(40).optional(),
})

const webPushBody = z.object({
  provider: z.literal('webpush'),
  platform: z.literal('web'),
  // The subscription's endpoint, on the browser's push service.
  token: z
    .string()
    .max(1024)
    .refine((value) => {
      try {
        return new URL(value).protocol === 'https:'
      } catch {
        return false
      }
    }),
  keys: z.object({ p256dh: z.string().min(1).max(200).regex(BASE64URL), auth: z.string().min(1).max(100).regex(BASE64URL) }),
  appVersion: z.string().max(40).optional(),
})

const deviceBody = z.discriminatedUnion('provider', [apnsBody, webPushBody])

export function pushDeviceRoutes(db: Db) {
  const app = new Hono<{ Variables: AppVars }>()

  // Sent on every launch with permission (Apple can rotate tokens). Upserts
  // on (provider, token) and moves the row to the caller: a phone passed to
  // another account follows its new owner.
  app.put('/', async (c) => {
    const parsed = deviceBody.safeParse(await c.req.json().catch(() => null))
    if (!parsed.success) return c.json({ error: 'invalid_request' }, 400)
    const body = parsed.data
    const token = body.provider === 'apns' ? body.token.toLowerCase() : body.token
    const fields = {
      userId: c.get('user').id,
      platform: body.platform,
      environment: body.provider === 'apns' ? body.environment : null,
      keys: body.provider === 'webpush' ? { p256dh: body.keys.p256dh, auth: body.keys.auth } : null,
      appVersion: body.appVersion ?? null,
      lastSeenAt: sql`now()`,
      disabledAt: null,
    }
    await db
      .insert(pushDevices)
      .values({ provider: body.provider, token, ...fields })
      .onConflictDoUpdate({ target: [pushDevices.provider, pushDevices.token], set: fields })
    return c.body(null, 204)
  })

  // Sent at sign-out, before the bearer is dropped. Only the caller's own
  // row goes; another account's registration of the same token is left be.
  // Idempotent: an unknown token is a 204 too.
  app.delete('/:token', async (c) => {
    const raw = c.req.param('token')
    if (!raw || raw.length > 1024) return c.json({ error: 'invalid_request' }, 400)
    // APNs tokens are stored lower-cased.
    const tokens = [...new Set([raw, /^[0-9a-fA-F]+$/.test(raw) ? raw.toLowerCase() : raw])]
    await db.delete(pushDevices).where(and(eq(pushDevices.userId, c.get('user').id), inArray(pushDevices.token, tokens)))
    return c.body(null, 204)
  })

  return app
}
