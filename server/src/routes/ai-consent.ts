import { eq } from 'drizzle-orm'
import { Hono } from 'hono'
import { createMiddleware } from 'hono/factory'
import { aiConsents } from '../db/schema'
import type { Db } from '../db/types'
import type { AppVars } from '../app'

// Plan 2026-11-02 AI consent (App Store 5.1.2(i)). Bump when the consent copy
// names a new processor or new data: every listener is asked again.
export const AI_CONSENT_VERSION = '2026-11-02'

export type AiConsentMode = 'off' | 'enforce'

export async function hasAiConsent(db: Db, userId: string): Promise<boolean> {
  const [row] = await db.select({ version: aiConsents.version }).from(aiConsents).where(eq(aiConsents.userId, userId))
  return row?.version === AI_CONSENT_VERSION
}

export function aiConsentRoutes(db: Db) {
  const app = new Hono<{ Variables: AppVars }>()
  app.post('/', async (c) => {
    const body = await c.req.json().catch(() => null) as { version?: unknown } | null
    if (typeof body?.version !== 'string') return c.json({ error: 'invalid_request' }, 400)
    // The client agreed to the copy it showed; an older copy is not consent
    // to what the DJ does now.
    if (body.version !== AI_CONSENT_VERSION) return c.json({ error: 'stale_consent_version' }, 409)
    await db
      .insert(aiConsents)
      .values({ userId: c.get('user').id, version: AI_CONSENT_VERSION })
      .onConflictDoUpdate({ target: aiConsents.userId, set: { version: AI_CONSENT_VERSION, grantedAt: new Date() } })
    return c.json({ aiConsent: true })
  })
  return app
}

// Mounted after requireSession on the routes that send listener data to a
// model or transcriber. Reads pass; 'off' (the default until clients that ask
// are live) passes everything.
export function requireAiConsent(db: Db, mode: AiConsentMode) {
  return createMiddleware<{ Variables: AppVars }>(async (c, next) => {
    if (mode === 'enforce' && c.req.method === 'POST' && !(await hasAiConsent(db, c.get('user').id))) {
      return c.json({ error: 'ai_consent_required' }, 403)
    }
    await next()
  })
}
