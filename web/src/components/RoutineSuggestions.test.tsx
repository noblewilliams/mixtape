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
it('generates only after a tap and a fresh server check; dismisses and saves off', async () => {
  const onCreate = vi.fn().mockResolvedValue(undefined)
  const select = vi.fn().mockResolvedValue({ prompt: suggestion.prompt })
  const dismiss = vi.fn().mockResolvedValue({ ok: true })
  const save = vi.fn().mockResolvedValue({ enabled: false })
  const api = createFakeApi({
    getSuggestions: async () => ({
      enabled: true,
      suggestion,
      dismissed: false,
    }),
    selectSuggestion: select,
    dismissSuggestion: dismiss,
    saveSuggestionPreference: save,
  })
  render(<RoutineSuggestions api={api} onCreate={onCreate} />)
  await screen.findByText(suggestion.title)
  expect(onCreate).not.toHaveBeenCalled()
  fireEvent.click(screen.getByRole('button', { name: 'Make this mix' }))
  await waitFor(() => expect(onCreate).toHaveBeenCalledWith(suggestion.prompt))
  fireEvent.click(screen.getByRole('button', { name: 'Not today' }))
  await screen.findByText('That suggestion is hidden for today.')
  expect(dismiss).toHaveBeenCalledTimes(1)
  fireEvent.click(screen.getByRole('button', { name: 'Suggestion settings' }))
  fireEvent.click(screen.getByRole('checkbox'))
  fireEvent.click(screen.getByRole('button', { name: 'Save' }))
  await waitFor(() => expect(save).toHaveBeenCalledWith(false))
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
it('keeps settings open on save failure and keeps the previous preference', async () => {
  const api = createFakeApi({
    getSuggestions: async () => ({
      enabled: true,
      suggestion,
      dismissed: false,
    }),
    saveSuggestionPreference: async () => {
      throw new Error('offline')
    },
  })
  render(<RoutineSuggestions api={api} onCreate={vi.fn()} />)
  await screen.findByText(suggestion.title)
  fireEvent.click(screen.getByRole('button', { name: 'Suggestion settings' }))
  fireEvent.click(screen.getByRole('checkbox'))
  fireEvent.click(screen.getByRole('button', { name: 'Save' }))
  await waitFor(() =>
    expect(screen.getAllByRole('alert').length).toBeGreaterThan(0),
  )
  expect(screen.getByRole('dialog')).toBeInTheDocument()
  fireEvent.click(screen.getByRole('button', { name: 'Cancel' }))
  expect(screen.getByText(suggestion.title)).toBeInTheDocument()
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
