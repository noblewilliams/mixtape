import { useState, type ReactNode } from 'react'
import { Cassette } from './Cassette'

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
  signInWithApple: () => Promise<{ error?: string }>
  signOut: () => Promise<unknown>
}

type AuthGateProps = {
  auth: AuthBridge
  children: (user: AuthUser) => ReactNode
}

function AppleMark() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path
        fill="currentColor"
        d="M16.71 12.74c.02 2.15 1.89 2.87 1.91 2.88-.02.05-.3 1.02-.98 2.03-.59.87-1.21 1.73-2.18 1.75-.95.02-1.26-.57-2.35-.57s-1.43.55-2.33.59c-.94.03-1.65-.94-2.25-1.8-1.22-1.77-2.15-5-0.9-7.18a3.5 3.5 0 0 1 2.98-1.81c.93-.02 1.81.63 2.35.63.54 0 1.56-.78 2.63-.66.45.02 1.71.18 2.52 1.37-.07.04-1.5.88-1.4 2.77ZM14.89 7.47c.49-.6.83-1.43.74-2.26-.72.03-1.59.48-2.1 1.08-.46.53-.86 1.38-.75 2.19.8.06 1.62-.41 2.11-1.01Z"
      />
    </svg>
  )
}

export function AuthGate({ auth, children }: AuthGateProps) {
  const session = auth.useSession()
  const [redirecting, setRedirecting] = useState(false)
  const [signInError, setSignInError] = useState('')

  if (session.data?.user) return children(session.data.user)

  const waiting = session.isPending || redirecting
  const errorMessage = signInError || (session.error ? 'We could not check your session. Please try again.' : '')

  async function startAppleSignIn() {
    setSignInError('')
    setRedirecting(true)
    try {
      const result = await auth.signInWithApple()
      if (result.error) {
        setSignInError(result.error)
        setRedirecting(false)
      }
    } catch {
      setSignInError('Apple sign-in did not finish.')
      setRedirecting(false)
    }
  }

  return (
    <main className="auth-page">
      <section className="auth-surface" aria-labelledby="auth-title">
        <div className="auth-intro">
          <span className="auth-wordmark">mixtape</span>
          <div className="auth-copy">
            <h1 id="auth-title">A tape for right now.</h1>
            <p>Start with a mood, a memory, or one song. The DJ will shape the rest from music you already love.</p>
          </div>
        </div>

        <div className="auth-action">
          <Cassette className="auth-cassette" loading={waiting} labelled={false} />
          <div className="auth-control">
            {redirecting ? (
              <p className="auth-status" role="status">
                Opening Apple sign-in
              </p>
            ) : session.isPending ? (
              <p className="auth-status" role="status">
                Checking your session
              </p>
            ) : (
              <p className="auth-status">Sign in to find your tapes and keep listening.</p>
            )}
            <button
              className="apple-sign-in"
              type="button"
              onClick={() => void startAppleSignIn()}
              disabled={waiting}
            >
              <AppleMark />
              <span>{redirecting ? 'Opening Apple…' : 'Continue with Apple'}</span>
            </button>
            <p className={`auth-error ${errorMessage ? 'is-visible' : ''}`} role={errorMessage ? 'alert' : undefined}>
              {errorMessage || '\u00a0'}
            </p>
          </div>
        </div>
      </section>
    </main>
  )
}
