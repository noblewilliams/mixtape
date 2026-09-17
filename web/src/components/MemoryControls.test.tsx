import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { MemoryControls } from './MemoryControls'
import { createFakeApi } from '../test/fake-api'
afterEach(cleanup)
it('confirms forgetting in a modal, dismisses outside without deletion, then reloads canonical notes', async () => {
  let notes = [{ id: 'n', note: 'Gentle mornings', createdAt: '2026-09-08' }]
  const remove = vi.fn(async () => {
    notes = []
    return { ok: true as const }
  })
  render(
    <MemoryControls
      api={createFakeApi({ listMemories: async () => ({ memories: notes }), deleteMemory: remove })}
      onClose={vi.fn()}
      onSessionExpired={vi.fn()}
    />,
  )
  fireEvent.click(await screen.findByRole('button', { name: 'Forget' }))
  let modal = screen.getByRole('alertdialog')
  expect(within(modal).getByText('Gentle mornings')).toBeInTheDocument()
  fireEvent.mouseDown(modal.parentElement!)
  expect(screen.queryByRole('alertdialog')).not.toBeInTheDocument()
  expect(remove).not.toHaveBeenCalled()
  fireEvent.click(screen.getByRole('button', { name: 'Forget' }))
  fireEvent.click(within(screen.getByRole('alertdialog')).getByRole('button', { name: 'Forget note' }))
  await waitFor(() => expect(screen.queryByText('Gentle mornings')).not.toBeInTheDocument())
  expect(remove).toHaveBeenCalledTimes(1)
})
it('uses the canonical read when the delete response is lost', async () => {
  let removed = false
  render(
    <MemoryControls
      api={createFakeApi({
        listMemories: async () => ({
          memories: removed ? [] : [{ id: 'n', note: 'Gentle mornings', createdAt: '2026-09-08' }],
        }),
        deleteMemory: async () => {
          removed = true
          throw new Error('lost response')
        },
      })}
      onClose={vi.fn()}
      onSessionExpired={vi.fn()}
    />,
  )
  fireEvent.click(await screen.findByRole('button', { name: 'Forget' }))
  fireEvent.click(screen.getByRole('button', { name: 'Forget note' }))
  expect(await screen.findByText('Note forgotten.')).toBeInTheDocument()
  expect(screen.queryByRole('alert')).not.toBeInTheDocument()
})
it('aborts a pending read on unmount and ignores late authentication errors', async () => {
  let signal: AbortSignal | undefined
  let reject!: (error: unknown) => void
  const expired = vi.fn()
  const view = render(
    <MemoryControls
      api={createFakeApi({
        listMemories: async (s) => {
          signal = s
          return await new Promise((_, r) => {
            reject = r
          })
        },
      })}
      onClose={vi.fn()}
      onSessionExpired={expired}
    />,
  )
  view.unmount()
  expect(signal?.aborted).toBe(true)
  reject(new Error('late result'))
  await Promise.resolve()
  expect(expired).not.toHaveBeenCalled()
})
