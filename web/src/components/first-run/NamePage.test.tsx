import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { NAME_PAGE_HEADLINE, NAME_PAGE_LINE, NamePage } from './NamePage'

function deferred() {
  let resolve!: () => void
  let reject!: (error: Error) => void
  const promise = new Promise<void>((done, fail) => { resolve = done; reject = fail })
  return { promise, resolve, reject }
}

const field = () => screen.getByRole('textbox', { name: 'Your name' })
const type = (value: string) => fireEvent.change(field(), { target: { value, selectionEnd: value.length } })
const continueButton = () => screen.getByRole('button', { name: 'Continue' })

function renderPage(overrides: Partial<Parameters<typeof NamePage>[0]> = {}) {
  const props = {
    saveName: vi.fn(async () => undefined),
    onSaved: vi.fn(),
    onSkip: vi.fn(),
    ...overrides,
  }
  render(<NamePage {...props} />)
  return props
}

describe('What should we call you?', () => {
  afterEach(cleanup)

  it('carries the approved copy on the sign-in image, with no back and no autofocus', () => {
    renderPage()

    expect(screen.getByRole('heading', { level: 1, name: NAME_PAGE_HEADLINE })).toBeInTheDocument()
    expect(NAME_PAGE_HEADLINE).toBe('What should we call you?')
    expect(screen.getByText('It shows in Settings, and the DJ may use it now and then.')).toBeInTheDocument()
    expect(NAME_PAGE_LINE).toBe('It shows in Settings, and the DJ may use it now and then.')
    expect(screen.getByRole('main')).toHaveAttribute('data-background', 'sign-in')
    expect(field()).toHaveAttribute('placeholder', 'Your name')
    expect(field()).toHaveAttribute('autocomplete', 'name')
    expect(screen.queryByRole('button', { name: 'Back' })).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Skip' })).toBeInTheDocument()
    // Focus goes to the heading, never the field.
    expect(field()).not.toHaveFocus()
    expect(screen.getByRole('heading', { level: 1 })).toHaveFocus()
  })

  it('names the document while shown and restores the title after', () => {
    document.title = 'Mixtape'
    renderPage()
    expect(document.title).toBe('What should we call you?')
    cleanup()
    expect(document.title).toBe('Mixtape')
  })

  it('keeps Continue focusable but dimmed until the normalised name is not empty', () => {
    const { saveName } = renderPage()
    const next = continueButton()
    expect(next).toBeEnabled()
    expect(next).toHaveAttribute('aria-disabled', 'true')
    expect(next).toHaveAccessibleDescription('Type a name.')
    expect(next.querySelector('.fr-ff--hollow')).not.toBeNull()

    type('   ')
    expect(next).toHaveAttribute('aria-disabled', 'true')
    fireEvent.click(next)
    fireEvent.submit(field().closest('form')!)
    expect(saveName).not.toHaveBeenCalled()

    type('Ada')
    expect(next).not.toHaveAttribute('aria-disabled')
    expect(next).not.toHaveAccessibleDescription()
    expect(next.querySelector('.fr-ff--hollow')).toBeNull()
  })

  it('saves the normalised name on Continue, shows Saving, then moves on', async () => {
    const save = deferred()
    const { saveName, onSaved } = renderPage({ saveName: vi.fn(() => save.promise) })
    type('  Ada   Okafor ')
    fireEvent.click(continueButton())

    expect(saveName).toHaveBeenCalledWith('Ada Okafor')
    const pill = screen.getByRole('button', { name: /Saving/ })
    expect(pill).toHaveAttribute('aria-busy', 'true')
    expect(field()).toHaveAttribute('readonly')
    expect(screen.getByRole('button', { name: 'Skip' })).toBeEnabled()

    fireEvent.click(pill)
    expect(saveName).toHaveBeenCalledOnce()

    await act(async () => save.resolve())
    expect(onSaved).toHaveBeenCalledOnce()
  })

  it('saves on Enter, but blocks the Enter that ends an IME composition', () => {
    const { saveName } = renderPage()
    type('Ada')
    // fireEvent returns false when the handler prevented the default (the form's submit).
    expect(fireEvent.keyDown(field(), { key: 'Enter', isComposing: true })).toBe(false)
    expect(fireEvent.keyDown(field(), { key: 'Enter', keyCode: 229 })).toBe(false)
    fireEvent.compositionStart(field())
    expect(fireEvent.keyDown(field(), { key: 'Enter' })).toBe(false)
    fireEvent.compositionEnd(field(), { target: { value: 'Ada', selectionEnd: 3 } })
    expect(fireEvent.keyDown(field(), { key: 'Enter' })).toBe(true)
    expect(saveName).not.toHaveBeenCalled()
    fireEvent.submit(field().closest('form')!)
    expect(saveName).toHaveBeenCalledWith('Ada')
  })

  it('keeps the text on failure, says so as an alert and offers Retry with focus on it', async () => {
    const save = deferred()
    const saveName = vi.fn(() => save.promise)
    const { onSaved } = renderPage({ saveName })
    type('Ada Okafor')
    fireEvent.click(continueButton())
    await act(async () => save.reject(new Error('offline')))

    expect(screen.getByRole('alert')).toHaveTextContent('Couldn’t save your name.')
    expect(field()).toHaveValue('Ada Okafor')
    expect(field()).toHaveAttribute('aria-invalid', 'true')
    expect(field()).not.toHaveAttribute('readonly')
    const retry = screen.getByRole('button', { name: 'Retry' })
    await waitFor(() => expect(retry).toHaveFocus())
    expect(onSaved).not.toHaveBeenCalled()

    saveName.mockResolvedValueOnce(undefined)
    fireEvent.click(retry)
    expect(saveName).toHaveBeenCalledTimes(2)
    await waitFor(() => expect(onSaved).toHaveBeenCalledOnce())
  })

  it('returns to Continue once the text is edited after a failure', async () => {
    renderPage({ saveName: vi.fn(async () => { throw new Error('offline') }) })
    type('Ada')
    fireEvent.click(continueButton())
    await screen.findByRole('button', { name: 'Retry' })
    type('Adaeze')
    expect(continueButton()).toBeInTheDocument()
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  })

  it('Skip moves on without saving, even while a save is running', () => {
    const { onSkip, saveName } = renderPage({ saveName: vi.fn(() => new Promise<void>(() => {})) })
    fireEvent.click(screen.getByRole('button', { name: 'Skip' }))
    expect(onSkip).toHaveBeenCalledOnce()
    expect(saveName).not.toHaveBeenCalled()

    cleanup()
    const second = renderPage({ saveName: vi.fn(() => new Promise<void>(() => {})) })
    type('Ada')
    fireEvent.click(continueButton())
    fireEvent.click(screen.getByRole('button', { name: 'Skip' }))
    expect(second.onSkip).toHaveBeenCalledOnce()
  })

  it('stops at 40 characters, counts from 30 and says why a paste was cut', () => {
    renderPage()
    type('a'.repeat(29))
    expect(screen.queryByText(/of 40/)).not.toBeInTheDocument()
    type('a'.repeat(30))
    expect(screen.getByText('30 of 40')).toBeInTheDocument()

    type('Oluwaseun Adaeze Okafor-Whitfield Balogun')
    expect(field()).toHaveValue('Oluwaseun Adaeze Okafor-Whitfield Balogu')
    expect(screen.getByText('40 of 40')).toBeInTheDocument()
    expect(screen.getByText('Names stop at 40 characters.')).toBeInTheDocument()
    expect(field()).toHaveAccessibleDescription(/40 of 40/)
  })

  it('applies the limit when an IME composition ends', () => {
    renderPage()
    type('a'.repeat(38))
    fireEvent.compositionStart(field())
    fireEvent.change(field(), { target: { value: `${'a'.repeat(38)}あいう` } })
    expect(field()).toHaveValue(`${'a'.repeat(38)}あいう`)
    fireEvent.compositionEnd(field(), { target: { value: `${'a'.repeat(38)}あいう`, selectionEnd: 41 } })
    expect(field()).toHaveValue(`${'a'.repeat(38)}あい`)
  })

  it('opens in a preview state when asked', () => {
    renderPage({ initial: { draft: 'Ada Okafor', failed: true } })
    expect(field()).toHaveValue('Ada Okafor')
    expect(screen.getByRole('alert')).toHaveTextContent('Couldn’t save your name.')
    expect(screen.getByRole('button', { name: 'Retry' })).toBeInTheDocument()
  })
})
