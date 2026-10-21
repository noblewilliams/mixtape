import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { ComponentProps } from 'react'
import { Home } from './Home'
import { demoSessions, demoShelfPreviewEntries } from '../data/demo'
import type { CollectionView, ListenLaterEntry } from '../domain'
import { toListenLaterEntry } from '../api/mappers'

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
  renderHome({ sessions: demoSessions.slice(0, count).map(s => ({ ...s, status: archived ? 'archived' : 'active' })), tab: archived ? 'archived' : 'active' })
  expect(screen.getByText(line)).toBeInTheDocument()
})

it('keeps the Mixes title on both tabs and says loading while nothing is loaded', () => {
  renderHome({ sessions: [], tab: 'archived', loading: true })
  expect(screen.getByRole('heading', { level: 1, name: 'Mixes' })).toBeInTheDocument()
  expect(screen.getByText('Loading mixes…')).toBeInTheDocument()
})

it('puts Active / Archived tabs and the view switch in one toolbar', () => {
  const tab = vi.fn(), view = vi.fn()
  const { container } = renderHome({ onTab: tab, onChangeCollectionView: view })
  const toolbar = container.querySelector('.mixes-toolbar')!
  const tabs = within(toolbar as HTMLElement).getByRole('navigation', { name: 'Mix sections' })
  expect(within(tabs).getByRole('button', { name: 'Active' })).toHaveAttribute('aria-current', 'page')
  expect(within(tabs).getByRole('button', { name: 'Archived' })).not.toHaveAttribute('aria-current')
  expect(within(toolbar as HTMLElement).getByRole('group', { name: 'Collection view' })).toBeInTheDocument()
  fireEvent.click(within(tabs).getByRole('button', { name: 'Archived' }))
  expect(within(tabs).getAllByRole('button').map(b => b.textContent)).toEqual(['Active', 'Archived'])
  expect(tab).toHaveBeenCalledWith('archived')
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
  [{ sessions: [], tab: 'archived' as const }, 'No archived mixes', undefined],
  [{ sessions: [], error: 'offline' }, 'Couldn’t load your mixes', 'Try again'],
])('centres the empty state under the toolbar', (props, title, action) => {
  const { container } = renderHome({ ...props, onRetry: vi.fn() })
  const empty = container.querySelector('.mixes-content > .polish-empty')!
  expect(within(empty as HTMLElement).getByRole('heading', { name: title })).toBeInTheDocument()
  if (action) expect(within(empty as HTMLElement).getByRole('button', { name: action })).toBeInTheDocument()
  else expect(within(empty as HTMLElement).queryByRole('button')).toBeNull()
})

describe('the Listen later tab', () => {
  const entries = demoShelfPreviewEntries.map(toListenLaterEntry)
  function renderShelf(shelf: Partial<NonNullable<ComponentProps<typeof Home>['shelf']>> = {}, props: Partial<ComponentProps<typeof Home>> = {}) {
    const handlers = { onRetry: vi.fn(), onFindAlbum: vi.fn(), onOpen: vi.fn(), onPlay: vi.fn(), onMarkListened: vi.fn(), onRemove: vi.fn() }
    const view = renderHome({ albumPicks: true, tab: 'listen-later', shelf: { entries, spotifyOnly: false, ...handlers, ...shelf }, ...props })
    return { ...view, ...handlers }
  }
  const tabs = () => screen.getByRole('navigation', { name: 'Mix sections' })

  it('adds the third tab only when album picks are on', () => {
    const tab = vi.fn()
    renderHome({ albumPicks: true, onTab: tab })
    expect(within(tabs()).getAllByRole('button').map(b => b.textContent)).toEqual(['Active', 'Archived', 'Listen later'])
    fireEvent.click(within(tabs()).getByRole('button', { name: 'Listen later' }))
    expect(tab).toHaveBeenCalledWith('listen-later')
  })

  it('marks the tab current and drops the view switch', () => {
    renderShelf()
    expect(within(tabs()).getByRole('button', { name: 'Listen later' })).toHaveAttribute('aria-current', 'page')
    expect(screen.queryByRole('group', { name: 'Collection view' })).toBeNull()
    expect(screen.queryByRole('region', { name: 'Tape list' })).toBeNull()
  })

  it('falls back to Active when album picks are off', () => {
    renderHome({ albumPicks: false, tab: 'listen-later' })
    expect(within(tabs()).getByRole('button', { name: 'Active' })).toHaveAttribute('aria-current', 'page')
    expect(screen.getByRole('region', { name: 'Tape list' })).toBeInTheDocument()
  })

  it.each([
    [entries.slice(0, 2).concat(entries.slice(4)), '2 albums saved · 2 listened'],
    [entries, '4 albums saved · 2 listened'],
    [entries.slice(0, 1), '1 album saved'],
    [[] as ListenLaterEntry[], '0 albums saved'],
  ])('counts the shelf as “%#”', (list, line) => {
    renderShelf({ entries: list })
    expect(screen.getByText(line)).toBeInTheDocument()
  })

  it('says it is loading the shelf with list skeletons', () => {
    const { container } = renderShelf({ entries: null })
    expect(screen.getByText('Loading your shelf…')).toBeInTheDocument()
    expect(container.querySelectorAll('.mixes-content .mix-skeleton')).toHaveLength(3)
  })

  it('draws the rows with the Listened label before the listened ones', () => {
    renderShelf()
    const list = screen.getByRole('list', { name: 'Listen later' })
    expect(within(list).getAllByRole('listitem')).toHaveLength(6)
    expect(screen.getByText('Listened', { selector: '.shelf-section' })).toBeInTheDocument()
  })

  it('passes the row actions through', () => {
    const { onPlay, onRemove, onOpen } = renderShelf()
    fireEvent.click(screen.getByRole('button', { name: 'Play Slow Rooms' }))
    expect(onPlay).toHaveBeenCalledWith(entries[2])
    fireEvent.click(screen.getByRole('button', { name: /^Slow Rooms Mara Ilesanmi/ }))
    expect(onOpen).toHaveBeenCalledWith('album-session-1')
    fireEvent.click(screen.getByRole('button', { name: 'Album actions for Slow Rooms' }))
    fireEvent.click(within(screen.getByRole('group', { name: 'Album actions' })).getByRole('button', { name: 'Remove' }))
    expect(onRemove).toHaveBeenCalledWith(entries[2])
  })

  it('centres the empty shelf with Find an album', () => {
    const { container, onFindAlbum } = renderShelf({ entries: [] })
    const empty = container.querySelector('.mixes-content > .polish-empty') as HTMLElement
    expect(within(empty).getByRole('heading', { name: 'Nothing saved for later' })).toBeInTheDocument()
    expect(empty).toHaveTextContent('Ask for an album, then choose Listen later to keep it here.')
    fireEvent.click(within(empty).getByRole('button', { name: 'Find an album' }))
    expect(onFindAlbum).toHaveBeenCalled()
  })

  it('says so when the shelf will not load', () => {
    const { container, onRetry } = renderShelf({ entries: null, error: 'offline' })
    const empty = container.querySelector('.mixes-content > .polish-empty') as HTMLElement
    expect(within(empty).getByRole('heading', { name: 'Couldn’t load your shelf' })).toBeInTheDocument()
    expect(empty).toHaveTextContent('Try again in a moment.')
    fireEvent.click(within(empty).getByRole('button', { name: 'Try again' }))
    expect(onRetry).toHaveBeenCalled()
  })

  it('leaves the routine suggestions to the Active tab', () => {
    renderShelf({}, { suggestions: <p>For this moment</p> })
    expect(screen.queryByText('For this moment')).toBeNull()
  })
})
