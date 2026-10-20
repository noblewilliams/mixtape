import { authClient } from './auth-client'
import { sessionTokenStore } from './session-token'

let inFlight: Promise<void> | null = null

async function signInAnonymously(): Promise<void> {
  let headerToken: string | null = null
  const result = await authClient.signIn.anonymous({
    fetchOptions: {
      onSuccess: (context) => { headerToken = context.response.headers.get('set-auth-token') },
    },
  })
  if (result.error) throw new Error(result.error.message || 'Could not start a session.')
  // The bearer plugin puts the signed session token in set-auth-token, as for
  // a social sign-in. The body's token is the raw value; the server accepts
  // both only because requireSignature is off, so it is never used here.
  if (!headerToken) throw new Error('Anonymous sign-in returned no set-auth-token header.')
  sessionTokenStore.write(headerToken)
}

/**
 * Make sure a session exists before the first action that needs the server
 * (first prompt, seed save, sync start). Creates an anonymous user only when
 * there is no session; never called on load. Concurrent calls share one
 * sign-in.
 */
export function ensureSession(): Promise<void> {
  if (sessionTokenStore.read()) return Promise.resolve()
  inFlight ??= signInAnonymously().finally(() => { inFlight = null })
  return inFlight
}
