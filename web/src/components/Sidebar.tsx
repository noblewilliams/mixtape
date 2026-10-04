import type { AppView } from '../domain'
import { HomeIcon, MusicIcon } from './Icons'
import { ThemeToggle } from './ThemeToggle'

export type MusicLinkLabel = { text: string; tone: 'ok' | 'waiting' | 'quiet' }
type SidebarProps = {
  activeView: AppView
  onOpenHome: () => void
  onOpenMusic: () => void
  onOpenMixes: () => void
  onOpenSettings: () => void
}

export function Sidebar({activeView,onOpenHome,onOpenMusic,onOpenMixes,onOpenSettings}: SidebarProps) {
  const current = activeView === 'session' ? 'mixes' : activeView === 'memories' ? 'settings' : activeView
  return <aside className="sidebar primary-sidebar" aria-label="Mixtape navigation">
    <button className="wordmark" type="button" onClick={onOpenHome} aria-label="Mixtape home">mixtape</button>
    <nav className="primary-nav" aria-label="Main navigation">
      <button type="button" onClick={onOpenHome} aria-current={current==='home'?'page':undefined}><HomeIcon/><span>Home</span></button>
      <button type="button" onClick={onOpenMusic} aria-current={current==='music'?'page':undefined}><MusicIcon/><span>Library</span></button>
      <button type="button" onClick={onOpenMixes} aria-current={current==='mixes'?'page':undefined}><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true"><rect x="3" y="5" width="18" height="14" rx="2"/><circle cx="8" cy="11" r="2"/><circle cx="16" cy="11" r="2"/><path d="M7 16h10"/></svg><span>Mixes</span></button>
    </nav>
    <div className="primary-sidebar-bottom">
      <nav className="primary-nav" aria-label="Settings"><button type="button" onClick={onOpenSettings} aria-current={current==='settings'?'page':undefined}><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true"><path d="M4 6h16M4 12h16M4 18h16"/><circle cx="9" cy="6" r="2"/><circle cx="15" cy="12" r="2"/><circle cx="9" cy="18" r="2"/></svg><span>Settings</span></button></nav>
      <ThemeToggle/>
    </div>
  </aside>
}
