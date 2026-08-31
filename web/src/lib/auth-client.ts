import { createAuthClient } from 'better-auth/react'
import { AUTH_URL } from '../config'
import type { AuthBridge } from '../components/AuthGate'
import { sessionTokenStore } from './session-token'

export const authClient = createAuthClient({
  baseURL: AUTH_URL,
  fetchOptions: { credentials: 'include' },
})

export const browserAuth: AuthBridge = {
  useSession: () => {
    const session = authClient.useSession()
    const token = session.data?.session.token
    if (token) sessionTokenStore.write(token)
    else sessionTokenStore.clear()

    return {
      data: session.data
        ? {
            user: {
              id: session.data.user.id,
              name: session.data.user.name,
              email: session.data.user.email,
              image: session.data.user.image,
            },
          }
        : null,
      isPending: session.isPending,
      error: session.error,
      refetch: session.refetch,
    }
  },
  signInWithApple: async () => {
    try {
      const result = await authClient.signIn.social({
        provider: 'apple',
        callbackURL: window.location.origin,
        errorCallbackURL: `${window.location.origin}/?auth_error=apple`,
      })
      return result.error ? { error: result.error.message || 'Apple sign-in did not finish.' } : {}
    } catch {
      return { error: 'Apple sign-in did not finish.' }
    }
  },
  signOut: () => {
    sessionTokenStore.clear()
    return authClient.signOut()
  },
}
