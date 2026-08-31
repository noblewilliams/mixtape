import { createMixtapeApi } from './api/client'
import { App } from './App'
import { AuthGate } from './components/AuthGate'
import { API_URL } from './config'
import { browserAuth } from './lib/auth-client'

const api = createMixtapeApi(API_URL)

function signOut() {
  void browserAuth.signOut()
}

export function RootApp() {
  return (
    <AuthGate auth={browserAuth}>
      {(user) => <App api={api} user={user} onSignOut={signOut} />}
    </AuthGate>
  )
}
