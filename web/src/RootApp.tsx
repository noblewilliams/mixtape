import { createMixtapeApi } from './api/client'
import { App } from './App'
import { AuthGate } from './components/AuthGate'
import { API_URL } from './config'
import { browserAuth } from './lib/auth-client'
import { sessionTokenStore } from './lib/session-token'
import { createMusicKitClient } from './musickit/client'

const api = createMixtapeApi(API_URL, sessionTokenStore.read)
const musicKit = createMusicKitClient({ getDeveloperToken: api.getMusicKitToken })

function signOut() {
  void browserAuth.signOut()
}

export function RootApp() {
  return (
    <AuthGate auth={browserAuth}>
      {(user, lastSignInProvider) => (
        <App
          api={api}
          accountAuth={browserAuth}
          lastSignInProvider={lastSignInProvider}
          musicKit={musicKit}
          user={user}
          onSignOut={signOut}
        />
      )}
    </AuthGate>
  )
}
