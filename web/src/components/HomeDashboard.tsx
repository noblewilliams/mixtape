import type { ReactNode } from 'react'
import type { DjSession } from '../domain'
import { HomeComposer } from './HomeComposer'
import { SessionRow } from './SessionControls'
import { MixSkeletons } from './UiStates'

type Props = {
  sessions: DjSession[]
  loading: boolean
  error: string
  busy: boolean
  suggestions: ReactNode
  player: ReactNode
  onRetry: () => void
  onOpenSession: (id: string) => void
  onOpenMixes: () => void
  onSubmit: (prompt: string) => Promise<void>
  transcribe: (audio: File, signal: AbortSignal) => Promise<{ text: string }>
  onRename: (id: string, title: string) => Promise<void>
  onArchive: (id: string) => Promise<void>
  onColor: (id: string, color: string) => Promise<void>
}

export function HomeDashboard(p: Props) {
  const recent = [...p.sessions]
    .filter(s => s.status === 'active')
    .sort((a, b) => Date.parse(b.updatedAt) - Date.parse(a.updatedAt))
    .slice(0, 4)

  return (
    <main className="home-dashboard">
      <h1>Home</h1>
      <div className="home-feed">
        {p.suggestions}
        <section className="recent-mixes" aria-label="Recent mixes">
          <header>
            <h2>Recent mixes</h2>
            <button className="wc-text" onClick={p.onOpenMixes}>All mixes →</button>
          </header>
          {p.error && (
            <div className="home-inline-error" role="alert">
              <span>
                {recent.length
                  ? 'Couldn’t refresh your mixes. Your saved list is still here.'
                  : 'Couldn’t load your mixes.'}
              </span>
              <button className="minimal-retry" onClick={p.onRetry}>Retry</button>
            </div>
          )}
          {p.loading && !recent.length ? (
            <MixSkeletons />
          ) : recent.length ? (
            <div className="recent-mix-grid">
              {recent.map(session => (
                <SessionRow
                  key={session.id}
                  showTape
                  session={session}
                  onOpen={() => p.onOpenSession(session.id)}
                  onRename={title => p.onRename(session.id, title)}
                  onArchive={() => p.onArchive(session.id)}
                  onColor={color => p.onColor(session.id, color)}
                />
              ))}
            </div>
          ) : !p.error && (
            <p className="home-empty-copy">
              Your mixes will appear here. Start with what you feel like hearing.
            </p>
          )}
        </section>
      </div>
      {p.player}
      <HomeComposer busy={p.busy} onSubmit={p.onSubmit} transcribe={p.transcribe} />
    </main>
  )
}
