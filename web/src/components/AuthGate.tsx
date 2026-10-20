import { useEffect, useState, type ReactNode } from 'react'
import {
  authErrorFromSearch,
  browserAuthPreferences,
  type AuthPreferenceStore,
  type AuthProvider,
} from '../lib/auth-provider'
import { restoredIdentity, rememberIdentity, clearWorkspaceRestore } from '../lib/workspace-restore'
import { Cassette } from './Cassette'
import { AppleMark, GoogleMark } from './ProviderMarks'
import { FirstRun } from './first-run/FirstRun'

export type AuthUser = {
  id: string
  name: string
  email: string
  image?: string | null
  /** True for a Better Auth anonymous session created by the first run. */
  isAnonymous?: boolean
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
  children: (user: AuthUser, lastUsed: AuthProvider | null, restoring: boolean) => ReactNode
}

function label(provider: AuthProvider): string {
  return provider === 'apple' ? 'Apple' : 'Google'
}

export function AuthGate({ auth, preferences = browserAuthPreferences, children }: AuthGateProps) {
  const session = auth.useSession()
  const [cachedUser, setCachedUser] = useState(restoredIdentity)
  const [lastUsed, setLastUsed] = useState<AuthProvider | null>(() => preferences.lastUsed())
  const [signInError, setSignInError] = useState(() => authErrorFromSearch(window.location.search))
  // The first run stays mounted while its own ensureSession() creates an
  // anonymous session, until it calls onDone. A returning anonymous listener
  // (session found by the first resolved check) goes straight to the shell.
  // Any resolved no-session state arms it, so sign-out followed by a new
  // anonymous session also stays in the flow.
  const resolved = !session.isPending && !session.error
  const [firstRunActive, setFirstRunActive] = useState(() => resolved && !session.data?.user)

  useEffect(() => {
    if (!resolved) return
    if (!session.data?.user) setFirstRunActive(true)
  }, [resolved, session.data?.user?.id])

  useEffect(() => {
    if (session.data?.user) setSignInError('')
  }, [session.data?.user?.id])

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

  useEffect(() => {
    const user = session.data?.user
    if (user) {
      if (cachedUser && cachedUser.id !== user.id) clearWorkspaceRestore(cachedUser.id)
      rememberIdentity(user)
      setCachedUser(user)
    } else if (!session.isPending && !session.error) {
      clearWorkspaceRestore()
      setCachedUser(null)
    }
  }, [session.data?.user.id, session.data?.user.name, session.data?.user.email, session.data?.user.image, session.data?.user.isAnonymous, session.isPending, session.error])

  const restoring = session.isPending || Boolean(session.error)
  const visibleUser = session.data?.user ?? (restoring ? cachedUser : null)
  const errorMessage = signInError || (session.error ? 'We couldn’t check your session. Try again.' : '')
  const firstRun = (
    <FirstRun
      auth={auth}
      preferences={preferences}
      lastUsed={lastUsed}
      error={errorMessage}
      anonymous={visibleUser?.isAnonymous === true}
      onStart={() => setSignInError('')}
      onDone={() => setFirstRunActive(false)}
    />
  )
  if (visibleUser?.isAnonymous && firstRunActive) return firstRun
  if (visibleUser) {
    return (
      <>
        <div className="workspace-session" inert={restoring} aria-busy={restoring}>
          {children(visibleUser, lastUsed, restoring)}
        </div>
        {restoring && (
          <div className="session-refresh-badge" role={session.error && !session.isPending ? 'alert' : 'status'}>
            {session.error && !session.isPending ? (
              <>Couldn’t refresh your session.<button onClick={() => { void session.refetch() }}>Retry</button></>
            ) : (
              <><span className="session-refresh-spinner" aria-hidden="true" />Refreshing…</>
            )}
          </div>
        )}
      </>
    )
  }

  if (session.isPending || (session.error && !signInError)) {
    return (
      <main className="session-check" aria-label="Mixtape">
        <span className="auth-wordmark">mixtape</span>
        {session.isPending ? (
          <p role="status">Checking your session…</p>
        ) : (
          <>
            <p role="alert">We couldn’t check your session. Try again.</p>
            <button className="minimal-retry" onClick={() => { void session.refetch() }}>Retry</button>
          </>
        )}
      </main>
    )
  }

  return firstRun
}

type SignInPageProps = {
  auth: Pick<AuthBridge, 'signIn'>
  preferences: AuthPreferenceStore
  lastUsed: AuthProvider | null
  error: string
  /** Called as a provider sign-in starts, so the gate can drop a stale URL error. */
  onStart?: () => void
}

/** The provider sign-in page; the first run renders it until its own pages land. */
export function SignInPage({ auth, preferences, lastUsed, error, onStart }: SignInPageProps) {
  const [redirecting, setRedirecting] = useState<AuthProvider | null>(null)
  const [localError, setLocalError] = useState<string | null>(null)
  const waiting = redirecting !== null
  const errorMessage = localError ?? error

  async function startSignIn(provider: AuthProvider) {
    setLocalError(null)
    onStart?.()
    setRedirecting(provider)
    preferences.begin(provider)
    try {
      const result = await auth.signIn(provider)
      if (result.error) {
        setLocalError(result.error)
        setRedirecting(null)
        preferences.clearPending()
      }
    } catch {
      setLocalError(`${label(provider)} sign-in did not finish.`)
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
