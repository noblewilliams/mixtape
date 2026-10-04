import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import type { ComponentProps } from 'react'
import { Home } from './Home'
import { demoSessions } from '../data/demo'
import type { CollectionView } from '../domain'

afterEach(cleanup)

function renderHome(props: Partial<ComponentProps<typeof Home>> = {}) {
  return render(<Home sessions={demoSessions.slice(0, 3)} collectionView="list" onChangeCollectionView={vi.fn()} onOpenSession={vi.fn()} onNewTape={vi.fn()} {...props} />)
}

it.each([
  [3, false, '3 mixes · recently updated'],
  [1, false, '1 mix · recently updated'],
  [0, false, '0 mixes'],
  [2, true, '2 archived mixes · recently updated'],
  [1, true, '1 archived mix · recently updated'],
  [0, true, '0 archived mixes'],
])('counts %i mixes (archived %s) as “%s”', (count, archived, line) => {
  renderHome({ sessions: demoSessions.slice(0, count).map(s => ({ ...s, status: archived ? 'archived' : 'active' })), archived })
  expect(screen.getByText(line)).toBeInTheDocument()
})

it('keeps the Mixes title on both tabs and says loading while nothing is loaded', () => {
  renderHome({ sessions: [], archived: true, loading: true })
  expect(screen.getByRole('heading', { level: 1, name: 'Mixes' })).toBeInTheDocument()
  expect(screen.getByText('Loading mixes…')).toBeInTheDocument()
})

it('puts Active / Archived tabs and the view switch in one toolbar', () => {
  const archived = vi.fn(), view = vi.fn()
  const { container } = renderHome({ onArchived: archived, onChangeCollectionView: view })
  const toolbar = container.querySelector('.mixes-toolbar')!
  const tabs = within(toolbar as HTMLElement).getByRole('navigation', { name: 'Mix sections' })
  expect(within(tabs).getByRole('button', { name: 'Active' })).toHaveAttribute('aria-current', 'page')
  expect(within(tabs).getByRole('button', { name: 'Archived' })).not.toHaveAttribute('aria-current')
  expect(within(toolbar as HTMLElement).getByRole('group', { name: 'Collection view' })).toBeInTheDocument()
  fireEvent.click(within(tabs).getByRole('button', { name: 'Archived' }))
  expect(archived).toHaveBeenCalledWith(true)
  fireEvent.click(screen.getByRole('button', { name: 'Grid view' }))
  expect(view).toHaveBeenCalledWith('grid')
})

it('renders the grid with the same actions as a list row', async () => {
  const open = vi.fn(), archive = vi.fn().mockResolvedValue(undefined)
  renderHome({ collectionView: 'grid', onOpenSession: open, onArchive: archive, onColor: vi.fn() })
  const grid = screen.getByRole('region', { name: 'Mix grid' })
  expect(within(grid).getAllByRole('button', { name: /^Open / })).toHaveLength(3)
  expect(screen.getByRole('button', { name: 'Grid view' })).toHaveAttribute('aria-pressed', 'true')
  fireEvent.click(within(grid).getByRole('button', { name: `Open ${demoSessions[0].title}` }))
  expect(open).toHaveBeenCalledWith(demoSessions[0].id)
  fireEvent.click(within(grid).getByRole('button', { name: `Mix actions for ${demoSessions[1].title}` }))
  const menu = screen.getByRole('group', { name: 'Mix actions' })
  expect(within(menu).getAllByRole('button').map(b => b.textContent)).toEqual(['Rename', 'Tape settings', 'Archive'])
  fireEvent.click(within(menu).getByRole('button', { name: 'Archive' }))
  await waitFor(() => expect(archive).toHaveBeenCalledWith(demoSessions[1].id))
})

it('falls back to the list for an unknown stored view', () => {
  renderHome({ collectionView: 'shelf' as CollectionView })
  expect(screen.getByRole('region', { name: 'Tape list' })).toBeInTheDocument()
  expect(screen.getByRole('button', { name: 'List view' })).toHaveAttribute('aria-pressed', 'true')
})

it.each([
  ['list', '.mix-skeleton', 3],
  ['grid', '.mix-skeleton-tile', 6],
  ['closet', '.rack-ghost', 3],
] as const)('loads the %s view with matching skeletons', (view, selector, count) => {
  const { container } = renderHome({ sessions: [], loading: true, collectionView: view })
  const status = screen.getByRole('status', { name: 'Loading mixes' })
  expect(status.querySelectorAll(selector)).toHaveLength(count)
  expect(container.querySelector('.mixes-toolbar')).toBeInTheDocument()
})

it.each([
  [{ sessions: [] }, 'Your next moment starts here', 'Make a mix'],
  [{ sessions: [], archived: true }, 'No archived mixes', undefined],
  [{ sessions: [], error: 'offline' }, 'Couldn’t load your mixes', 'Try again'],
])('centres the empty state under the toolbar', (props, title, action) => {
  const { container } = renderHome({ ...props, onRetry: vi.fn() })
  const empty = container.querySelector('.mixes-content > .polish-empty')!
  expect(within(empty as HTMLElement).getByRole('heading', { name: title })).toBeInTheDocument()
  if (action) expect(within(empty as HTMLElement).getByRole('button', { name: action })).toBeInTheDocument()
  else expect(within(empty as HTMLElement).queryByRole('button')).toBeNull()
})
