import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { SessionRow } from './SessionControls'
import { demoSessions } from '../data/demo'
afterEach(cleanup)
it('edits a name inline and retains input on a failed save', async () => {
  const rename = vi.fn().mockRejectedValue(new Error('offline'))
  render(<SessionRow session={demoSessions[0]} onOpen={vi.fn()} onRename={rename} onArchive={vi.fn()} />)
  fireEvent.click(screen.getByRole('button', { name: `Rename ${demoSessions[0].title}` }))
  fireEvent.change(screen.getByRole('textbox', { name: 'Mix name' }), { target: { value: 'New name' } })
  fireEvent.keyDown(screen.getByRole('textbox'), { key: 'Enter' })
  await screen.findByRole('alert')
  expect(screen.getByRole('textbox')).toHaveValue('New name')
  expect(rename).toHaveBeenCalledTimes(1)
})
it('dismisses its minimal action menu outside and archives only on action', async () => {
  const archive = vi.fn().mockResolvedValue(undefined)
  render(<SessionRow session={demoSessions[0]} onOpen={vi.fn()} onRename={vi.fn()} onArchive={archive} />)
  fireEvent.click(screen.getByRole('button', { name: 'Mix actions' }))
  expect(screen.getByRole('group', { name: 'Mix actions' })).toBeInTheDocument()
  fireEvent.pointerDown(document.body)
  expect(screen.queryByRole('group', { name: 'Mix actions' })).not.toBeInTheDocument()
  expect(archive).not.toHaveBeenCalled()
  fireEvent.click(screen.getByRole('button', { name: 'Mix actions' }))
  fireEvent.click(screen.getAllByRole('button', { name: 'Archive' }).at(-1)!)
  await waitFor(() => expect(archive).toHaveBeenCalledTimes(1))
})
it('dismisses actions when pressing another control in the same row', () => {
  render(<SessionRow session={demoSessions[0]} onOpen={vi.fn()} onRename={vi.fn()} onArchive={vi.fn()} />)
  fireEvent.click(screen.getByRole('button', { name: 'Mix actions' }))
  fireEvent.pointerDown(screen.getByRole('button', { name: `Open ${demoSessions[0].title}` }))
  expect(screen.queryByRole('group')).not.toBeInTheDocument()
})
it('cancels an inline rename without saving', () => {
  const rename = vi.fn()
  render(<SessionRow session={demoSessions[0]} onOpen={vi.fn()} onRename={rename} onArchive={vi.fn()} />)
  fireEvent.click(screen.getByRole('button', { name: `Rename ${demoSessions[0].title}` }))
  fireEvent.change(screen.getByRole('textbox'), { target: { value: 'Discard me' } })
  fireEvent.keyDown(screen.getByRole('textbox'), { key: 'Escape' })
  expect(rename).not.toHaveBeenCalled()
  expect(screen.queryByRole('textbox')).not.toBeInTheDocument()
})
