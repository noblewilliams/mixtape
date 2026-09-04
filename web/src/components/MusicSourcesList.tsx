import { useState } from 'react'
import type { ApiMusicSource, ListeningImportSource } from '../api/client'
import { ledgerRangeLabel, shortDate, sourceName } from '../lib/onboarding'

type MusicSourcesListProps = {
  sources: ApiMusicSource[]
  onImportAgain: (source: 'spotify_export') => void
  onRemove: (source: ListeningImportSource) => void
}

function sourceDetail(source: ApiMusicSource): string {
  const ledger = ledgerRangeLabel(source.ledgerFrom, source.ledgerTo)
  if (source.source === 'apple_live') return `Connected ${shortDate(source.connectedAt)} · synced from this browser`
  const imported = `Imported ${shortDate(source.lastImportedAt ?? source.connectedAt)}`
  const parts = [imported, ledger, source.source === 'spotify_export' ? 're-import any time' : null]
  return parts.filter((part): part is string => part !== null).join(' · ')
}

function removalCopy(source: ListeningImportSource): { title: string; body: string } {
  if (source === 'spotify_export') {
    return {
      title: 'Remove your Spotify data?',
      body:
        'Deletes your listening history, liked songs, artists, and playlists from Mixtape. The DJ forgets nothing you told it in the interview, and the songs you pasted stay.',
    }
  }
  return {
    title: 'Remove the Apple Music export?',
    body:
      'Deletes the listening history that came from the export. Your synced Apple Music library stays, and the DJ forgets nothing you told it.',
  }
}

function removable(source: ApiMusicSource['source']): source is ListeningImportSource {
  return source === 'spotify_export' || source === 'apple_export'
}

export function MusicSourcesList({ sources, onImportAgain, onRemove }: MusicSourcesListProps) {
  const [confirming, setConfirming] = useState<ListeningImportSource | null>(null)
  const confirmation = confirming ? removalCopy(confirming) : null

  return (
    <section className="card sources-card" aria-labelledby="sources-title">
      <p className="quiet-kicker" id="sources-title">Your music · connected</p>
      <ul className="source-list">
        {sources.map((source) => {
          const name = sourceName(source)
          return (
            <li className="source-row" key={source.source}>
              <span className="source-mark" aria-hidden="true">
                {source.source === 'spotify_export' ? 'SP' : 'AM'}
              </span>
              <span className="source-copy">
                <strong>{name}</strong>
                <small>{sourceDetail(source)}</small>
              </span>
              <span className="source-actions">
                {source.source === 'spotify_export' ? (
                  <button className="btn" type="button" onClick={() => onImportAgain('spotify_export')}>
                    Import again
                  </button>
                ) : null}
                {removable(source.source) ? (
                  <button
                    className="btn danger"
                    type="button"
                    onClick={() => setConfirming(source.source as ListeningImportSource)}
                    aria-label={`Remove ${name}`}
                  >
                    Remove
                  </button>
                ) : null}
              </span>
            </li>
          )
        })}
      </ul>
      {confirming && confirmation ? (
        <div className="dialog confirm-inline" role="alertdialog" aria-labelledby="remove-source-title">
          <h3 id="remove-source-title">{confirmation.title}</h3>
          <p>{confirmation.body}</p>
          <div className="dialog-actions">
            <button className="btn" type="button" autoFocus onClick={() => setConfirming(null)}>
              Keep it
            </button>
            <button
              className="btn danger"
              type="button"
              aria-label="Confirm remove"
              onClick={() => {
                const source = confirming
                setConfirming(null)
                onRemove(source)
              }}
            >
              Remove
            </button>
          </div>
        </div>
      ) : null}
    </section>
  )
}
