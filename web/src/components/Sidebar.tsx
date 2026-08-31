import type { AppView, DjSession } from '../domain'
import { Cassette } from './Cassette'
import { HomeIcon, PlusIcon, SignOutIcon, SyncIcon } from './Icons'

type SidebarProps = {
  sessions: DjSession[]
  activeSessionId: string | null
  activeView: AppView
  userName: string
  onOpenSession: (id: string) => void
  onOpenHome: () => void
  onNewTape: () => void
  onSync: () => void
  onSignOut: () => void
}

export function Sidebar({
  sessions,
  activeSessionId,
  activeView,
  userName,
  onOpenSession,
  onOpenHome,
  onNewTape,
  onSync,
  onSignOut,
}: SidebarProps) {
  return (
    <aside className="sidebar" aria-label="Mixtape navigation">
      <div className="sidebar-topline">
        <button className="wordmark" type="button" onClick={onOpenHome} aria-label="Mixtape home">
          mixtape
        </button>
        <button
          className={`nav-icon-button ${activeView === 'home' ? 'is-active' : ''}`}
          type="button"
          onClick={onOpenHome}
          aria-label="Home"
        >
          <HomeIcon />
        </button>
      </div>

      <button className="new-tape-button" type="button" onClick={onNewTape} aria-label="Make a new tape">
        <span className="new-tape-reel" aria-hidden="true" />
        <span>Make a new tape</span>
        <PlusIcon />
      </button>

      <div className="sidebar-section-heading">
        <span>Your tapes</span>
        <span>{sessions.length}</span>
      </div>

      <nav className="session-list" aria-label="Your tapes">
        {sessions.slice(0, 8).map((session) => (
          <button
            className={`session-link ${activeView === 'session' && activeSessionId === session.id ? 'is-active' : ''}`}
            type="button"
            key={session.id}
            onClick={() => onOpenSession(session.id)}
          >
            <Cassette
              className="session-cassette"
              title={session.title}
              caseColor={session.caseColor}
              stockColor={session.stockColor}
              labelled={false}
            />
            <span className="session-link-copy">
              <strong>{session.title}</strong>
              <small>
                {session.trackCount === 0 ? 'Blank tape' : `${session.trackCount} tracks`} · {session.ageLabel}
              </small>
            </span>
          </button>
        ))}
      </nav>

      <div className="sidebar-footer">
        <span className="avatar" aria-hidden="true">
          {userName.trim().charAt(0).toUpperCase() || 'M'}
        </span>
        <span className="account-copy">
          <strong>{userName}</strong>
          <small>Signed in with Apple</small>
        </span>
        <button className="sync-button" type="button" onClick={onSync} aria-label="Sync music library">
          <SyncIcon />
        </button>
        <button className="sync-button" type="button" onClick={onSignOut} aria-label="Sign out">
          <SignOutIcon />
        </button>
      </div>
    </aside>
  )
}
