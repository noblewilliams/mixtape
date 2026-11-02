import { eq } from 'drizzle-orm'
import type { Context } from 'hono'
import { user } from '../db/auth-schema'
import type { Db } from '../db/types'
import type { AppVars } from '../app'
import { revokeAppleForUser, type AppleRevokeDeps } from '../auth/apple-revoke'

// Plan 2026-11-02 account deletion (App Store 5.1.1(v)). One DELETE on
// "user": every user-keyed table cascades (pinned by
// test/account-deletion.test.ts), funnel_events is SET NULL, and the
// sessions go with it, so the caller's bearer token is dead afterwards.
const MAX_CODE_LENGTH = 2048

export type AccountDeletionWiring = { apple?: AppleRevokeDeps }

export async function deleteAccount(c: Context<{ Variables: AppVars }>, db: Db, wiring?: AccountDeletionWiring) {
  const code = await readCode(c.req.raw)
  if (code === false) return c.json({ error: 'invalid_request' }, 400)

  const userId = c.get('user').id
  // Revoke first: the Apple account row goes with the user.
  const apple = await revokeAppleForUser(db, userId, { code, deps: wiring?.apple })
  await db.delete(user).where(eq(user.id, userId))
  return c.json({ deleted: true, apple })
}

// undefined: no code sent. false: a body that is not the contract.
async function readCode(req: Request): Promise<string | undefined | false> {
  const text = await req.text()
  if (text.trim() === '') return undefined
  let body: unknown
  try {
    body = JSON.parse(text)
  } catch {
    return false
  }
  if (typeof body !== 'object' || body === null || Array.isArray(body)) return false
  const code = (body as { appleAuthorizationCode?: unknown }).appleAuthorizationCode
  if (code === undefined) return undefined
  if (typeof code !== 'string' || code.length === 0 || code.length > MAX_CODE_LENGTH) return false
  return code
}
