import { createMixtapeApi } from './api/client'
import { App } from './App'
import { useMemo } from 'react'
import { AuthGate, type AuthUser } from './components/AuthGate'
import type { AuthProvider } from './lib/auth-provider'
import { API_URL } from './config'
import { browserAuth } from './lib/auth-client'
import { sessionTokenStore } from './lib/session-token'
import { createMusicKitClient } from './musickit/client'

const api = createMixtapeApi(API_URL, sessionTokenStore.read)

function signOut() {
  void browserAuth.signOut()
}

export function RootApp() {
  return (
    <AuthGate auth={browserAuth}>
      {(user, lastSignInProvider) => (
        <SignedInApp key={user.id} user={user} lastSignInProvider={lastSignInProvider} />
      )}
    </AuthGate>
  )
}

function SignedInApp({ user, lastSignInProvider }: { user: AuthUser; lastSignInProvider: AuthProvider | null }) {
  // Browser authorization and pending work belong to this sign-in, never a module singleton.
  const musicKit = useMemo(() => createMusicKitClient({ getDeveloperToken: api.getMusicKitToken }), [])
  return <App api={api} accountAuth={browserAuth} lastSignInProvider={lastSignInProvider} musicKit={musicKit} user={user} onSignOut={signOut} />
}
