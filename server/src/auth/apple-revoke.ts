import { and, eq } from 'drizzle-orm'
import { decodeJwt } from 'jose'
import { account } from '../db/auth-schema'
import type { Db } from '../db/types'
import type { FetchLike } from '../musickit/catalog'

// Plan 2026-11-02 account deletion: Apple asks apps that offer Sign in with
// Apple to revoke the listener's tokens when the account is deleted.
const APPLE_TOKEN_URL = 'https://appleid.apple.com/auth/token'
const APPLE_REVOKE_URL = 'https://appleid.apple.com/auth/revoke'
const APPLE_TIMEOUT_MS = 5_000

export type AppleRevokeDeps = {
  // Native tokens are issued to the bundle id, web ones to the Services ID;
  // a token is only revocable by the client it was issued to.
  bundleId: string
  webClientId: string
  clientSecret: (clientId: string) => Promise<string>
  fetchLike?: FetchLike
}

// revoked: Apple accepted the revoke. failed: there was a token to revoke (or
// a code to exchange) and it did not work. not_linked: no Apple login.
// no_token: an Apple login with nothing stored and no code sent.
export type AppleRevokeOutcome = 'revoked' | 'failed' | 'not_linked' | 'no_token'

type Token = { clientId: string, token: string, hint: 'refresh_token' | 'access_token' }

// Never throws: a failure here must not keep a listener's data alive.
export async function revokeAppleForUser(
  db: Db,
  userId: string,
  { code, deps }: { code?: string, deps?: AppleRevokeDeps },
): Promise<AppleRevokeOutcome> {
  const rows = await db
    .select({ sub: account.accountId, refreshToken: account.refreshToken, accessToken: account.accessToken })
    .from(account)
    .where(and(eq(account.userId, userId), eq(account.providerId, 'apple')))
  if (rows.length === 0) return 'not_linked'

  const stored = rows.find((r) => r.refreshToken || r.accessToken)
  if (!code && !stored) return 'no_token'
  if (!deps) {
    console.error('account deletion apple revoke not configured')
    return 'failed'
  }

  try {
    if (code) {
      const exchanged = await exchange(deps, code)
      if (!exchanged) {
        fail('exchange')
      } else if (rows.some((r) => r.sub === exchanged.sub)) {
        return (await revoke(deps, exchanged)) ? 'revoked' : fail('revoke')
      } else {
        // The device's Apple ID is not the linked one: the sheet minted a new
        // grant for it. Revoke that too, but it says nothing about the linked
        // grant, so fall through to whatever token is stored.
        await revoke(deps, exchanged)
        fail('subject')
      }
    }
    if (!stored) return 'failed'
    const token: Token = stored.refreshToken
      ? { clientId: deps.webClientId, token: stored.refreshToken, hint: 'refresh_token' }
      : { clientId: deps.webClientId, token: stored.accessToken!, hint: 'access_token' }
    return (await revoke(deps, token)) ? 'revoked' : fail('revoke')
  } catch {
    return fail('request')
  }
}

async function revoke(deps: AppleRevokeDeps, token: Token): Promise<boolean> {
  const res = await post(deps, APPLE_REVOKE_URL, {
    client_id: token.clientId,
    client_secret: await deps.clientSecret(token.clientId),
    token: token.token,
    token_type_hint: token.hint,
  })
  return res.ok
}

async function exchange(deps: AppleRevokeDeps, code: string): Promise<(Token & { sub: string }) | null> {
  const res = await post(deps, APPLE_TOKEN_URL, {
    client_id: deps.bundleId,
    client_secret: await deps.clientSecret(deps.bundleId),
    code,
    grant_type: 'authorization_code',
  })
  if (!res.ok) return null
  const body = await res.json() as { refresh_token?: unknown, access_token?: unknown, id_token?: unknown }
  // Straight from Apple over TLS, so the subject is read, not verified.
  const sub = typeof body.id_token === 'string' ? subjectOf(body.id_token) : null
  if (!sub) return null
  if (typeof body.refresh_token === 'string') return { clientId: deps.bundleId, token: body.refresh_token, hint: 'refresh_token', sub }
  if (typeof body.access_token === 'string') return { clientId: deps.bundleId, token: body.access_token, hint: 'access_token', sub }
  return null
}

function subjectOf(idToken: string): string | null {
  try {
    const { sub } = decodeJwt(idToken)
    return typeof sub === 'string' ? sub : null
  } catch {
    return null
  }
}

function post(deps: AppleRevokeDeps, url: string, form: Record<string, string>) {
  return (deps.fetchLike ?? fetch)(url, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams(form).toString(),
    // Runs before the delete: a hung Apple must not stall it.
    signal: AbortSignal.timeout(APPLE_TIMEOUT_MS),
  })
}

// The stage only: Apple's error bodies can echo the code or token.
function fail(stage: string): 'failed' {
  console.error(`account deletion apple revoke failed: ${stage}`)
  return 'failed'
}
