import { useEffect, useState, type ReactNode } from 'react'
import {
  authErrorFromSearch,
  browserAuthPreferences,
  type AuthPreferenceStore,
  type AuthProvider,
} from '../lib/auth-provider'
import { Cassette } from './Cassette'
import { AppleMark, GoogleMark } from './ProviderMarks'

export type AuthUser = {
  id: string
  name: string
  email: string
  image?: string | null
}

export type AuthSessionState = {
  data: { user: AuthUser } | null
  isPending: boolean
  error: Error | null
  refetch: () => void | Promise<void>
}

export type AuthBridge = {
  useSession: () => AuthSessionState
  signIn: (provider: AuthProvider) => Promise<{ error?: string }>
  signOut: () => Promise<unknown>
}

type AuthGateProps = {
  auth: AuthBridge
  preferences?: AuthPreferenceStore
  children: (user: AuthUser, lastUsed: AuthProvider | null) => ReactNode
}

function label(provider: AuthProvider): string {
  return provider === 'apple' ? 'Apple' : 'Google'
}

export function AuthGate({ auth, preferences = browserAuthPreferences, children }: AuthGateProps) {
  const session = auth.useSession()
  const [redirecting, setRedirecting] = useState<AuthProvider | null>(null)
  const [lastUsed, setLastUsed] = useState<AuthProvider | null>(() => preferences.lastUsed())
  const [signInError, setSignInError] = useState(() => authErrorFromSearch(window.location.search))

  useEffect(() => {
    if (!signInError) return
    preferences.clearPending()
    const url = new URL(window.location.href)
    url.searchParams.delete('auth_error')
    url.searchParams.delete('error')
    window.history.replaceState({}, '', `${url.pathname}${url.search}${url.hash}`)
  }, [preferences, signInError])

  useEffect(() => {
    if (!session.data?.user) return
    const promoted = preferences.promotePending()
    if (promoted) setLastUsed(promoted)
  }, [preferences, session.data?.user?.id])

  if (session.data?.user) return children(session.data.user, lastUsed)

  const waiting = session.isPending || redirecting !== null
  const errorMessage = signInError || (session.error ? 'We couldn’t check your session. Try again.' : '')

  async function startSignIn(provider: AuthProvider) {
    setSignInError('')
    setRedirecting(provider)
    preferences.begin(provider)
    try {
      const result = await auth.signIn(provider)
      if (result.error) {
        setSignInError(result.error)
        setRedirecting(null)
        preferences.clearPending()
      }
    } catch {
      setSignInError(`${label(provider)} sign-in did not finish.`)
      setRedirecting(null)
      preferences.clearPending()
    }
  }

  return (
    <main className="auth-page">
      <section className="auth-surface" aria-labelledby="auth-title">
        <div className="auth-intro">
          <span className="auth-wordmark">mixtape</span>
          <div className="auth-copy">
            <h1 id="auth-title">Your music, mixed for right now.</h1>
            <p>Start with a mood, a memory, or one song. Mixtape builds a mix from music you already love.</p>
          </div>
        </div>

        <div className="auth-action">
          <Cassette className="auth-cassette" loading={waiting} labelled={false} />
          <div className="auth-control">
            {redirecting ? (
              <p className="auth-status" role="status">
                Opening {label(redirecting)} sign-in
              </p>
            ) : session.isPending ? (
              <p className="auth-status" role="status">
                Checking your session
              </p>
            ) : (
              <p className="auth-status">Sign in to start a mix and keep your taste in sync.</p>
            )}
            <div className="auth-provider-row">
              {(['apple', 'google'] as const).map((provider) => {
                const isLastUsed = lastUsed === provider
                const lastUsedId = `last-used-${provider}`
                return (
                  <div className="auth-provider-choice" key={provider}>
                    <button
                      className={`provider-sign-in provider-sign-in--${provider}`}
                      type="button"
                      aria-describedby={isLastUsed ? lastUsedId : undefined}
                      onClick={() => void startSignIn(provider)}
                      disabled={waiting}
                    >
                      {provider === 'apple' ? <AppleMark /> : <GoogleMark />}
                      <span>{redirecting === provider ? `Opening ${label(provider)}…` : `Continue with ${label(provider)}`}</span>
                    </button>
                    {isLastUsed ? <span className="auth-last-used" id={lastUsedId}>last used</span> : null}
                  </div>
                )
              })}
            </div>
            <p className={`auth-error ${errorMessage ? 'is-visible' : ''}`} role={errorMessage ? 'alert' : undefined}>
              {errorMessage || '\u00a0'}
            </p>
          </div>
        </div>
      </section>
    </main>
  )
}
