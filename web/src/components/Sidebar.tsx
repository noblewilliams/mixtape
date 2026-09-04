import type { AppView, DjSession } from '../domain'
import type { AuthProvider } from '../lib/auth-provider'
import { Cassette } from './Cassette'
import { HomeIcon, MusicIcon, PlusIcon, SignOutIcon, SyncIcon } from './Icons'

export type MusicLinkLabel = { text: string; tone: 'ok' | 'waiting' | 'quiet' }

type SidebarProps = {
  sessions: DjSession[]
  activeSessionId: string | null
  activeView: AppView
  userName: string
  signInMethod: AuthProvider | null
  musicLabel: MusicLinkLabel
  onOpenSession: (id: string) => void
  onOpenHome: () => void
  onOpenMusic: () => void
  onNewTape: () => void
  onOpenAccount: () => void
  onSync: () => void
  onSignOut: () => void
  /** True while a Spotify upload holds the one-playlist-run gate. */
  syncDisabled?: boolean
}

export function Sidebar({
  sessions,
  activeSessionId,
  activeView,
  userName,
  signInMethod,
  musicLabel,
  onOpenSession,
  onOpenHome,
  onOpenMusic,
  onNewTape,
  onOpenAccount,
  onSync,
  syncDisabled = false,
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

      <button
        className={`music-link ${activeView === 'spotify' ? 'is-active' : ''}`}
        type="button"
        onClick={onOpenMusic}
        aria-current={activeView === 'spotify' ? 'page' : undefined}
      >
        <span className="music-link-mark" aria-hidden="true">
          <MusicIcon />
        </span>
        <span className="music-link-copy">
          <strong>Your music</strong>
          <small className={`music-link-state music-link-state--${musicLabel.tone}`}>{musicLabel.text}</small>
        </span>
        <span className="chevron" aria-hidden="true">
          ›
        </span>
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
        <button className="sidebar-account" type="button" onClick={onOpenAccount} aria-label="Open account settings">
          <span className="avatar" aria-hidden="true">
            {userName.trim().charAt(0).toUpperCase() || 'M'}
          </span>
          <span className="account-copy">
            <strong>{userName}</strong>
            <small>{signInMethod ? `Signed in with ${signInMethod === 'apple' ? 'Apple' : 'Google'}` : 'Mixtape account'}</small>
          </span>
        </button>
        <button className="sync-button" type="button" onClick={onSync} aria-label="Sync music library" disabled={syncDisabled}>
          <SyncIcon />
        </button>
        <button className="sync-button" type="button" onClick={onSignOut} aria-label="Sign out">
          <SignOutIcon />
        </button>
      </div>
    </aside>
  )
}
