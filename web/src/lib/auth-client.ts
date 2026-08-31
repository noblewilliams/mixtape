import { createAuthClient } from 'better-auth/react'
import { AUTH_URL } from '../config'
import type { AuthBridge } from '../components/AuthGate'
import type { AccountBridge } from '../components/AccountDialog'
import type { AuthProvider } from './auth-provider'
import { sessionTokenStore } from './session-token'

export const authClient = createAuthClient({
  baseURL: AUTH_URL,
  fetchOptions: { credentials: 'include' },
})

function providerLabel(provider: AuthProvider): string {
  return provider === 'apple' ? 'Apple' : 'Google'
}

export const browserAuth: AuthBridge & AccountBridge = {
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
  signIn: async (provider) => {
    try {
      const result = await authClient.signIn.social({
        provider,
        callbackURL: window.location.origin,
        errorCallbackURL: `${window.location.origin}/?auth_error=${provider}`,
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
        callbackURL: `${window.location.origin}/?account=linked&provider=${provider}`,
        errorCallbackURL: `${window.location.origin}/?account_error=${provider}`,
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
    sessionTokenStore.clear()
    return authClient.signOut()
  },
}
