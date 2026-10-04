import { createMixtapeApi } from './api/client'
import { App } from './App'
import { useLayoutEffect, useMemo, useSyncExternalStore } from 'react'
import { AuthGate, type AuthUser } from './components/AuthGate'
import type { AuthProvider } from './lib/auth-provider'
import { API_URL } from './config'
import { browserAuth } from './lib/auth-client'
import { WorkspaceRestoreProvider, clearWorkspaceRestore } from './lib/workspace-restore'
import { createSessionRequestGate } from './lib/session-request-gate'
import { sessionTokenStore } from './lib/session-token'
import { createMusicKitClient } from './musickit/client'

const api = createMixtapeApi(API_URL, sessionTokenStore.read)

function signOut() {
  clearWorkspaceRestore()
  void browserAuth.signOut()
}

export function RootApp() {
  return (
    <AuthGate auth={browserAuth}>
      {(user, lastSignInProvider, restoring) => (
        <WorkspaceRestoreProvider key={user.id} userId={user.id} restoring={restoring}><SignedInApp user={user} lastSignInProvider={lastSignInProvider} restoring={restoring} /></WorkspaceRestoreProvider>
      )}
    </AuthGate>
  )
}

function SignedInApp({ user, lastSignInProvider, restoring }: { user: AuthUser; lastSignInProvider: AuthProvider | null; restoring: boolean }) {
  const gate = useMemo(() => createSessionRequestGate(api), [])
  const pendingReads = useSyncExternalStore(gate.subscribe, gate.getPending)
  useLayoutEffect(() => { gate.setReady(!restoring); return () => gate.setReady(false) }, [gate, restoring])
  useLayoutEffect(() => () => gate.dispose(), [gate])
  // Browser authorization and pending work belong to this sign-in, never a module singleton.
  const musicKit = useMemo(() => createMusicKitClient({ getDeveloperToken: gate.api.getMusicKitToken }), [])
  return <>
    <App api={gate.api} accountAuth={browserAuth} lastSignInProvider={lastSignInProvider} musicKit={musicKit} user={user} onSignOut={signOut} />
    {!restoring && pendingReads > 0 && <div className="session-refresh-badge" role="status"><span className="session-refresh-spinner" aria-hidden="true" />Refreshing…</div>}
  </>
}
