import { cleanup, fireEvent, render, screen, within } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { toAlbumPick } from '../api/mappers'
import { demoAlbumPick, demoAlbumRefinedPick, demoAlbumRunnersUp } from '../data/demo'
import type { AlbumPick, AlbumPickState } from '../domain'
import { AlbumPanel } from './AlbumPanel'

const pick = toAlbumPick(demoAlbumPick)
const runnersUp = demoAlbumRunnersUp.map(toAlbumPick)

function mount(state: Partial<AlbumPickState> = {}, props: Partial<Parameters<typeof AlbumPanel>[0]> = {}) {
  const handlers = { onPlay: vi.fn(), onToggleSaved: vi.fn(), onPick: vi.fn() }
  render(<AlbumPanel state={{ version: 1, pick, runnersUp, passed: [], ...state }} spotifyOnly={false} {...handlers} {...props} />)
  return handlers
}

describe('AlbumPanel', () => {
  afterEach(cleanup)

  it('draws the pick with its heading, meta line and why', () => {
    mount()
    const panel = screen.getByRole('complementary', { name: 'The album' })
    expect(within(panel).getByText('The album')).toBeInTheDocument()
    expect(within(panel).getByText('pick 1')).toBeInTheDocument()
    expect(within(panel).getByText('Low Tide Hours')).toBeInTheDocument()
    expect(within(panel).getByText('Mara Ilesanmi')).toBeInTheDocument()
    expect(panel.querySelector('.album-meta')).toHaveTextContent(/^Album · 2019 · 11 songs · 44 min$/)
    expect(within(panel).getByText('Slow and warm, and you already know three of its songs.')).toBeInTheDocument()
    expect(within(panel).queryByText('New to you')).toBeNull()
  })

  it('appends the New to you mark only when the listener holds none of it', () => {
    mount({ pick: toAlbumPick(demoAlbumRefinedPick), version: 2 })
    const meta = screen.getByText('New to you').closest('.album-meta')
    expect(meta).toHaveTextContent('Album · 1978 · 8 songs · 36 min · New to you')
  })

  it('labels each album type and skips what the catalogue left out', () => {
    const odd: AlbumPick = { ...pick, type: 'ep', releaseYear: null, trackCount: 1, durationMs: 72 * 60_000 }
    mount({ pick: odd })
    expect(document.querySelector('.album-meta')).toHaveTextContent(/^EP · 1 song · 1 hr 12 min$/)
    cleanup()
    mount({ pick: { ...pick, type: 'soundtrack', releaseYear: 2001, trackCount: null, durationMs: null } })
    expect(document.querySelector('.album-meta')).toHaveTextContent(/^Soundtrack · 2001$/)
  })

  it('plays the pick with Play now, and holds it while busy', () => {
    const { onPlay } = mount()
    fireEvent.click(screen.getByRole('button', { name: 'Play now' }))
    expect(onPlay).toHaveBeenCalledWith(pick)
    cleanup()
    mount({}, { busy: true })
    expect(screen.getByRole('button', { name: 'Play now' })).toBeDisabled()
  })

  it('offers a Spotify search in place of Play now for Spotify-only listeners', () => {
    mount({}, { spotifyOnly: true })
    expect(screen.queryByRole('button', { name: 'Play now' })).toBeNull()
    const link = screen.getByRole('link', { name: 'Open in Spotify' })
    expect(link).toHaveAttribute('href', 'https://open.spotify.com/search/Mara%20Ilesanmi%20Low%20Tide%20Hours')
    expect(link).toHaveAttribute('target', '_blank')
    expect(link).toHaveAttribute('rel', 'noopener noreferrer')
  })

  it('toggles Listen later, and shows the saved state pressed', () => {
    const { onToggleSaved } = mount()
    const save = screen.getByRole('button', { name: 'Listen later' })
    expect(save).toHaveAttribute('aria-pressed', 'false')
    fireEvent.click(save)
    expect(onToggleSaved).toHaveBeenCalledWith(pick)
    cleanup()
    mount({ pick: { ...pick, savedForLater: true } })
    expect(screen.getByRole('button', { name: 'Saved for later' })).toHaveAttribute('aria-pressed', 'true')
  })

  it('keeps the runners-up folded until Show, then picks one', () => {
    const { onPick } = mount()
    expect(screen.getByText('Two more it considered')).toBeInTheDocument()
    expect(screen.queryByText('Nightshift Radio')).toBeNull()
    const toggle = screen.getByRole('button', { name: 'Show' })
    expect(toggle).toHaveAttribute('aria-expanded', 'false')
    fireEvent.click(toggle)
    expect(screen.getByRole('button', { name: 'Hide' })).toHaveAttribute('aria-expanded', 'true')
    const row = screen.getByText('Nightshift Radio').closest('li')!
    expect(row).toHaveTextContent('The Quiet Parade · EP · 2016 · New to you')
    expect(screen.getByText('Slow Rooms').closest('li')).not.toHaveTextContent('New to you')
    fireEvent.click(within(row).getByRole('button', { name: 'Pick this' }))
    expect(onPick).toHaveBeenCalledWith(runnersUp[0].id)
  })

  it('keeps each meta part whole so the line wraps only between parts', () => {
    mount()
    const parts = [...document.querySelectorAll('.album-meta-part')].map((part) => part.textContent)
    expect(parts).toEqual(['Album', '2019', '11 songs', '44 min'])
  })

  it('draws no runners-up section when there are none', () => {
    mount({ runnersUp: [] })
    expect(screen.queryByText('Two more it considered')).toBeNull()
  })

  it('shows only a quiet line before any album is verified', () => {
    mount({ pick: null, runnersUp: [] })
    const panel = screen.getByRole('complementary', { name: 'The album' })
    expect(within(panel).getByText('No album yet')).toBeInTheDocument()
    expect(within(panel).queryByRole('button')).toBeNull()
  })
})
