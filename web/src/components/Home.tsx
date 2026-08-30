import type { CollectionView, DjSession } from '../domain'
import type { CSSProperties } from 'react'
import { Cassette } from './Cassette'
import { NewTapeCompactButton } from './TapeActions'

type HomeProps = {
  sessions: DjSession[]
  collectionView: CollectionView
  onChangeCollectionView: (view: CollectionView) => void
  onOpenSession: (id: string) => void
  onNewTape: () => void
}

const darkSpines = new Set(['#3e4850', '#51434f', '#596454', '#76584f'])

export function Home({
  sessions,
  collectionView,
  onChangeCollectionView,
  onOpenSession,
  onNewTape,
}: HomeProps) {
  return (
    <main className="home-panel">
      <header className="home-header">
        <div>
          <p className="quiet-kicker">Your collection</p>
          <h1>Your tapes</h1>
          <p>{sessions.length} sessions · sorted by last played</p>
        </div>
        <NewTapeCompactButton onClick={onNewTape} />
      </header>

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
            <button className="tape-card" type="button" key={session.id} onClick={() => onOpenSession(session.id)}>
              <Cassette
                title={session.title}
                caseColor={session.caseColor}
                stockColor={session.stockColor}
              />
              <span className="tape-card-copy">
                <strong>{session.title}</strong>
                <small>
                  {session.trackCount === 0 ? 'Blank tape' : `${session.trackCount} tracks`} · {session.ageLabel}
                </small>
              </span>
            </button>
          ))}
        </section>
      ) : (
        <section className="closet" aria-label="Tape closet">
          <ol className="closet-shelf">
            {sessions.map((session) => (
              <li key={session.id}>
                <button
                  className="tape-spine"
                  type="button"
                  style={
                    {
                      '--spine-color': session.caseColor,
                      '--spine-ink': darkSpines.has(session.caseColor) ? '#f0ece5' : '#3d3740',
                    } as CSSProperties
                  }
                  onClick={() => onOpenSession(session.id)}
                  aria-label={`Open ${session.title}`}
                >
                  <span>{session.title}</span>
                </button>
              </li>
            ))}
          </ol>
          <p className="closet-hint">Choose a spine to reopen its conversation and queue.</p>
        </section>
      )}
    </main>
  )
}
