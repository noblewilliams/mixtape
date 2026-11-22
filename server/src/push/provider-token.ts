import { and, eq } from 'drizzle-orm'
import { importPKCS8, SignJWT } from 'jose'
import { apnsProviderTokens } from '../db/schema'
import type { Db } from '../db/types'

export type ApnsKey = { teamId: string; keyId: string; privateKey: string }

// Apple: refresh no more than once every 20 minutes and no less than once
// every 60. Reuse under 40 keeps clear of both edges.
export const APNS_TOKEN_REUSE_MS = 40 * 60_000

export async function signApnsProviderToken({ teamId, keyId, privateKey }: ApnsKey, now: Date): Promise<string> {
  const signingKey = await importPKCS8(privateKey.replace(/\\n/g, '\n'), 'ES256')
  return new SignJWT({})
    .setProtectedHeader({ alg: 'ES256', kid: keyId })
    .setIssuer(teamId)
    .setIssuedAt(Math.floor(now.getTime() / 1000))
    .sign(signingKey)
}

// The provider token is shared through `apns_provider_tokens` so the many
// isolates and objects do not each refresh it (429
// TooManyProviderTokenUpdates). The row holds a signed credential, never the
// .p8; neither is ever logged.
//
// `forceRefresh` is for a 403 ExpiredProviderToken/InvalidProviderToken.
// Pass the token APNs rejected as `rejectedToken`: if another sender has
// already replaced it, that newer token is used rather than signing again.
export async function getApnsProviderToken(
  db: Db,
  key: ApnsKey,
  {
    now = new Date(),
    forceRefresh = false,
    rejectedToken,
    sign = signApnsProviderToken,
  }: {
    now?: Date
    forceRefresh?: boolean
    rejectedToken?: string
    sign?: (key: ApnsKey, now: Date) => Promise<string>
  } = {},
): Promise<string> {
  if (!key.teamId) throw new Error('APNs team ID is required')
  if (!key.keyId) throw new Error('APNs key ID is required')
  if (!key.privateKey) throw new Error('APNs private key is required')

  const current = await read(db, key.keyId)
  if (current) {
    const young = now.getTime() - current.issuedAt.getTime() < APNS_TOKEN_REUSE_MS
    const replacedSinceRejection = rejectedToken !== undefined && current.token !== rejectedToken
    if (young && (!forceRefresh || replacedSinceRejection)) return current.token
  }

  // issued_at is stored at whole seconds, matching the JWT's iat.
  const issuedAt = new Date(Math.floor(now.getTime() / 1000) * 1000)
  const token = await sign(key, issuedAt)

  const won = current
    ? await db
        .update(apnsProviderTokens)
        .set({ token, issuedAt })
        .where(and(eq(apnsProviderTokens.keyId, key.keyId), eq(apnsProviderTokens.issuedAt, current.issuedAt)))
        .returning({ token: apnsProviderTokens.token })
    : await db
        .insert(apnsProviderTokens)
        .values({ keyId: key.keyId, token, issuedAt })
        .onConflictDoNothing()
        .returning({ token: apnsProviderTokens.token })
  if (won.length > 0) return token

  // Lost the race: another sender stored its token first. Use the winner's.
  const winner = await read(db, key.keyId)
  if (!winner) throw new Error('APNs provider token row vanished')
  return winner.token
}

async function read(db: Db, keyId: string) {
  const [row] = await db
    .select({ token: apnsProviderTokens.token, issuedAt: apnsProviderTokens.issuedAt })
    .from(apnsProviderTokens)
    .where(eq(apnsProviderTokens.keyId, keyId))
  return row
}
