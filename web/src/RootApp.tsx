import { createMixtapeApi, type CreateSessionResponse } from './api/client'
import { App } from './App'
import { useLayoutEffect, useMemo, useSyncExternalStore } from 'react'
import { AuthGate, type AuthUser } from './components/AuthGate'
import type { AuthProvider } from './lib/auth-provider'
import { API_URL, DOWNLOAD_URL } from './config'
import { browserAuth } from './lib/auth-client'
import { WorkspaceRestoreProvider, clearWorkspaceRestore } from './lib/workspace-restore'
import { createSessionRequestGate } from './lib/session-request-gate'
import { sessionTokenStore } from './lib/session-token'
import { createMusicKitClient, loadMusicKitScript } from './musickit/client'
import { ensureSession } from './lib/anonymous-session'
import { createFirstRunServices } from './components/first-run/services'
import { SharedMixPage, type SharedMixPlayer } from './components/SharedMixPage'
import { PlaybackController } from './playback/controller'
import { sharedMixToken } from './lib/shared-route'

const api = createMixtapeApi(API_URL, sessionTokenStore.read)

// Built when the first run first renders, never for a browser that already has a session.
function firstRunServices() {
  return createFirstRunServices({
    api,
    musicKit: createMusicKitClient({ getDeveloperToken: api.getMusicKitToken }),
    ensureSession,
  })
}

function signOut() {
  clearWorkspaceRestore()
  void browserAuth.signOut()
}

// DELETE /me already ended every session; a server sign-out would have nothing to end.
function accountDeleted() {
  clearWorkspaceRestore()
  browserAuth.forgetSession()
}

export function RootApp() {
  // /m/<token> is public: it never enters AuthGate, so no sign-in and no first run.
  const sharedToken = sharedMixToken(window.location)
  if (sharedToken) return <SharedMixRoute token={sharedToken} />
  return (
    <AuthGate auth={browserAuth} firstRunServices={firstRunServices}>
      {(user, lastSignInProvider, restoring, initialSession, refetch, signInError) => (
        <WorkspaceRestoreProvider key={user.id} userId={user.id} restoring={restoring}><SignedInApp user={user} lastSignInProvider={lastSignInProvider} restoring={restoring} initialSession={initialSession} refetch={refetch} signInError={signInError} /></WorkspaceRestoreProvider>
      )}
    </AuthGate>
  )
}

function SignedInApp({ user, lastSignInProvider, restoring, initialSession, refetch, signInError }: { user: AuthUser; lastSignInProvider: AuthProvider | null; restoring: boolean; initialSession: CreateSessionResponse | null; refetch: () => void | Promise<void>; signInError: string }) {
  const gate = useMemo(() => createSessionRequestGate(api), [])
  const pendingReads = useSyncExternalStore(gate.subscribe, gate.getPending)
  useLayoutEffect(() => { gate.setReady(!restoring); return () => gate.setReady(false) }, [gate, restoring])
  useLayoutEffect(() => () => gate.dispose(), [gate])
  // Browser authorization and pending work belong to this sign-in, never a module singleton.
  const musicKit = useMemo(() => createMusicKitClient({ getDeveloperToken: gate.api.getMusicKitToken }), [])
  return <>
    <App api={gate.api} initialSession={initialSession ?? undefined} accountAuth={browserAuth} signInAuth={browserAuth} refetchSession={refetch} signInError={signInError} lastSignInProvider={lastSignInProvider} musicKit={musicKit} user={user} onSignOut={signOut} onAccountDeleted={accountDeleted} />
    {!restoring && pendingReads > 0 && <div className="session-refresh-badge" role="status"><span className="session-refresh-spinner" aria-hidden="true" />Refreshing…</div>}
  </>
}

// Play on Apple Music for the shared page. Only Play creates a session
// (ensureSession), and the developer token is asked for after it; the script
// itself needs none, so it can load on the visit. The controller is never
// initialized: a shared play collects no listening evidence.
function sharedMixPlayer(): SharedMixPlayer {
  const musicKit = createMusicKitClient({ getDeveloperToken: api.getMusicKitToken })
  const preload = () => { loadMusicKitScript().catch(() => undefined) }
  return { ensureSession, preload, musicKit, playback: new PlaybackController(api, musicKit, 'shared-mix') }
}

function SharedMixRoute({ token }: { token: string }) {
  // Reads the browser's session (if any) so its token rides on the share read;
  // never creates one on load.
  const session = browserAuth.useSession()
  const userId = session.data?.user && sessionTokenStore.read() ? session.data.user.id : null
  const player = useMemo(sharedMixPlayer, [])
  return <SharedMixPage token={token} api={api} session={{ isPending: session.isPending, userId }} player={player} downloadUrl={DOWNLOAD_URL} />
}
