import { EmptyState, MixSkeletons } from './UiStates'
import { SessionRow } from './SessionControls'
import { TapeRack } from './TapeRack'
import { Tabs } from './Tabs'
import { ViewSwitch } from './ViewSwitch'
import type { CollectionView, DjSession } from '../domain'
import type { ReactNode } from 'react'
import { NewTapeCompactButton } from './TapeActions'

type HomeProps = {
  loading?: boolean
  error?: string
  onRetry?: () => void
  onColor?: (id: string, color: string) => Promise<void>
  player?: ReactNode
  suggestions?: ReactNode
  archived?: boolean
  onArchived?: (value: boolean) => void
  onRename?: (id: string, title: string) => Promise<void>
  onArchive?: (id: string) => Promise<void>
  onRestore?: (id: string) => Promise<void>
  sessions: DjSession[]
  collectionView: CollectionView
  onChangeCollectionView: (view: CollectionView) => void
  onOpenSession: (id: string) => void
  onNewTape: () => void
}

function countLine(count: number, archived: boolean) {
  return `${count} ${archived ? 'archived ' : ''}${count === 1 ? 'mix' : 'mixes'}${count ? ' · recently updated' : ''}`
}

export function Home({
  loading = false, error, onRetry, onColor, player, suggestions, sessions, archived = false, onArchived, onRename, onArchive, onRestore,
  collectionView,
  onChangeCollectionView,
  onOpenSession,
  onNewTape,
}: HomeProps) {
  // A stored view from another version must not break the page.
  const view: CollectionView = collectionView === 'grid' || collectionView === 'closet' ? collectionView : 'list'
  const row = (session: DjSession, layout: 'row' | 'tile') => (
    <SessionRow showTape layout={layout} key={session.id} session={session} onOpen={() => onOpenSession(session.id)}
      onColor={onColor ? (color) => onColor(session.id, color) : undefined}
      onRename={(title) => onRename?.(session.id, title) ?? Promise.resolve()}
      onArchive={() => onArchive?.(session.id) ?? Promise.resolve()}
      onRestore={() => onRestore?.(session.id) ?? Promise.resolve()} />
  )
  return (
    <main className="home-panel mixes-panel">
      {player}
      <header className="home-header">
        <div>
          <h1>Mixes</h1>
          <p>{loading && sessions.length === 0 ? 'Loading mixes…' : countLine(sessions.length, archived)}</p>
        </div>
        <NewTapeCompactButton onClick={onNewTape} />
      </header>

      {!archived && suggestions}
      <div className="mixes-toolbar">
        <Tabs label="Mix sections" current={archived ? 'archived' : 'active'} onSelect={(tab) => onArchived?.(tab === 'archived')}
          items={[{ id: 'active', label: 'Active' }, { id: 'archived', label: 'Archived' }]} />
        <ViewSwitch value={view} onChange={onChangeCollectionView} />
      </div>

      <div className="mixes-content">
        {error && sessions.length > 0 && <div className="mix-refresh" role="alert"><span>Couldn’t refresh your mixes. Your mixes are still here.</span><button className="minimal-retry" onClick={onRetry}>Retry</button></div>}
        {loading && sessions.length === 0 ? <MixSkeletons view={view} /> : sessions.length === 0 ? <EmptyState kind={error ? 'error' : 'tape'} title={error ? 'Couldn’t load your mixes' : archived ? 'No archived mixes' : 'Your next moment starts here'} description={error ? 'Try again in a moment.' : archived ? 'Mixes you archive will appear here.' : 'Tell the DJ what you’re in the mood for.'} action={error ? { label: 'Try again', onClick: onRetry! } : archived ? undefined : { label: 'Make a mix', onClick: onNewTape }} />
          : view === 'list' ? <section className="tape-grid" aria-label="Tape list">{sessions.map((session) => row(session, 'row'))}</section>
          : view === 'grid' ? <section className="mix-grid" aria-label="Mix grid">{sessions.map((session) => row(session, 'tile'))}</section>
          : <TapeRack sessions={sessions} onOpenSession={onOpenSession} />}
      </div>
    </main>
  )
}
