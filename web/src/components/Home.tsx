import { SessionRow } from './SessionControls'
import type { CollectionView, DjSession } from '../domain'
import type { CSSProperties, ReactNode } from 'react'
import { NewTapeCompactButton } from './TapeActions'

type HomeProps = {
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

const darkSpines = new Set(['#3e4850', '#51434f', '#596454', '#76584f'])

export function Home({
  player, suggestions, sessions, archived = false, onArchived, onRename, onArchive, onRestore,
  collectionView,
  onChangeCollectionView,
  onOpenSession,
  onNewTape,
}: HomeProps) {
  return (
    <main className="home-panel">
      {player}
      <header className="home-header">
        <div>
          <p className="quiet-kicker">Your collection</p>
          <h1>{archived ? 'Archived mixes' : 'Your tapes'}</h1>
          <p>{sessions.length} sessions · sorted by last played</p>
        </div>
        <NewTapeCompactButton onClick={onNewTape} />
      </header>

      {!archived && suggestions}
      <nav className="wc-tabs"><button className="wc-text" aria-pressed={!archived} onClick={() => onArchived?.(false)}>Active mixes</button><button className="wc-text" aria-pressed={archived} onClick={() => onArchived?.(true)}>Archived mixes</button></nav>
      {sessions.length === 0 && <p>{archived ? 'No archived mixes.' : 'No mixes yet.'}</p>}
      <div className="collection-toolbar">
        <p>Return to a moment, or start from a blank tape.</p>
        <div className="view-switch" aria-label="Collection view">
          <button
            className={collectionView === 'list' ? 'is-active' : ''}
            type="button"
            onClick={() => onChangeCollectionView('list')}
            aria-pressed={collectionView === 'list'}
          >
            List view
          </button>
          <button
            className={collectionView === 'closet' ? 'is-active' : ''}
            type="button"
            onClick={() => onChangeCollectionView('closet')}
            aria-pressed={collectionView === 'closet'}
          >
            Closet view
          </button>
        </div>
      </div>

      {collectionView === 'list' ? (
        <section className="tape-grid" aria-label="Tape list">
          {sessions.map((session) => (
            <SessionRow key={session.id} session={session} onOpen={() => onOpenSession(session.id)}
              onRename={(title) => onRename?.(session.id, title) ?? Promise.resolve()}
              onArchive={() => onArchive?.(session.id) ?? Promise.resolve()}
              onRestore={() => onRestore?.(session.id) ?? Promise.resolve()} />
          ))}
        </section>
      ) : (
        <section className="closet" aria-label="Tape closet">
          <ol className="closet-shelf">
            {sessions.map((session) => (
              <li key={session.id} className="wc-closet-mix" style={{
                '--spine-color': session.caseColor,
                '--spine-ink': darkSpines.has(session.caseColor) ? '#f0ece5' : '#3d3740',
              } as CSSProperties}>
                <SessionRow session={session} onOpen={() => onOpenSession(session.id)}
                  onRename={(title) => onRename?.(session.id, title) ?? Promise.resolve()}
                  onArchive={() => onArchive?.(session.id) ?? Promise.resolve()}
                  onRestore={() => onRestore?.(session.id) ?? Promise.resolve()} />
              </li>
            ))}
          </ol>
          <p className="closet-hint">Tap a name to edit it. Open returns to its conversation and queue.</p>
        </section>
      )}
    </main>
  )
}
