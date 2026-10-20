import { useEffect, useState, type CSSProperties, type ReactNode } from 'react'
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
import { backgroundUrl } from './first-run/FirstRunPage'
import type { FirstRunServices } from './first-run/services'
import type { CreateSessionResponse } from '../api/client'

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
  /**
   * `initialSession` is the mix the first run just made, for the shell to
   * open; `refetch` re-reads the session (the in-app sign-in page calls it
   * as a provider sign-in starts; on the web redirect the real path is the
   * reload after the redirect); `signInError` is a failed sign-in that came
   * back to an anonymous listener (empty otherwise).
   */
  children: (
    user: AuthUser,
    lastUsed: AuthProvider | null,
    restoring: boolean,
    initialSession: CreateSessionResponse | null,
    refetch: () => void | Promise<void>,
    signInError: string,
  ) => ReactNode
  /** Builds the first run's runs and API; called once, when the first run first renders. */
  firstRunServices?: () => FirstRunServices
}

function label(provider: AuthProvider): string {
  return provider === 'apple' ? 'Apple' : 'Google'
}

export function AuthGate({ auth, preferences = browserAuthPreferences, children, firstRunServices }: AuthGateProps) {
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
  const [handoffSession, setHandoffSession] = useState<CreateSessionResponse | null>(null)

  useEffect(() => {
    if (!resolved) return
    if (!session.data?.user) {
      setFirstRunActive(true)
      setHandoffSession(null)
    }
  }, [resolved, session.data?.user?.id])

  // An account clears a URL sign-in error. An anonymous listener keeps it:
  // their sign-in from the cap or the Keep pill failed, and the shell reopens
  // the sign-in page with it.
  useEffect(() => {
    if (session.data?.user && !session.data.user.isAnonymous) setSignInError('')
  }, [session.data?.user?.id, session.data?.user?.isAnonymous])

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
      services={firstRunServices}
      signIn={{ auth, preferences, lastUsed, error: errorMessage, onStart: () => setSignInError('') }}
      onDone={({ session: created }) => {
        setHandoffSession(created ?? null)
        setFirstRunActive(false)
      }}
    />
  )
  // Once armed, the flow stays mounted through the anonymous session's
  // arrival (and any refetch in between) until it hands off.
  if (firstRunActive && (!visibleUser || visibleUser.isAnonymous)) return firstRun
  if (visibleUser) {
    return (
      <>
        <div className="workspace-session" inert={restoring} aria-busy={restoring}>
          {children(visibleUser, lastUsed, restoring, handoffSession, session.refetch, visibleUser.isAnonymous ? signInError : '')}
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

/** The sign-in headline from the Keep sheet, the cap and the You row. */
export const KEEP_HEADLINE = 'Keep your mixes.'
/** The cap's line under that headline. */
export const CAP_LINE = 'That’s three mixes on this device. Sign in to keep going, and to keep these.'
const WELCOME_SIGN_IN_HEADLINE = 'Your music, mixed for right now.'

/**
 * `welcome`: behind the first run's foot link, unchanged. `keep`: from the
 * Keep sheet or the You row. `cap`: the fourth mix, with the cap line and no
 * last-used note (board C1, C2).
 */
export type SignInVariant = 'welcome' | 'keep' | 'cap'

export function signInHeadline(variant: SignInVariant): string {
  return variant === 'welcome' ? WELCOME_SIGN_IN_HEADLINE : KEEP_HEADLINE
}

type SignInPageProps = {
  auth: Pick<AuthBridge, 'signIn'>
  preferences: AuthPreferenceStore
  lastUsed: AuthProvider | null
  error: string
  variant?: SignInVariant
  /** Called as a provider sign-in starts, so the gate can drop a stale URL error. */
  onStart?: () => void
  /**
   * Called when Better Auth's sign-in call resolves without an error. On the
   * web that is as the redirect starts, not after the sign-in; the real path
   * is the reload after the redirect. The shell refetches the session here
   * for flows that do not leave the page.
   */
  onSignedIn?: () => void
}

/**
 * The provider sign-in page: the existing screen on the plum-black sign-in
 * image. The only place provider buttons appear.
 */
export function SignInPage({ auth, preferences, lastUsed, error, variant = 'welcome', onStart, onSignedIn }: SignInPageProps) {
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
      } else {
        onSignedIn?.()
      }
    } catch {
      setLocalError(`${label(provider)} sign-in did not finish.`)
      setRedirecting(null)
      preferences.clearPending()
    }
  }

  const welcome = variant === 'welcome'
  const line = welcome
    ? 'Start with a mood, a memory, or one song. Mixtape builds a mix from music you already love.'
    : variant === 'cap'
      ? CAP_LINE
      : null
  const noted = variant === 'cap' ? null : lastUsed
  const style = { '--auth-bg': `url("${backgroundUrl('sign-in')}")` } as CSSProperties
  return (
    <main className="auth-page auth-page--graphic" style={style}>
      <section className="auth-surface" aria-labelledby="auth-title">
        <div className="auth-intro">
          <span className="auth-wordmark">mixtape</span>
          <div className="auth-copy">
            <h1 id="auth-title" tabIndex={-1}>{signInHeadline(variant)}</h1>
            {line ? <p>{line}</p> : null}
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
              <p className="auth-status">{welcome ? 'Sign in to start a mix and keep your taste in sync.' : '\u00a0'}</p>
            )}
            <div className="auth-provider-row">
              {(['apple', 'google'] as const).map((provider) => {
                const isLastUsed = noted === provider
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
