import { appReturnUrl } from './app-url'
import { createAuthClient } from 'better-auth/react'
import { anonymousClient } from 'better-auth/client/plugins'
import { AUTH_URL } from '../config'
import type { AuthBridge } from '../components/AuthGate'
import type { AccountBridge } from '../components/AccountDialog'
import type { AuthProvider } from './auth-provider'
import { sessionTokenStore } from './session-token'

export const authClient = createAuthClient({
  baseURL: AUTH_URL,
  // credentials: 'include' also carries an anonymous session's cookie into a
  // social sign-in, which is how the server links it to the account.
  fetchOptions: { credentials: 'include' },
  plugins: [anonymousClient()],
})

// The token useSession last saw. A token ensureSession() stored before the
// session refetch lands must survive the renders in between, so the hook only
// clears a token it observed itself (sign-out clears explicitly).
let observedToken: string | null = null

function providerLabel(provider: AuthProvider): string {
  return provider === 'apple' ? 'Apple' : 'Google'
}

export const browserAuth: AuthBridge & AccountBridge = {
  useSession: () => {
    const session = authClient.useSession()
    const token = session.data?.session.token
    if (token) {
      observedToken = token
      sessionTokenStore.write(token)
    } else if (observedToken && !session.isPending) {
      observedToken = null
      sessionTokenStore.clear()
    }

    return {
      data: session.data
        ? {
            user: {
              id: session.data.user.id,
              name: session.data.user.name,
              email: session.data.user.email,
              image: session.data.user.image,
              isAnonymous: session.data.user.isAnonymous === true,
            },
          }
        : null,
      isPending: session.isPending,
      error: session.error,
      refetch: session.refetch,
    }
  },
  signIn: async (provider) => {
    try {
      const result = await authClient.signIn.social({
        provider,
        callbackURL: appReturnUrl(window.location.origin, import.meta.env.BASE_URL),
        errorCallbackURL: appReturnUrl(window.location.origin, import.meta.env.BASE_URL, { auth_error: provider }),
      })
      return result.error ? { error: result.error.message || `${providerLabel(provider)} sign-in did not finish.` } : {}
    } catch {
      return { error: `${providerLabel(provider)} sign-in did not finish.` }
    }
  },
  listAccounts: async () => {
    const result = await authClient.listAccounts()
    if (result.error) throw new Error('Could not load linked accounts')
    return (result.data ?? []).map(({ id, providerId }) => ({ id, providerId }))
  },
  linkProvider: async (provider) => {
    try {
      const result = await authClient.linkSocial({
        provider,
        callbackURL: appReturnUrl(window.location.origin, import.meta.env.BASE_URL, { account: 'linked', provider }),
        errorCallbackURL: appReturnUrl(window.location.origin, import.meta.env.BASE_URL, { account_error: provider }),
      })
      return result.error ? { error: result.error.message || `Could not link ${providerLabel(provider)}.` } : {}
    } catch {
      return { error: `Could not link ${providerLabel(provider)}.` }
    }
  },
  unlinkAccount: async (accountId) => {
    try {
      const result = await authClient.unlinkAccount({ accountId })
      return result.error ? { error: result.error.message || 'Could not remove that sign-in method.' } : {}
    } catch {
      return { error: 'Could not remove that sign-in method.' }
    }
  },
  signOut: () => {
    observedToken = null
    sessionTokenStore.clear()
    return authClient.signOut()
  },
}
