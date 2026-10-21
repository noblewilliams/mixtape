import { cleanup, fireEvent, render, screen, within } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import type { ComponentProps } from 'react'
import { ListenLaterList } from './ListenLaterList'
import { demoShelfPreviewEntries } from '../data/demo'
import { toListenLaterEntry } from '../api/mappers'

afterEach(cleanup)

const entries = demoShelfPreviewEntries.map(toListenLaterEntry)

function renderList(props: Partial<ComponentProps<typeof ListenLaterList>> = {}) {
  const handlers = { onOpen: vi.fn(), onPlay: vi.fn(), onMarkListened: vi.fn(), onRemove: vi.fn() }
  render(<ListenLaterList entries={entries} spotifyOnly={false} {...handlers} {...props} />)
  return handlers
}

const rowOf = (title: string) => screen.getByText(title).closest('.shelf-row') as HTMLElement

it('draws a row with the open button, the subline and a play button', () => {
  const { onOpen, onPlay } = renderList()
  const row = rowOf('Low Tide Hours')
  expect(row).toHaveTextContent('Mara Ilesanmi · Album · 2019 · 44 min')
  expect(row.querySelector('.shelf-cover')).not.toBeNull()
  // The open button is named by its content: title, then subline.
  fireEvent.click(within(row).getByRole('button', { name: 'Low Tide Hours Mara Ilesanmi · Album · 2019 · 44 min' }))
  expect(onOpen).toHaveBeenCalledWith('album-session-1')
  fireEvent.click(within(row).getByRole('button', { name: 'Play Low Tide Hours' }))
  expect(onPlay).toHaveBeenCalledWith(entries[0])
})

it('skips the parts the catalogue left out', () => {
  renderList({ entries: [{ ...entries[0], releaseYear: null, durationMs: null }] })
  expect(rowOf('Low Tide Hours').querySelector('small')).toHaveTextContent(/^Mara Ilesanmi · Album$/)
})

it('keeps the server order and puts the Listened label before the listened rows', () => {
  renderList()
  const titles = screen.getAllByRole('listitem').map((item) => item.querySelector('strong')?.textContent)
  expect(titles).toEqual(entries.map((entry) => entry.title))
  const label = screen.getByText('Listened', { selector: '.shelf-section' })
  const firstListened = rowOf('Nightshift Radio')
  const lastUnlistened = rowOf('Every Room Is a Harbour, Part Two: The Long Way Round')
  expect(lastUnlistened.compareDocumentPosition(label) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
  expect(label.compareDocumentPosition(firstListened) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
})

it('mutes listened rows and ends their subline with the plum status word', () => {
  renderList()
  const row = rowOf('Nightshift Radio')
  expect(row).toHaveClass('shelf-row--listened')
  expect(row).toHaveTextContent('The Quiet Parade · EP · Listened 12 Oct')
  expect(within(row).getByText('Listened 12 Oct').tagName).toBe('B')
  // The status word sits outside the part that truncates.
  expect(within(row).getByText('Listened 12 Oct').closest('.shelf-mark')).not.toBeNull()
  expect(row.querySelector('.shelf-who')).toHaveTextContent(/^The Quiet Parade · EP$/)
  expect(within(row).getByRole('button', { name: /^Nightshift Radio The Quiet Parade · EP · Listened 12 Oct$/ })).toBeInTheDocument()
})

it('disables Mark listened and Remove while that row has a request in flight', () => {
  renderList({ pendingIds: [entries[0].id] })
  fireEvent.click(within(rowOf('Low Tide Hours')).getByRole('button', { name: 'Album actions for Low Tide Hours' }))
  const menu = screen.getByRole('group', { name: 'Album actions' })
  expect(within(menu).getByRole('button', { name: 'Open' })).toBeEnabled()
  expect(within(menu).getByRole('button', { name: 'Mark listened' })).toBeDisabled()
  expect(within(menu).getByRole('button', { name: 'Remove' })).toBeDisabled()
})

it('has no Listened label when nothing is listened', () => {
  renderList({ entries: entries.slice(0, 2) })
  expect(screen.queryByText('Listened', { selector: '.shelf-section' })).toBeNull()
})

it('draws the title as plain text when the album has no session', () => {
  renderList()
  const row = rowOf('Every Room Is a Harbour, Part Two: The Long Way Round')
  expect(within(row).queryByRole('button', { name: /^Every Room/ })).toBeNull()
  fireEvent.click(within(row).getByRole('button', { name: 'Album actions for Every Room Is a Harbour, Part Two: The Long Way Round' }))
  const menu = screen.getByRole('group', { name: 'Album actions' })
  expect(within(menu).getAllByRole('button').map((button) => button.textContent)).toEqual(['Mark listened', 'Remove'])
})

it('offers Open, Mark listened and Remove, and calls the handlers', () => {
  const { onOpen, onMarkListened, onRemove } = renderList()
  const menuButton = () => within(rowOf('Low Tide Hours')).getByRole('button', { name: 'Album actions for Low Tide Hours' })
  fireEvent.click(menuButton())
  const menu = () => screen.getByRole('group', { name: 'Album actions' })
  expect(within(menu()).getAllByRole('button').map((button) => button.textContent)).toEqual(['Open', 'Mark listened', 'Remove'])
  fireEvent.click(within(menu()).getByRole('button', { name: 'Open' }))
  expect(onOpen).toHaveBeenCalledWith('album-session-1')
  expect(screen.queryByRole('group', { name: 'Album actions' })).toBeNull()
  fireEvent.click(menuButton())
  fireEvent.click(within(menu()).getByRole('button', { name: 'Mark listened' }))
  expect(onMarkListened).toHaveBeenCalledWith(entries[0])
  fireEvent.click(menuButton())
  fireEvent.click(within(menu()).getByRole('button', { name: 'Remove' }))
  expect(onRemove).toHaveBeenCalledWith(entries[0])
})

it('leaves Mark listened out of a listened row', () => {
  renderList()
  fireEvent.click(within(rowOf('Harbour Lights')).getByRole('button', { name: 'Album actions for Harbour Lights' }))
  expect(within(screen.getByRole('group', { name: 'Album actions' })).getAllByRole('button').map((button) => button.textContent)).toEqual(['Open', 'Remove'])
})

it('closes the menu on Escape and returns focus to the dots', () => {
  renderList()
  const dots = within(rowOf('Slow Rooms')).getByRole('button', { name: 'Album actions for Slow Rooms' })
  fireEvent.click(dots)
  expect(dots).toHaveAttribute('aria-expanded', 'true')
  fireEvent.keyDown(document, { key: 'Escape' })
  expect(screen.queryByRole('group', { name: 'Album actions' })).toBeNull()
  expect(dots).toHaveFocus()
})

it('gives a Spotify-only listener the Spotify search in the play slot', () => {
  renderList({ spotifyOnly: true })
  const row = rowOf('Slow Rooms')
  expect(within(row).queryByRole('button', { name: 'Play Slow Rooms' })).toBeNull()
  const link = within(row).getByRole('link', { name: 'Open Slow Rooms in Spotify' })
  expect(link).toHaveAttribute('href', 'https://open.spotify.com/search/Mara%20Ilesanmi%20Slow%20Rooms')
  expect(link).toHaveClass('shelf-play')
})
