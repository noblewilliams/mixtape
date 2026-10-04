import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { SessionRow } from './SessionControls'
import { SaveDialog, Toast } from './Overlays'
import { demoSessions } from '../data/demo'
afterEach(cleanup)
it('writes the original colour after an uncertain colour save', async () => {
  const save = vi.fn().mockRejectedValueOnce(new Error('offline')).mockResolvedValue(undefined)
  render(<SessionRow session={{ ...demoSessions[0], caseColor: '#d88c9a' }} onOpen={vi.fn()} onRename={vi.fn()} onArchive={vi.fn()} onColor={save} />)
  fireEvent.click(screen.getByRole('button', { name: 'Mix actions' }))
  fireEvent.click(screen.getByRole('button', { name: 'Tape settings' }))
  const modal = screen.getByRole('dialog', { name: 'Tape settings' })
  fireEvent.click(within(modal).getByRole('button', { name: 'Cherry' }))
  await within(modal).findByRole('alert')
  fireEvent.click(within(modal).getByRole('button', { name: 'Rose' }))
  await waitFor(() => expect(save).toHaveBeenLastCalledWith('#d88c9a'))
})
it('keeps a failed colour save in tape settings for retry', async () => {
  const save = vi.fn().mockRejectedValueOnce(new Error('offline')).mockResolvedValue(undefined)
  render(<SessionRow session={demoSessions[0]} onOpen={vi.fn()} onRename={vi.fn()} onArchive={vi.fn()} onColor={save} />)
  fireEvent.click(screen.getByRole('button', { name: 'Mix actions' }))
  fireEvent.click(screen.getByRole('button', { name: 'Tape settings' }))
  const modal = screen.getByRole('dialog', { name: 'Tape settings' })
  expect(within(modal).getAllByRole('button', { pressed: false })).toHaveLength(48)
  fireEvent.click(within(modal).getByRole('button', { name: 'Cherry' }))
  await within(modal).findByRole('alert')
  fireEvent.click(within(modal).getByRole('button', { name: 'Cherry' }))
  await waitFor(() => expect(save).toHaveBeenCalledTimes(2))
  expect(save).toHaveBeenLastCalledWith('#b84755')
})
it('disables a playlist creation with a whitespace-only name', () => {
  const save = vi.fn()
  render(<SaveDialog defaultName="Dinner" onClose={vi.fn()} onSave={save} />)
  fireEvent.change(screen.getByRole('textbox', { name: 'Playlist name' }), { target: { value: '   ' } })
  expect(screen.getByRole('button', { name: 'Confirm create playlist' })).toBeDisabled()
  expect(save).not.toHaveBeenCalled()
})
it('announces info politely and keeps an undo action accessible', () => {
  const undo = vi.fn()
  render(<Toast message="Mix archived" tone="info" action={{ label: 'Undo', onClick: undo }} />)
  expect(screen.getByRole('status')).toHaveTextContent('Mix archived')
  fireEvent.click(screen.getByRole('button', { name: 'Undo' }))
  expect(undo).toHaveBeenCalledOnce()
})

it('traps playlist focus, returns it, and prevents dismissal while saving', () => {
  const close = vi.fn()
  const opener = document.createElement('button')
  document.body.append(opener)
  opener.focus()
  const view = render(<SaveDialog defaultName="Dinner" onClose={close} onSave={vi.fn()} />)
  expect(screen.getByRole('dialog')).toContainElement(document.activeElement as HTMLElement)
  fireEvent.keyDown(document, { key: 'Escape' })
  expect(close).toHaveBeenCalledOnce()
  view.rerender(<SaveDialog defaultName="Dinner" busy onClose={close} onSave={vi.fn()} />)
  fireEvent.keyDown(document, { key: 'Escape' })
  fireEvent.mouseDown(document.querySelector('.wc-overlay')!)
  expect(close).toHaveBeenCalledOnce()
  view.unmount()
  expect(document.activeElement).toBe(opener)
  opener.remove()
})

it('leaves the playlist dialog unchanged when nothing in the mix is new', () => {
  render(<SaveDialog defaultName="Dinner" newToYouCount={0} onClose={vi.fn()} onSave={vi.fn()} />)
  const dialog = screen.getByRole('dialog', { name: 'Create playlist' })
  expect(dialog).not.toHaveAttribute('aria-describedby')
  expect(dialog).not.toHaveTextContent(/new to you/i)
})

it('tells the listener that creating the playlist adds one new song to the library', () => {
  render(<SaveDialog defaultName="Dinner" newToYouCount={1} onClose={vi.fn()} onSave={vi.fn()} />)
  const dialog = screen.getByRole('dialog', { name: 'Create playlist' })
  const note = '1 song here is new to you. Creating the playlist adds it to your Apple Music library.'
  expect(dialog).toHaveAccessibleDescription(note)
  const sentence = within(dialog).getByText(note)
  expect(sentence).toHaveClass('playlist-dialog-note')
  expect(screen.getByRole('textbox', { name: 'Playlist name' }).compareDocumentPosition(sentence) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
})

it('tells the listener that creating the playlist adds several new songs to the library', () => {
  render(<SaveDialog defaultName="Dinner" newToYouCount={3} onClose={vi.fn()} onSave={vi.fn()} />)
  expect(screen.getByRole('dialog', { name: 'Create playlist' })).toHaveAccessibleDescription(
    '3 songs here are new to you. Creating the playlist adds them to your Apple Music library.',
  )
})
