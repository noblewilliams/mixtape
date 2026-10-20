import type { AuthPreferenceStore, AuthProvider } from '../../lib/auth-provider'
import { SignInPage, type AuthBridge } from '../AuthGate'

export type FirstRunProps = {
  auth: Pick<AuthBridge, 'signIn'>
  preferences: AuthPreferenceStore
  lastUsed: AuthProvider | null
  error: string
  /** True once the flow's own ensureSession() has created an anonymous session. */
  anonymous: boolean
  onStart?: () => void
  /** Leave the flow for the shell. */
  onDone: () => void
}

/**
 * Shown with no session, and kept mounted after the flow creates an
 * anonymous session until it calls onDone. Placeholder until the first-run
 * pages land: it shows the sign-in page. Those pages call ensureSession()
 * right before the first prompt, seed save or sync start, never on load.
 */
export function FirstRun({ anonymous, onDone, ...signIn }: FirstRunProps) {
  return (
    <div className="first-run" data-testid="first-run" style={{ display: 'contents' }}>
      <SignInPage {...signIn} />
      {anonymous && <button type="button" className="minimal-retry" onClick={onDone}>Continue to your mixes</button>}
    </div>
  )
}
