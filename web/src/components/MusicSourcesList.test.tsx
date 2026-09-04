import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { ApiMusicSource } from '../api/client'
import { MusicSourcesList } from './MusicSourcesList'

const extended: ApiMusicSource = {
  source: 'spotify_export',
  connectedAt: '2026-09-01T09:00:00.000Z',
  lastImportedAt: '2026-09-04T09:30:00.000Z',
  ledgerFrom: '2018-03-02',
  ledgerTo: '2026-08-29',
  packages: ['spotify_extended'],
}

const appleLive: ApiMusicSource = {
  source: 'apple_live',
  connectedAt: '2026-08-20T09:00:00.000Z',
  lastImportedAt: '2026-08-21T09:00:00.000Z',
  ledgerFrom: null,
  ledgerTo: null,
  packages: [],
}

function renderList(sources: ApiMusicSource[]) {
  const onImportAgain = vi.fn()
  const onRemove = vi.fn()
  render(<MusicSourcesList sources={sources} onImportAgain={onImportAgain} onRemove={onRemove} />)
  return { onImportAgain, onRemove }
}

describe('MusicSourcesList', () => {
  afterEach(cleanup)

  it('lists each source with its mark, import date, and ledger range', () => {
    renderList([extended, appleLive])

    expect(screen.getByText('Your music · connected')).toBeInTheDocument()
    expect(screen.getByText('Spotify · extended history')).toBeInTheDocument()
    expect(screen.getByText('Imported 4 Sep · Mar 2018 → Aug 2026 · re-import any time')).toBeInTheDocument()
    expect(screen.getByText('Apple Music')).toBeInTheDocument()
    expect(screen.getByText('Connected 20 Aug · synced from this browser')).toBeInTheDocument()
    expect(screen.getAllByText('SP')).toHaveLength(1)
    expect(screen.getAllByText('AM')).toHaveLength(1)
  })

  it('offers Import again only where an import page exists, and no Remove for a live library', () => {
    const { onImportAgain } = renderList([extended, appleLive])

    expect(screen.getAllByRole('button', { name: 'Import again' })).toHaveLength(1)
    expect(screen.getByRole('button', { name: 'Remove Spotify · extended history' })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Remove Apple Music' })).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: 'Import again' }))
    expect(onImportAgain).toHaveBeenCalledWith('spotify_export')
  })

  it('confirms removal with what goes and what stays before calling back', () => {
    const { onRemove } = renderList([extended])

    fireEvent.click(screen.getByRole('button', { name: 'Remove Spotify · extended history' }))

    expect(screen.getByRole('alertdialog', { name: 'Remove your Spotify data?' })).toBeInTheDocument()
    expect(screen.getByText(
      'Deletes your listening history, liked songs, artists, and playlists from Mixtape. The DJ forgets nothing you told it in the interview, and the songs you pasted stay.',
    )).toBeInTheDocument()
    expect(onRemove).not.toHaveBeenCalled()
    expect(screen.getByRole('button', { name: 'Keep it' })).toHaveFocus()

    fireEvent.click(screen.getByRole('button', { name: 'Keep it' }))
    expect(screen.queryByRole('alertdialog')).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: 'Remove Spotify · extended history' }))
    fireEvent.click(screen.getByRole('button', { name: 'Confirm remove' }))
    expect(onRemove).toHaveBeenCalledWith('spotify_export')
  })
})
