import { createAuthClient } from 'better-auth/react'
import { API_URL } from '../config'
import type { AuthBridge } from '../components/AuthGate'

export const authClient = createAuthClient({
  baseURL: API_URL,
  fetchOptions: { credentials: 'include' },
})

export const browserAuth: AuthBridge = {
  useSession: () => {
    const session = authClient.useSession()
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
  signOut: () => authClient.signOut(),
}
