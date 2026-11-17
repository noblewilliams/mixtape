import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import type { ComponentProps } from 'react'
import { Home } from './Home'
import { demoSessions } from '../data/demo'
import type { SharedMixRow } from '../domain'

afterEach(cleanup)

const mixes = demoSessions.slice(0, 4)
const [first, second, third, fourth] = mixes
const shared: SharedMixRow = {
  token: 'tok-ada', title: 'Late drive, windows down', caseColor: '#bc5734', sharerName: 'Ada',
  savedAt: new Date(Date.UTC(2026, 7, 30, 1)).toISOString(), trackCount: 10, durationMs: 2_400_000,
}

function renderHome(props: Partial<ComponentProps<typeof Home>> = {}) {
  const handlers = {
    onOpenSession: vi.fn(),
    onDeleteMany: vi.fn(async () => 'deleted' as const),
    onArchiveMany: vi.fn(async () => [] as string[]),
    onSignIn: vi.fn(),
  }
  const view = render(<Home sessions={mixes} collectionView="list" onChangeCollectionView={vi.fn()} onNewTape={vi.fn()} {...handlers} {...props} />)
  return { ...view, ...handlers, ...props }
}

const subline = (session: typeof first) => `${session.trackCount} songs · ${session.ageLabel}`
const selectButton = () => screen.getByRole('button', { name: 'Select' })
const box = (title: string) => screen.getByRole('checkbox', { name: title })
const bar = () => screen.getByRole('toolbar', { name: 'Selected mixes' })

it('offers a quiet Select beside the view switch in List and Grid, not Closet', () => {
  const { rerender } = renderHome()
  expect(selectButton()).toBeInTheDocument()
  rerender(<Home sessions={mixes} collectionView="grid" onChangeCollectionView={vi.fn()} onOpenSession={vi.fn()} onNewTape={vi.fn()} />)
  expect(selectButton()).toBeInTheDocument()
  rerender(<Home sessions={mixes} collectionView="closet" onChangeCollectionView={vi.fn()} onOpenSession={vi.fn()} onNewTape={vi.fn()} />)
  expect(screen.queryByRole('button', { name: 'Select' })).not.toBeInTheDocument()
})

it('hides Select on the Listen later shelf', () => {
  renderHome({ albumPicks: true, tab: 'listen-later', shelf: { entries: [], spotifyOnly: false, onRetry: vi.fn(), onFindAlbum: vi.fn(), onOpen: vi.fn(), onPlay: vi.fn(), onMarkListened: vi.fn(), onRemove: vi.fn() } })
  expect(screen.queryByRole('button', { name: 'Select' })).not.toBeInTheDocument()
})

it('enters select mode: Done, checkboxes named by title, count line and a disabled bar', () => {
  renderHome({ sharedRows: [shared] })
  expect(screen.queryByRole('checkbox')).not.toBeInTheDocument()
  fireEvent.click(selectButton())
  expect(screen.getByRole('button', { name: 'Done' })).toBeInTheDocument()
  expect(screen.getAllByRole('checkbox')).toHaveLength(4)
  expect(box(first.title)).not.toBeChecked()
  // Shared rows take no checkbox.
  expect(screen.queryByRole('checkbox', { name: shared.title })).not.toBeInTheDocument()
  expect(screen.getByText('0 of 5 selected')).toBeInTheDocument()
  expect(within(bar()).getByText('0 selected')).toBeInTheDocument()
  expect(within(bar()).getByRole('button', { name: 'Archive' })).toBeDisabled()
  expect(within(bar()).getByRole('button', { name: 'Delete' })).toBeDisabled()
})

it('ticks a row on click instead of opening it, and Shift-click ticks a range', () => {
  const { onOpenSession } = renderHome()
  fireEvent.click(selectButton())
  fireEvent.click(screen.getByText(subline(first)))
  expect(onOpenSession).not.toHaveBeenCalled()
  expect(box(first.title)).toBeChecked()
  fireEvent.click(box(third.title), { shiftKey: true })
  expect(box(second.title)).toBeChecked()
  expect(box(third.title)).toBeChecked()
  expect(box(fourth.title)).not.toBeChecked()
  expect(screen.getByText('3 of 4 selected')).toBeInTheDocument()
  expect(within(bar()).getByText('3 selected')).toBeInTheDocument()
  fireEvent.click(box(second.title))
  expect(box(second.title)).not.toBeChecked()
})

it('leaves select mode on Done, Escape, a tab change or the Closet', () => {
  const { rerender } = renderHome()
  fireEvent.click(selectButton())
  fireEvent.click(screen.getByRole('button', { name: 'Done' }))
  expect(screen.queryByRole('checkbox')).not.toBeInTheDocument()
  expect(screen.getByText('4 mixes · recently updated')).toBeInTheDocument()

  fireEvent.click(selectButton())
  fireEvent.keyDown(document, { key: 'Escape' })
  expect(screen.queryByRole('checkbox')).not.toBeInTheDocument()

  fireEvent.click(selectButton())
  rerender(<Home sessions={mixes.map(s => ({ ...s, status: 'archived' }))} tab="archived" collectionView="list" onChangeCollectionView={vi.fn()} onOpenSession={vi.fn()} onNewTape={vi.fn()} />)
  expect(screen.queryByRole('checkbox')).not.toBeInTheDocument()

  fireEvent.click(selectButton())
  rerender(<Home sessions={mixes} tab="archived" collectionView="closet" onChangeCollectionView={vi.fn()} onOpenSession={vi.fn()} onNewTape={vi.fn()} />)
  rerender(<Home sessions={mixes} tab="archived" collectionView="list" onChangeCollectionView={vi.fn()} onOpenSession={vi.fn()} onNewTape={vi.fn()} />)
  expect(screen.queryByRole('checkbox')).not.toBeInTheDocument()
})

it('puts the checkbox on each grid tile and ticks a tile on click', () => {
  const { onOpenSession } = renderHome({ collectionView: 'grid' })
  fireEvent.click(selectButton())
  const grid = screen.getByRole('region', { name: 'Mix grid' })
  expect(within(grid).getAllByRole('checkbox')).toHaveLength(4)
  fireEvent.click(within(grid).getByText(subline(second)))
  expect(onOpenSession).not.toHaveBeenCalled()
  expect(box(second.title)).toBeChecked()
})

it('archives the ticked mixes in one action and leaves select mode', async () => {
  const { onArchiveMany } = renderHome()
  fireEvent.click(selectButton())
  fireEvent.click(box(first.title))
  fireEvent.click(box(third.title))
  fireEvent.click(within(bar()).getByRole('button', { name: 'Archive' }))
  await waitFor(() => expect(onArchiveMany).toHaveBeenCalledWith([first.id, third.id], 'archived'))
  await waitFor(() => expect(screen.queryByRole('checkbox')).not.toBeInTheDocument())
})

it('keeps the mixes that failed to archive ticked', async () => {
  renderHome({ onArchiveMany: vi.fn(async () => [third.id]) })
  fireEvent.click(selectButton())
  fireEvent.click(box(first.title))
  fireEvent.click(box(third.title))
  fireEvent.click(within(bar()).getByRole('button', { name: 'Archive' }))
  await waitFor(() => expect(box(first.title)).not.toBeChecked())
  expect(box(third.title)).toBeChecked()
})

it('offers Unarchive on the Archived tab', async () => {
  const archived = mixes.map(s => ({ ...s, status: 'archived' as const }))
  const { onArchiveMany } = renderHome({ sessions: archived, tab: 'archived' })
  fireEvent.click(selectButton())
  fireEvent.click(box(first.title))
  fireEvent.click(within(bar()).getByRole('button', { name: 'Unarchive' }))
  await waitFor(() => expect(onArchiveMany).toHaveBeenCalledWith([first.id], 'active'))
})

it('confirms a delete with Cancel focused first and deletes on Delete', async () => {
  const { onDeleteMany } = renderHome()
  fireEvent.click(selectButton())
  fireEvent.click(box(first.title))
  fireEvent.click(box(second.title))
  fireEvent.click(within(bar()).getByRole('button', { name: 'Delete' }))
  const modal = screen.getByRole('alertdialog', { name: 'Delete 2 mixes?' })
  expect(within(modal).getByText('They’re gone for good, with their chats and versions. This can’t be undone.')).toBeInTheDocument()
  expect(within(modal).getAllByRole('button').map(b => b.textContent)).toEqual(['Cancel', 'Delete 2 mixes'])
  expect(within(modal).getByRole('button', { name: 'Cancel' })).toHaveFocus()
  fireEvent.click(within(modal).getByRole('button', { name: 'Delete 2 mixes' }))
  await waitFor(() => expect(onDeleteMany).toHaveBeenCalledWith([first.id, second.id]))
  await waitFor(() => expect(screen.queryByRole('alertdialog')).not.toBeInTheDocument())
  expect(screen.queryByRole('checkbox')).not.toBeInTheDocument()
})

it('says “Delete this mix?” for one and adds the share and working lines when true', () => {
  renderHome({ isShared: (id) => id === first.id, isWorking: (id) => id === first.id })
  fireEvent.click(selectButton())
  fireEvent.click(box(first.title))
  fireEvent.click(within(bar()).getByRole('button', { name: 'Delete' }))
  const modal = screen.getByRole('alertdialog', { name: 'Delete this mix?' })
  expect(modal).toHaveTextContent('Their share links will stop working.')
  expect(modal).toHaveTextContent('The one being made will stop.')
})

it('leaves out the share and working lines when neither is true', () => {
  renderHome({ isShared: () => false, isWorking: () => false })
  fireEvent.click(selectButton())
  fireEvent.click(box(first.title))
  fireEvent.click(within(bar()).getByRole('button', { name: 'Delete' }))
  const modal = screen.getByRole('alertdialog', { name: 'Delete this mix?' })
  expect(modal).not.toHaveTextContent('share links')
  expect(modal).not.toHaveTextContent('being made')
})

it('Cancel closes the confirm and keeps the selection', () => {
  const { onDeleteMany } = renderHome()
  fireEvent.click(selectButton())
  fireEvent.click(box(first.title))
  fireEvent.click(within(bar()).getByRole('button', { name: 'Delete' }))
  fireEvent.click(screen.getByRole('button', { name: 'Cancel' }))
  expect(screen.queryByRole('alertdialog')).not.toBeInTheDocument()
  expect(box(first.title)).toBeChecked()
  expect(onDeleteMany).not.toHaveBeenCalled()
})

it('shows a failed delete inside the modal and keeps it open with the selection', async () => {
  renderHome({ onDeleteMany: vi.fn(async () => { throw new Error('offline') }) })
  fireEvent.click(selectButton())
  fireEvent.click(box(first.title))
  fireEvent.click(within(bar()).getByRole('button', { name: 'Delete' }))
  const modal = screen.getByRole('alertdialog', { name: 'Delete this mix?' })
  fireEvent.click(within(modal).getByRole('button', { name: 'Delete mix' }))
  expect(await within(modal).findByRole('alert')).toHaveTextContent('Couldn’t delete. Try again.')
  expect(screen.getByRole('alertdialog', { name: 'Delete this mix?' })).toBeInTheDocument()
  expect(box(first.title)).toBeChecked()
})

it('asks an anonymous listener to sign in instead of deleting', () => {
  const { onDeleteMany, onSignIn } = renderHome({ anonymous: true })
  fireEvent.click(selectButton())
  fireEvent.click(box(first.title))
  fireEvent.click(within(bar()).getByRole('button', { name: 'Delete' }))
  const modal = screen.getByRole('alertdialog', { name: 'Sign in to delete mixes' })
  expect(modal).toHaveTextContent('Mixes made before you sign in can be archived, not deleted.')
  expect(within(modal).getAllByRole('button').map(b => b.textContent)).toEqual(['Not now', 'Sign in'])
  fireEvent.click(within(modal).getByRole('button', { name: 'Sign in' }))
  expect(onSignIn).toHaveBeenCalled()
  expect(onDeleteMany).not.toHaveBeenCalled()
})

it('turns a sign_in_required answer into the sign-in modal', async () => {
  renderHome({ onDeleteMany: vi.fn(async () => 'sign_in_required' as const) })
  fireEvent.click(selectButton())
  fireEvent.click(box(first.title))
  fireEvent.click(within(bar()).getByRole('button', { name: 'Delete' }))
  fireEvent.click(within(screen.getByRole('alertdialog')).getByRole('button', { name: 'Delete mix' }))
  expect(await screen.findByRole('alertdialog', { name: 'Sign in to delete mixes' })).toBeInTheDocument()
  fireEvent.click(screen.getByRole('button', { name: 'Not now' }))
  expect(screen.queryByRole('alertdialog')).not.toBeInTheDocument()
  expect(box(first.title)).toBeChecked()
})

it('in Grid, clicks inside Tape settings leave the tile’s tick alone', () => {
  renderHome({ collectionView: 'grid', onColor: vi.fn(async () => undefined) })
  fireEvent.click(selectButton())
  fireEvent.click(screen.getByRole('button', { name: `Mix actions for ${first.title}` }))
  fireEvent.click(screen.getByRole('button', { name: 'Tape settings' }))
  fireEvent.click(within(screen.getByRole('dialog', { name: 'Tape settings' })).getByRole('button', { name: 'Done' }))
  expect(box(first.title)).not.toBeChecked()
})

it('Escape that closes Tape settings keeps select mode and its ticks', () => {
  renderHome({ onColor: vi.fn(async () => undefined) })
  fireEvent.click(selectButton())
  fireEvent.click(box(second.title))
  fireEvent.click(screen.getAllByRole('button', { name: 'Mix actions' })[0])
  fireEvent.click(screen.getByRole('button', { name: 'Tape settings' }))
  fireEvent.keyDown(document, { key: 'Escape' })
  expect(screen.queryByRole('dialog', { name: 'Tape settings' })).not.toBeInTheDocument()
  expect(box(second.title)).toBeChecked()
})

it('offers no Rename in the row menu while selecting', () => {
  renderHome()
  fireEvent.click(selectButton())
  fireEvent.click(screen.getAllByRole('button', { name: 'Mix actions' })[0])
  expect(screen.queryByRole('button', { name: `Rename ${first.title}` })).not.toBeInTheDocument()
})

it('names the count on the confirm’s Delete button', () => {
  renderHome()
  fireEvent.click(selectButton())
  fireEvent.click(box(first.title))
  fireEvent.click(within(bar()).getByRole('button', { name: 'Delete' }))
  expect(within(screen.getByRole('alertdialog')).getByRole('button', { name: 'Delete mix' })).toBeInTheDocument()
  fireEvent.click(within(screen.getByRole('alertdialog')).getByRole('button', { name: 'Cancel' }))
  fireEvent.click(box(second.title))
  fireEvent.click(within(bar()).getByRole('button', { name: 'Delete' }))
  expect(within(screen.getByRole('alertdialog')).getByRole('button', { name: 'Delete 2 mixes' })).toBeInTheDocument()
})
