import {
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor,
} from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { RoutineSuggestions } from './RoutineSuggestions'
import { createFakeApi } from '../test/fake-api'
afterEach(cleanup)
const suggestion = {
  id: '5-3-fall',
  title: 'Ease into a slower pace.',
  prompt: 'Make a mix that gradually winds down.',
  reason: 'You have made winding-down mixes on 3 Friday evenings.',
}
it('generates only after a tap and a fresh server check, then dismisses the suggestion', async () => {
  const onCreate = vi.fn().mockResolvedValue(undefined)
  const select = vi.fn().mockResolvedValue({ prompt: suggestion.prompt })
  const dismiss = vi.fn().mockResolvedValue({ ok: true })
  const api = createFakeApi({
    getSuggestions: async () => ({
      enabled: true,
      suggestion,
      dismissed: false,
    }),
    selectSuggestion: select,
    dismissSuggestion: dismiss,
  })
  render(<RoutineSuggestions api={api} onCreate={onCreate} />)
  await screen.findByText(suggestion.title)
  expect(onCreate).not.toHaveBeenCalled()
  fireEvent.click(screen.getByRole('button', { name: 'Make this mix' }))
  await waitFor(() => expect(onCreate).toHaveBeenCalledWith(suggestion.prompt))
  fireEvent.click(screen.getByRole('button', { name: 'Not today' }))
  await waitFor(() => expect(screen.queryByText(suggestion.title)).not.toBeInTheDocument())
  expect(dismiss).toHaveBeenCalledTimes(1)
  expect(screen.queryByRole('checkbox')).not.toBeInTheDocument()
})
it('does not generate an expired suggestion and exposes retry on network failure', async () => {
  const onCreate = vi.fn()
  const api = createFakeApi({
    getSuggestions: async () => ({
      enabled: true,
      suggestion,
      dismissed: false,
    }),
    selectSuggestion: async () => {
      throw new Error('expired')
    },
  })
  render(<RoutineSuggestions api={api} onCreate={onCreate} />)
  fireEvent.click(await screen.findByRole('button', { name: 'Make this mix' }))
  await screen.findByRole('alert')
  expect(onCreate).not.toHaveBeenCalled()
})
it('ignores a selection completed after leaving the account surface', async () => {
  let resolve!: (value: { prompt: string }) => void
  const onCreate = vi.fn()
  const api = createFakeApi({
    getSuggestions: async () => ({
      enabled: true,
      suggestion,
      dismissed: false,
    }),
    selectSuggestion: () =>
      new Promise((done) => {
        resolve = done
      }),
  })
  const view = render(<RoutineSuggestions api={api} onCreate={onCreate} />)
  fireEvent.click(await screen.findByRole('button', { name: 'Make this mix' }))
  view.unmount()
  resolve({ prompt: suggestion.prompt })
  await Promise.resolve()
  expect(onCreate).not.toHaveBeenCalled()
})
it('does not start another mix when manual creation begins during validation', async () => {
  let resolve!: (value: { prompt: string }) => void
  const onCreate = vi.fn()
  const api = createFakeApi({
    getSuggestions: async () => ({
      enabled: true,
      suggestion,
      dismissed: false,
    }),
    selectSuggestion: () =>
      new Promise((done) => {
        resolve = done
      }),
  })
  const view = render(<RoutineSuggestions api={api} onCreate={onCreate} />)
  fireEvent.click(await screen.findByRole('button', { name: 'Make this mix' }))
  view.rerender(<RoutineSuggestions api={api} onCreate={onCreate} busy />)
  resolve({ prompt: suggestion.prompt })
  await waitFor(() =>
    expect(
      screen.getByRole('button', { name: 'Making your mix…' }),
    ).toBeDisabled(),
  )
  expect(onCreate).not.toHaveBeenCalled()
})

it('leaves no empty recommendation section when no routine is available', async () => {
  render(<RoutineSuggestions api={createFakeApi()} onCreate={vi.fn()} />)
  await waitFor(() => expect(screen.queryByRole('region', { name: 'Routine suggestions' })).not.toBeInTheDocument())
  expect(screen.queryByText('Checking your usual moments…')).not.toBeInTheDocument()
})

it('recovers a failed read without starting a mix', async () => {
  const onCreate = vi.fn()
  const getSuggestions = vi.fn()
    .mockRejectedValueOnce(new Error('offline'))
    .mockResolvedValueOnce({ enabled: true, suggestion, dismissed: false })
  render(<RoutineSuggestions api={createFakeApi({ getSuggestions })} onCreate={onCreate} />)
  await screen.findByRole('alert')
  fireEvent.click(screen.getByRole('button', { name: 'Refresh suggestions' }))
  await screen.findByText(suggestion.title)
  expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  expect(onCreate).not.toHaveBeenCalled()
})
